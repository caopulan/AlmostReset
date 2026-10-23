import Foundation
import Darwin
import CryptoKit

/// Small, bounded transports. All reads run on CodexService's actor, never the main actor.
final class JSONTransport {
    enum Framing { case lines, lengthPrefix, webSocket }
    private var fragmented = Data()
    private let input: Int32
    private let output: Int32
    private let framing: Framing
    private let process: Process?
    private var buffer = Data()
    private let ownedSocket: Bool
    private var closed = false

    init(executable: String, arguments: [String], home: String) throws {
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home
        // This is an independent client; never inherit a desktop's tool pipe identity.
        for key in ["CODEX_APP_TOOLS_PIPE_PATH", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CODEX_CLI_PATH"] { env.removeValue(forKey: key) }
        p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        input = stdout.fileHandleForReading.fileDescriptor; output = stdin.fileHandleForWriting.fileDescriptor
        process = p; framing = .lines; ownedSocket = false
        retainedHandles = [stdin.fileHandleForWriting, stdout.fileHandleForReading]
        _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }
    private var retainedHandles: [FileHandle] = []

    init(socketPath: String, webSocket: Bool = false) throws {
        var info = stat()
        guard stat(socketPath, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw CodexError.unavailable("Codex Desktop's local socket is unavailable or is not owned by this user.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexError.unavailable("Could not open the Codex Desktop socket.") }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); throw CodexError.unavailable("The Codex socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw CodexError.unavailable("Codex Desktop is not accepting local connections (\(String(cString: strerror(errno)))).") }
        input = fd; output = fd; framing = webSocket ? .webSocket : .lengthPrefix; process = nil; ownedSocket = true
        if webSocket { try handshake() }
    }

    deinit { close() }
    func close() {
        guard !closed else { return }; closed = true
        if ownedSocket { Darwin.close(input) }
        else {
            for handle in retainedHandles { try? handle.close() }
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        switch framing {
        case .lines: data.append(10)
        case .webSocket: data = webSocketFrame(data, opcode: 1)
        case .lengthPrefix:
            var size = UInt32(data.count).littleEndian
            let header = withUnsafeBytes(of: &size) { Data($0) }; data.insert(contentsOf: header, at: 0)
        }
        try write(data)
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(output, address.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexError.unavailable("The Codex connection closed while sending a request.") }
                offset += count
            }
        }
    }

    func receive(deadline: Date) throws -> [String: Any] {
        while true {
            if let payload = try consumeFrame() {
                guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw CodexError.protocolError("Codex returned a non-object message.")
                }
                return object
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexError.timeout("Codex did not respond before the deadline.") }
            var pollFD = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            let result = poll(&pollFD, 1, Int32(min(remaining * 1000, 30_000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                if result == 0 { continue }
                throw CodexError.unavailable("Could not read the Codex connection.")
            }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(input, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexError.unavailable("The Codex connection closed.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 268_435_456 else { throw CodexError.protocolError("Codex sent an oversized frame.") }
        }
    }

    private func webSocketFrame(_ data: Data, opcode: UInt8) -> Data {
        var result = Data([128 | opcode])
        if data.count < 126 { result.append(128 | UInt8(data.count)) }
        else if data.count <= 65_535 {
            result.append(128 | 126); result.append(UInt8((data.count >> 8) & 255)); result.append(UInt8(data.count & 255))
        } else {
            result.append(128 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((UInt64(data.count) >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        result.append(contentsOf: mask)
        result.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }

    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
        try write(Data(request.utf8))
        let deadline = Date().addingTimeInterval(10)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard deadline.timeIntervalSinceNow > 0 else { throw CodexError.timeout("App Server WebSocket handshake timed out.") }
            var item = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 1000) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(input, &bytes, bytes.count)
            guard count > 0 else { throw CodexError.unavailable("App Server closed its handshake.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count < 65_536 else { throw CodexError.protocolError("Invalid WebSocket handshake.") }
        }
        let end = buffer.range(of: Data("\r\n\r\n".utf8))!.upperBound
        let response = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeSubrange(..<end)
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard response.hasPrefix("HTTP/1.1 101"), response.lowercased().contains("sec-websocket-accept: " + accept.lowercased()) else {
            throw CodexError.protocolError("The socket did not complete an App Server WebSocket handshake.")
        }
    }

    private func consumeFrame() throws -> Data? {
        switch framing {
        case .lines:
            guard let end = buffer.firstIndex(of: 10) else { return nil }
            let payload = buffer[..<end]; buffer.removeSubrange(...end)
            if payload.isEmpty { return try consumeFrame() }
            return Data(payload)
        case .webSocket:
            guard buffer.count >= 2 else { return nil }
            let first = buffer[0], second = buffer[1], opcode = first & 15
            let final = first & 128 != 0
            var offset = 2, length = Int(second & 127)
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = Int(buffer[2]) << 8 | Int(buffer[3]); offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                let value = buffer[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard value <= 268_435_456 else { throw CodexError.protocolError("Oversized WebSocket frame.") }
                length = Int(value); offset = 10
            }
            let masked = second & 128 != 0
            let maskLength = masked ? 4 : 0
            guard buffer.count >= offset + maskLength + length else { return nil }
            let mask = masked ? Array(buffer[offset..<(offset + 4)]) : []
            offset += maskLength
            var payload = Data(buffer[offset..<(offset + length)])
            buffer.removeSubrange(0..<(offset + length))
            if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            if opcode == 8 { throw CodexError.unavailable("The App Server closed the WebSocket.") }
            if opcode == 9 { try write(webSocketFrame(payload, opcode: 10)); return try consumeFrame() }
            if opcode == 10 { return try consumeFrame() }
            guard opcode == 0 || opcode == 1 else { throw CodexError.protocolError("Unexpected App Server WebSocket frame.") }
            fragmented.append(payload)
            guard fragmented.count <= 268_435_456 else { throw CodexError.protocolError("Oversized App Server message.") }
            if final { let result = fragmented; fragmented = Data(); return result }
            return try consumeFrame()
        case .lengthPrefix:
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
            guard length > 0, length <= 268_435_456 else { throw CodexError.protocolError("Codex sent an invalid frame length.") }
            guard buffer.count >= 4 + length else { return nil }
            let payload = buffer.subdata(in: 4..<(4 + length)); buffer.removeSubrange(0..<(4 + length)); return payload
        }
    }
}

final class AppServerClient {
    private let transport: JSONTransport
    private var requestID = 0
    init(executable: String, home: String, socket: String?) throws {
        if let socket { transport = try JSONTransport(socketPath: socket, webSocket: true) }
        else { transport = try JSONTransport(executable: executable, arguments: ["app-server", "--listen", "stdio://"], home: home) }
        _ = try request("initialize", ["clientInfo": ["name": "almostreset", "title": "AlmostReset", "version": "0.1.0"],
                                      "capabilities": ["experimentalApi": true]])
        try transport.send(["method": "initialized"])
    }
    func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 20) throws -> [String: Any] {
        requestID += 1; let id = requestID
        try transport.send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let response = try transport.receive(deadline: deadline)
            guard response.number("id") == Double(id) else { continue }
            if let error = response["error"] as? [String: Any] { throw CodexError.rpc(error.string("message") ?? "Codex rejected \(method).") }
            guard let result = response["result"] as? [String: Any] else { throw CodexError.protocolError("Missing result for \(method).") }
            return result
        }
    }
}
