import SwiftUI
import UIKit

/// Full-message text in a native, selectable text view. SwiftUI's per-`Text`
/// selection fights the bubble's long-press menu and the scroll view, so
/// selecting a passage or reading a very long message happens here instead.
struct SelectableTextSheet: View {
    static let maximumDisplayedCharacters = 120_000
    fileprivate static let maximumLinkDetectionUTF8Bytes = 12_000

    let text: String
    var title: String = "Select Text"
    var subtitle: String? = nil
    var onReuseInComposer: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyAll = false
    @State private var usesMonospacedFont = false

    private var displayedSlice: (text: String, isTruncated: Bool) {
        guard let cutIndex = text.index(
            text.startIndex,
            offsetBy: Self.maximumDisplayedCharacters,
            limitedBy: text.endIndex
        ), cutIndex < text.endIndex else {
            return (text, false)
        }
        return (String(text[..<cutIndex]), true)
    }

    var body: some View {
        let slice = displayedSlice

        NavigationStack {
            VStack(spacing: 0) {
                if slice.isTruncated {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Showing first 120,000 characters for smooth scrolling. Copy All copies the entire message.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }

                SelectableTextView(
                    text: slice.text,
                    usesMonospacedFont: usesMonospacedFont
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title)
                            .font(.headline)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                        didCopyAll = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            didCopyAll = false
                        }
                    } label: {
                        Label(
                            didCopyAll ? "Copied" : "Copy All",
                            systemImage: didCopyAll ? "checkmark" : "doc.on.doc"
                        )
                    }

                    Button {
                        usesMonospacedFont.toggle()
                    } label: {
                        Image(systemName: usesMonospacedFont ? "textformat" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(usesMonospacedFont ? "Use standard font" : "Use monospaced font")

                    if let onReuseInComposer {
                        Button {
                            onReuseInComposer(text)
                            dismiss()
                        } label: {
                            Image(systemName: "arrow.up.doc")
                        }
                        .accessibilityLabel("Reuse in Composer")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppText.done) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Sheet for inspecting or editing a large pasted snippet in the chat composer.
struct PastedSnippetEditorSheet: View {
    let snippet: ComposerPastedSnippet
    let onSave: (String) -> Bool
    let onExpandIntoField: (() -> Void)?
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftText: String
    @State private var usesMonospacedFont = false
    @State private var didCopy = false
    @State private var didExplicitlyFinish = false

    init(
        snippet: ComposerPastedSnippet,
        onSave: @escaping (String) -> Bool,
        onExpandIntoField: (() -> Void)? = nil,
        onRemove: @escaping () -> Void
    ) {
        self.snippet = snippet
        self.onSave = onSave
        self.onExpandIntoField = onExpandIntoField
        self.onRemove = onRemove
        if snippet.isEditableInSheet {
            self._draftText = State(initialValue: snippet.text)
        } else {
            let cut = snippet.text.index(
                snippet.text.startIndex,
                offsetBy: SelectableTextSheet.maximumDisplayedCharacters,
                limitedBy: snippet.text.endIndex
            ) ?? snippet.text.endIndex
            self._draftText = State(initialValue: String(snippet.text[..<cut]))
        }
    }

    private var currentMetricsLabel: String {
        guard snippet.isEditableInSheet, draftText.utf8.count != snippet.byteCount else {
            return snippet.metricsLabel
        }
        return LongTextMetrics.computeBounded(for: draftText).summaryLabel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !snippet.isEditableInSheet {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Previewing first 120,000 characters. The complete pasted text (\(snippet.metricsLabel)) will be sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                }

                EditableTextView(
                    text: $draftText,
                    isEditable: snippet.isEditableInSheet,
                    usesMonospacedFont: usesMonospacedFont
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Pasted Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Pasted Text")
                            .font(.headline)
                        Text(currentMetricsLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItemGroup(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        didExplicitlyFinish = true
                        onRemove()
                        dismiss()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }

                    Menu {
                        Button {
                            UIPasteboard.general.string = snippet.isEditableInSheet ? draftText : snippet.text
                            didCopy = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                didCopy = false
                            }
                        } label: {
                            Label(didCopy ? "Copied" : "Copy All", systemImage: "doc.on.doc")
                        }

                        Button {
                            usesMonospacedFont.toggle()
                        } label: {
                            Label(
                                usesMonospacedFont ? "Standard Font" : "Monospaced Font",
                                systemImage: usesMonospacedFont ? "textformat" : "chevron.left.forwardslash.chevron.right"
                            )
                        }

                        if let onExpandIntoField, snippet.canExpandIntoTextField {
                            Button {
                                if snippet.isEditableInSheet, draftText != snippet.text {
                                    guard onSave(draftText) else { return }
                                }
                                didExplicitlyFinish = true
                                onExpandIntoField()
                                dismiss()
                            } label: {
                                Label("Move to Text Field", systemImage: "character.cursor.ibeam")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Pasted text options")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppText.done) {
                        if snippet.isEditableInSheet, draftText != snippet.text {
                            guard onSave(draftText) else { return }
                        }
                        didExplicitlyFinish = true
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            if !didExplicitlyFinish, snippet.isEditableInSheet, draftText != snippet.text {
                _ = onSave(draftText)
            }
        }
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String
    let usesMonospacedFont: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        // Synchronous link detection scans the entire buffer on MainActor; skip
        // it on large payloads so opening a 100 KB log or prompt stays instant.
        view.dataDetectorTypes = text.utf8.count <= SelectableTextSheet.maximumLinkDetectionUTF8Bytes ? [.link] : []
        view.backgroundColor = .clear
        view.font = resolvedFont
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let desiredDetectors: UIDataDetectorTypes = text.utf8.count <= SelectableTextSheet.maximumLinkDetectionUTF8Bytes ? [.link] : []
        if uiView.dataDetectorTypes != desiredDetectors {
            uiView.dataDetectorTypes = desiredDetectors
        }
        if uiView.font != resolvedFont {
            uiView.font = resolvedFont
        }
        if uiView.text != text {
            uiView.text = text
        }
    }

    private var resolvedFont: UIFont {
        if usesMonospacedFont {
            return UIFontMetrics(forTextStyle: .footnote)
                .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        return UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 16))
    }
}

private struct EditableTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let usesMonospacedFont: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = isEditable
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.backgroundColor = .clear
        view.font = resolvedFont
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.text = $text
        if uiView.isEditable != isEditable {
            uiView.isEditable = isEditable
        }
        if uiView.font != resolvedFont {
            uiView.font = resolvedFont
        }
        if !context.coordinator.isUpdatingFromUIKit, uiView.text != text {
            uiView.text = text
        }
    }

    private var resolvedFont: UIFont {
        if usesMonospacedFont {
            return UIFontMetrics(forTextStyle: .footnote)
                .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        return UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .systemFont(ofSize: 15))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isUpdatingFromUIKit = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            isUpdatingFromUIKit = true
            text.wrappedValue = textView.text ?? ""
            isUpdatingFromUIKit = false
        }
    }
}
