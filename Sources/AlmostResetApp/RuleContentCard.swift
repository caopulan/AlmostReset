import SwiftUI
import AlmostResetCore

struct RuleContentCard: View {
    @EnvironmentObject var app: AppModel
    let rule: AutomationRule
    let index: Int
    let edit: () -> Void
    let delete: () -> Void
    @State private var now = Date()
    private var matches: [Session] { RuleInspection.sessions(for: rule.selector, in: app.sessions, now: now) }
    private var reference: String { LF("Rule %d", index + 1) }
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(spacing: 11) {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(index == 0 ? Color.accent : .secondary)
                    .frame(width: 28, height: 28)
                    .background(index == 0 ? Color.accent.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }.padding(.top, 1)
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 18) {
                    selectorRows.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        RuleSessionCount(sessions: matches)
                        Toggle(L("Enabled"), isOn: Binding(get: { rule.enabled }, set: { app.toggleRule(rule.id, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(LF("Enable %@", reference))

                    }.padding(.top, 2)
                }
                HStack(spacing: 8) {
                    Image(systemName: rule.action.isStop ? "stop.fill" : "arrow.turn.down.right").font(.system(size: 10))
                        .foregroundStyle(rule.action.isStop ? Color.red.opacity(0.75) : Color.accent)
                    Text(rule.action.title).font(.system(size: 11, weight: .medium))
                    if case .continueSession(let settings) = rule.action {
                        let summary = [settings.model, settings.reasoning?.rawValue, settings.speed?.displayTitle].compactMap { $0 }.joined(separator: " · ")
                        if !summary.isEmpty { Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    Button(action: edit) { Image(systemName: "pencil").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Edit")).accessibilityLabel(L("Edit") + " " + reference)
                    Button(action: delete) { Image(systemName: "trash").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Delete")).accessibilityLabel(L("Delete") + " " + reference)
                }.padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            }
        }.padding(18)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(index == 0 && rule.enabled ? Color.accent.opacity(0.22) : Color.line))
            .opacity(rule.enabled ? 1 : 0.72)
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    @ViewBuilder private var selectorRows: some View {
        switch rule.selector {
        case .sessions(let ids):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(NSOrderedSet(array: ids).array.compactMap { $0 as? String }), id: \.self) { id in
                    let session = app.sessions.first { $0.id == id }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(session.map { $0.projectPath.isEmpty ? L("Unknown project") : $0.projectName } ?? "—")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .lineLimit(1).frame(width: 104, alignment: .leading).help(session?.projectPath ?? id)
                        Text(session.map { $0.title.isEmpty ? L("Untitled session") : $0.title } ?? (L("Unavailable session") + " · " + String(id.prefix(8))))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 3)
                }
            }
        case .conditions(let match, let conditions):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(conditions.enumerated()), id: \.element.id) { row, condition in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if conditions.count > 1 {
                            Text(row == 0 ? "" : L((condition.joinWithPrevious ?? match) == .all ? "AND" : "OR"))
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).frame(width: 22, alignment: .leading)
                        }
                        Text(L(condition.field.rawValue.capitalized)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        Text(L(condition.comparison == .moreThan ? "more than" : "is"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        Text(condition.values.map { conditionValue($0, field: condition.field) }.joined(separator: ", "))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 3)
                }
            }
        }
    }
    private func conditionValue(_ value: String, field: SessionField) -> String {
        switch field {
        case .project: return URL(fileURLWithPath: value).lastPathComponent
        case .speed: return SessionSpeed(rawValue: value)?.displayTitle ?? value
        case .status: return L(value.capitalized)
        default: return value
        }
    }
}

struct RuleSessionCount: View {
    @EnvironmentObject var app: AppModel
    var sessions: [Session]
    @State private var presented = false
    @State private var badgeHovered = false
    @State private var popupHovered = false
    @State private var hoverTask: Task<Void, Never>?
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack").font(.system(size: 10))
                Text(LF("%d sessions", sessions.count)).font(.system(size: 11, weight: .medium))
            }.foregroundStyle(presented ? Color.accent : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.primary.opacity(0.035), in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain)
            .onHover { inside in
                badgeHovered = inside
                hoverTask?.cancel()
                if inside {
                    hoverTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                        if badgeHovered { presented = true }
                    }
                } else { closeAfterHover() }
            }
            .popover(isPresented: $presented, arrowEdge: .leading) {
                RuleMatchPopover(sessions: sessions)
                    .onHover { inside in popupHovered = inside; if inside { hoverTask?.cancel() } else { closeAfterHover() } }
            }
            .onChange(of: presented) { _, open in
                if open, Date().timeIntervalSince(app.lastRefresh ?? .distantPast) > 15 {
                    Task { await app.refresh() }
                }
                if !open { popupHovered = false }
            }
            .onDisappear { hoverTask?.cancel() }
            .accessibilityLabel(LF("%d sessions", sessions.count))
    }
    private func closeAfterHover() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            if !badgeHovered && !popupHovered { presented = false }
        }
    }
}

struct RuleMatchPopover: View {
    @EnvironmentObject var app: AppModel
    let sessions: [Session]
    private var groups: [(String, [Session])] { Dictionary(grouping: sessions, by: \.projectPath).sorted { $0.key < $1.key } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LF("%d sessions", sessions.count)).font(.system(size: 14, weight: .semibold))
                Spacer()
                if app.isRefreshing { ProgressView().controlSize(.small) }
            }
            Text(L("Running + recent 30 min")).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            if sessions.isEmpty { Text(L("No matching sessions")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 14) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(groups, id: \.0) { project, rows in
                            VStack(alignment: .leading, spacing: 9) {
                                Label(project.isEmpty ? L("Unknown project") : URL(fileURLWithPath: project).lastPathComponent, systemImage: "folder")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).help(project)
                                ForEach(rows) { session in
                                    HStack(alignment: .top, spacing: 9) {
                                        Circle().fill(session.status.tint).frame(width: 6, height: 6).padding(.top, 5)
                                        Text(session.title.isEmpty ? L("Untitled session") : session.title)
                                            .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text(L(session.status.rawValue.capitalized)).foregroundStyle(session.status.tint)
                                            if session.status != .running {
                                                TimelineView(.periodic(from: .now, by: 15)) { context in
                                                    let minutes = max(0, Int(context.date.timeIntervalSince(session.updatedAt) / 60))
                                                    Text(minutes == 0 ? L("Just now") : LF("%d min ago", minutes)).foregroundStyle(.secondary)
                                                }
                                            }
                                        }.font(.system(size: 10)).frame(minWidth: 48, alignment: .trailing)
                                    }.padding(.leading, 3)
                                }
                            }
                        }
                    }.padding(.vertical, 2)
                }.frame(height: min(330, CGFloat(sessions.count) * 49 + CGFloat(groups.count) * 28))
            }
        }.padding(18).frame(width: 390).background(Color.canvas)
    }
}
