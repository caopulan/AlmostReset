import SwiftUI
import AlmostResetCore

extension SessionSpeed {
    var displayTitle: String { L(self == .normal ? "Standard" : rawValue.capitalized) }
}
extension SessionStatus {
    var tint: Color {
        switch self { case .running: return .green; case .waiting: return .orange; case .idle, .completed: return .secondary; case .unknown: return .secondary }
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search sessions or paste a link"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L(placeholder), text: $text).textFieldStyle(.plain)
                .accessibilityLabel(L(placeholder))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel(L("Clear search"))
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line))
    }
}

struct SessionsView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var runningOnly = false
    @State private var clock = Date()
    @State private var selection = Set<String>()
    @State private var showEditor = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L("Sessions")).font(.system(size: 27, weight: .semibold))
                Spacer()
                Text(LF("%d running", app.runningSessions.count)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                SearchField(text: $query)
                Picker(L("Session state"), selection: $runningOnly) {
                    Text(L("Running")).tag(true); Text(L("Running + recent 30 min")).tag(false)
                }.labelsHidden().frame(width: 220)
                Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .controlSize(.large).disabled(app.isRefreshing).accessibilityLabel(L("Refresh sessions"))
            }
            if app.filteredSessions(query: query, runningOnly: runningOnly, now: clock).isEmpty {
                EmptyPanel(symbol: "rectangle.stack", title: app.isRefreshing ? "Loading sessions…" : (query.isEmpty ? "No eligible sessions" : "No sessions found"))
            } else {
                SessionTable(sessions: app.filteredSessions(query: query, runningOnly: runningOnly, now: clock), selection: $selection, showsActivity: true)
            }
            HStack {
                Text(LF("%d selected", selection.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                if !selection.isEmpty { Button(L("Clear")) { selection.removeAll() }.buttonStyle(.plain).foregroundStyle(Color.accent) }
                Spacer()
                Button { showEditor = true } label: { Label(L("Create rule"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).controlSize(.large).disabled(selection.isEmpty)
            }
        }
        .task { await app.refresh() }
        .sheet(isPresented: $showEditor) { RuleEditor(kind: .sessions, selected: selection).environmentObject(app) }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { clock = $0 }
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if (try? SessionReference.sessionID(from: query)) != nil {
                runningOnly = false
                await app.resolveSession(query)
            } else { await app.searchSessions(query) }
        }
    }
}

struct SessionTable: View {
    var sessions: [Session]
    @Binding var selection: Set<String>
    var compact = false
    var allowsSelection = true
    var showsActivity = false
    @State private var collapsed = Set<String>()
    private var groups: [(String, [Session])] {
        Dictionary(grouping: sessions, by: \.projectPath).sorted { a, b in
            let ar = a.value.contains { $0.status == .running }; let br = b.value.contains { $0.status == .running }
            return ar == br ? a.key.localizedStandardCompare(b.key) == .orderedAscending : ar
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("Session")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Model")).frame(width: compact ? 108 : 160, alignment: .leading)
                Text(L("Reasoning")).frame(width: 70, alignment: .leading)
                Text(L("Speed")).frame(width: 68, alignment: .leading)
                if showsActivity { Text(L("Last activity")).frame(width: 88, alignment: .leading) }
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.0) { project, rows in
                        Section {
                            if !collapsed.contains(project) {
                                ForEach(rows.sorted { $0.updatedAt > $1.updatedAt }) { session in
                                    sessionRow(session)
                                    Divider().padding(.leading, 44)
                                }
                            }
                        } header: {
                            Button {
                                if collapsed.contains(project) { collapsed.remove(project) } else { collapsed.insert(project) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: collapsed.contains(project) ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 9)
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(rows.first?.projectName ?? L("Project")).fontWeight(.semibold).lineLimit(1)
                                    Spacer()
                                    Text("\(rows.count)").foregroundStyle(.secondary)
                                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Color.canvas)
                            }.buttonStyle(.plain).help(project)
                        }
                    }
                }
            }
        }
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }
    private func activityText(_ session: Session, at now: Date) -> String {
        if session.status == .running { return L("Running") }
        let minutes = max(0, Int(now.timeIntervalSince(session.updatedAt) / 60))
        return minutes == 0 ? L("Just now") : LF("%d min ago", minutes)
    }
    private func sessionRow(_ session: Session) -> some View {
        HStack(spacing: 12) {
            if allowsSelection {
                Toggle(isOn: Binding(get: { selection.contains(session.id) }, set: { value in if value { selection.insert(session.id) } else { selection.remove(session.id) } })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(LF("Select %@", session.title))
            }
            Circle().fill(session.status.tint).frame(width: 6, height: 6).help(L(session.status.rawValue.capitalized))
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title.isEmpty ? L("Untitled session") : session.title).lineLimit(1).font(.system(size: 12, weight: .medium))
                if !session.control.isAvailable {
                    Label(L("View only"), systemImage: "eye").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(session.model ?? "—").font(.system(size: 11)).lineLimit(1).frame(width: compact ? 108 : 160, alignment: .leading).help(session.model ?? L("Model unavailable"))
            Text(session.reasoning?.rawValue ?? "—").font(.system(size: 11)).frame(width: 70, alignment: .leading)
            Text(session.speed?.displayTitle ?? "—").font(.system(size: 11)).frame(width: 68, alignment: .leading)
            if showsActivity {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(activityText(session, at: timeline.date)).font(.system(size: 11))
                        .foregroundStyle(session.status == .running ? Color.green : .secondary)
                }.frame(width: 88, alignment: .leading)
            }
        }.padding(.horizontal, 14).padding(.vertical, compact ? 10 : 14)
            .background(selection.contains(session.id) ? Color.accent.opacity(0.045) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { guard allowsSelection else { return }; if selection.contains(session.id) { selection.remove(session.id) } else { selection.insert(session.id) } }
            .contextMenu {
                Button(L("Open in Codex")) { if let url = session.deepLink { NSWorkspace.shared.open(url) } }
                Button(L("Copy session link")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.deepLink?.absoluteString ?? session.id, forType: .string) }
                Button(L("Copy session ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string) }
            }.help(session.control.unavailableReason.map(localizedMessage) ?? session.title)
    }
}
