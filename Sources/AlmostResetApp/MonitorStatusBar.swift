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
                    HStack(spacing: 24) {
                        quotaView.frame(width: app.mainWindows.count > 1 ? 210 : 156)
                        Rectangle().fill(Color.line).frame(width: 1, height: 68)
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            impactView.frame(maxWidth: 320)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity)
                        Rectangle().fill(Color.line).frame(width: 1, height: 68)
                        VStack(spacing: 10) {
                            control
                            HStack(spacing: 12) { stateView; refreshButton }
                        }.frame(width: 156)
                    }.padding(.horizontal, 24).padding(.vertical, 22)

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
                quotaRing(window.remainingPercent, label: app.isQuotaStale ? L("Last known") : window.friendlyName == "Weekly" ? L("Weekly usage") : L(window.friendlyName) + " " + L("Usage"))
            }
        }.frame(maxWidth: .infinity)
    }
    private func quotaRing(_ percent: Double?, label: String) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.065), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, percent ?? 0))) / 100)
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(percent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.horizontal, 6)
        }.frame(width: portrait ? 88 : 84, height: portrait ? 88 : 84).padding(4)
    }
    private var impactView: some View {
        VStack(alignment: .center, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Color.red.opacity(0.65).frame(width: geo.size.width * Double(impact.stopped) / Double(max(1, impact.total)))
                    Color.teal.frame(width: geo.size.width * Double(impact.continued) / Double(max(1, impact.total)))
                    Color.primary.opacity(0.12)
                }.clipShape(Capsule())
            }.frame(height: portrait ? 8 : 6)
            HStack(spacing: 0) {
                impactMetric("Stop", impact.stopped, Color.red.opacity(0.65))
                impactMetric("Resume", impact.continued, .teal)
                impactMetric("Unaffected", impact.unaffected, .secondary.opacity(0.5))
            }
            Text(LF("%d rules · %d affected", app.rules.count, impact.affected))
                .font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .center)
        }.help(L("Running + recent 30 min") + " · " + L("In priority order"))
    }
    private func impactMetric(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)").font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(L(label)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }.frame(maxWidth: .infinity)
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
                .frame(maxWidth: portrait ? .infinity : nil).frame(width: portrait ? nil : 144, height: 36)
                .foregroundStyle(.white).background(Color.accent, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(app.isExecuting || (!app.listener.isListening && !app.canStart))
            .opacity(app.canStart || app.listener.isListening ? 1 : 0.5)
    }
}
