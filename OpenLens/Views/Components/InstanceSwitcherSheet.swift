import SwiftUI

// MARK: - Instance Switcher Sheet

/// Native multi-instance manager and quick switcher for OpenCode servers.
/// Allows switching live between configured OpenCode instances without disconnecting first,
/// probing live reachability/running counts on demand, discovering nearby LAN servers,
/// and adding/editing/pairing new instances.
struct InstanceSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.instanceStatusMonitor) private var statusMonitor

    @State private var discovery = BonjourDiscovery()
    @State private var editorMode: InstanceEditorSheet.Mode?
    @State private var switchErrorMessage: String?
    @State private var connectionToForget: SavedConnection?

    private var activeSessionCount: Int {
        sessionsService.effectiveStatuses.values.filter { SessionListOrganization.isWorking($0) }.count
    }

    private var unsavedDiscoveredServers: [BonjourDiscovery.DiscoveredServer] {
        let savedKeys = savedConnections.otherSavedEndpointKeys(excludingConnectionID: nil)
        return discovery.discoveredServers.filter { server in
            !savedKeys.contains(normalizedEndpointKey(server.url))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let switchErrorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.appWarning)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Couldn’t Switch Instance")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.appPrimary)
                                Text(switchErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(Color.appSecondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                self.switchErrorMessage = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.appSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Color.appWarning.opacity(0.12))
                }

                Section {
                    if savedConnections.connections.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Saved Instances")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appPrimary)
                            Text("Add an OpenCode server to switch between machines or ports effortlessly.")
                                .font(.caption)
                                .foregroundStyle(Color.appSecondary)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(savedConnections.connections) { saved in
                            instanceRow(saved)
                        }
                    }

                    Button {
                        editorMode = .add(prefillURL: nil, prefillName: nil)
                    } label: {
                        Label("Add OpenCode Instance", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.appAccent)
                    }
                } header: {
                    HStack {
                        Text("OpenCode Instances")
                        Spacer()
                        if statusMonitor.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } footer: {
                    Text("Switching verifies the target server is reachable before changing your active session.")
                }
                .listRowBackground(Color.appSurface)

                if !unsavedDiscoveredServers.isEmpty || discovery.isSearching {
                    Section("Nearby on Local Network") {
                        ForEach(unsavedDiscoveredServers) { server in
                            Button {
                                editorMode = .add(prefillURL: server.url, prefillName: server.name)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bonjour")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.appAccent)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.appPrimary)
                                            .lineLimit(1)
                                        Text(server.url)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(Color.appSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer(minLength: 8)

                                    Text("Add")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.appAccent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.appAccent.opacity(0.14), in: Capsule())
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if unsavedDiscoveredServers.isEmpty && discovery.isSearching {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning local network…")
                                    .font(.caption)
                                    .foregroundStyle(Color.appSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.appSurface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Instances")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(statusMonitor.isRefreshing)
                    .help("Check server status")
                    .accessibilityLabel("Check server status")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(item: $editorMode) { mode in
                InstanceEditorSheet(
                    mode: mode,
                    onSwitched: {
                        dismiss()
                    },
                    onSaved: {
                        refreshStatuses()
                    }
                )
                .presentationDetents([.medium, .large])
                .adaptiveSheetDragIndicator()
                .presentationBackground(Color.appBackground)
            }
            .confirmationDialog(
                "Forget Instance?",
                isPresented: Binding(
                    get: { connectionToForget != nil },
                    set: { if !$0 { connectionToForget = nil } }
                ),
                presenting: connectionToForget
            ) { target in
                Button("Forget \"\(target.displayName)\"", role: .destructive) {
                    savedConnections.removeConnection(target)
                    connectionToForget = nil
                    refreshStatuses()
                }
                Button(AppText.cancel, role: .cancel) {
                    connectionToForget = nil
                }
            } message: { target in
                Text("Remove \(target.hostDisplay) from saved OpenCode instances. Cached sessions on that server are unaffected.")
            }
            .onAppear {
                refreshAll()
            }
            .onDisappear {
                discovery.stopBrowsing()
            }
        }
    }

    @ViewBuilder
    private func instanceRow(_ saved: SavedConnection) -> some View {
        let isActive = saved.id == savedConnections.activeConnectionID && (connection.isConnected || connection.isReconnecting)
        let isSwitchingThis = connection.switchingToConnectionID == saved.id
        let isAnySwitching = connection.switchingToConnectionID != nil
        let status = statusMonitor.status(for: saved.id)

        HStack(spacing: 12) {
            Button {
                guard !isActive, !isAnySwitching else { return }
                switchTo(saved)
            } label: {
                HStack(spacing: 12) {
                    InstanceStatusDot(
                        isActive: isActive,
                        isReconnecting: isActive && connection.isReconnecting,
                        status: status
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(saved.displayName)
                                .font(saved.hasCustomName
                                    ? .subheadline.weight(.semibold)
                                    : .system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.appPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if isActive {
                                Text(connection.isReconnecting ? "Reconnecting" : "Active")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(connection.isReconnecting ? Color.appWarning : Color.appSuccess)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (connection.isReconnecting ? Color.appWarning : Color.appSuccess).opacity(0.14),
                                        in: Capsule()
                                    )
                            }
                        }

                        HStack(spacing: 6) {
                            if saved.hasCustomName {
                                Text(saved.hostDisplay)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.appSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            if let statusLine = statusSummary(for: saved, isActive: isActive, status: status) {
                                if saved.hasCustomName {
                                    Text("·")
                                        .font(.caption)
                                        .foregroundStyle(Color.appSecondary.opacity(0.6))
                                }
                                Text(statusLine)
                                    .font(.caption)
                                    .foregroundStyle(statusSummaryColor(status: status, isActive: isActive))
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    if isSwitchingThis {
                        ProgressView()
                            .controlSize(.small)
                    } else if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isAnySwitching && !isSwitchingThis)

            Button {
                editorMode = .edit(saved)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit \(saved.displayName)")
            .accessibilityLabel("Edit \(saved.displayName)")
        }
        .contextMenu {
            if !isActive {
                Button {
                    switchTo(saved)
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
                    connectionToForget = saved
                } label: {
                    Label(AppText.forget, systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isActive {
                Button(role: .destructive) {
                    connectionToForget = saved
                } label: {
                    Label(AppText.forget, systemImage: "trash")
                }
            }
            Button {
                editorMode = .edit(saved)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(Color.appAccent)
        }
    }

    private func switchTo(_ saved: SavedConnection) {
        switchErrorMessage = nil
        Task {
            let result = await connection.switchToInstance(saved)
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                if !(error is CancellationError) {
                    switchErrorMessage = error.localizedDescription
                    refreshStatuses()
                }
            }
        }
    }

    private func refreshAll() {
        refreshStatuses()
        discovery.startBrowsing()
    }

    private func refreshStatuses() {
        statusMonitor.refreshStatuses(
            for: savedConnections.connections,
            activeConnectionID: savedConnections.activeConnectionID,
            activeConnection: connection,
            activeSessionCount: activeSessionCount
        )
    }

    private func statusSummary(
        for saved: SavedConnection,
        isActive: Bool,
        status: InstanceStatusMonitor.Status
    ) -> String? {
        switch status {
        case .checking:
            return "Checking…"
        case .online(let proto, let version, let running):
            var parts: [String] = []
            if let running, running > 0 {
                parts.append(running == 1 ? "1 running" : "\(running) running")
            } else {
                parts.append("Online")
            }
            if let version, !version.isEmpty {
                parts.append("\(proto.rawValue.uppercased()) · \(version)")
            } else {
                parts.append(proto.rawValue.uppercased())
            }
            return parts.joined(separator: " · ")
        case .offline:
            return "Offline"
        case .unknown:
            return isActive ? "Online" : saved.username
        }
    }

    private func statusSummaryColor(status: InstanceStatusMonitor.Status, isActive: Bool) -> Color {
        if isActive {
            return connection.isReconnecting ? Color.appWarning : Color.appSecondary
        }
        switch status {
        case .online:
            return Color.appSecondary
        case .offline:
            return Color.appDanger.opacity(0.85)
        case .checking, .unknown:
            return Color.appSecondary.opacity(0.75)
        }
    }

    private func normalizedEndpointKey(_ rawURL: String) -> String {
        rawURL.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Instance Status Dot

struct InstanceStatusDot: View {
    let isActive: Bool
    let isReconnecting: Bool
    let status: InstanceStatusMonitor.Status

    private var color: Color {
        if isActive {
            return isReconnecting ? Color.appWarning : Color.appSuccess
        }
        switch status {
        case .online:
            return Color.appSuccess
        case .offline:
            return Color.appDanger.opacity(0.8)
        case .checking:
            return Color.appWarning.opacity(0.8)
        case .unknown:
            return Color.appSecondary.opacity(0.4)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if isActive && !isReconnecting {
                    Circle()
                        .stroke(color.opacity(0.32), lineWidth: 3)
                }
            }
            .frame(width: 14, height: 14)
    }
}

// MARK: - Instance Editor Sheet (Add / Edit / Pair)

struct InstanceEditorSheet: View {
    enum Mode: Identifiable {
        case add(prefillURL: String?, prefillName: String?)
        case edit(SavedConnection)

        var id: String {
            switch self {
            case .add(let url, let name):
                return "add:\(url ?? ""):\(name ?? "")"
            case .edit(let conn):
                return "edit:\(conn.id)"
            }
        }
    }

    private enum ProbeState: Equatable {
        case idle
        case probing
        case success(String)
        case failure(String)
    }

    let mode: Mode
    var onSwitched: (() -> Void)? = nil
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.connection) private var connection
    @Environment(\.savedConnections) private var savedConnections

    @State private var name: String
    @State private var serverURL: String
    @State private var username: String
    @State private var password: String
    @State private var alternateServerURLs: [String]
    @State private var probeState: ProbeState = .idle
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var isQRScannerPresented = false

    private var editingConnection: SavedConnection? {
        if case .edit(let conn) = mode { return conn }
        return nil
    }

    private var isEditingActiveConnection: Bool {
        guard let editing = editingConnection else { return false }
        return editing.id == savedConnections.activeConnectionID
    }

    private var trimmedURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var detectedPairingLink: OpenCodePairingLink? {
        OpenCodePairingLink(rawValue: trimmedURL)
    }

    private var detectedDeepLink: DeepLinkConnection? {
        URL(string: trimmedURL).flatMap(DeepLinkConnection.init(from:))
    }

    private var canSave: Bool {
        !trimmedURL.isEmpty && !isSubmitting
    }

    init(
        mode: Mode,
        onSwitched: (() -> Void)? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onSwitched = onSwitched
        self.onSaved = onSaved

        switch mode {
        case .add(let prefillURL, let prefillName):
            _name = State(initialValue: prefillName ?? "")
            _serverURL = State(initialValue: prefillURL ?? "")
            _username = State(initialValue: "opencode")
            _password = State(initialValue: "")
            _alternateServerURLs = State(initialValue: [])
        case .edit(let conn):
            _name = State(initialValue: conn.name ?? "")
            _serverURL = State(initialValue: conn.serverURL)
            _username = State(initialValue: conn.username)
            _password = State(initialValue: conn.password)
            _alternateServerURLs = State(initialValue: conn.alternateServerURLs ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. MacBook Pro, Work Linux)", text: $name)
                        .textInputAutocapitalization(.words)

                    HStack(spacing: 8) {
                        TextField("http://host:4096 or pairing link", text: $serverURL)
                            .font(.system(size: 14, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onChange(of: serverURL) { _, _ in
                                if probeState != .idle { probeState = .idle }
                                submitError = nil
                            }

                        #if !targetEnvironment(macCatalyst)
                        if editingConnection == nil {
                            Button {
                                isQRScannerPresented = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.appAccent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Scan pairing QR code")
                        }
                        #endif
                    }

                    if detectedPairingLink != nil {
                        Label("OpenCode pairing link detected — will pair automatically on save.", systemImage: "link.badge.plus")
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                    } else if detectedDeepLink != nil {
                        Label("OpenLens connect link detected — credentials will be imported.", systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                    }
                } header: {
                    Text("Instance")
                } footer: {
                    Text("Each instance keeps its own sessions, cached history, workspaces, and default model.")
                }
                .listRowBackground(Color.appSurface)

                if detectedPairingLink == nil && detectedDeepLink == nil {
                    Section("Authentication") {
                        TextField("Username", text: $username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        SecureField("Password (optional)", text: $password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .listRowBackground(Color.appSurface)

                    Section {
                        Button {
                            testConnection()
                        } label: {
                            HStack(spacing: 10) {
                                switch probeState {
                                case .idle:
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Color.appAccent)
                                    Text("Test Connection")
                                        .foregroundStyle(Color.appPrimary)
                                case .probing:
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Checking server…")
                                        .foregroundStyle(Color.appSecondary)
                                case .success(let detail):
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.appSuccess)
                                    Text(detail)
                                        .foregroundStyle(Color.appSuccess)
                                case .failure(let message):
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.appDanger)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(Color.appDanger)
                                }
                                Spacer()
                            }
                        }
                        .disabled(trimmedURL.isEmpty || probeState == .probing || isSubmitting)
                    }
                    .listRowBackground(Color.appSurface)
                }

                if let submitError {
                    Section {
                        Label(submitError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appDanger)
                    }
                    .listRowBackground(Color.appDanger.opacity(0.1))
                }

                Section {
                    if editingConnection == nil || !isEditingActiveConnection {
                        Button {
                            saveInstance(andSwitch: true)
                        } label: {
                            HStack {
                                Spacer()
                                if isSubmitting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text(editingConnection == nil ? "Save & Switch" : "Save & Switch to Instance")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .foregroundStyle(Color.appAccent)
                        .disabled(!canSave)
                    }

                    Button {
                        saveInstance(andSwitch: false)
                    } label: {
                        HStack {
                            Spacer()
                            Text(editingConnection == nil ? "Add Without Switching" : "Save Changes")
                                .fontWeight(isEditingActiveConnection ? .semibold : .regular)
                            Spacer()
                        }
                    }
                    .foregroundStyle(isEditingActiveConnection ? Color.appAccent : Color.appPrimary)
                    .disabled(!canSave)
                }
                .listRowBackground(Color.appSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(editingConnection == nil ? "Add Instance" : "Edit Instance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.cancel) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
            #if !targetEnvironment(macCatalyst)
            .sheet(isPresented: $isQRScannerPresented) {
                NavigationStack {
                    QRCodeCameraView(isActive: isQRScannerPresented, usesDarkBackground: true) { code in
                        isQRScannerPresented = false
                        handleScannedCode(code)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Pairing QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(AppText.cancel) {
                                isQRScannerPresented = false
                            }
                        }
                    }
                }
            }
            #endif
        }
    }

    private func handleScannedCode(_ code: ScannedOpenLensCode) {
        submitError = nil
        switch code {
        case .direct(let deepLink):
            serverURL = deepLink.serverURL
            username = deepLink.username
            password = deepLink.password
            alternateServerURLs = deepLink.alternateServerURLs
        case .openCodePairing(let link):
            isSubmitting = true
            Task {
                defer { isSubmitting = false }
                do {
                    let paired = try await OpenCodePairingClient().pair(using: link)
                    serverURL = paired.serverURL
                    username = paired.username
                    password = paired.password
                    alternateServerURLs = paired.alternateServerURLs
                    probeState = .success("Paired — ready to save")
                } catch {
                    submitError = (error as? OpenCodePairingError)?.localizedDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func testConnection() {
        probeState = .probing
        submitError = nil
        let effectiveUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "opencode"
            : username.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let result = await connection.probeEndpoint(
                url: trimmedURL,
                username: effectiveUsername,
                password: password
            )
            switch result {
            case .success(let capabilities):
                let versionSuffix = capabilities.serverVersion.map { " · \($0)" } ?? ""
                probeState = .success("Online · \(capabilities.protocolVersion.rawValue.uppercased())\(versionSuffix)")
            case .failure(let error):
                probeState = .failure(error.localizedDescription)
            }
        }
    }

    private func saveInstance(andSwitch: Bool) {
        submitError = nil
        isSubmitting = true

        Task {
            defer { isSubmitting = false }

            var resolvedURL = trimmedURL
            var resolvedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedUsername.isEmpty { resolvedUsername = "opencode" }
            var resolvedPassword = password
            var resolvedAlternates = alternateServerURLs

            if let pairingLink = detectedPairingLink {
                do {
                    let paired = try await OpenCodePairingClient().pair(using: pairingLink)
                    resolvedURL = paired.serverURL
                    resolvedUsername = paired.username
                    resolvedPassword = paired.password
                    resolvedAlternates = paired.alternateServerURLs
                } catch {
                    submitError = (error as? OpenCodePairingError)?.localizedDescription ?? error.localizedDescription
                    return
                }
            } else if let deepLink = detectedDeepLink {
                resolvedURL = deepLink.serverURL
                resolvedUsername = deepLink.username
                resolvedPassword = deepLink.password
                resolvedAlternates = deepLink.alternateServerURLs
            }

            let cleanedName = name.nilIfBlank

            // Fast path: renaming the active instance without changing URL or credentials.
            if let editing = editingConnection,
               isEditingActiveConnection,
               editing.serverURL.trimmingCharacters(in: .whitespacesAndNewlines) == resolvedURL,
               editing.username == resolvedUsername,
               editing.password == resolvedPassword {
                savedConnections.renameConnection(id: editing.id, name: cleanedName)
                onSaved?()
                dismiss()
                return
            }

            let saved = savedConnections.addOrUpdateInstance(
                id: editingConnection?.id,
                name: cleanedName,
                serverURL: resolvedURL,
                username: resolvedUsername,
                password: resolvedPassword,
                alternateServerURLs: resolvedAlternates
            )
            onSaved?()

            let shouldReconnectNow = andSwitch || isEditingActiveConnection
            if shouldReconnectNow {
                let result = await connection.switchToInstance(
                    saved,
                    forceReconnect: isEditingActiveConnection
                )
                switch result {
                case .success:
                    dismiss()
                    onSwitched?()
                case .failure(let error):
                    if !(error is CancellationError) {
                        submitError = "Saved instance, but couldn’t connect yet: \(error.localizedDescription)"
                    }
                }
            } else {
                dismiss()
            }
        }
    }
}
