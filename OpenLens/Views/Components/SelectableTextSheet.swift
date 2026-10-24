import SwiftUI
import UIKit

/// Full-message text in a native, selectable text view. SwiftUI's per-`Text`
/// selection fights the bubble's long-press menu and the scroll view, so
/// selecting a passage or a whole reply is done here instead. Links are live.
struct SelectableTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyAll = false

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.string = text
                            didCopyAll = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                didCopyAll = false
                            }
                        } label: {
                            Label(didCopyAll ? "Copied" : "Copy All", systemImage: didCopyAll ? "checkmark" : "doc.on.doc")
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

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = [.link]
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}
