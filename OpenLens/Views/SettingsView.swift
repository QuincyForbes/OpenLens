import SwiftUI
import UIKit

struct SettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/martynpekala/OpenLens")!

    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.requestReviewPrompt) private var requestReviewPrompt
    @Environment(\.gitHubStarsService) private var gitHubStars

    @State private var showDisconnectConfirmation = false

    @AppStorage(AppPreferenceKeys.showThinking) private var showThinking = true
    @AppStorage(AppPreferenceKeys.autoReconnect) private var autoReconnect = true
    @AppStorage(AppPreferenceKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppPreferenceKeys.liveActivitiesEnabled) private var liveActivitiesEnabled = true
    @AppStorage(AppPreferenceKeys.hideOpenCodeFreeProvider) private var hideOpenCodeFreeProvider = true
    @AppStorage(AppPreferenceKeys.colorSchemeMode) private var colorSchemeMode: AppColorSchemeMode = .system
    @AppStorage(OpenLensAppearance.storageKey) private var appearance: OpenLensAppearance = .classic
    @AppStorage(AppPreferenceKeys.compactSessionRows) private var compactSessionRows = false
    private let accentColor = AccentColorPreference.shared
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled = FeatureFlags.debugFeaturesDefault

    var body: some View {
        Form {
            if let host = connection.serverHostDisplay {
                Section("Connected Server") {
                    detailRow("Server", value: host)
                    if let capabilities = connection.serverCapabilities {
                        let versionText = connection.serverVersion.map { " · \($0)" } ?? ""
                        detailRow("Protocol", value: "\(capabilities.protocolVersion.rawValue.uppercased())\(versionText)")
                    } else if let version = connection.serverVersion {
                        detailRow("Version", value: version)
                    }
                    if let directory = connection.selectedProjectDirectory {
                        detailRow("Workspace", value: directory)
                    }
                    NavigationLink {
                        MeridianUsageView()
                    } label: {
                        Label("Meridian Quotas & Usage", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
            } else {
                Section("Meridian") {
                    NavigationLink {
                        MeridianUsageView()
                    } label: {
                        Label("Meridian Quotas & Usage", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
            }

            if savedConnections.connections.count > 1 {
                Section("Saved Servers") {
                    ForEach(savedConnections.connections) { saved in
                        let isActive = saved.id == savedConnections.activeConnectionID
                        Button {
                            guard !isActive else { return }
                            Task {
                                await connection.connect(
                                    url: saved.serverURL,
                                    username: saved.username,
                                    password: saved.password,
                                    method: .manual
                                )
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(saved.displayName)
                                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.appPrimary)
                                    Text(saved.username)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isActive {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.appUserAccent)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isActive {
                                Button(role: .destructive) {
                                    savedConnections.removeConnection(saved)
                                } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }

            Section(AppText.settingsAppPreferences) {
                Toggle(isOn: $showThinking) {
                    preferenceLabel(AppText.showThinking, subtitle: AppText.showThinkingSubtitle, icon: "brain")
                }
                Toggle(isOn: $hapticsEnabled) {
                    preferenceLabel(AppText.settingsHaptics, subtitle: AppText.settingsHapticsSubtitle, icon: "hand.tap")
                }
                Toggle(isOn: $liveActivitiesEnabled) {
                    preferenceLabel(AppText.settingsLiveActivities, subtitle: AppText.settingsLiveActivitiesSubtitle, icon: "platter.filled.top.iphone")
                }
                Toggle(isOn: $autoReconnect) {
                    preferenceLabel(AppText.autoReconnect, subtitle: AppText.autoReconnectSubtitle, icon: "arrow.triangle.2.circlepath")
                }
                Toggle(isOn: $hideOpenCodeFreeProvider) {
                    preferenceLabel(
                        "Hide OpenCode Free Provider",
                        subtitle: "Only show Meridian (Anthropic & OpenAI) and API-key providers like Google",
                        icon: "line.3.horizontal.decrease.circle"
                    )
                }
            }
            .tint(Color.appUserAccent)

            Section(AppText.appearance) {
                Picker("Color Scheme", selection: $colorSchemeMode) {
                    ForEach(AppColorSchemeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Theme Palette", selection: $appearance) {
                    ForEach(OpenLensAppearance.allCases) { item in
                        Text("\(item.displayName) · \(item.subtitle)").tag(item)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent Presets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(AccentColorPreference.presets) { preset in
                                let isSelected = accentColor.hex.caseInsensitiveCompare(preset.hex) == .orderedSame
                                Button {
                                    accentColor.setHex(preset.hex)
                                } label: {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 28, height: 28)
                                        .overlay {
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Accent preset \(preset.name)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                ColorPicker(
                    AppText.settingsAccentColor,
                    selection: accentColor.binding,
                    supportsOpacity: false
                )
                if accentColor.hasCustomColor {
                    Button(AppText.settingsAccentColorReset, role: .destructive) {
                        accentColor.reset()
                    }
                }

                Toggle(isOn: $compactSessionRows) {
                    preferenceLabel(
                        "Compact Session List",
                        subtitle: "Denser rows to fit more sessions on screen",
                        icon: "rectangle.compress.vertical"
                    )
                }
            }

            Section {
                if gitHubStars.state != .failed {
                    starGoalRow
                }
                Link(destination: repositoryURL) {
                    Label(AppText.settingsSupportGitHubCTA, systemImage: "arrow.up.right.square")
                }
                .tint(Color.appUserAccent)
                Button {
                    requestReviewPrompt()
                } label: {
                    Label(AppText.settingsSupportReviewCTA, systemImage: "star.bubble.fill")
                }
            } header: {
                Text(AppText.settingsAboutSupport)
            }

            Text(appVersionBuild)

            #if DEBUG
            Section(AppText.developer) {
                Toggle(isOn: $debugFeaturesEnabled) {
                    preferenceLabel(
                        AppText.settingsDebugFeatures,
                        subtitle: AppText.settingsDebugFeaturesSubtitle,
                        icon: "wrench.and.screwdriver"
                    )
                }

                if debugFeaturesEnabled {
                    Button {
                        liveActivity.previewLiveActivity()
                    } label: {
                        Label(AppText.settingsLiveActivityDebugTitle, systemImage: "waveform.path.ecg")
                    }
                    Button {
                        liveActivity.dismissImmediately()
                    } label: {
                        Label(AppText.settingsLiveActivityDismissTitle, systemImage: "xmark.circle")
                    }
                }
            }
            #endif

            if showsDisconnectToolbarButton {
                Section {
                    Button(role: .destructive) {
                        showDisconnectConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(AppText.disconnect)
                            Spacer()
                        }
                    }
                    .accessibilityHint(AppText.disconnectMessage)
                    .confirmationDialog(
                        AppText.disconnect,
                        isPresented: $showDisconnectConfirmation
                    ) {
                        Button(AppText.disconnect, role: .destructive) {
                            liveActivity.dismissImmediately()
                            connection.manualDisconnect()
                        }
                        Button(AppText.done, role: .cancel) {}
                    } message: {
                        Text(AppText.disconnectMessage)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: liveActivitiesEnabled) { _, enabled in
            if !enabled {
                liveActivity.dismissImmediately()
            }
        }
        .task {
            await gitHubStars.refresh()
        }
    }

    private var starGoalRow: some View {
        let isLoaded = gitHubStars.starCount != nil
        let count = gitHubStars.starCount ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(AppText.settingsStarGoalTitle, systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(AppText.settingsStarGoalProgress(count, goal: gitHubStars.goal))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: gitHubStars.progress)
                    .tint(Color.appUserAccent)
            }
            .redacted(reason: isLoaded ? [] : .placeholder)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppText.settingsStarGoalTitle)
            .accessibilityValue(isLoaded ? AppText.settingsStarGoalProgress(count, goal: gitHubStars.goal) : "")

            Text(AppText.settingsStarGoalBody(goal: gitHubStars.goal))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func preferenceLabel(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var showsDisconnectToolbarButton: Bool {
        switch connection.state {
        case .connected, .reconnecting, .connecting:
            true
        case .disconnected, .error:
            false
        }
    }

    private var appVersionBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        guard let build, !build.isEmpty, build != version else {
            return version
        }
        return "Version \(version) (\(build))"
    }
}
