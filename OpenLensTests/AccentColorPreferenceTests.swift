import SwiftUI
import Testing
@testable import OpenLens

struct AccentColorPreferenceTests {

    @MainActor
    private func onAccentColor(forHex hex: String) -> Color {
        let suiteName = "AccentColorPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(hex, forKey: AppPreferenceKeys.accentColor)
        return AccentColorPreference(userDefaults: defaults).onAccentColor
    }

    @MainActor
    @Test(arguments: ["007AFF", "FF9500", "34C759", "AF52DE", "FF3B30"])
    func midToneAccentsKeepWhiteForeground(hex: String) {
        #expect(onAccentColor(forHex: hex) == .white)
    }

    @MainActor
    @Test(arguments: ["FFFFFF", "FFE600", "F2F2F7"])
    func paleAccentsUseDarkForeground(hex: String) {
        #expect(onAccentColor(forHex: hex) != .white)
    }

    @MainActor
    @Test
    func favoriteModelsCanBeToggledAcrossMultipleProviders() {
        let suiteName = "FavoriteModelsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppPreferences.favoriteModelIDs(userDefaults: defaults)
        #expect(initial.contains("anthropic/claude-opus-5-5"))
        #expect(initial.contains("openai/gpt-6-astra"))
        #expect(initial.contains("google/gemini-4-argon"))

        let afterAdding = AppPreferences.toggleFavoriteModelID("google/gemini-4-argon-pro", userDefaults: defaults)
        #expect(afterAdding.contains("google/gemini-4-argon-pro"))

        let afterRemoving = AppPreferences.toggleFavoriteModelID("anthropic/claude-opus-5-5", userDefaults: defaults)
        #expect(!afterRemoving.contains("anthropic/claude-opus-5-5"))
        #expect(afterRemoving.contains("google/gemini-4-argon-pro"))
    }

    @MainActor
    @Test
    func hideOpenCodeFreeProviderFiltersFreeProviderWhenMeridianOrGooglePresent() {
        let previous = UserDefaults.standard.object(forKey: AppPreferenceKeys.hideOpenCodeFreeProvider)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppPreferenceKeys.hideOpenCodeFreeProvider)
            } else {
                UserDefaults.standard.removeObject(forKey: AppPreferenceKeys.hideOpenCodeFreeProvider)
            }
        }

        let client = ChatClient(isDemoMode: false)
        client.providers = [
            OCProvider(id: "anthropic", name: "Anthropic", models: [
                "claude-opus-5-5": OCProviderModel(id: "claude-opus-5-5", name: "Claude Opus 5.5")
            ]),
            OCProvider(id: "openai", name: "OpenAI", models: [
                "gpt-6-astra": OCProviderModel(id: "gpt-6-astra", name: "GPT-6 Astra")
            ]),
            OCProvider(id: "google", name: "Google", models: [
                "gemini-4-argon": OCProviderModel(id: "gemini-4-argon", name: "Gemini 4 Argon")
            ]),
            OCProvider(id: "opencode", name: "OpenCode", models: [
                "beam-free": OCProviderModel(id: "beam-free", name: "Beam Free")
            ])
        ]

        UserDefaults.standard.set(true, forKey: AppPreferenceKeys.hideOpenCodeFreeProvider)
        client.refreshProviderFilter()
        let filteredProviders = Set(client.availableModels.map { $0.providerID })
        #expect(filteredProviders == ["anthropic", "openai", "google"])

        UserDefaults.standard.set(false, forKey: AppPreferenceKeys.hideOpenCodeFreeProvider)
        client.refreshProviderFilter()
        let allProviders = Set(client.availableModels.map { $0.providerID })
        #expect(allProviders == ["anthropic", "openai", "google", "opencode"])
    }
}
