import SwiftUI
import AlmostResetCore

struct ActivityView: View {
    @EnvironmentObject var app: AppModel
    @State private var failuresOnly = false
    private var groups: [(String, [AutomationLogEntry])] {
        Dictionary(grouping: app.logs, by: { $0.eventID?.uuidString ?? $0.id.uuidString })
            .filter { !failuresOnly || $0.value.contains { $0.kind == .failed || $0.kind == .skipped } || (!unfinished($0.value).isEmpty && $0.value.first?.eventID != app.activeEventID) }
            .sorted { ($0.value.last?.date ?? .distantPast) > ($1.value.last?.date ?? .distantPast) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(L("Activity")).font(.system(size: 27, weight: .semibold))
                Spacer()
                Picker(L("Events"), selection: $failuresOnly) {
                    Text(L("All events")).tag(false); Text(L("Needs attention")).tag(true)
                }.labelsHidden().frame(width: 155)
            }
            if groups.isEmpty { EmptyPanel(symbol: "clock", title: failuresOnly ? "Nothing needs attention" : "No activity yet") }
            else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(groups, id: \.0) { _, entries in
                            Panel {
                                VStack(alignment: .leading, spacing: 0) {
                                    let header = entries.first(where: { $0.kind == .reset }) ?? entries[0]
                                    HStack(alignment: .top) {
                                        Image(systemName: header.kind == .reset ? "arrow.clockwise" : "info.circle").foregroundStyle(Color.accent)
                                        Text(localizedMessage(header.message)).font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text(header.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }.padding(18)
                                    let outcomes = entries.filter { $0.kind != .reset && $0.kind != .planned && $0.id != header.id }
                                    ForEach(outcomes) { entry in
                                        Divider()
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: entry.kind == .info ? "info.circle" : entry.kind == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                                .foregroundStyle(entry.kind == .info ? Color.secondary : entry.kind == .succeeded ? Color.green : Color.orange)
                                            Text(localizedMessage(entry.message)).font(.system(size: 12)).textSelection(.enabled)
                                            Spacer(minLength: 12)
                                            Text(entry.date.formatted(date: .omitted, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                        }.padding(16)
                                    }
                                    let pending = unfinished(entries)
                                    if !pending.isEmpty {
                                        Divider()
                                        Label(header.eventID == app.activeEventID ? LF("Applying %d remaining actions…", pending.count) : LF("%d actions unfinished. Inspect sessions before retrying.", pending.count), systemImage: "clock")
                                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
                                        ForEach(pending) { entry in
                                            Text(localizedMessage(entry.message)).font(.system(size: 11)).foregroundStyle(.secondary)
                                                .padding(.horizontal, 16).padding(.bottom, 12)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func unfinished(_ entries: [AutomationLogEntry]) -> [AutomationLogEntry] {
        entries.filter { planned in
            planned.kind == .planned && !entries.contains { outcome in
                outcome.sessionID == planned.sessionID && [.succeeded, .failed, .skipped].contains(outcome.kind)
            }
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject var app: AppModel
    private var checking: Bool { app.isRefreshing || app.isReconnecting }
    private var connectionTitle: String {
        if checking { return L("Checking Codex…") }
        if app.resolvedCLIPath == nil { return L("Codex not found") }
        if app.connection.isControllable { return L("Codex connected") }
        return L(app.connection.status == .readOnly ? "Codex found · usage only" : "Connection failed")
    }
    private var connectionHelp: String {
        if checking { return L("Checking the executable and local connection") }
        if app.resolvedCLIPath == nil { return L("Choose the Codex executable to connect") }
        if app.connection.status == .readOnly { return L("Path found. Open Codex Desktop to control sessions.") }
        if app.connection.status == .disconnected { return L("Path found. Recheck the connection; no need to select it again.") }
        return L(app.cliPath.isEmpty ? "Automatically detected · no selection needed" : "Using your selected executable")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("Settings")).font(.system(size: 27, weight: .semibold))
                .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            ScrollView {
                VStack(spacing: 18) {
                    Panel {
                        VStack(spacing: 22) {
                            settingRow("Language") {
                                Picker(L("Language"), selection: $app.language) {
                                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                            settingRow("Check interval") {
                                ChoicePicker(value: $app.pollInterval, options: [(15, L("15 seconds")), (30, L("30 seconds")), (60, L("1 minute")), (120, L("2 minutes"))])
                            }
                            settingRow("Launch at login") {
                                Toggle(L("Launch at login"), isOn: Binding(get: { app.launchAtLogin }, set: app.setLaunchAtLogin))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                        }.padding(26)
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top, spacing: 12) {
                                if checking { ProgressView().controlSize(.small).frame(width: 20) }
                                else {
                                    Image(systemName: app.connection.isControllable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .font(.system(size: 18)).foregroundStyle(app.connection.isControllable ? Color.green : Color.orange)
                                }
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(connectionTitle).font(.system(size: 14, weight: .semibold))
                                    Text(connectionHelp).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            if let path = app.resolvedCLIPath {
                                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Color.canvas, in: RoundedRectangle(cornerRadius: 8))
                            } else if !app.cliPath.isEmpty {
                                Text(app.cliPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            if app.connection.status == .disconnected, let error = app.errorMessage, !checking {
                                Text(localizedMessage(error)).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                            }
                            HStack(spacing: 14) {
                                Button(L(app.resolvedCLIPath == nil ? "Choose path…" : "Choose manually…"), action: chooseCLI)
                                if !app.cliPath.isEmpty {
                                    Button(L("Use automatic detection")) { Task { await app.useAutomaticCLI() } }.buttonStyle(.plain).foregroundStyle(Color.accent)
                                }
                                Spacer()
                                Button(L("Check again")) { Task { await app.reconnect() } }
                            }.disabled(checking || app.isExecuting)
                        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
        }.onChange(of: app.pollInterval) { _, _ in app.updatePreferences() }
    }
    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 22) {
            Text(L(title)).font(.system(size: 13)).frame(width: 120, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func chooseCLI() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = L("Choose the Codex executable")
        if panel.runModal() == .OK, let url = panel.url { app.cliPath = url.path; Task { await app.reconnect() } }
    }
}

struct ChoicePicker<Value: Hashable>: View {
    @Binding var value: Value
    var options: [(Value, String)]
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack {
                Text(options.first { $0.0 == value }?.1 ?? "—").lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.line))
        }.buttonStyle(.plain)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(options, id: \.0) { option, title in
                            Button { value = option; expanded = false } label: {
                                HStack {
                                    Text(title).lineLimit(2)
                                    Spacer()
                                    if value == option { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                                }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(6)
                }.frame(width: 270, height: min(330, CGFloat(options.count) * 36 + 12))
            }
    }
}
