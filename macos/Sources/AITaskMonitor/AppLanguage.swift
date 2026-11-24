import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }
    private static let previewLock = NSLock()
    private static var storedPreviewOverride: AppLanguage?
    private static let sourceLanguageKey = "ai.taskmonitor.background-source-language"
    static var previewOverride: AppLanguage? {
        get {
            previewLock.lock()
            defer { previewLock.unlock() }
            return storedPreviewOverride
        }
        set {
            previewLock.lock()
            storedPreviewOverride = newValue
            previewLock.unlock()
        }
    }

    static func resolve(_ mode: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard mode == .system else { return mode }
        let first = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-") ?? ""
        return first.split(separator: "-").first?.lowercased() == "ru" ? .ru : .en
    }

    static var current: AppLanguage {
        if let raw = Thread.current.threadDictionary[sourceLanguageKey] as? String,
           let language = AppLanguage(rawValue: raw), language != .system { return language }
        if let previewOverride { return previewOverride }
        let saved = UserDefaults.standard.string(forKey: "languageMode") ?? AppLanguage.system.rawValue
        return resolve(AppLanguage(rawValue: saved) ?? .system, preferredLanguages: Locale.preferredLanguages)
    }

    static func withSourceLanguage<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[sourceLanguageKey]
        dictionary[sourceLanguageKey] = language.rawValue
        defer {
            if let previous { dictionary[sourceLanguageKey] = previous }
            else { dictionary.removeObject(forKey: sourceLanguageKey) }
        }
        return try body()
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
