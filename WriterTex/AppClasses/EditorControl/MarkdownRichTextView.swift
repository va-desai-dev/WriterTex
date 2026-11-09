import AppKit

/// Changes to the table around the selection, from the paragraph style menu.
enum MarkdownTableEdit: CaseIterable {
    case rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn, deleteTable

    var title: String {
        switch self {
        case .rowAbove: "Add Row Above"
        case .rowBelow: "Add Row Below"
        case .columnLeft: "Add Column Left"
        case .columnRight: "Add Column Right"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        case .deleteTable: "Delete Table"
        }
    }
}


/// The editor's text view: rich text that edits like Notes, on TextKit 1 so
/// tables are real `NSTextTable` cells. Formatting commands change what text
/// means; the style sheet decides how it looks. Markdown markers are local typing
/// shortcuts, independent of the document's rich-text storage.
final class MarkdownRichTextView: NSTextView {
    var document: MarkdownRichText!
    private var isPasting = false
    private var hasPalette = false
    /// Only the untouched row added by Return can be removed by a second Return.
    private var returnRow: (range: NSRange, caret: Int)?
    /// Opens the cite-while-you-write picker; the editor's host knows the bibliography.
    var onInsertCitation: (() -> Void)?

    // SwiftUI updates elsewhere in the window can leave the arrow showing over
    // the text. The text view's own tracking area has the last word on its cursor.
    private lazy var cursorArea = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(cursorArea) { addTrackingArea(cursorArea) }
    }

    override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setCursor(for: event)
    }

    private func setCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return }
        (isLink(at: point) ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    private func isLink(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return false }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return false }
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(location) else { return false }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length && storage.attribute(.link, at: index, effectiveRange: nil) != nil
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // Erase the antialiased edge of a selection, including fractional backing
        // pixels. Keep this local: a no-layout invalidation may arrive mid-edit.
        let pixel = convertFromBacking(NSSize(width: 1, height: 1))
        let repaint = backingAlignedRect(rect.insetBy(dx: -pixel.width, dy: -pixel.height),
                                         options: .alignAllEdgesOutward)
        super.setNeedsDisplay(repaint, avoidAdditionalLayout: flag)
    }

    override func didChangeText() {
        returnRow = nil
        super.didChangeText()
        // A paragraph break can move smaller text beyond AppKit's dirty region.
        // Repaint after the edit, allowing layout of the visible text. Expanding
        // a no-layout invalidation instead can briefly draw an empty viewport.
        setNeedsDisplay(visibleRect)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        if let row = returnRow, ranges.count != 1 || ranges.first?.rangeValue != NSRange(location: row.caret, length: 0) {
            returnRow = nil
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
    }

    /// Follows Appearance settings without replacing the text storage, moving the
    /// caret or touching Undo. Theme colors are dynamic and never equal as
    /// objects, so they are compared as drawn: comparing the objects would
    /// recolor and relayout the whole manuscript on every SwiftUI update.
    func updatePalette(_ palette: ManuscriptPalette) {
        let old = document.style.theme
        let changed = drawn(Self.colors(of: old)) != drawn(Self.colors(of: palette))
        guard changed || !hasPalette else { return }
        hasPalette = true
        insertionPointColor = palette.bodyText
        linkTextAttributes = [.foregroundColor: palette.link, .cursor: NSCursor.pointingHand]
        guard changed, let storage = textStorage else { return }
        var style = MarkdownStyleSheet(theme: palette, manuscript: document.style.manuscript)
        style.codeBackground = document.style.codeBackground
        document.style = style
        storage.beginEditing()
        style.recolor(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        typingAttributes[.foregroundColor] = style.color(for: typingAttributes)
    }

    private static func colors(of palette: ManuscriptPalette) -> [NSColor] {
        [palette.bodyText, palette.mutedText, palette.link, palette.strikethroughColor, palette.highlightColor]
    }

    private func drawn(_ colors: [NSColor]) -> [NSColor?] {
        var resolved: [NSColor?] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = colors.map { $0.usingColorSpace(.sRGB) }
        }
        return resolved
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let shortcutEligible = !isPasting && !hasMarkedText() && selectedRange().length == 0
            && (replacementRange.location == NSNotFound || replacementRange == selectedRange())
        super.insertText(insertString, replacementRange: replacementRange)
        guard shortcutEligible, let typed = insertString as? String, typed.utf16.count == 1,
              !hasMarkedText(), let storage = textStorage,
              let shortcut = document.typingShortcut(in: storage, at: selectedRange().location, typed: typed) else { return }
        // The triggering key belongs to typing; automatic formatting gets its
        // own undo event so Undo restores the complete literal shortcut.
        breakUndoCoalescing()
        if let undoManager, undoManager.groupsByEvent, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        // Process the replacement before notifying the view or moving the caret;
        // an outer storage editing transaction leaves layout using stale ranges.
        replace(shortcut.range, with: shortcut.text)
        setSelectedRange(NSRange(location: shortcut.range.location + shortcut.caretOffset, length: 0))
        typingAttributes = shortcut.typingAttributes
    }

    /// Return leaves an empty code line and starts body text after a heading or
    /// rule. Quotes continue until their paragraph style is explicitly changed.
    override func insertNewline(_ sender: Any?) {
        // A table cell holds one line, so Return moves down a row instead.
        if moveDownInTable() { return }
        if let line = caretLine {
            let content = (string as NSString).substring(with: Self.trimmed(line.paragraph, in: string as NSString))
            if content.isEmpty, line.style.textBlocks.contains(where: { $0 is MarkdownCodeBlock }) {
                reformat(line.paragraph) { [weak self] paragraph in
                    guard let self = self else { return paragraph }
                    return self.document.applyingBody(to: paragraph)
                }
                return
            }
        }
        super.insertNewline(sender)
        // A heading or rule is one paragraph long; the next one is body text.
        guard typingAttributes[.markdownHeading] != nil
                || (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is MarkdownRuleBlock,
              let storage = textStorage else { return }
        var body = document.style.bodyAttributes
        if let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle,
           paragraph.textBlocks.contains(where: { $0 is MarkdownQuoteBlock }) {
            let style = document.style.bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.textBlocks = paragraph.textBlocks
            body[.paragraphStyle] = style
        }
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        if paragraph.length <= 1, shouldChangeText(in: paragraph, replacementString: nil) {
            storage.setAttributes(body, range: paragraph)
            didChangeText()
        }
        typingAttributes = body
    }

    private struct CaretLine {
        let paragraph: NSRange
        let style: NSParagraphStyle
    }

    private var caretLine: CaretLine? {
        guard let storage = textStorage, selectedRange().length == 0 else { return nil }
        let text = string as NSString
        let caret = selectedRange().location
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let attributes = paragraph.length > 0 && paragraph.location < storage.length
            ? storage.attributes(at: paragraph.location, effectiveRange: nil) : typingAttributes
        return CaretLine(paragraph: paragraph, style: attributes[.paragraphStyle] as? NSParagraphStyle ?? .default)
    }

    private static func trimmed(_ paragraph: NSRange, in text: NSString) -> NSRange {
        var range = paragraph
        while range.length > 0, [0x0A, 0x0D, 0x2029].contains(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range
    }

    /// Gives `paragraph` the block formatting `transform` applies, keeping its
    /// inline formatting. The caret lands after any marker the block adds.
    private func reformat(_ paragraph: NSRange, _ transform: (NSAttributedString) -> NSAttributedString) {
        guard let storage = textStorage else { return }
        let rest = storage.attributedSubstring(from: paragraph)
        let replacement = transform(rest)
        // Formatting a sample gives the attributes new typing takes in an empty paragraph.
        let sample = transform(NSAttributedString(string: "X", attributes: rest.length > 0 ? rest.attributes(at: 0, effectiveRange: nil) : typingAttributes))
        let marker = sample.length - 1
        let attributes = sample.attributes(at: marker, effectiveRange: nil)
        replace(paragraph, with: replacement)
        setSelectedRange(NSRange(location: paragraph.location + marker, length: 0))
        typingAttributes = attributes
    }

    /// One undo step, so ⌘Z brings back exactly what was typed.
    @discardableResult private func replace(_ range: NSRange, with replacement: NSAttributedString) -> Bool {
        guard let storage = textStorage else { return false }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        breakUndoCoalescing()
        return true
    }

    override func insertLineBreak(_ sender: Any?) {
        if !moveDownInTable() { super.insertLineBreak(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if !protectsTableEdge(forward: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if !protectsTableEdge(forward: true) { super.deleteForward(sender) }
    }

    // MARK: Tables

    private func paragraphStyle(at location: Int) -> NSParagraphStyle {
        guard let storage = textStorage, location < storage.length else {
            return typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        }
        return storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle ?? .default
    }

    /// The caret's paragraph is in a table.
    var selectionInTable: Bool {
        selectionParagraphStyle.textBlocks.last is NSTextTableBlock
    }

    private var selectionParagraphStyle: NSParagraphStyle {
        selectedRange().length == 0
            ? typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            : paragraphStyle(at: selectedRange().location)
    }

    /// Tables go between top-level paragraphs: not inside lists, quotes, code or other tables.
    var canInsertTable: Bool {
        let style = selectionParagraphStyle
        return style.textLists.isEmpty && style.textBlocks.isEmpty
    }

    /// Inserts an empty table, header row included, after the caret's paragraph,
    /// or in its place when that paragraph is empty, and puts the caret in its first cell.
    func insertTable(rows: Int = 3, columns: Int = 3) {
        guard canInsertTable, let storage = textStorage else { return }
        let text = string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let content = Self.trimmed(paragraph, in: text)
        let empty = Array(repeating: Array(repeating: NSAttributedString(), count: columns), count: rows)
        let table = document.table(empty, alignments: Array(repeating: .left, count: columns)).text
        let replacement = NSMutableAttributedString()
        let range: NSRange
        if content.length == 0 {
            range = paragraph
        } else {
            range = NSRange(location: NSMaxRange(paragraph), length: 0)
            // The last paragraph has no break to end it before the table.
            if NSMaxRange(content) == NSMaxRange(paragraph) {
                replacement.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: content.location, effectiveRange: nil)))
            }
        }
        let tableStart = range.location + replacement.length
        replacement.append(table)
        // Something to write in after a table that ends the document.
        if NSMaxRange(range) >= storage.length {
            replacement.append(NSAttributedString(string: "\n", attributes: document.style.bodyAttributes))
        }
        replace(range, with: replacement)
        setSelectedRange(NSRange(location: tableStart, length: 0))
        typingAttributes = storage.attributes(at: tableStart, effectiveRange: nil)
    }

    /// The alignment of the caret's column, read from its cell.
    var selectedColumnAlignment: MarkdownRichText.TableAlignment? {
        let style = selectionParagraphStyle
        guard style.textBlocks.last is NSTextTableBlock else { return nil }
        return switch style.alignment { case .center: .center; case .right: .right; default: .left }
    }

    func alignColumn(_ alignment: MarkdownRichText.TableAlignment) {
        guard selectedColumnAlignment != alignment else { return }
        rebuildTable { _, alignments, _, column in alignments[column] = alignment }
    }

    func editTable(_ edit: MarkdownTableEdit) {
        let blank = NSAttributedString()
        rebuildTable { cells, alignments, row, column in
            switch edit {
            case .rowAbove: cells.insert(Array(repeating: blank, count: alignments.count), at: row)
            case .rowBelow: cells.insert(Array(repeating: blank, count: alignments.count), at: row + 1); row += 1
            case .columnLeft, .columnRight:
                if edit == .columnRight { column += 1 }
                alignments.insert(.left, at: column)
                for index in cells.indices { cells[index].insert(blank, at: column) }
            case .deleteRow: cells.remove(at: row); row = min(row, cells.count - 1)
            case .deleteColumn:
                alignments.remove(at: column)
                for index in cells.indices { cells[index].remove(at: column) }
                column = min(column, alignments.count - 1)
            case .deleteTable: cells = []
            }
        }
    }

    /// Rebuilds the table around the caret with `change` applied to its cells,
    /// alignments and the caret's cell, as one undo step, keeping every other
    /// cell's content and formatting. No cells left removes the table.
    private func rebuildTable(_ change: (inout [[NSAttributedString]], inout [MarkdownRichText.TableAlignment], inout Int, inout Int) -> Void) {
        guard let storage = textStorage, let grid = document.tableGrid(at: selectedRange().location, in: storage) else { return }
        var cells = grid.cells, alignments = grid.alignments
        var row = grid.row, column = grid.column
        change(&cells, &alignments, &row, &column)
        guard !cells.isEmpty, !alignments.isEmpty else {
            guard replace(grid.range, with: NSAttributedString()) else { return }
            setSelectedRange(NSRange(location: min(grid.range.location, storage.length), length: 0))
            return
        }
        let rebuilt = document.table(cells, alignments: alignments)
        guard replace(grid.range, with: rebuilt.text) else { return }
        let start = grid.range.location + rebuilt.starts[row][column]
        setSelectedRange(NSRange(location: start + (cells[row][column]).length, length: 0))
        typingAttributes = storage.attributes(at: start, effectiveRange: nil)
    }

    /// Return moves down or appends a row. A second Return removes that untouched
    /// row and places the caret in a body paragraph outside the table.
    private func moveDownInTable() -> Bool {
        guard let storage = textStorage, let grid = document.tableGrid(at: selectedRange().location, in: storage) else { return false }
        guard grid.row + 1 < grid.cells.count else {
            if let row = returnRow, selectedRange() == NSRange(location: row.caret, length: 0),
               NSMaxRange(row.range) == NSMaxRange(grid.range), grid.cells[grid.row].allSatisfy({ $0.length == 0 }) {
                let end = NSMaxRange(grid.range)
                let following = (string as NSString).paragraphRange(for: NSRange(location: end, length: 0))
                let style = paragraphStyle(at: end)
                let emptyBody = following.length > 0 && Self.trimmed(following, in: string as NSString).length == 0
                    && style.textBlocks.isEmpty && style.textLists.isEmpty && style.headerLevel == 0
                let body = document.style.bodyAttributes
                guard replace(row.range, with: NSAttributedString(string: emptyBody ? "" : "\n", attributes: body)) else { return true }
                setSelectedRange(NSRange(location: row.range.location, length: 0))
                typingAttributes = body
                scrollRangeToVisible(selectedRange())
            } else if let table = (paragraphStyle(at: selectedRange().location).textBlocks.last as? NSTextTableBlock)?.table as? MarkdownTable {
                if let row = appendRow(to: table, row: grid.cells.count, at: NSMaxRange(grid.range), column: grid.column) {
                    returnRow = (row, selectedRange().location)
                }
            } else {
                // External RTF tables gain WriterTex's cell styles on their first edit.
                editTable(.rowBelow)
                if let added = document.tableGrid(at: selectedRange().location, in: storage), added.cells.count == grid.cells.count + 1 {
                    returnRow = (NSRange(location: NSMaxRange(added.range) - added.alignments.count, length: added.alignments.count), selectedRange().location)
                }
            }
            return true
        }
        let text = string as NSString
        var location = grid.range.location
        while location < NSMaxRange(grid.range) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            if let cell = paragraphStyle(at: paragraph.location).textBlocks.last as? NSTextTableBlock,
               cell.startingRow == grid.row + 1, cell.startingColumn == grid.column {
                setSelectedRange(NSRange(location: NSMaxRange(MarkdownRichText.contentRange(of: paragraph, in: storage)), length: 0))
                return true
            }
            location = NSMaxRange(paragraph)
        }
        return true
    }

    /// Append cells without replacing the existing table or its contents.
    private func appendRow(to table: MarkdownTable, row: Int, at location: Int, column: Int) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let cells = NSMutableAttributedString()
        for index in 0..<table.numberOfColumns {
            cells.append(NSAttributedString(string: "\n", attributes: document.cellAttributes(table, row: row, column: index)))
        }
        let added = NSRange(location: location, length: cells.length)
        if location == storage.length {
            cells.append(NSAttributedString(string: "\n", attributes: document.style.bodyAttributes))
        }
        guard replace(NSRange(location: location, length: 0), with: cells) else { return nil }
        setSelectedRange(NSRange(location: location + column, length: 0))
        typingAttributes = storage.attributes(at: selectedRange().location, effectiveRange: nil)
        scrollRangeToVisible(selectedRange())
        return added
    }

    /// Backspace immediately after a table removes the whole table. Other edge
    /// deletions must not merge a cell with its neighbor or the following body.
    private func protectsTableEdge(forward: Bool) -> Bool {
        guard let storage = textStorage, selectedRange().length == 0 else { return false }
        let text = string as NSString
        let breakIndex = forward ? selectedRange().location : selectedRange().location - 1
        guard breakIndex >= 0, breakIndex < text.length, text.character(at: breakIndex) == 0x0A else { return false }
        let before = text.paragraphRange(for: NSRange(location: breakIndex, length: 0))
        let after = NSMaxRange(before) < text.length ? text.paragraphRange(for: NSRange(location: NSMaxRange(before), length: 0)) : nil
        func cell(_ paragraph: NSRange?) -> NSTextTableBlock? {
            guard let paragraph, paragraph.length > 0 else { return nil }
            return (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        switch (cell(before), cell(after)) {
        case (nil, nil): return false
        case (nil, _?): if before.length == 1 { return false }
        case (let previous?, nil):
            if !forward {
                let range = storage.range(of: previous.table, at: breakIndex)
                guard range.location != NSNotFound, range.length > 0 else { return true }
                let attributes = after.map { storage.attributes(at: $0.location, effectiveRange: nil) }
                    ?? document.style.bodyAttributes
                guard replace(range, with: NSAttributedString()) else { return true }
                setSelectedRange(NSRange(location: range.location, length: 0))
                typingAttributes = attributes
                scrollRangeToVisible(selectedRange())
                return true
            }
        case (_?, _?): break
        }
        NSSound.beep()
        return true
    }

    override func insertTab(_ sender: Any?) {
        returnRow = nil
        if !moveToCell(forward: true) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        returnRow = nil
        if !moveToCell(forward: false) { super.insertBacktab(sender) }
    }

    /// Selects the next or previous cell's text; Tab in the last cell adds a row.
    private func moveToCell(forward: Bool) -> Bool {
        let text = string as NSString
        guard let storage = textStorage, storage.length > 0 else { return false }
        // A selection may span cells. Anchor navigation to its first paragraph;
        // treating the whole selection as a cell can insert overlapping row indices.
        let here = text.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        func cell(at paragraph: NSRange) -> NSTextTableBlock? {
            guard paragraph.location < storage.length else { return nil }
            return (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        guard let current = cell(at: here), let table = current.table as? MarkdownTable else { return false }
        var paragraph = here
        var rowEnd = NSMaxRange(here)
        while true {
            let next = forward ? NSMaxRange(paragraph) : paragraph.location - 1
            guard next >= 0, next < storage.length else { break }
            paragraph = text.paragraphRange(for: NSRange(location: next, length: 0))
            guard let block = cell(at: paragraph), block.table === table else { break }
            rowEnd = NSMaxRange(paragraph)
            if block !== current {
                var content = paragraph
                if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
                setSelectedRange(content)
                return true
            }
        }
        guard forward else { return true }
        _ = appendRow(to: table, row: current.startingRow + 1, at: rowEnd, column: 0)
        return true
    }

    /// The Font panel and Format menu send font changes; only bold and italic carry
    /// meaning here, and the style sheet owns family and size. Converting a plain and
    /// a bold-italic probe tells whether the change adds or removes each trait.
    override func changeFont(_ sender: Any?) {
        let manager = sender as? NSFontManager ?? .shared
        let plain = NSFont.systemFont(ofSize: document.style.manuscript.body.size)
        let full = manager.convert(plain, toHaveTrait: [.boldFontMask, .italicFontMask])
        let converted = (manager.traits(of: manager.convert(plain)), manager.traits(of: manager.convert(full)))
        for (trait, inline) in [(NSFontTraitMask.boldFontMask, MarkdownInlineStyle.strong), (.italicFontMask, .emphasis)] {
            switch (converted.0.contains(trait), converted.1.contains(trait)) {
            case (true, true): setInlineStyle(inline, enabled: true)
            case (false, false): setInlineStyle(inline, enabled: false)
            default: break
            }
        }
    }

    /// Styles every run of the selection shares; a mixed selection shows a style as off.
    var selectedInlineStyle: MarkdownInlineStyle {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return MarkdownInlineStyle(typingAttributes) }
        var shared = MarkdownInlineStyle(rawValue: ~0)
        storage.enumerateAttribute(.markdownInline, in: range) { value, _, _ in
            shared.formIntersection(MarkdownInlineStyle(rawValue: value as? Int ?? 0))
        }
        return shared
    }

    /// A code span holds plain text on one line outside a code block: no images or wiki links.
    private func canMakeCode(_ range: NSRange) -> Bool {
        func inCodeBlock(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is MarkdownCodeBlock
        }
        guard range.length > 0, let storage = textStorage else { return !inCodeBlock(typingAttributes) }
        guard (string as NSString).rangeOfCharacter(from: .newlines, range: range).location == NSNotFound else { return false }
        var allowed = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.attachment] != nil || attributes[.markdownSpan] != nil || inCodeBlock(attributes) {
                allowed = false
                stop.pointee = true
            }
        }
        return allowed
    }

    func setInlineStyle(_ inline: MarkdownInlineStyle, enabled: Bool) {
        let range = selectedRange()
        if inline.contains(.code), enabled, !canMakeCode(range) { return }
        func updating(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var updated = attributes
            var current = MarkdownInlineStyle(attributes)
            if enabled { current.formUnion(inline) } else { current.subtract(inline) }
            // Code paints its own background, so it replaces a highlight.
            if enabled, inline.contains(.code) { current.remove(.highlight) }
            current.store(in: &updated)
            document.style.apply(to: &updated)
            return updated
        }
        guard range.length > 0, let storage = textStorage else {
            typingAttributes = updating(typingAttributes)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            storage.setAttributes(updating(attributes), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private var selectedParagraphs: NSAttributedString {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        if range.length > 0, let textStorage { return textStorage.attributedSubstring(from: range) }
        return NSAttributedString(string: "X", attributes: typingAttributes)
    }

    var headingSelection: (level: Int?, canApply: Bool) {
        document.headingSelection(in: formattingSelection)
    }

    /// A caret needs only one attribute run, even inside a manuscript-sized paragraph.
    private var formattingSelection: NSAttributedString {
        guard selectedRange().length == 0 else { return selectedParagraphs }
        return NSAttributedString(string: "X", attributes: typingAttributes)
    }

    func setHeadingLevel(_ level: Int) {
        let heading = headingSelection
        guard (0...6).contains(level), heading.canApply, heading.level != level else { return }
        formatParagraphs { document.applyingHeading(level, to: $0) }
    }

    var quoteSelection: (isQuoted: Bool, containsQuote: Bool, canApply: Bool) {
        document.quoteSelection(in: formattingSelection)
    }


    func setBlockQuote(_ enabled: Bool) {
        let quote = quoteSelection
        guard quote.canApply, enabled ? !quote.isQuoted : quote.containsQuote else { return }
        formatParagraphs { document.applyingQuote(enabled, to: $0) }
    }

    /// Paragraph styles share the same selection-preserving native undo path.
    private func formatParagraphs(_ transform: (NSAttributedString) -> NSAttributedString) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let formatted = transform(selectedParagraphs)
        guard range.length > 0 else {
            typingAttributes = formatted.attributes(at: 0, effectiveRange: nil)
            return
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        formatted.enumerateAttributes(in: NSRange(location: 0, length: formatted.length)) { attributes, subrange, _ in
            storage.setAttributes(attributes, range: NSRange(location: range.location + subrange.location, length: subrange.length))
        }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        if selection.length == 0 {
            typingAttributes = storage.attributes(at: min(selection.location, storage.length - 1), effectiveRange: nil)
        }
    }

    var listSelection: (kind: MarkdownListKind?, containsList: Bool, canApply: Bool) {
        document.listSelection(in: formattingSelection)
    }

    /// Choosing the selection's current list style again turns it back into body text, as in Notes.
    func setListKind(_ kind: MarkdownListKind?) {
        let current = listSelection
        let target = kind == current.kind ? nil : kind
        guard current.canApply, target != nil || current.containsList, let storage = textStorage else { return }
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let original = storage.attributedSubstring(from: range)
        let formatted = document.applyingList(target, to: original, typingAttributes: typingAttributes)
        func markerLength(_ text: NSAttributedString) -> Int {
            MarkdownRichText.listMarkerLength(of: (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)), in: text)
        }
        let oldMarker = markerLength(original), newMarker = markerLength(formatted)
        replace(range, with: formatted)
        // Keep the caret or selection on the same text as markers come and go.
        let start = max(selection.location + newMarker - oldMarker, range.location + newMarker)
        let end = selection.length > 0 ? max(start, NSMaxRange(selection) + formatted.length - original.length) : start
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    /// Body clears lists as well as headings.
    func setBodyStyle() {
        if listSelection.containsList { setListKind(nil) }
        setBlockQuote(false)
        setHeadingLevel(0)
    }

    /// Preserve rich manuscript styles and images between editors alongside
    /// AppKit's RTF/RTFD representations. The same hooks serve copy and drag.
    private static let manuscriptPasteboardType = ManuscriptDocument.pasteboardType

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.manuscriptPasteboardType] + super.writablePasteboardTypes
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.manuscriptPasteboardType] + super.readablePasteboardTypes
    }

    /// Rich types from other apps, read here so their formatting gains meaning.
    /// AppKit still pastes them under their legacy NeXT/Apple names on macOS 26.
    private static let richPasteboardTypes: [String: NSAttributedString.DocumentType] = [
        NSPasteboard.PasteboardType.rtf.rawValue: .rtf, "NeXT Rich Text Format v1.0 pasteboard type": .rtf,
        NSPasteboard.PasteboardType.rtfd.rawValue: .rtfd, "NeXT RTFD pasteboard type": .rtfd,
        NSPasteboard.PasteboardType.html.rawValue: .html, "Apple HTML pasteboard type": .html,
    ]

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isPasting = true
        defer { isPasting = false }
        if type == Self.manuscriptPasteboardType {
            guard let data = pboard.data(forType: type),
                  let rich = try? ManuscriptDocument.decode(data, using: document) else { return false }
            insertText(rich, replacementRange: selectedRange())
            return true
        }
        if let documentType = Self.richPasteboardTypes[type.rawValue] {
            guard let data = pboard.data(forType: type),
                  let rich = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil) else { return false }
            insertText(document.importing(rich), replacementRange: selectedRange())
            return true
        }
        // Plain text pastes as typed.
        return super.readSelection(from: pboard, type: type)
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == Self.manuscriptPasteboardType {
            guard let storage = textStorage, selectedRange().length > 0,
                  let data = try? ManuscriptDocument.encode(storage.attributedSubstring(from: selectedRange())) else { return false }
            return pboard.setData(data, forType: type)
        }
        guard type == .string || type.rawValue == "NSStringPboardType" else {
            return super.writeSelection(to: pboard, type: type)
        }
        guard let storage = textStorage, selectedRange().length > 0 else { return false }
        let selection = storage.attributedSubstring(from: selectedRange())
        return pboard.setString(selection.string, forType: type)
    }
}
