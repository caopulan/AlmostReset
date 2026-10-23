import SwiftUI
import AlmostResetCore

enum RuleCreationKind: String, Identifiable {
    case sessions, conditions
    var id: String { rawValue }
    var title: String { L(self == .sessions ? "Specific sessions" : "Conditions") }
    var caption: String { L(self == .sessions ? "Pick exact tasks" : "Match tasks automatically") }
    var symbol: String { self == .sessions ? "checklist" : "line.3.horizontal.decrease" }
}

struct NewRuleButton: View {
    let choose: (RuleCreationKind) -> Void
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) { Image(systemName: "plus"); Text(L("New rule")); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }.buttonStyle(PrimaryButtonStyle())
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                VStack(spacing: 5) {
                    choice(.sessions)
                    choice(.conditions)
                }.padding(9).frame(width: 265).background(Color.canvas)
            }
    }
    private func choice(_ kind: RuleCreationKind) -> some View {
        Button {
            expanded = false
            choose(kind)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: kind.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(kind.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(kind.caption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(kind.title + ", " + kind.caption)
    }
}

struct RuleEditor: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let existingID: UUID?
    let kind: RuleCreationKind
    @State private var step = 0
    private let legacyName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedIDs: Set<String>
    @State private var match: ConditionMatch
    @State private var conditions: [SessionCondition]
    @State private var actionKind: Int
    @State private var selectedModel: String
    @State private var reasoning: String
    @State private var speed: String
    @State private var prompt: String
    @State private var query = ""
    @State private var validationError: String?
    @State private var enabled: Bool
    @State private var isSaving = false
    @State private var saved = false
    @State private var clock = Date()

    init(kind: RuleCreationKind = .sessions, rule: AutomationRule? = nil, selected: Set<String> = []) {
        existingID = rule?.id
        legacyName = rule?.name ?? ""
        _enabled = State(initialValue: rule?.enabled ?? true)
        switch rule?.selector {
        case .sessions(let ids):
            self.kind = .sessions; _selectedIDs = State(initialValue: Set(ids))
            _match = State(initialValue: .all); _conditions = State(initialValue: [SessionCondition(field: .reasoning, values: [])])
        case .conditions(let combination, let rows):
            self.kind = .conditions; _selectedIDs = State(initialValue: [])
            _match = State(initialValue: combination); _conditions = State(initialValue: rows)
        case nil:
            self.kind = kind; _selectedIDs = State(initialValue: selected)
            _match = State(initialValue: .all); _conditions = State(initialValue: [SessionCondition(field: .reasoning, values: [])])
        }
        if case .continueSession(let config) = rule?.action {
            _actionKind = State(initialValue: 1); _selectedModel = State(initialValue: config.model ?? "")
            _reasoning = State(initialValue: config.reasoning?.rawValue ?? "")
            _speed = State(initialValue: config.speed?.rawValue ?? "")
            _prompt = State(initialValue: config.prompt)
        } else {
            _actionKind = State(initialValue: 0); _selectedModel = State(initialValue: "")
            _reasoning = State(initialValue: ""); _speed = State(initialValue: "")
            _prompt = State(initialValue: L("continue"))
        }
    }

    private var selector: SessionSelector {
        kind == .sessions ? .sessions(selectedIDs.sorted()) : .conditions(match: match, conditions: conditions)
    }
    private var eligible: [Session] { app.sessions.filter { $0.isRecentOrRunning(at: clock) } }
    private var visibleSessions: [Session] {
        let reference = try? SessionReference.sessionID(from: query)
        return eligible.filter { session in
            if let reference { return session.id == reference }
            return session.matchesSearch(query)
        }
    }
    private var preview: [Session] { app.runningSessions.filter { selector.matches($0) } }
    private var matchCount: Int { kind == .conditions ? preview.count : eligible.filter { selectedIDs.contains($0.id) }.count }
    private var supportedEfforts: [ReasoningEffort] { app.models.first { $0.id == selectedModel }?.reasoningEfforts ?? ReasoningEffort.allCases }
    private var supportedSpeeds: [SessionSpeed] { app.models.first { $0.id == selectedModel }?.speeds ?? SessionSpeed.allCases }

    private var draftAction: SessionAction {
        actionKind == 0 ? .stop : .continueSession(ContinuationSettings(model: selectedModel.isEmpty ? nil : selectedModel,
            reasoning: ReasoningEffort(rawValue: reasoning), speed: SessionSpeed(rawValue: speed), prompt: prompt.isEmpty ? L("continue") : prompt))
    }
    private var selectedPreset: RulePreset? {
        RulePreset.allCases.first { $0.configuration(prompt: L("continue")).matchesDraft(match: match, conditions: conditions, action: draftAction) }
    }
    private var sheetHeight: CGFloat { min(step == 0 ? 740 : (actionKind == 0 ? 270 : 490), (NSScreen.main?.visibleFrame.height ?? 900) - 80) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.34) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if step == 0 { matchPage }
                else { actionPage }
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let validationError { InlineError(text: validationError).padding(.horizontal, 26).padding(.bottom, 16) }
            Divider()
            footer
        }.background(Color.canvas)
            .frame(width: 820, height: sheetHeight)
            .animation(motion, value: step)
            .animation(motion, value: actionKind)
            .onChange(of: selectedModel) { _, _ in
                if !reasoning.isEmpty && !supportedEfforts.contains(where: { $0.rawValue == reasoning }) { reasoning = "" }
                if !speed.isEmpty && !supportedSpeeds.contains(where: { $0.rawValue == speed }) { speed = "" }
            }
            .task { await app.refresh() }
            .task(id: query) { await search() }
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { clock = $0 }
    }
    private var header: some View {
        HStack(spacing: 24) {
            Spacer()
            stepBadge(0, title: L(kind == .sessions ? "Choose sessions" : "Set conditions"))
            Rectangle().fill(Color.line).frame(width: 48, height: 1)
            stepBadge(1, title: L("Choose action"))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Cancel"))
        }.padding(.horizontal, 26).padding(.vertical, 23)
    }
    private func stepBadge(_ index: Int, title: String) -> some View {
        Button {
            guard !isSaving else { return }
            if index == 0 { step = 0; validationError = nil }
            else { advance() }
        } label: {
        HStack(spacing: 8) {
            Group { if index < step { Image(systemName: "checkmark") } else { Text("\(index + 1)") } }
                .font(.system(size: 12, weight: .semibold)).frame(width: 27, height: 27)
                .foregroundStyle(index <= step ? Color.white : Color.secondary)
                .background(index < step ? Color.green : index == step ? Color.accent : Color.primary.opacity(0.05), in: Circle())
            Text(title).font(.system(size: 12, weight: index == step ? .semibold : .regular))
                .foregroundStyle(index == step ? Color.accent : Color.secondary)
        }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).disabled(isSaving)
    }
    @ViewBuilder private var matchPage: some View {
        if kind == .sessions {
            VStack(alignment: .leading, spacing: 14) {
                SearchField(text: $query)
                HStack {
                    Text(L("Running + recent 30 min")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Select all")) { selectedIDs.formUnion(visibleSessions.map(\.id)) }.buttonStyle(.plain).foregroundStyle(Color.accent).disabled(visibleSessions.isEmpty)
                    Button(L("Clear")) { selectedIDs.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(selectedIDs.isEmpty)
                }
                if visibleSessions.isEmpty { EmptyPanel(symbol: "magnifyingglass", title: query.isEmpty ? "No eligible sessions" : "No sessions found") }
                else { SessionTable(sessions: visibleSessions, selection: $selectedIDs, compact: true, showsActivity: true) }
                let hiddenCount = selectedIDs.subtracting(Set(eligible.map(\.id))).count
                if hiddenCount > 0 {
                    HStack {
                        Text(L("Some selected sessions are no longer active or recent.")).font(.system(size: 11)).foregroundStyle(.orange)
                        Spacer()
                        Button(L("Clear")) { selectedIDs.formIntersection(Set(eligible.map(\.id))) }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 15) {
                presetPicker
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($conditions) { $condition in conditionRow($condition) }
                    }
                }.frame(height: min(200, CGFloat(conditions.count) * 58 + 4))
                Button { conditions.append(SessionCondition(field: .speed, values: [])) } label: { Label(L("Add condition"), systemImage: "plus") }
                Divider()
                HStack(spacing: 12) {
                    Text(L("Match preview")).font(.system(size: 14, weight: .semibold))
                    let total = app.runningSessions.count
                    CapsuleTag(text: LF("%d of %d running · %.1f%%", preview.count, total, total == 0 ? 0 : 100 * Double(preview.count) / Double(total)), tint: .accent)
                    Spacer()
                    if app.isRefreshing { ProgressView().controlSize(.small) }
                    Button { Task { await app.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).accessibilityLabel(L("Refresh"))
                }
                if preview.isEmpty { EmptyPanel(symbol: "line.3.horizontal.decrease", title: "No matching running sessions") }
                else { SessionTable(sessions: preview, selection: .constant([]), compact: true, allowsSelection: false, showsActivity: true) }
            }
        }
    }
    private func conditionRow(_ binding: Binding<SessionCondition>) -> some View {
        HStack(spacing: 10) {
            if conditions.first?.id == binding.wrappedValue.id {
                Color.clear.frame(width: 65, height: 1)
            } else {
                ChoicePicker(value: Binding(get: { binding.wrappedValue.joinWithPrevious ?? match }, set: { binding.wrappedValue.joinWithPrevious = $0 }), options: [(ConditionMatch.all, L("AND")), (.any, L("OR"))])
                    .frame(width: 65).help(L("AND takes precedence over OR"))
            }
            ChoicePicker(value: binding.field, options: SessionField.allCases.filter { $0 != .project }.map { ($0, L($0.rawValue.capitalized)) })
                .frame(width: 125).accessibilityLabel(L("Field") + ": " + L(binding.wrappedValue.field.rawValue.capitalized))
                .onChange(of: binding.wrappedValue.field) { _, _ in binding.wrappedValue.values = []; binding.wrappedValue.comparison = .equals }
            ChoicePicker(value: binding.comparison, options: binding.wrappedValue.field == .reasoning ? [(.equals, L("is")), (.moreThan, L("more than"))] : [(.equals, L("is"))])
                .frame(width: 105).accessibilityLabel(L("Operator") + ": " + L(binding.wrappedValue.comparison == .equals ? "is" : "more than"))
                .onChange(of: binding.wrappedValue.comparison) { _, value in
                    if value == .moreThan { binding.wrappedValue.values = Array(binding.wrappedValue.values.prefix(1)) }
                }
            MultiValuePicker(values: binding.values, options: options(for: binding.wrappedValue.field), single: binding.wrappedValue.comparison == .moreThan)
                .frame(maxWidth: .infinity)
            Button { conditions.removeAll { $0.id == binding.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 22).disabled(conditions.count == 1)
                .accessibilityLabel(L("Remove condition"))
        }.padding(7).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    }
    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("Presets")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                ForEach(RulePreset.allCases) { preset in
                    Button { applyPreset(preset) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: preset == .stopAstra ? "stop.circle" : preset == .standardFastSessions ? "speedometer" : "arrow.triangle.branch")
                                .font(.system(size: 14)).foregroundStyle(selectedPreset == preset ? Color.accent : .secondary)
                            Text(presetTitle(preset)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.horizontal, 12).frame(height: 45)
                            .foregroundStyle(selectedPreset == preset ? Color.accent : .primary)
                            .background(selectedPreset == preset ? Color.accent.opacity(0.07) : Color.panel, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectedPreset == preset ? Color.accent.opacity(0.4) : Color.line))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selectedPreset == preset ? [.isSelected] : [])
                }
            }
        }.padding(12).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
    private func presetTitle(_ preset: RulePreset) -> String {
        switch preset {
        case .stopAstra: return L("Stop 6-astra")
        case .standardFastSessions: return L("Fast → Standard and continue")
        case .astraToSol: return L("6-astra → 6-sol · xhigh")
        }
    }
    private func applyPreset(_ preset: RulePreset) {
        let config = preset.configuration(prompt: L("continue"))
        match = config.match; conditions = config.conditions
        selectedModel = ""; reasoning = ""; speed = ""; prompt = L("continue")
        switch config.action {
        case .stop: actionKind = 0
        case .continueSession(let values):
            actionKind = 1; selectedModel = values.model ?? ""
            reasoning = values.reasoning?.rawValue ?? ""; speed = values.speed?.rawValue ?? ""; prompt = values.prompt
        }
        validationError = nil
    }
    private var modelOptions: [(String, String)] {
        var options = [("", L("Keep current"))] + app.models.map { ($0.id, $0.displayName) }
        if !selectedModel.isEmpty && !options.contains(where: { $0.0 == selectedModel }) { options.append((selectedModel, selectedModel)) }
        return options
    }
    private var actionPage: some View {
        VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(kind.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(kind == .sessions ? LF("%d selected", matchCount) : selectorSummary(selector))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    actionChoice(0, title: L("Stop session"), symbol: "stop.fill")
                    actionChoice(1, title: L("Continue"), symbol: "play.fill")
                }.padding(4).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                if actionKind == 1 {
                    Panel {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 7) {
                                    SectionCaption(title: "Model")
                                    ChoicePicker(value: $selectedModel, options: modelOptions).accessibilityLabel(L("Model") + ": " + (modelOptions.first { $0.0 == selectedModel }?.1 ?? selectedModel))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 7) {
                                    SectionCaption(title: "Reasoning")
                                    ChoicePicker(value: $reasoning, options: [("", L("Keep current"))] + supportedEfforts.map { ($0.rawValue, $0.rawValue) })
                                        .accessibilityLabel(L("Reasoning") + ": " + (reasoning.isEmpty ? L("Keep current") : reasoning))
                                }.frame(width: 130, alignment: .leading)
                                VStack(alignment: .leading, spacing: 7) {
                                    SectionCaption(title: "Speed")
                                    ChoicePicker(value: $speed, options: [("", L("Keep current"))] + supportedSpeeds.map { ($0.rawValue, $0.displayTitle) })
                                        .accessibilityLabel(L("Speed") + ": " + (SessionSpeed(rawValue: speed)?.displayTitle ?? L("Keep current")))
                                }.frame(width: 130, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                SectionCaption(title: "Prompt")
                                TextEditor(text: $prompt).font(.system(size: 13)).scrollContentBackground(.hidden)
                                    .padding(8).frame(height: 76)
                                    .background(Color.canvas, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.line))
                                    .accessibilityLabel(L("Prompt"))
                            }
                        }.padding(16)
                    }.transition(.opacity)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion, value: actionKind)
    }
    private func actionChoice(_ index: Int, title: String, symbol: String) -> some View {
        Button { withAnimation(motion) { actionKind = index } } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 13, weight: .medium))
            }.padding(.horizontal, 16).frame(height: 34)
                .foregroundStyle(actionKind == index ? Color.accent : .secondary)
                .background(actionKind == index ? Color.panel : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(actionKind == index ? Color.line : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(actionKind == index ? [.isSelected] : [])
    }
    private var footer: some View {
        HStack {
            if step == 0 { Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
            else { Button(L("Back")) { step = 0; validationError = nil } }
            Spacer()
            if step == 0 {
                Text(kind == .sessions ? LF("%d selected", matchCount) : LF("%d running", preview.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L("Next")) { advance() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Toggle(L("Enabled"), isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                Button(saved ? "✓ " + L("Saved") : L(existingID == nil ? "Create rule" : "Save rule"), action: save)
                    .scaleEffect(saved ? 0.95 : 1).animation(motion, value: saved)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(isSaving || !app.canEditRules)
            }
        }.padding(.horizontal, 26).padding(.vertical, 18)
    }
    private func validSelection() -> Bool {
        clock = Date()
        if kind == .sessions {
            guard !selectedIDs.isEmpty else { validationError = L("Select at least one session."); return false }
            guard selectedIDs.isSubset(of: Set(eligible.map(\.id))) else { validationError = L("Some selected sessions are no longer active or recent."); return false }
        } else {
            guard !conditions.isEmpty, !conditions.contains(where: { $0.values.isEmpty }) else { validationError = L("Choose a value for each condition."); return false }
            guard !conditions.contains(where: { $0.comparison == .moreThan && ($0.field != .reasoning || $0.values.count != 1) }) else { validationError = L("A more-than comparison needs one reasoning level."); return false }
        }
        validationError = nil; return true
    }
    private func advance() { if validSelection() { step = 1 } }
    private func save() {
        guard validSelection() else { step = 0; return }
        let rule = AutomationRule(id: existingID ?? UUID(), name: legacyName, enabled: enabled, selector: selector,
                                  action: draftAction, scope: kind == .sessions ? .recent : .running)
        isSaving = true
        if existingID == nil { app.pendingRuleID = rule.id }
        Task {
            if await app.saveRule(rule) {
                withAnimation(motion) { saved = true }
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
                dismiss()
                if existingID == nil {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 260))
                    app.presentedRuleID = rule.id
                }
            } else { app.pendingRuleID = nil; validationError = localizedMessage(app.storageError ?? "Could not save rule.") }
            isSaving = false
        }
    }
    private func options(for field: SessionField) -> [(String, String)] {
        switch field {
        case .reasoning: return ReasoningEffort.allCases.map { ($0.rawValue, $0.rawValue) }
        case .speed: return SessionSpeed.allCases.map { ($0.rawValue, $0.displayTitle) }
        case .status: return SessionStatus.allCases.filter { $0 != .unknown }.map { ($0.rawValue, L($0.rawValue.capitalized)) }
        case .model: return Array(Set(app.models.map(\.id) + app.runningSessions.compactMap(\.model))).sorted().map { ($0, $0) }
        case .project: return Array(Set(app.runningSessions.map(\.projectPath).filter { !$0.isEmpty })).sorted().map { ($0, $0.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        }
    }
    private func search() async {
        guard kind == .sessions, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        guard !Task.isCancelled else { return }
        let requested = query
        if let id = try? SessionReference.sessionID(from: requested) {
            let resolved = await app.resolveSession(requested)
            guard !Task.isCancelled, query == requested else { return }
            clock = Date()
            if resolved, eligible.contains(where: { $0.id == id }) { selectedIDs.insert(id); validationError = nil }
            else if resolved { validationError = L("This session has no activity in the last 30 minutes.") }
            else { validationError = localizedMessage(app.errorMessage ?? "Session not found.") }
        } else { await app.searchSessions(requested) }
    }
}

struct MultiValuePicker: View {
    @Binding var values: [String]
    let options: [(String, String)]
    var single = false
    @State private var expanded = false
    private var rows: [(String, String)] {
        options + values.filter { value in !options.contains { $0.0 == value } }.map { ($0, $0) }
    }
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack {
                Text(values.isEmpty ? L(single ? "Choose a value" : "Choose values") : values.map { value in options.first { $0.0 == value }?.1 ?? value }.joined(separator: ", "))
                    .lineLimit(1).foregroundStyle(values.isEmpty ? .secondary : .primary)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.line))
        }.buttonStyle(.plain)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows, id: \.0) { value, title in
                            Button {
                                if single { values = [value]; expanded = false }
                                else if values.contains(value) { values.removeAll { $0 == value } }
                                else { values.append(value) }
                            } label: {
                                HStack {
                                    Image(systemName: values.contains(value) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(values.contains(value) ? Color.accent : Color.secondary)
                                    Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if !values.isEmpty {
                            Divider()
                            Button(L("Clear selection")) { values = [] }.buttonStyle(.plain).foregroundStyle(.secondary).padding(8)
                        }
                    }.padding(6)
                }.frame(width: 310, height: min(340, CGFloat(rows.count + (values.isEmpty ? 0 : 1)) * 38 + 12))
            }
    }
}
