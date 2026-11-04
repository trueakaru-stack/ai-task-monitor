import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }
    static var previewOverride: AppLanguage?

    static func resolve(_ mode: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard mode == .system else { return mode }
        let first = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-") ?? ""
        return first.split(separator: "-").first?.lowercased() == "ru" ? .ru : .en
    }

    static var current: AppLanguage {
        if let previewOverride { return previewOverride }
        let saved = UserDefaults.standard.string(forKey: "languageMode") ?? AppLanguage.system.rawValue
        return resolve(AppLanguage(rawValue: saved) ?? .system, preferredLanguages: Locale.preferredLanguages)
    }

    var title: String {
        switch self {
        case .system: return tr("Системный", "System")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

func tr(_ russian: String, _ english: String) -> String {
    AppLanguage.current == .ru ? russian : english
}
