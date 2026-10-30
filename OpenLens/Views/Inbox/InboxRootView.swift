import SwiftUI

private enum InboxLayout {
    static let screenInset: CGFloat = 20
    static let screenVerticalPadding: CGFloat = 24
    static let sectionGap: CGFloat = 28
    static let rowPaddingHorizontal: CGFloat = 16
    static let rowPaddingVertical: CGFloat = 14
}

struct InboxRootView: View {
    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Bindable var chatClient: ChatClient

    @Environment(\.inboxService) private var inboxService
    @Environment(\.sessionsService) private var sessionsService
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router: AppRouter?

    @State private var viewState: ViewState = .idle
    @State private var snapshot = InboxSnapshot(permissions: [], questions: [], forms: [])
    @State private var sessionsByID: [String: OCSession] = [:]
    @State private var activeQuestion: OCQuestionRequest?
    @State private var activeForm: OCFormRequest?
    @State private var isResolvingForm = false

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView()
                    .tint(Color.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
            } else {
                content
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadInbox()
            if ScreenshotFixtures.opensGlobalFormSheet {
                activeForm = snapshot.globalForms.first
            }
        }
        .refreshable {
            await loadInbox(force: true)
        }
        .sheet(item: $activeQuestion) { question in
            QuestionView(
                request: question,
                onSubmit: { answers in
                    Task {
                        await submitQuestion(question, answers: answers)
                    }
                },
                onDismiss: {
                    Task {
                        await rejectQuestion(question)
                    }
                },
                onDefer: {
                    activeQuestion = nil
                }
            )
        }
        .sheet(item: $activeForm) { form in
            FormView(
                form: form,
                onSubmit: { answer in
                    Task {
                        await submitForm(form, answer: answer)
                    }
                },
                onCancel: {
                    Task {
                        await cancelForm(form)
                    }
                },
                isSubmitting: isResolvingForm,
                onDefer: {
                    activeForm = nil
                }
            )
            .interactiveDismissDisabled(isResolvingForm)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage,
           snapshot.permissions.isEmpty,
           snapshot.questions.isEmpty,
           snapshot.forms.isEmpty {
            FeaturePlaceholderView(
                title: "Inbox",
                subtitle: errorMessage,
                symbol: "exclamationmark.triangle",
                highlights: [
                    "Pull to refresh and retry",
                    "Inbox reads pending permissions, questions, and forms",
                    "Chat keeps working while inbox reloads"
                ]
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: InboxLayout.sectionGap) {
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if let warning = snapshot.warning {
                        errorCard(warning)
                    }

                    if !snapshot.globalForms.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionHeader(title: "Global MCP forms", count: snapshot.globalForms.count)
                            formsCard(snapshot.globalForms)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Permissions", count: snapshot.permissions.count)
                        permissionsCard
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Questions", count: snapshot.questions.count)
                        questionsCard
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Forms", count: snapshot.sessionForms.count)
                        formsCard(snapshot.sessionForms)
                    }
                }
                .padding(.horizontal, InboxLayout.screenInset)
                .padding(.bottom, InboxLayout.screenVerticalPadding)
            }
            .background(Color.appBackground)
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSecondary)
                .kerning(0.5)

            Spacer(minLength: 8)

            Text(count == 1 ? "1 item" : "\(count) items")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.appSecondary)
        }
    }

    private var permissionsCard: some View {
        SurfaceCard(padding: 0) {
            if snapshot.permissions.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending permission requests.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.permissions.enumerated()), id: \.element.id) { index, permission in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Permission", tint: .orange)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(permission.title?.nilIfBlank ?? "Permission request")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    if let description = permission.description?.nilIfBlank {
                                        Text(description)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.appSecondary)
                                    }

                                    if let tool = permission.toolDisplayName?.nilIfBlank {
                                        metadataChip(text: tool, monospaced: true)
                                    }

                                    sessionContextRow(for: permission.sessionID)
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: AppText.deny, fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await respondToPermission(permission, reply: .reject)
                                    }
                                }
                                actionButton(title: AppText.allowOnce, fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    Task {
                                        await respondToPermission(permission, reply: .once)
                                    }
                                }
                                actionButton(title: AppText.allowAll, fill: Color.appWarning.opacity(0.14), foreground: Color.appWarning) {
                                    Task {
                                        await respondToPermission(permission, reply: .always)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < snapshot.permissions.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private var questionsCard: some View {
        SurfaceCard(padding: 0) {
            if snapshot.questions.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending questions from the agent.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.questions.enumerated()), id: \.element.id) { index, question in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: "Question", tint: Color.appPrimary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(question.questions.first?.header.nilIfBlank ?? "Agent question")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    Text(question.questions.first?.question.nilIfBlank ?? "Open the sheet to answer this question.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.appSecondary)
                                        .lineLimit(3)

                                    metadataChip(
                                        text: "\(question.questions.count) prompt\(question.questions.count == 1 ? "" : "s")",
                                        monospaced: false
                                    )

                                    sessionContextRow(for: question.sessionID)
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: "Answer", fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    activeQuestion = question
                                }
                                actionButton(title: "Dismiss", fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await rejectQuestion(question)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < snapshot.questions.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func formsCard(_ forms: [OCFormRequest]) -> some View {
        SurfaceCard(padding: 0) {
            if forms.isEmpty {
                emptyRow(symbol: "checkmark.circle", text: "No pending forms from the agent.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(forms.enumerated()), id: \.element.identity) { index, form in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                itemBadge(title: form.isGlobal ? "MCP" : "Form", tint: Color.appPrimary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(form.title.nilIfBlank ?? "Agent form")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.appPrimary)

                                    Text(form.hasUnsupportedFields
                                        ? "Open this form to see fields OpenLens cannot safely submit."
                                        : "\(form.fields.count) field\(form.fields.count == 1 ? "" : "s") ready for review.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.appSecondary)
                                        .lineLimit(3)

                                    if form.isGlobal {
                                        Text("Workspace interaction · no chat owner")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.appSecondary)
                                        if let directory = form.globalDirectory {
                                            Text(directory)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Color.appSecondary)
                                                .lineLimit(2)
                                        }
                                    } else {
                                        sessionContextRow(for: form.sessionID)
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                actionButton(title: "Open", fill: Color.appAccent, foreground: Color.appOnAccent) {
                                    activeForm = form
                                }
                                actionButton(title: "Cancel", fill: Color.appTertiary, foreground: Color.appPrimary) {
                                    Task {
                                        await cancelForm(form)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
                        .padding(.vertical, InboxLayout.rowPaddingVertical)

                        if index < forms.count - 1 {
                            SurfaceDivider()
                        }
                    }
                }
            }
        }
    }

    private func actionButton(title: String, fill: Color, foreground: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func itemBadge(title: String, tint: Color) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appSurface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.3), lineWidth: 1)
            )
    }

    private func metadataChip(text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(monospaced ? .system(size: 12, weight: .medium, design: .monospaced) : .system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.appSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appTertiary, in: Capsule())
    }

    private func emptyRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appSecondary)

            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.appSecondary)

            Spacer()
        }
        .padding(.horizontal, InboxLayout.rowPaddingHorizontal)
        .padding(.vertical, InboxLayout.rowPaddingVertical)
    }

    private func errorCard(_ message: String) -> some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.appSecondary)
                Spacer()
            }
        }
    }

    private var isInitialLoading: Bool {
        if case .loading = viewState {
            return snapshot.permissions.isEmpty && snapshot.questions.isEmpty && snapshot.forms.isEmpty
        }
        return false
    }

    private var errorMessage: String? {
        if case .error(let message) = viewState {
            return message
        }
        return nil
    }

    @ViewBuilder
    private func sessionContextRow(for sessionID: String?) -> some View {
        if let sessionID, !sessionID.isEmpty, sessionID != "global" {
            let session = sessionsByID[sessionID]
            let title = session?.title.nilIfBlank ?? sessionID
            let repo = session.map(SessionListOrganization.repositoryTitle(for:))
            HStack(spacing: 8) {
                Label(
                    repo.map { "\(title) · \($0)" } ?? title,
                    systemImage: "bubble.left.and.bubble.right"
                )
                .font(.caption)
                .foregroundStyle(Color.appSecondary)
                .lineLimit(1)

                if let session, router != nil {
                    Spacer(minLength: 4)
                    Button("Open Chat") {
                        chatClient.prepareForOpeningSession(session)
                        router?.selectChatSession(session)
                        dismiss()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }

    private func loadInbox(force: Bool = false) async {
        if !force, case .loaded = viewState {
            return
        }

        viewState = .loading
        do {
            async let loadedSessions = try? sessionsService.listAllSessions()
            snapshot = try await inboxService.loadInbox()
            if let sessions = await loadedSessions {
                sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            }
            viewState = .loaded
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func respondToPermission(_ permission: OCPermissionRequest, reply: OCPermissionReply) async {
        do {
            try await inboxService.respondToPermission(permission, reply: reply)
            if chatClient.pendingPermission?.id == permission.id {
                chatClient.pendingPermission = nil
                chatClient.showPermissionAlert = false
            }
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func submitQuestion(_ question: OCQuestionRequest, answers: [[String]]) async {
        do {
            try await inboxService.respondToQuestion(requestID: question.id, answers: answers)
            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func rejectQuestion(_ question: OCQuestionRequest) async {
        do {
            try await inboxService.rejectQuestion(requestID: question.id)
            if chatClient.pendingQuestion?.id == question.id {
                chatClient.pendingQuestion = nil
                chatClient.showQuestionSheet = false
            }
            activeQuestion = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func submitForm(_ form: OCFormRequest, answer: [String: OCFormValue]) async {
        guard !isResolvingForm else { return }
        isResolvingForm = true
        defer { isResolvingForm = false }

        do {
            try await inboxService.respondToForm(form, answer: answer)
            if chatClient.pendingForm?.id == form.id, chatClient.pendingForm?.owner == form.owner {
                chatClient.pendingForm = nil
                chatClient.showFormSheet = false
            }
            activeForm = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    private func cancelForm(_ form: OCFormRequest) async {
        guard !isResolvingForm else { return }
        isResolvingForm = true
        defer { isResolvingForm = false }

        do {
            try await inboxService.cancelForm(form)
            if chatClient.pendingForm?.id == form.id, chatClient.pendingForm?.owner == form.owner {
                chatClient.pendingForm = nil
                chatClient.showFormSheet = false
            }
            activeForm = nil
            await loadInbox(force: true)
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }
}
