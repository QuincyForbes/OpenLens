import SwiftUI
import UIKit

struct SettingsView: View {
    private let repositoryURL = URL(string: "https://github.com/martynpekala/OpenLens")!

    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.instanceStatusMonitor) private var statusMonitor
    @Environment(\.liveActivity) private var liveActivity
    @Environment(\.requestReviewPrompt) private var requestReviewPrompt
    @Environment(\.gitHubStarsService) private var gitHubStars
    @Environment(AppRouter.self) private var router: AppRouter?

    @State private var showDisconnectConfirmation = false
    @State private var editorMode: InstanceEditorSheet.Mode?
    @State private var switchErrorMessage: String?

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
                    if let active = savedConnections.activeConnection, active.hasCustomName {
                        detailRow("Instance", value: active.displayName)
                    }
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

            instancesSection

            Section(AppText.settingsAppPreferences) {
                Toggle(isOn: $showThinking) {
                    preferenceLabel(AppText.showThinking, subtitle: AppText.showThinkingSubtitle, icon: "brain")
                }
                #if !targetEnvironment(macCatalyst)
                Toggle(isOn: $hapticsEnabled) {
                    preferenceLabel(AppText.settingsHaptics, subtitle: AppText.settingsHapticsSubtitle, icon: "hand.tap")
                }
                Toggle(isOn: $liveActivitiesEnabled) {
                    preferenceLabel(AppText.settingsLiveActivities, subtitle: AppText.settingsLiveActivitiesSubtitle, icon: "platter.filled.top.iphone")
                }
                #endif
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

            #if targetEnvironment(macCatalyst)
            Section("Keyboard Shortcuts") {
                detailRow("Send Prompt", value: "Return / ⌘Return")
                detailRow("New Line in Composer", value: "⇧Return")
                detailRow("Paste Image, File, or Text", value: "⌘V / ⌥⌘V")
                detailRow("Attach File or Image", value: "⇧⌘A")
                detailRow("Choose Model", value: "⇧⌘M")
                detailRow("New Session", value: "⌘N")
                detailRow("Quick Switch Session", value: "⌘K")
                detailRow("Switch OpenCode Instance", value: "⇧⌘I")
                detailRow("Search Sessions", value: "⌥⌘F")
                detailRow("Toggle Sidebar", value: "⌥⌘S")
                detailRow("Stop Agent Response", value: "⌘.")
            }
            .listRowBackground(Color.appSurface)
            #endif

            Section {
                if gitHubStars.state != .failed {
                    starGoalRow
                }
                Link(destination: repositoryURL) {
                    Label(AppText.settingsSupportGitHubCTA, systemImage: "arrow.up.right.square")
                }
                .tint(Color.appUserAccent)
                #if !targetEnvironment(macCatalyst)
                Button {
                    requestReviewPrompt()
                } label: {
                    Label(AppText.settingsSupportReviewCTA, systemImage: "star.bubble.fill")
                }
                #endif
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

                #if !targetEnvironment(macCatalyst)
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
                #endif
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
            refreshInstanceStatuses()
            await gitHubStars.refresh()
        }
        .sheet(item: $editorMode) { mode in
            InstanceEditorSheet(
                mode: mode,
                onSaved: {
                    refreshInstanceStatuses()
                }
            )
            .presentationDetents([.medium, .large])
            .adaptiveSheetDragIndicator()
            .presentationBackground(Color.appBackground)
        }
    }

    private var instancesSection: some View {
        Section {
            if let switchErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appWarning)
                    Text(switchErrorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.appSecondary)
                    Spacer()
                    Button {
                        self.switchErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(savedConnections.connections) { saved in
                instanceRow(saved)
            }

            Button {
                editorMode = .add(prefillURL: nil, prefillName: nil)
            } label: {
                Label("Add OpenCode Instance", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.appUserAccent)
            }

            if router != nil {
                Button {
                    router?.requestInstanceSwitcher()
                } label: {
                    Label("Discover & Manage Instances…", systemImage: "server.rack")
                        .foregroundStyle(Color.appPrimary)
                }
            }
        } header: {
            HStack {
                Text("OpenCode Instances")
                Spacer()
                if statusMonitor.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else if savedConnections.connections.count > 1 {
                    Button {
                        refreshInstanceStatuses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(Color.appSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh instance status")
                }
            }
        }
        .listRowBackground(Color.appSurface)
    }

    @ViewBuilder
    private func instanceRow(_ saved: SavedConnection) -> some View {
        let isActive = saved.id == savedConnections.activeConnectionID
            && (connection.isConnected || connection.isReconnecting)
        let isSwitchingThis = connection.switchingToConnectionID == saved.id
        let status = statusMonitor.status(for: saved.id)

        HStack(spacing: 10) {
            Button {
                guard !isActive, connection.switchingToConnectionID == nil else { return }
                switchToSavedInstance(saved)
            } label: {
                HStack(spacing: 10) {
                    InstanceStatusDot(
                        isActive: isActive,
                        isReconnecting: isActive && connection.isReconnecting,
                        status: status
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(saved.displayName)
                            .font(saved.hasCustomName
                                ? .system(size: 14, weight: .semibold)
                                : .system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.appPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        instanceSubtitle(saved: saved, isActive: isActive, status: status)
                    }

                    Spacer()

                    if isSwitchingThis {
                        ProgressView()
                            .controlSize(.small)
                    } else if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.appUserAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editorMode = .edit(saved)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit \(saved.displayName)")
            .accessibilityLabel("Edit \(saved.displayName)")

            #if targetEnvironment(macCatalyst)
            if !isActive {
                Button(role: .destructive) {
                    savedConnections.removeConnection(saved)
                    refreshInstanceStatuses()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppText.forget)
                .accessibilityLabel("\(AppText.forget) \(saved.displayName)")
            }
            #endif
        }
        .contextMenu {
            if !isActive {
                Button {
                    switchToSavedInstance(saved)
                } label: {
                    Label("Switch to Instance", systemImage: "arrow.left.arrow.right")
                }
            }
            Button {
                editorMode = .edit(saved)
            } label: {
                Label("Edit Instance", systemImage: "pencil")
            }
            if !isActive {
                Divider()
                Button(role: .destructive) {
                    savedConnections.removeConnection(saved)
                    refreshInstanceStatuses()
                } label: {
                    Label(AppText.forget, systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isActive {
                Button(role: .destructive) {
                    savedConnections.removeConnection(saved)
                    refreshInstanceStatuses()
                } label: {
                    Label("Forget", systemImage: "trash")
                }
            }
            Button {
                editorMode = .edit(saved)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(Color.appUserAccent)
        }
    }

    private func instanceSubtitle(
        saved: SavedConnection,
        isActive: Bool,
        status: InstanceStatusMonitor.Status
    ) -> some View {
        HStack(spacing: 5) {
            if saved.hasCustomName {
                Text(saved.hostDisplay)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.appSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(saved.username)
                    .font(.caption)
                    .foregroundStyle(Color.appSecondary)
            }

            if case .online(_, _, let running) = status, let running, running > 0 {
                Text("· \(running) running")
                    .font(.caption)
                    .foregroundStyle(Color.appSuccess)
            } else if case .offline = status, !isActive {
                Text("· Offline")
                    .font(.caption)
                    .foregroundStyle(Color.appDanger.opacity(0.85))
            }
        }
    }

    private func switchToSavedInstance(_ saved: SavedConnection) {
        switchErrorMessage = nil
        Task {
            let result = await connection.switchToInstance(saved)
            if case .failure(let error) = result, !(error is CancellationError) {
                switchErrorMessage = error.localizedDescription
                refreshInstanceStatuses()
            }
        }
    }

    private func refreshInstanceStatuses() {
        let activeCount = sessionsService.effectiveStatuses.values
            .filter { SessionListOrganization.isWorking($0) }
            .count
        statusMonitor.refreshStatuses(
            for: savedConnections.connections,
            activeConnectionID: savedConnections.activeConnectionID,
            activeConnection: connection,
            activeSessionCount: activeCount
        )
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
