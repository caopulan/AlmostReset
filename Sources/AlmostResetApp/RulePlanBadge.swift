import SwiftUI
import AlmostResetCore

struct RulePlanBadge: View {
    @EnvironmentObject var app: AppModel
    @State private var presented = false
    @State private var hovered = false
    @State private var popupHovered = false
    @State private var hoverTask: Task<Void, Never>?
    private var plan: [PlannedSessionAction] {
        let active = RuleInspection.sessions(for: .sessions(app.sessions.map(\.id)), in: app.sessions)
        return RuleEngine.plan(rules: app.rules, sessions: active)
    }
    var body: some View {
        Button { presented.toggle() } label: {
            Label(LF("%d sessions", plan.count), systemImage: "rectangle.stack")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: Capsule())
        }.buttonStyle(.plain)
            .onHover { inside in hovered = inside; scheduleHover(open: inside) }
            .popover(isPresented: $presented, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(LF("%d sessions", plan.count)).font(.headline)
                    if plan.isEmpty { Text(L("No matching sessions")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12) }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(plan) { item in
                                    VStack(alignment: .leading, spacing: 9) {
                                        HStack {
                                            Label(item.session.projectName, systemImage: "folder")
                                            Spacer()
                                            Text(item.ruleName)
                                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                                        HStack(alignment: .top) {
                                            Text(item.session.title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                            Spacer()
                                            Text(L(item.session.status.rawValue.capitalized)).font(.system(size: 10)).foregroundStyle(item.session.status.tint)
                                        }
                                        if let reason = item.unavailableReason {
                                            Text(L("Cannot apply") + " · " + localizedMessage(reason)).font(.system(size: 11)).foregroundStyle(.orange)
                                        } else if case .stop = item.action {
                                            Label(L("Will stop"), systemImage: "stop.fill").font(.system(size: 11)).foregroundStyle(.red)
                                        } else if case .continueSession(let settings) = item.action {
                                            Text(configuration(item.session.model, item.session.reasoning, item.session.speed))
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                            Label(configuration(settings.model ?? item.session.model, settings.reasoning ?? item.session.reasoning, settings.speed ?? item.session.speed), systemImage: "arrow.turn.down.right")
                                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accent)
                                            Text("“" + settings.effectivePrompt + "”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }.padding(.vertical, 14)
                                    Divider()
                                }
                            }
                        }.frame(height: min(440, CGFloat(plan.count) * 160))
                    }
                }.padding(18).frame(width: 430).background(Color.canvas)
                    .onHover { inside in popupHovered = inside; if inside { hoverTask?.cancel() } else { scheduleHover(open: false) } }
            }
            .onChange(of: presented) { _, open in
                if open, Date().timeIntervalSince(app.lastRefresh ?? .distantPast) > 15 { Task { await app.refresh() } }
                if !open { popupHovered = false }
            }
            .onDisappear { hoverTask?.cancel() }
    }
    private func configuration(_ model: String?, _ reasoning: ReasoningEffort?, _ speed: SessionSpeed?) -> String {
        [model ?? "—", reasoning?.rawValue ?? "—", speed?.displayTitle ?? "—"].joined(separator: " · ")
    }
    private func scheduleHover(open: Bool) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(open ? 180 : 280)) } catch { return }
            if open && hovered { presented = true }
            if !open && !hovered && !popupHovered { presented = false }
        }
    }
}
