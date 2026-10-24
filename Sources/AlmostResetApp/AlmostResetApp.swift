import SwiftUI
import AlmostResetCore

@main struct AlmostResetApp: App {
    @NSApplicationDelegateAdaptor(AlmostResetAppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            MonitorStatusBar(portrait: true).id(app.language).environmentObject(app).tint(.accent)
        } label: {
            Image(nsImage: BrandArtwork.menuImage).renderingMode(.template)
            Text(app.mainWindows.first?.remainingPercent.map { (app.isQuotaStale ? "~" : "") + "\(Int($0))%" } ?? "—")
        }.menuBarExtraStyle(.window)
        Window("AlmostReset", id: "main") {
            MainWindow().id(app.language).environment(\.locale, Locale(identifier: app.language.rawValue)).environmentObject(app).tint(.accent).task { await app.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                AppUpdateMenuCommand(updater: app.updates)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { app.page = .settings; showMainWindow() }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.title == "AlmostReset" }) { window.makeKeyAndOrderFront(nil) }
}

@MainActor final class AlmostResetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start services even when macOS restores only the menu bar after relaunch.
        Task { await AppModel.shared.start() }
    }
}
