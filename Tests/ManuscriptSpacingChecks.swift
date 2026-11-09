import AppKit
@testable import WriterTex

@main struct ManuscriptSpacingChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        run()
        exit(0)
    }

    @MainActor static func paragraph(_ text: NSAttributedString, containing needle: String) -> NSParagraphStyle {
        let location = (text.string as NSString).range(of: needle).location
        precondition(location != NSNotFound, "Missing \(needle)")
        return text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as! NSParagraphStyle
    }

    @MainActor static func run() {
        let source = "# Title\n\nBody one 😀 is a long paragraph with `code` that wraps across several lines of the page so the line height shows on every line of it.\n\n## Section\n\nBody two.\n\n- First\n- Second\n\n```\nlet x = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let screen = MarkdownStyleSheet(theme: .screen, manuscript: .screen)
        let text = MarkdownRichText(baseURL: nil, style: screen).load(source)

        let body = paragraph(text, containing: "Body one")
        precondition(body.lineHeightMultiple == screen.manuscript.lineSpacing && body.minimumLineHeight == 0,
                     "Body uses the requested native line-height multiplier without a fixed minimum")
        precondition(body.paragraphSpacing == 8 && body.paragraphSpacingBefore == 0, "Body keeps 8 pt after")
        let title = paragraph(text, containing: "Title"), section = paragraph(text, containing: "Section")
        precondition(title.paragraphSpacingBefore == 10 && section.paragraphSpacingBefore == 10 && title.paragraphSpacing == 8,
                     "Headings take their level's spacing")
        precondition(title.minimumLineHeight == 0 && title.lineHeightMultiple == body.lineHeightMultiple,
                     "TextKit derives heading line height from its font and native multiplier")
        precondition(paragraph(text, containing: "First").paragraphSpacing == 3, "List items sit close")
        precondition(paragraph(text, containing: "let x").paragraphSpacing == 0, "Code lines sit close")
        precondition(paragraph(text, containing: "1").paragraphSpacing == 0, "Table cells sit close")
        print("PASS: Screen spacing uses native paragraph spacing and line-height multipliers")

        let legacy = #"{"body":{"size":12,"capitalization":"asTyped","bold":false,"italic":false,"underline":false},"headings":[{"size":12,"capitalization":"asTyped","bold":true,"italic":false,"underline":false}]}"#
        let old = try! JSONDecoder().decode(ManuscriptStyle.self, from: Data(legacy.utf8))
        precondition(old.lineSpacing == 1.15 && old.body.spaceAfter == 8 && old.headings[0].spaceBefore == 10 && old.headings[0].spaceAfter == 8,
                     "Styles saved before spacing existed keep the spacing exports had")
        var settings = ManuscriptExportSettings()
        settings.style.body.spaceAfter = 6
        let reopened = try! JSONDecoder().decode(ManuscriptExportSettings.self, from: try! JSONEncoder().encode(settings))
        precondition(reopened == settings, "Spacing round-trips through saved export settings")
        print("PASS: Saved export settings keep spacing, and older ones keep their old spacing")

        let export = MarkdownStyleSheet(theme: .print, manuscript: .manuscript)
        let printed = ManuscriptPDF.manuscriptText(text, baseURL: nil, style: export, settings: ManuscriptExportSettings(), citations: nil).text
        let printedBody = paragraph(printed, containing: "Body one")
        precondition(printedBody.lineHeightMultiple == 2 && printedBody.minimumLineHeight == 0
                     && printedBody.paragraphSpacing == 0 && paragraph(printed, containing: "Section").paragraphSpacingBefore == 0,
                     "The manuscript preset uses native double spacing without fixed line heights")
        print("PASS: Export uses the manuscript's native spacing settings")

        let word = ManuscriptDOCX.render(text, baseURL: nil, title: "Spacing", settings: settings, citations: nil).data
        func contains(_ fragment: String) -> Bool { word.range(of: Data(fragment.utf8)) != nil }
        precondition(contains(#"<w:spacing w:before="0" w:after="120" w:line="480" w:lineRule="auto"/>"#),
                     "Word gets the line spacing multiple and the body's paragraph spacing")
        print("PASS: Word export writes line spacing as Word's own multiple, with per-level paragraph spacing")
    }
}
