import AppKit
import SwiftUI

/// A one-line find field. Focus is requested explicitly, never by mounting.
struct FindInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let identifier: String
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FindInputScrollView {
        let scroll = FindInputScrollView()
        let input = FindPanelTextView()
        input.font = FindBarContent.font
        input.autoresizingMask = [.width]
        input.drawsBackground = false
        input.textContainerInset = .zero
        input.string = text
        input.delegate = context.coordinator
        input.writingToolsCoordinator = .none
        input.writingToolsBehavior = .none
        input.placeholder = placeholder
        input.setAccessibilityPlaceholderValue(placeholder)
        input.setAccessibilityLabel(placeholder)
        input.setAccessibilityIdentifier(identifier)
        scroll.drawsBackground = false
        scroll.documentView = input
        return scroll
    }

    func updateNSView(_ scroll: FindInputScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? FindPanelTextView else { return }
        if input.string != text {
            input.string = text
            input.needsDisplay = true
        }
        input.placeholder = placeholder
        input.action = onSubmit
        scroll.focusRequest = focusRequest
        scroll.applyFocusRequest()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FindInputScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FindInput
        init(_ parent: FindInput) { self.parent = parent }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onDismiss()
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextView else { return }
            parent.text = input.string
        }
    }
}

final class FindInputScrollView: NSScrollView {
    var focusRequest = 0
    private var appliedFocusRequest = 0

    override var intrinsicContentSize: NSSize {
        guard let input = documentView as? NSTextView, let font = input.font else {
            return super.intrinsicContentSize
        }
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(input.layoutManager?.defaultLineHeight(for: font) ?? (font.ascender - font.descender + font.leading)))
    }

    override func layout() {
        super.layout()
        documentView?.setFrameSize(NSSize(width: contentSize.width, height: intrinsicContentSize.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusRequest()
    }

    func applyFocusRequest() {
        guard focusRequest != appliedFocusRequest, let window, let documentView else { return }
        appliedFocusRequest = focusRequest
        window.makeFirstResponder(documentView)
    }
}

/// A one-line text view that behaves like a search field: Return runs
/// `action`, focus selects everything, and a placeholder shows while empty.
final class FindPanelTextView: NSTextView {
    var action: (() -> Void)?

    /// Drawn in place of the text while the view is empty (NSTextView has no public placeholder).
    var placeholder: String? {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)

        isRichText = false
        font = .systemFont(ofSize: 0)
        // Without this the typing font can fall back to Last Resort.
        typingAttributes[.font] = font
        baseWritingDirection = userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .natural

        // One line that scrolls sideways instead of wrapping.
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Tab, Shift-Tab and Return behave as in a text field.
        isFieldEditor = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x + padding, y: origin.y,
                          width: bounds.width - origin.x - padding, height: bounds.height - origin.y)
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? .systemFont(ofSize: 0),
            .foregroundColor: NSColor.placeholderTextColor,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder lies outside the glyph area NSTextView invalidates on edit.
        if string.count <= 1 { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        selectedRange = NSRange(location: 0, length: (string as NSString).length)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        selectedRange = NSRange(location: 0, length: 0)
        return super.resignFirstResponder()
    }

    override func insertNewline(_ sender: Any?) {
        action?()
    }
}
