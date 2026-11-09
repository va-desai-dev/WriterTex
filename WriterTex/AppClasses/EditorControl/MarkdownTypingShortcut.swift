import AppKit

extension MarkdownRichText {
    struct TypingShortcut {
        let range: NSRange
        let text: NSAttributedString
        let typingAttributes: [NSAttributedString.Key: Any]
        let caretOffset: Int
    }

    /// Recognizes only the paragraph at the insertion point, never the document.
    /// Pasted text and marked-text composition do not use this path.
    func typingShortcut(in text: NSAttributedString, at caret: Int, typed: String) -> TypingShortcut? {
        guard caret > 0, caret <= text.length, [" ", "*", "_", "~", "`"].contains(typed) else { return nil }
        let string = text.string as NSString
        let windowStart = max(0, caret - (typed == " " ? 8 : 4_096))
        let lineBreak = string.rangeOfCharacter(from: .newlines, options: .backwards,
                                                range: NSRange(location: windowStart, length: caret - windowStart))
        let start = lineBreak.location == NSNotFound ? windowStart : NSMaxRange(lineBreak)
        let attributes = text.attributes(at: caret - 1, effectiveRange: nil)
        let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        guard !paragraphStyle.textBlocks.contains(where: { $0 is MarkdownCodeBlock || $0 is MarkdownRuleBlock }),
              !MarkdownInlineStyle(attributes).contains(.code),
              attributes[.link] == nil, attributes[.attachment] == nil else { return nil }
        let prefixLength = caret - start
        if typed == " ", (windowStart == 0 || lineBreak.location != NSNotFound), prefixLength <= 7,
           paragraphStyle.textLists.isEmpty, paragraphStyle.textBlocks.allSatisfy({ $0 is MarkdownQuoteBlock }) {
            let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
            let prefix = string.substring(with: NSRange(location: paragraph.location, length: prefixLength))
            let marker = String(prefix.dropLast())
            let remaining = text.attributedSubstring(from: NSRange(location: caret, length: NSMaxRange(paragraph) - caret))
            let transform: (NSAttributedString) -> NSAttributedString
            if (1...6).contains(marker.count), marker.allSatisfy({ $0 == "#" }) {
                transform = { self.applyingHeading(marker.count, to: $0) }
            } else if let kind: MarkdownListKind = ["-": .dashed, "*": .bulleted, "+": .bulleted, "1.": .numbered][marker] {
                transform = { self.applyingList(kind, to: $0, typingAttributes: attributes) }
            } else { return nil }
            let formatted = transform(remaining)
            // Continue the actual list we inserted. Formatting a separate sample
            // creates another NSTextList, so AppKit restarts at 1 on Return.
            let sample = formatted.length > 0 ? formatted : transform(NSAttributedString(string: "X", attributes: attributes))
            let markerLength = Self.listMarkerLength(of: NSRange(location: 0, length: sample.length), in: sample)
            return TypingShortcut(range: paragraph, text: formatted,
                                  typingAttributes: sample.attributes(at: min(markerLength, sample.length - 1), effectiveRange: nil), caretOffset: markerLength)
        }

        guard typed != " " else { return nil }
        // Bounded look-behind keeps even a very long unbroken paragraph cheap.
        let tail = string.substring(with: NSRange(location: start, length: caret - start)) as NSString
        let delimiters: [(String, MarkdownInlineStyle)] = typed == "*" ? [("**", .strong), ("*", .emphasis)]
            : typed == "_" ? [("__", .strong), ("_", .emphasis)]
            : typed == "~" ? [("~~", .strikethrough)] : [("`", .code)]
        for (marker, inline) in delimiters {
            let length = marker.utf16.count
            guard tail.length > length * 2, tail.hasSuffix(marker) else { continue }
            let closing = tail.length - length
            let opening = tail.range(of: marker, options: .backwards, range: NSRange(location: 0, length: closing))
            guard opening.location != NSNotFound else { continue }
            // Delimiters inside words and escaped punctuation stay literal.
            if start + opening.location > 0 {
                let before = string.substring(with: NSRange(location: start + opening.location - 1, length: 1))
                guard before.rangeOfCharacter(from: .whitespacesAndNewlines.union(.punctuationCharacters)) != nil,
                      before != "\\", before != String(marker.prefix(1)) else { continue }
            }
            let contentRange = NSRange(location: start + NSMaxRange(opening), length: closing - NSMaxRange(opening))
            let content = string.substring(with: contentRange)
            guard !content.isEmpty, content.first?.isWhitespace == false, content.last?.isWhitespace == false,
                  !content.contains(String(marker.prefix(1))) else { continue }
            let replacement = NSMutableAttributedString(attributedString: text.attributedSubstring(from: contentRange))
            replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { old, range, _ in
                var updated = old
                MarkdownInlineStyle(old).union(inline).store(in: &updated)
                self.style.apply(to: &updated)
                replacement.setAttributes(updated, range: range)
            }
            return TypingShortcut(range: NSRange(location: start + opening.location, length: tail.length - opening.location),
                                  text: replacement, typingAttributes: attributes, caretOffset: replacement.length)
        }
        return nil
    }
}
