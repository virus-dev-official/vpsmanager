import SwiftUI
import AppKit

/// A line-number gutter for an NSTextView, drawn as a vertical NSRulerView attached to
/// the enclosing NSScrollView. Line starts are cached and recomputed only when the text
/// actually changes, so drawing during scroll is just a binary search + a draw call.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    private var lineStartIndices: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        recomputeLineStarts()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func recomputeLineStarts() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var indices: [Int] = [0]
        var searchLocation = 0
        while searchLocation < ns.length {
            let searchRange = NSRange(location: searchLocation, length: ns.length - searchLocation)
            let found = ns.range(of: "\n", range: searchRange)
            if found.location == NSNotFound { break }
            let next = found.location + 1
            indices.append(next)
            searchLocation = next
        }
        lineStartIndices = indices
    }

    private func lineNumber(forCharacterIndex idx: Int) -> Int {
        guard !lineStartIndices.isEmpty else { return 1 }
        var lo = 0
        var hi = lineStartIndices.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStartIndices[mid] <= idx { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        CodeTheme.gutterBackground.setFill()
        bounds.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CodeTheme.lineNumber,
            .paragraphStyle: paragraphStyle
        ]

        var lastLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = self.lineNumber(forCharacterIndex: charIndex)
            guard line != lastLine else { return }
            lastLine = line

            let converted = self.convert(fragRect, from: textView)
            let numberString = "\(line)" as NSString
            let size = numberString.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - 8
            let y = converted.minY + (converted.height - size.height) / 2
            numberString.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
}

/// A dark, monospaced, line-numbered code editor with live per-language syntax
/// highlighting — the "looks like VS Code" text surface used for editing remote files.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = CodeTheme.font
        textView.textColor = CodeTheme.plain
        textView.backgroundColor = CodeTheme.background
        textView.insertionPointColor = .white
        textView.typingAttributes = [.font: CodeTheme.font, .foregroundColor: CodeTheme.plain]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isEditable = isEditable
        textView.isSelectable = true

        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodeTheme.background
        scrollView.borderType = .noBorder

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        textView.string = text
        context.coordinator.applyHighlight()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
            context.coordinator.applyHighlight()
        }

        if context.coordinator.language != language {
            context.coordinator.language = language
            context.coordinator.applyHighlight()
        }

        textView.isEditable = isEditable
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var language: CodeLanguage

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.language = parent.language
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            rulerView?.recomputeLineStarts()
            rulerView?.needsDisplay = true
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            SyntaxHighlighter.highlight(textStorage, language: language)
        }

        @objc func boundsDidChange(_ notification: Notification) {
            rulerView?.needsDisplay = true
        }

        func applyHighlight() {
            guard let ts = textView?.textStorage else { return }
            SyntaxHighlighter.highlight(ts, language: language)
            rulerView?.recomputeLineStarts()
            rulerView?.needsDisplay = true
        }
    }
}