import SwiftUI
import AlmostResetCore

struct MonitorStatusBar: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    private var title: String {
        switch app.listener.phase {
        case .idle: return L(app.isRefreshing && app.quota == nil ? "Reading usage…" : "Ready to start")
        case .preparing: return L("Preparing listener")
        case .listening: return L(app.connection.status != .disconnected && app.quota != nil ? "Waiting for reset" : "Waiting for connection")
        case .executing: return L("Applying rules…")
        case .completed: return app.runFailed == 0 ? L("Run complete") : L("Completed with issues")
        }
    }
    private var stateColor: Color {
        if app.listener.phase == .completed { return app.runFailed == 0 ? .green : .orange }
        return app.listener.isListening || app.isExecuting ? .accent : .secondary
    }
    var portrait = false
    private var impact: RuleImpact { RuleImpact(rules: app.rules, sessions: app.sessions) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            Panel {
                if portrait {
                    VStack(spacing: 18) {
                        HStack(alignment: .center, spacing: 18) {
                            quotaView.frame(maxWidth: .infinity)
                            VStack(spacing: 9) {
                                control
                                stateView
                                HStack(spacing: 16) {
                                    Button { app.page = .rules; openWindow(id: "main"); showMainWindow() } label: {
                                        Image(systemName: "square.grid.2x2").font(.system(size: 12)).frame(width: 22, height: 22)
                                    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Dashboard")).help(L("Dashboard"))
                                    refreshButton
                                }
                            }.frame(width: 126)
                        }
                        Divider()
                        impactView
                    }.padding(22).frame(width: app.mainWindows.count > 1 ? 420 : 320)
                } else {
                    HStack(spacing: 22) {
                        quotaView.frame(width: app.mainWindows.count > 1 ? 290 : 240)
                        Rectangle().fill(Color.line).frame(width: 1, height: 66)
                        impactView.frame(maxWidth: .infinity)
                        Rectangle().fill(Color.line).frame(width: 1, height: 66)
                        VStack(alignment: .center, spacing: 9) { control; stateView }
                            .padding(.trailing, 18)
                    }.padding(20)
                        .overlay(alignment: .bottomTrailing) { refreshButton.padding(.trailing, 9).padding(.bottom, 20) }
                }
            }
        }.task { if portrait { await app.refresh() } }
    }
    private var refreshButton: some View {
        Button { Task { await app.refresh() } } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(app.isRefreshing || app.isExecuting).accessibilityLabel(L("Refresh"))
    }
    private var quotaView: some View {
        HStack(spacing: 18) {
            if app.mainWindows.isEmpty { quotaRing(nil, label: L("Usage unavailable")) }
            ForEach(Array(app.mainWindows.prefix(2))) { window in
                quotaRing(window.remainingPercent, label: window.friendlyName == "Weekly" ? L("Weekly usage") : L(window.friendlyName) + " " + L("Usage"))
            }
        }.frame(maxWidth: .infinity)
    }
    private func quotaRing(_ percent: Double?, label: String) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.065), lineWidth: 7)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, percent ?? 0))) / 100)
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(percent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.horizontal, 6)
        }.frame(width: 88, height: 88).padding(4)
    }
    private var impactView: some View {
        VStack(alignment: portrait ? .center : .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.red.opacity(0.65).frame(width: geo.size.width * Double(impact.stopped) / Double(max(1, impact.total)))
                    Color.teal.frame(width: geo.size.width * Double(impact.continued) / Double(max(1, impact.total)))
                    Color.primary.opacity(0.12)
                }.clipShape(Capsule())
            }.frame(height: portrait ? 12 : 7)
            HStack(spacing: 10) {
                legend("Stop", impact.stopped, .red.opacity(0.65))
                legend("Resume", impact.continued, .teal)
                legend("Unaffected", impact.unaffected, .secondary.opacity(0.5))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: portrait ? .center : .leading)
            Text(LF("%d rules · %d affected", app.rules.count, impact.affected))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: portrait ? .center : .leading)
        }.help(L("Running + recent 30 min") + " · " + L("In priority order"))
    }
    private func legend(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(L(label) + " \(count)").lineLimit(1) }
    }
    private var stateView: some View {
        VStack(alignment: .center, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Group {
                if let date = app.lastUsageAndSessionsRefresh {
                    Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                        .help(L("Usage and sessions refreshed") + " · " + date.formatted(date: .abbreviated, time: .standard))
                } else { Text("—:—:—").help(L("Not refreshed yet")) }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .accessibilityLabel(L("Usage and sessions refreshed"))
        }
    }
    private var control: some View {
        Button {
            if app.listener.isListening { app.stopListening() } else { app.startListening() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: app.listener.isListening ? "stop.fill" : "play.fill")
                Text(L(app.isExecuting ? "Executing" : app.listener.isListening ? "Stop listening" : "Start"))
            }.font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: portrait ? .infinity : nil).frame(width: portrait ? nil : 126, height: 42)
                .foregroundStyle(.white).background(Color.accent, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(app.isExecuting || (!app.listener.isListening && !app.canStart))
            .opacity(app.canStart || app.listener.isListening ? 1 : 0.5)
    }
}
