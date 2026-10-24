import AppKit
import SwiftUI
import Combine
import Sparkle
import AlmostResetCore

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var available = false
    @Published private(set) var canCheck = false
    @Published private(set) var automatic = true
    @Published private(set) var status = ""
    @Published private(set) var detail: String?
    private var controller: SPUStandardUpdaterController?
    private weak var app: AppModel?
    private var subscriptions = Set<AnyCancellable>()
    private var pendingInstallation: (() -> Void)?
    private var preparing = false
    private var pendingIsAutomatic = false
    private var authorizedRelaunch = false

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }

    func start(app: AppModel) {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        self.app = app
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        available = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .combineLatest(updater.publisher(for: \.automaticallyDownloadsUpdates))
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.automatic = $0 && $1 }.store(in: &subscriptions)
        app.$listener.combineLatest(app.$isExecuting, app.$isRefreshing, app.$isReconnecting)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.attemptInstallation() }.store(in: &subscriptions)
        app.$isSavingRules.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.attemptInstallation() }.store(in: &subscriptions)
        controller.startUpdater()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.automatic, self.canCheck else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    func setAutomatic(_ value: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = value
        updater.automaticallyDownloadsUpdates = value
        automatic = value
        if value { attemptInstallation() }
    }

    func check() {
        guard canCheck else { return }
        status = "Checking for updates…"; detail = nil
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "Update available"; detail = item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = "Up to date"; detail = nil
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        authorizedRelaunch = false
        app?.isInstallingUpdate = false
        if (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == 1001 {
            status = "Up to date"; detail = nil; return
        }
        status = "Update check failed"; detail = error.localizedDescription
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = "Downloading update…"; detail = item.displayVersionString
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        queueInstallation(install, automatic: true)
        return true
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock install: @escaping () -> Void) -> Bool {
        if authorizedRelaunch { return false }
        queueInstallation(install, automatic: false)
        return true
    }
    private func queueInstallation(_ install: @escaping () -> Void, automatic: Bool) {
        pendingIsAutomatic = automatic
        pendingInstallation = install
        status = "Update ready · waiting for idle"; detail = nil
        // Invoke on a later main-loop turn, after Sparkle receives the delegate result.
        Task { [weak self] in self?.attemptInstallation() }
    }
    private func attemptInstallation() {
        guard pendingInstallation != nil, !preparing, !pendingIsAutomatic || automatic, let app, app.canInstallAppUpdate else { return }
        preparing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.preparing = false }
            guard await app.prepareForAppUpdate(), let install = self.pendingInstallation else { return }
            guard !self.pendingIsAutomatic || self.automatic else { return }
            self.pendingInstallation = nil
            app.isInstallingUpdate = true
            self.authorizedRelaunch = true
            self.status = "Installing update…"
            install()
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(L("App updates")).font(.system(size: 14, weight: .semibold)); Spacer(); Text(updater.version).foregroundStyle(.secondary) }
                Toggle(L("Automatically check and install updates"), isOn: Binding(get: { updater.automatic }, set: updater.setAutomatic))
                    .toggleStyle(.switch).controlSize(.small)
                HStack {
                    if !updater.status.isEmpty { Text(L(updater.status)).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(L("Check for updates…"), action: updater.check).disabled(!updater.canCheck)
                }
                if let detail = updater.detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(26)
        }
    }
}

struct AppUpdateMenuCommand: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button(L("Check for updates…"), action: updater.check).disabled(!updater.canCheck)
    }
}
