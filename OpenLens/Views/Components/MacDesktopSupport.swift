import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// Subtle pointer hover highlight for `.plain`-styled desktop/trackpad controls.
    func macHoverHighlight(
        cornerRadius: CGFloat = 10,
        tint: Color = Color.appPrimary,
        opacity: Double = 0.06
    ) -> some View {
        modifier(MacHoverHighlightModifier(cornerRadius: cornerRadius, tint: tint, opacity: opacity))
    }

    /// Hides the mobile bottom-sheet grabber pill on Mac Catalyst modal sheets.
    @ViewBuilder
    func adaptiveSheetDragIndicator() -> some View {
        #if targetEnvironment(macCatalyst)
        self.presentationDragIndicator(.hidden)
        #else
        self.presentationDragIndicator(.visible)
        #endif
    }

    /// Enables native mouse I-beam text selection on Mac Catalyst without
    /// competing with touch scrolling and long-press menus on iPhone/iPad.
    @ViewBuilder
    func macInlineTextSelection() -> some View {
        #if targetEnvironment(macCatalyst)
        self.textSelection(.enabled)
        #else
        self
        #endif
    }
}

private struct MacHoverHighlightModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let opacity: Double

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(opacity))
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

#if targetEnvironment(macCatalyst)
/// Configures native macOS window chrome and minimum split-view dimensions.
struct MacWindowSceneConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            Self.configureIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            Self.configureIfNeeded(from: uiView)
        }
    }

    private static func configureIfNeeded(from view: UIView) {
        guard let windowScene = view.window?.windowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 860, height: 580)
        if let titlebar = windowScene.titlebar {
            titlebar.toolbarStyle = .unified
            titlebar.titleVisibility = .hidden
        }
    }
}
#endif

/// Attaches `UIPasteConfiguration` and `UITextPasteDelegate` to SwiftUI's
/// underlying composer `UITextView` / `UITextField` so `Cmd+V` and Paste menus
/// accept screenshots, copied images, and Finder files without inserting bare
/// filenames into the text input.
struct ComposerPasteInterceptor: UIViewRepresentable {
    var isEnabled: Bool
    var isFocused: Bool
    var onPasteProviders: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onPasteProviders: onPasteProviders)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughHostView(onWindowAttach: { host in
            context.coordinator.installIfNeeded(near: host)
        })
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onPasteProviders = onPasteProviders
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(near: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private final class PassthroughHostView: UIView {
        var onWindowAttach: ((UIView) -> Void)?

        init(onWindowAttach: @escaping (UIView) -> Void) {
            self.onWindowAttach = onWindowAttach
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onWindowAttach?(self)
            }
        }
    }

    final class Coordinator: NSObject, UITextPasteDelegate {
        var isEnabled: Bool
        var onPasteProviders: ([NSItemProvider]) -> Void

        private weak var attachedTextView: UITextView?
        private weak var attachedTextField: UITextField?

        init(isEnabled: Bool, onPasteProviders: @escaping ([NSItemProvider]) -> Void) {
            self.isEnabled = isEnabled
            self.onPasteProviders = onPasteProviders
        }

        func installIfNeeded(near anchorView: UIView) {
            let config = UIPasteConfiguration(
                acceptableTypeIdentifiers: ComposerItemImporter.acceptableTypeIdentifiers
            )
            var ancestor: UIView? = anchorView.superview
            var depth = 0
            while let container = ancestor, depth < 5 {
                if let textView = Self.findDescendant(ofType: UITextView.self, in: container) {
                    if attachedTextView !== textView {
                        uninstall()
                        textView.pasteConfiguration = config
                        textView.pasteDelegate = self
                        attachedTextView = textView
                    }
                    return
                }
                if let textField = Self.findDescendant(ofType: UITextField.self, in: container) {
                    if attachedTextField !== textField {
                        uninstall()
                        textField.pasteConfiguration = config
                        textField.pasteDelegate = self
                        attachedTextField = textField
                    }
                    return
                }
                ancestor = container.superview
                depth += 1
            }
        }

        func uninstall() {
            if let textView = attachedTextView, textView.pasteDelegate === self {
                textView.pasteDelegate = nil
            }
            if let textField = attachedTextField, textField.pasteDelegate === self {
                textField.pasteDelegate = nil
            }
            attachedTextView = nil
            attachedTextField = nil
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            transform item: UITextPasteItem
        ) {
            guard isEnabled,
                  ComposerItemImporter.shouldInterceptTextFieldPaste(item.itemProvider) else {
                item.setDefaultResult()
                return
            }
            let provider = item.itemProvider
            item.setNoResult()
            onPasteProviders([provider])
        }

        private static func findDescendant<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
            if let match = root as? T {
                return match
            }
            for subview in root.subviews {
                if let match = findDescendant(ofType: type, in: subview) {
                    return match
                }
            }
            return nil
        }
    }
}
