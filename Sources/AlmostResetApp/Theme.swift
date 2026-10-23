import SwiftUI

extension Color {
    static let canvas = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1) : NSColor(red: 0.965, green: 0.961, blue: 0.95, alpha: 1) })
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let accent = Color(red: 0.87, green: 0.35, blue: 0.17)
    static let line = Color.primary.opacity(0.075)
    static let muted = Color.secondary
}

struct CapsuleTag: View {
    var text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.075), in: Capsule())
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line, lineWidth: 1))
    }
}

struct EmptyPanel: View {
    var symbol: String
    var title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Color.secondary.opacity(0.55))
            Text(L(title)).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            if let actionTitle, let action { Button(L(actionTitle), action: action).buttonStyle(PrimaryButtonStyle()) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

struct SectionCaption: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(L(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
}

struct InlineError: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(localizedMessage(text)).textSelection(.enabled)
        }.font(.system(size: 12)).foregroundStyle(.red).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
