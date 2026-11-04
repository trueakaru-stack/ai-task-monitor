import Foundation

enum AppVersion {
    // Swift Package tests and source previews do not run inside the release bundle.
    static let sourceVersion = "0.3.5-alpha"
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "AITaskMonitorReleaseVersion") as? String ?? sourceVersion
    }
    static var display: String { current.replacingOccurrences(of: "-", with: " ") }
}
