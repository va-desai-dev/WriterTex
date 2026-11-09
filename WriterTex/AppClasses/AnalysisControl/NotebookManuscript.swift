import AppKit

/// The notebook's results as WriterTex manuscript text: headings, paragraphs
/// and native tables, the same content `NotebookReport.markdown` writes, so a
/// result can go straight into writing without retyping a number. Builds a
/// whole new manuscript, or one step's section for the pasteboard.
@MainActor struct NotebookManuscript {
    private let builder = MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))

    static func document(
        title: String,
        steps: [AnalysisStep],
        results: [UUID: AnalysisResult],
        failures: [UUID: String],
        missingCodes: [String]
    ) -> NSAttributedString {
        let manuscript = NotebookManuscript()
        let output = NSMutableAttributedString(attributedString: manuscript.heading(title, 1))
        output.append(manuscript.paragraph("Exported \(Date().formatted(date: .abbreviated, time: .shortened))."))
        output.append(manuscript.paragraph(missingCodes.isEmpty
            ? "Only empty cells were set as missing data."
            : "All cells with the following: \(missingCodes.joined(separator: ", "))" + "were considered as missing data."))
        for (position, step) in steps.enumerated() {
            output.append(manuscript.section(step, number: position + 1, result: results[step.id], failure: failures[step.id]))
        }
        return output
    }

    /// One step's result on a pasteboard: as WriterTex rich text for a
    /// manuscript, RTF for other writing apps, and tab-separated plain text
    /// for a spreadsheet.
    static func copy(_ step: AnalysisStep, number: Int, result: AnalysisResult, to pasteboard: NSPasteboard = .general) throws {
        let text = NotebookManuscript().section(step, number: number, result: result, failure: nil)
        try ManuscriptDocument.write(text, plain: plainText(step, number: number, result: result), to: pasteboard)
    }

    /// A step's heading, then its input, notes and tables, or why it has none.
    func section(_ step: AnalysisStep, number: Int, result: AnalysisResult?, failure: String?) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: heading("\(number). \(step.title)", 2))
        if let failure {
            output.append(paragraph("Did Not Run: \(failure)"))
            return output
        }
        guard let result else {
            output.append(paragraph("Not Run."))
            return output
        }
        output.append(paragraph(Self.inputLine(step, result.input), .emphasis))
        for note in result.notes { output.append(paragraph(note)) }
        for table in result.tables {
            if let caption = table.caption { output.append(paragraph(caption, .emphasis)) }
            let cells = [table.columns.map { NSAttributedString(string: $0) }]
                + table.rows.map { $0.map { NSAttributedString(string: NotebookReport.text($0)) } }
            output.append(builder.table(cells, alignments: Self.alignments(table)).text)
            if let legend = NotebookReport.legend(for: table) { output.append(paragraph(legend)) }
        }
        return output
    }

    private func paragraph(_ text: String, _ inline: MarkdownInlineStyle = []) -> NSAttributedString {
        let style = builder.style
        var attributes = style.bodyAttributes
        inline.store(in: &attributes)
        style.apply(to: &attributes)
        return NSAttributedString(string: text + "\n", attributes: attributes)
    }

    private func heading(_ text: String, _ level: Int) -> NSAttributedString {
        builder.applyingHeading(level, to: paragraph(text))
    }

    private static func inputLine(_ step: AnalysisStep, _ input: AnalysisInputSummary) -> String {
        let mPolicy = step.missing
        let mLabel = mPolicy.rawValue
        let scope = input.scope
        let s = scope.label
        let fullScope = scope == .allRows
        let d = input.datasetLabel
        let mText = switch mPolicy {
            case .fail: "\(mLabel)"
            case .listwise, .pairwise: "\(mLabel) Deletion"
        }
        let m = "Missing Policy: \(mText)"
        let t = "\(input.capturedAt.formatted(date: .numeric, time: .standard))"
        if fullScope {
            return "Data: \(d) | \(input.rowCount) Total Rows | \(m) | \(t)"
        } else {
            return "Data: \(d) | \(input.rowCount) Rows (\(s)) | \(m) | \(t)"
        }
    }

    /// The same section as lines, each table row's cells separated by tabs.
    static func plainText(_ step: AnalysisStep, number: Int, result: AnalysisResult) -> String {
        var lines = ["\(number). \(step.title)", inputLine(step, result.input)] + result.notes
        for table in result.tables {
            lines.append("")
            if let caption = table.caption { lines.append(caption) }
            lines.append(table.columns.joined(separator: "\t"))
            lines += table.rows.map { $0.map(NotebookReport.text).joined(separator: "\t") }
            if let legend = NotebookReport.legend(for: table) { lines.append(legend) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Numbers line up on the right; a column holding any text reads from the left.
    private static func alignments(_ table: AnalysisResultTable) -> [MarkdownRichText.TableAlignment] {
        table.columns.indices.map { column in
            let numeric = table.rows.allSatisfy { row in
                guard column < row.count else { return true }
                if case .text = row[column] { return false }
                return true
            }
            return numeric ? .right : .left
        }
    }
}
