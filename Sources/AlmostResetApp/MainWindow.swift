import SwiftUI
import AlmostResetCore

struct MainWindow: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                BrandMark(size: 48).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 26).padding(.top, 28).padding(.bottom, 6)
                VStack(spacing: 5) {
                    ForEach(AppPage.allCases, id: \.self) { page in
                        Button { app.page = page } label: {
                            HStack(spacing: 12) {
                                Image(systemName: page.symbol).font(.system(size: 15)).frame(width: 20)
                                Text(L(page.rawValue)).font(.system(size: 13, weight: app.page == page ? .semibold : .regular))
                                Spacer()
                            }.foregroundStyle(app.page == page ? Color.accent : Color.primary.opacity(0.8))
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(app.page == page ? Color.accent.opacity(0.075) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .leading) {
                                    if app.page == page { Capsule().fill(Color.accent).frame(width: 3, height: 16) }
                                }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
                Spacer()
            }.frame(width: 164).background(Color.primary.opacity(0.018))
            Rectangle().fill(Color.line).frame(width: 1)
            VStack(spacing: 22) {
                if let error = app.storageError ?? app.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        Text(localizedMessage(error)).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        Button { app.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.font(.system(size: 11)).padding(.horizontal, 26).padding(.vertical, 10).background(Color.red.opacity(0.045))
                }
                Group {
                    switch app.page {
                    case .rules: RulesView()
                    case .sessions: SessionsView()
                    case .activity: ActivityView()
                    case .settings: SettingsPage()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(28).frame(maxWidth: app.page == .rules ? 1060 : .infinity).frame(maxWidth: .infinity)
        }.background(Color.canvas).frame(minWidth: 980, minHeight: 680)
    }
}

enum BrandArtwork {
    static let image: NSImage = {
        let resources = Bundle.main.url(forResource: "AlmostReset_AlmostResetApp", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
        let image = NSImage(contentsOf: resources.url(forResource: "BrandMark", withExtension: "png")!)!
        image.isTemplate = true
        return image
    }()
    static let menuImage: NSImage = {
        let image = BrandArtwork.image.copy() as! NSImage
        image.size = NSSize(width: 20, height: 18)
        image.isTemplate = true
        return image
    }()
}

struct BrandMark: View {
    var size: CGFloat = 28
    var monochrome = false
    var body: some View {
        Image(nsImage: BrandArtwork.image).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(monochrome ? Color.primary : Color.accent)
            .frame(width: size, height: size * 0.88).accessibilityLabel("AlmostReset")
    }
}

struct RulesView: View {
    @EnvironmentObject var app: AppModel
    @State private var editRule: AutomationRule?
    @State private var creationKind: RuleCreationKind?
    @State private var draggingRule: UUID?
    @State private var ruleFrames: [UUID: CGRect] = [:]
    @State private var arriving: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleteRule: AutomationRule?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Text(L("Rules")).font(.system(size: 23, weight: .semibold))
                Text(L("In priority order")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                RulePlanBadge()
                NewRuleButton { creationKind = $0 }.disabled(!app.canEditRules)
            }
            MonitorStatusBar()
            if app.rules.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("No rules yet")).foregroundStyle(.secondary)
                    NewRuleButton { creationKind = $0 }.disabled(!app.canEditRules)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(app.rules.enumerated()), id: \.element.id) { index, rule in
                            RuleContentCard(rule: rule, index: index, edit: { editRule = rule }, delete: { deleteRule = rule })
                                .id(rule.id)
                                .contentShape(RoundedRectangle(cornerRadius: 13))
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: RuleFramePreference.self, value: [rule.id: geometry.frame(in: .named("ruleList"))])
                                })
                                .shadow(color: Color.black.opacity(draggingRule == rule.id ? 0.08 : 0), radius: 8, y: 3)
                                .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("ruleList"))
                                    .onChanged { value in
                                        guard app.canEditRules, !app.isExecuting else { return }
                                        draggingRule = rule.id
                                        guard let target = app.rules.first(where: { $0.id != rule.id && ruleFrames[$0.id]?.contains(value.location) == true }) else { return }
                                        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
                                            app.moveRule(rule.id, before: target.id)
                                        }
                                    }
                                    .onEnded { _ in draggingRule = nil })
                                .scaleEffect(arriving == rule.id ? 0.96 : 1)
                                .offset(y: arriving == rule.id ? 12 : 0)
                                .opacity(app.pendingRuleID == rule.id ? 0 : arriving == rule.id ? 0.3 : 1)
                        }
                    }.padding(.bottom, 10)
                        .coordinateSpace(name: "ruleList")
                        .onPreferenceChange(RuleFramePreference.self) { ruleFrames = $0 }
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: app.rules.map(\.id))
                }.onChange(of: app.presentedRuleID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                    guard !reduceMotion else { app.pendingRuleID = nil; return }
                    arriving = id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(30))
                        withAnimation(.spring(response: 0.48, dampingFraction: 0.76)) { app.pendingRuleID = nil; arriving = nil }
                    }
                }
                }
            }
        }
        .task { await app.refresh() }
        .sheet(item: $creationKind) { RuleEditor(kind: $0).environmentObject(app) }
        .sheet(item: $editRule) { rule in RuleEditor(rule: rule).environmentObject(app) }
        .alert(L("Delete rule?"), isPresented: Binding(get: { deleteRule != nil }, set: { if !$0 { deleteRule = nil } })) {
            Button(L("Cancel"), role: .cancel) { deleteRule = nil }
            Button(L("Delete"), role: .destructive) { if let rule = deleteRule { app.deleteRule(rule.id) }; deleteRule = nil }
        } message: { Text(deleteRule.map { selectorSummary($0.selector) } ?? "") }
    }
}

func selectorSummary(_ selector: SessionSelector) -> String {
    switch selector {
    case .sessions(let ids): return LF("%d selected sessions", ids.count)
    case .conditions(let match, let conditions):
        return conditions.enumerated().map { index, condition in
            let prefix = index == 0 ? "" : " " + L((condition.joinWithPrevious ?? match) == .all ? "AND" : "OR") + " "
            let values = condition.values.map { value in
                if condition.field == .project { return URL(fileURLWithPath: value).lastPathComponent }
                if condition.field == .speed { return SessionSpeed(rawValue: value)?.displayTitle ?? value }
                return value
            }.joined(separator: ", ")
            return prefix + L(condition.field.rawValue.capitalized) + " " + L(condition.comparison == .moreThan ? "more than" : "is") + " " + values
        }.joined()
    }
}
extension SessionAction {
    var isStop: Bool { if case .stop = self { return true }; return false }
    var title: String { L(isStop ? "Stop session" : "Continue") }
}

private struct RuleFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
