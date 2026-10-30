import SwiftUI

struct MeridianUsageView: View {
    @Environment(\.meridianUsageService) private var meridianService
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            endpointSection

            if let snapshot = meridianService.snapshot {
                summarySection(snapshot)
                accountsSection(snapshot)

                if !snapshot.models24h.isEmpty {
                    modelsSection(snapshot)
                }
            } else if meridianService.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Meridian usage…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = meridianService.errorMessage {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.appWarning)
                    Button("Try Again") {
                        Task { await meridianService.refresh() }
                    }
                }
            }
        }
        .navigationTitle("Meridian Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await meridianService.refresh() }
                } label: {
                    if meridianService.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(meridianService.isLoading)
                .accessibilityLabel("Refresh Meridian usage")
            }
        }
        .refreshable {
            await meridianService.refresh()
        }
        .task {
            await meridianService.refresh()
        }
    }

    private var endpointSection: some View {
        Section {
            @Bindable var service = meridianService
            TextField("http://host:3456 (optional)", text: $service.customEndpointURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.subheadline, design: .monospaced))
                .onSubmit {
                    Task { await meridianService.refresh() }
                }

            if let endpoint = meridianService.snapshot?.endpointURL,
               let url = URL(string: endpoint) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open Meridian Dashboard", systemImage: "safari")
                }
            }
        } header: {
            Text("Meridian Endpoint")
        } footer: {
            Text("Leave blank to automatically check port 3456 on your connected OpenCode server host.")
        }
    }

    private func summarySection(_ snapshot: MeridianUsageSnapshot) -> some View {
        Section("Engine & 24h Telemetry") {
            if let version = snapshot.engineVersion {
                LabeledContent("Engine", value: "v\(version)")
            }
            if let routing = snapshot.routingMode {
                LabeledContent("Routing", value: routing)
            }
            if let requests = snapshot.totalRequests24h {
                LabeledContent("24h Requests", value: requests.formatted())
            }
            if let usd = snapshot.totalUsd24h {
                LabeledContent(
                    "24h Est. Value",
                    value: usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))
                )
            }
            if let cacheHit = snapshot.cacheHitRate24h {
                LabeledContent("Cache Hit Rate", value: "\(Int((cacheHit * 100).rounded()))%")
            }
        }
    }

    private func accountsSection(_ snapshot: MeridianUsageSnapshot) -> some View {
        Section {
            ForEach(snapshot.profiles) { profile in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.appPrimary)
                                    .lineLimit(1)

                                if profile.isActive {
                                    Text("ACTIVE")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color.appOnAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.appAccent, in: Capsule())
                                }
                            }

                            Text(profile.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !profile.isActive {
                            Button {
                                Task { await meridianService.activateProfile(profile.id) }
                            } label: {
                                if meridianService.switchingProfileID == profile.id {
                                    ProgressView()
                                } else {
                                    Text("Use")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(meridianService.switchingProfileID != nil)
                        }
                    }

                    ForEach(profile.windows) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(window.label) quota")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text("\(window.remainingPercent)% left")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(quotaTint(for: window))
                                if let resetDate = window.resetDate {
                                    Text("· resets \(resetDate, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            ProgressView(value: window.remainingFraction)
                                .tint(quotaTint(for: window))
                        }
                    }

                    if let failure = profile.failureReason, !failure.isEmpty {
                        Label("Last check: \(failure.replacingOccurrences(of: "_", with: " "))", systemImage: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Accounts (\(snapshot.profiles.count))")
        }
    }

    private func modelsSection(_ snapshot: MeridianUsageSnapshot) -> some View {
        Section("24h Model Breakdown") {
            ForEach(snapshot.models24h) { model in
                HStack {
                    Text(model.id)
                        .font(.system(.footnote, design: .monospaced))
                    Spacer()
                    Text("\(model.requests.formatted()) req")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let usd = model.estimatedUsd {
                        Text(usd.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                            .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
    }

    private func quotaTint(for window: MeridianWindowQuota) -> Color {
        if window.remainingPercent <= 5 { return .red }
        if window.remainingPercent <= 20 { return .orange }
        return Color.appAccent
    }
}

struct MeridianInsightsCard: View {
    @Environment(\.meridianUsageService) private var meridianService
    @State private var showFullMeridianSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "MERIDIAN QUOTAS")
                Spacer()
                Button("Details") {
                    showFullMeridianSheet = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appAccent)
            }

            SurfaceCard(padding: 14, cornerRadius: 10) {
                if let snapshot = meridianService.snapshot, !snapshot.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(snapshot.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(profile.displayName)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.appPrimary)
                                        .lineLimit(1)
                                    if profile.isActive {
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(Color.appAccent)
                                    }
                                    Spacer()
                                    Text(profile.providerBadge)
                                        .font(.caption2)
                                        .foregroundStyle(Color.appSecondary)
                                }

                                HStack(spacing: 10) {
                                    ForEach(profile.windows) { window in
                                        Text("\(window.label): \(window.remainingPercent)% left")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(window.remainingPercent <= 10 ? .orange : Color.appSecondary)
                                    }
                                }
                            }
                        }
                    }
                } else if meridianService.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Checking Meridian accounts…")
                            .font(.footnote)
                            .foregroundStyle(Color.appSecondary)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("View live Claude & ChatGPT account quotas")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.appPrimary)
                            Text("Connects to Meridian on port 3456 or a custom URL.")
                                .font(.caption)
                                .foregroundStyle(Color.appSecondary)
                        }
                        Spacer()
                        Button("Configure") {
                            showFullMeridianSheet = true
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .task {
            if meridianService.snapshot == nil {
                await meridianService.refresh()
            }
        }
        .sheet(isPresented: $showFullMeridianSheet) {
            NavigationStack {
                MeridianUsageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(AppText.done) {
                                showFullMeridianSheet = false
                            }
                        }
                    }
            }
        }
    }
}
