import Foundation
import AlmostResetCore

func L(_ key: String) -> String {
    let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .chinese
    return UIStrings.value(key, language: language)
}
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale(identifier: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"), arguments: arguments)
}
/// Translate app-owned log fragments without changing user-authored titles or prompts.
func localizedMessage(_ message: String) -> String {
    if message.hasPrefix("Quota increased · ") {
        let details = String(message.dropFirst("Quota increased · ".count))
            .replacingOccurrences(of: "Weekly ", with: L("Weekly") + " ")
            .replacingOccurrences(of: "5-hour ", with: L("5-hour") + " ")
        return L("Quota increased") + " · " + details
    }
    if let split = message.range(of: " · ") {
        return String(message[..<split.lowerBound]) + " · " + L(String(message[split.upperBound...]))
    }
    for prefix in ["Cannot load saved rules: ", "Cannot save: ", "Search failed: ", "Actions paused: cannot save reset checkpoint. "] where message.hasPrefix(prefix) {
        return LF(prefix + "%@", String(message.dropFirst(prefix.count)))
    }
    return L(message)
}
