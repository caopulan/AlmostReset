import Foundation

public enum UpdateInstallationPolicy {
    public static func canInstall(listening: Bool, executing: Bool, refreshing: Bool, reconnecting: Bool, storageReady: Bool, writingRules: Bool = false) -> Bool {
        storageReady && !writingRules && !listening && !executing && !refreshing && !reconnecting
    }
}
