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
/// Configures native macOS window chrome and minimum split-view dimensions once per scene.
struct MacWindowSceneConfigurator: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = WindowAttachView { host in
            context.coordinator.configureIfNeeded(from: host)
        }
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.configureIfNeeded(from: uiView)
    }

    private final class WindowAttachView: UIView {
        var onAttach: ((UIView) -> Void)?

        init(onAttach: @escaping (UIView) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onAttach?(self)
            }
        }
    }

    final class Coordinator {
        private weak var configuredScene: UIWindowScene?

        func configureIfNeeded(from view: UIView) {
            guard let windowScene = view.window?.windowScene,
                  configuredScene !== windowScene else {
                return
            }
            configuredScene = windowScene
            if let restrictions = windowScene.sizeRestrictions {
                let maxSize = restrictions.maximumSize
                let minW = maxSize.width > 0 ? min(860, maxSize.width) : 860
                let minH = maxSize.height > 0 ? min(580, maxSize.height) : 580
                restrictions.minimumSize = CGSize(width: minW, height: minH)
            }
            if let titlebar = windowScene.titlebar {
                titlebar.toolbarStyle = .unified
                titlebar.titleVisibility = .hidden
            }
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
            if let tv = attachedTextView, tv.window != nil, tv.pasteDelegate === self {
                return
            }
            if let tf = attachedTextField, tf.window != nil, tf.pasteDelegate === self {
                return
            }
            var ancestor: UIView? = anchorView.superview
            var depth = 0
            while let container = ancestor, depth < 5 {
                if let textView = Self.findDescendant(ofType: UITextView.self, in: container) {
                    if attachedTextView !== textView {
                        uninstall()
                        textView.pasteConfiguration = UIPasteConfiguration(
                            acceptableTypeIdentifiers: ComposerItemImporter.acceptableTypeIdentifiers
                        )
                        textView.pasteDelegate = self
                        attachedTextView = textView
                    }
                    return
                }
                if let textField = Self.findDescendant(ofType: UITextField.self, in: container) {
                    if attachedTextField !== textField {
                        uninstall()
                        textField.pasteConfiguration = UIPasteConfiguration(
                            acceptableTypeIdentifiers: ComposerItemImporter.acceptableTypeIdentifiers
                        )
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
