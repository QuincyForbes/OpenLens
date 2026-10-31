import Foundation
import SwiftUI

enum AppPreferenceKeys {
    static let accentColor = "accentColor"
    static let autoReconnect = "autoReconnect"
    static let colorSchemeMode = "colorSchemeMode"
    static let compactSessionRows = "compactSessionRows"
    static let favoriteModelIDs = "favoriteModelIDs"
    static let hapticsEnabled = "hapticsEnabled"
    static let hideOpenCodeFreeProvider = "hideOpenCodeFreeProvider"
    static let liveActivitiesEnabled = "liveActivitiesEnabled"
    static let quickModelAssignments = "quickModelAssignments"
    static let showThinking = "showThinking"
}

enum AppColorSchemeMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppPreferences {
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.hapticsEnabled) as? Bool ?? true
    }

    static var liveActivitiesEnabled: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.liveActivitiesEnabled) as? Bool ?? true
    }

    static var hideOpenCodeFreeProvider: Bool {
        UserDefaults.standard.object(forKey: AppPreferenceKeys.hideOpenCodeFreeProvider) as? Bool ?? true
    }

    static let defaultFavoriteModelIDs: [String] = [
        "anthropic/claude-opus-5-5",
        "anthropic/claude-sonnet-5-5",
        "anthropic/claude-fable-5-1",
        "openai/gpt-6-astra",
        "openai/gpt-6.1-sol",
        "openai/gpt-6.1-terra",
        "google/gemini-4-argon",
        "google/gemini-3.8-flash"
    ]

    static func favoriteModelIDs(userDefaults: UserDefaults = .standard) -> Set<String> {
        if let saved = userDefaults.stringArray(forKey: AppPreferenceKeys.favoriteModelIDs) {
            return Set(saved)
        }
        return Set(defaultFavoriteModelIDs)
    }

    @discardableResult
    static func toggleFavoriteModelID(
        _ id: String,
        userDefaults: UserDefaults = .standard
    ) -> Set<String> {
        var current = favoriteModelIDs(userDefaults: userDefaults)
        if !current.insert(id).inserted {
            current.remove(id)
        }
        userDefaults.set(current.sorted(), forKey: AppPreferenceKeys.favoriteModelIDs)
        return current
    }

    static func quickModelAssignments(
        userDefaults: UserDefaults = .standard
    ) -> [ModelQuickAction: QuickModelAssignment] {
        guard let data = userDefaults.data(forKey: AppPreferenceKeys.quickModelAssignments),
              let encoded = try? JSONDecoder().decode([String: QuickModelAssignment].self, from: data) else {
            return [:]
        }

        return encoded.reduce(into: [:]) { assignments, entry in
            guard let action = ModelQuickAction(rawValue: entry.key) else { return }
            assignments[action] = entry.value
        }
    }

    static func saveQuickModelAssignments(
        _ assignments: [ModelQuickAction: QuickModelAssignment],
        userDefaults: UserDefaults = .standard
    ) {
        let encoded = assignments.reduce(into: [String: QuickModelAssignment]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }

        guard let data = try? JSONEncoder().encode(encoded) else { return }
        userDefaults.set(data, forKey: AppPreferenceKeys.quickModelAssignments)
    }
}
