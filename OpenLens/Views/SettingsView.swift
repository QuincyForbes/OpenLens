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
    @AppStorage(AppPreferenceKeys.compactSessionRows) private var compactSessionRows = false
    private let appearancePreference = AppearancePreference.shared
    private let accentColor = AccentColorPreference.shared
    @AppStorage(FeatureFlags.debugFeaturesKey) private var debugFeaturesEnabled = FeatureFlags.debugFeaturesDefault

    var body: some View {
        let _ = appearancePreference.appearance
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
                .listRowBackground(Color.appSurface)
            } else {
                Section("Meridian") {
                    NavigationLink {
                        MeridianUsageView()
                    } label: {
                        Label("Meridian Quotas & Usage", systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
                .listRowBackground(Color.appSurface)
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
                                        .foregroundStyle(Color.appSecondary)
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
                .listRowBackground(Color.appSurface)
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
            .listRowBackground(Color.appSurface)

            Section(AppText.appearance) {
                Picker("Color Scheme", selection: $colorSchemeMode) {
                    ForEach(AppColorSchemeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme Palette")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(OpenLensAppearance.allCases) { item in
                            let isSelected = appearancePreference.appearance == item
                            let palette = item.theme.colors
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    appearancePreference.setAppearance(item)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    HStack(spacing: -4) {
                                        Circle()
                                            .fill(palette.background.color)
                                            .frame(width: 16, height: 16)
                                            .overlay(Circle().stroke(palette.separator.color, lineWidth: 1))
                                        Circle()
                                            .fill(palette.accent.color)
                                            .frame(width: 16, height: 16)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayName)
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.appPrimary)
                                        Text(item.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.appSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(Color.appUserAccent)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? Color.appUserAccent.opacity(0.12) : Color.appTertiary)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isSelected ? Color.appUserAccent : Color.appSeparator, lineWidth: isSelected ? 1.5 : 1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent Presets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondary)
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
            .listRowBackground(Color.appSurface)

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
            .listRowBackground(Color.appSurface)

            Text(appVersionBuild)
                .foregroundStyle(Color.appSecondary)
                .listRowBackground(Color.appSurface)

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
            .listRowBackground(Color.appSurface)
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
                .listRowBackground(Color.appSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .foregroundStyle(Color.appPrimary)
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
                        .foregroundStyle(Color.appSecondary)
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
                .foregroundStyle(Color.appSecondary)
        }
        .padding(.vertical, 4)
    }

    private func preferenceLabel(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.appUserAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(Color.appPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.appSecondary)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(Color.appSecondary)
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
