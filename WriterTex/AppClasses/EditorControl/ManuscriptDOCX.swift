import AppKit

/// Writes a WriterTex document as a Word file from the editor's semantic rich
/// text: levels become real Heading 1–6 styles (so Word's navigation pane and
/// table of contents see them), lists use Word numbering, tables are `w:tbl`,
/// figures are embedded pictures, and the export sheet's header and
/// footer carry live PAGE/NUMPAGES fields.
@MainActor enum ManuscriptDOCX {
    static func render(_ source: NSAttributedString, baseURL: URL?, title: String, settings: ManuscriptExportSettings,
                       citations: ManuscriptCitationSource?) -> (data: Data, missing: [String]) {
        var result = (Data(), [String]())
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let style = MarkdownStyleSheet(theme: .print, manuscript: settings.style)
            let (text, missing) = ManuscriptPDF.manuscriptText(source, baseURL: baseURL, style: style, settings: settings, citations: citations)
            var writer = Writer(text: text, baseURL: baseURL, settings: settings, title: title)
            result = (writer.package(), missing)
        }
        return result
    }

    private struct Writer {
        let text: NSAttributedString
        let baseURL: URL?
        let settings: ManuscriptExportSettings
        let title: String
        let paper = NSPrintInfo.shared.paperSize
        /// Relationships beyond the fixed parts, and the media they point at.
        var relationships: [(id: String, type: String, target: String, external: Bool)] = []
        var media: [(name: String, data: Data)] = []
        var pictures = 0
        /// One Word list per top-level list, with each depth's kind and first number.
        var lists: [ObjectIdentifier: (id: Int, levels: [Int: (kind: MarkdownListKind, start: Int)])] = [:]

        init(text: NSAttributedString, baseURL: URL?, settings: ManuscriptExportSettings, title: String) {
            self.text = text
            self.baseURL = baseURL
            self.settings = settings
            self.title = title
        }

        var contentWidth: Int { Int((paper.width - 2 * ManuscriptPDF.margin) * 20) }

        mutating func package() -> Data {
            let body = document()
            let hasHeader = ![settings.header.left, settings.header.center, settings.header.right].allSatisfy(\.isEmpty)
            let hasFooter = ![settings.footer.left, settings.footer.center, settings.footer.right].allSatisfy(\.isEmpty)
            var zip = StoredZip()
            var overrides = [("/word/document.xml", "wordprocessingml.document.main"), ("/word/styles.xml", "wordprocessingml.styles"),
                             ("/word/numbering.xml", "wordprocessingml.numbering")]
            if hasHeader { overrides.append(("/word/header1.xml", "wordprocessingml.header")) }
            if hasFooter { overrides.append(("/word/footer1.xml", "wordprocessingml.footer")) }
            zip.add("[Content_Types].xml", Self.xml("""
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Default Extension="png" ContentType="image/png"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
                <Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="gif" ContentType="image/gif"/>\
                \(overrides.map { "<Override PartName=\"\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.1)+xml\"/>" }.joined())\
                <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
                </Types>
                """))
            zip.add("_rels/.rels", Self.xml("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
                </Relationships>
                """))
            zip.add("docProps/core.xml", Self.xml("""
                <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
                xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(Self.escape(title))</dc:title><dc:creator>WriterTex</dc:creator></cp:coreProperties>
                """))
            let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
            var parts = [("rIdStyles", "styles", "styles.xml"), ("rIdNumbering", "numbering", "numbering.xml")]
            if hasHeader { parts.append(("rIdHeader", "header", "header1.xml")) }
            if hasFooter { parts.append(("rIdFooter", "footer", "footer1.xml")) }
            zip.add("word/_rels/document.xml.rels", Self.xml("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                \(parts.map { "<Relationship Id=\"\($0.0)\" Type=\"\(officeRelationships)\($0.1)\" Target=\"\($0.2)\"/>" }.joined())\
                \(relationships.map { "<Relationship Id=\"\($0.id)\" Type=\"\(officeRelationships)\($0.type)\" Target=\"\(Self.escape($0.target))\"\($0.external ? " TargetMode=\"External\"" : "")/>" }.joined())\
                </Relationships>
                """))
            let sections = (hasHeader ? "<w:headerReference w:type=\"default\" r:id=\"rIdHeader\"/>" : "")
                + (hasFooter ? "<w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>" : "")
            zip.add("word/document.xml", Self.xml("""
                <w:document \(Self.namespaces)><w:body>\(body)<w:sectPr>\(sections)\
                <w:pgSz w:w="\(Int(paper.width * 20))" w:h="\(Int(paper.height * 20))"/>\
                <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
                </w:sectPr></w:body></w:document>
                """))
            zip.add("word/styles.xml", Self.xml(styles()))
            zip.add("word/numbering.xml", Self.xml(numbering()))
            if hasHeader { zip.add("word/header1.xml", Self.xml("<w:hdr \(Self.namespaces)>\(furniture(settings.header))</w:hdr>")) }
            if hasFooter { zip.add("word/footer1.xml", Self.xml("<w:ftr \(Self.namespaces)>\(furniture(settings.footer))</w:ftr>")) }
            for item in media { zip.add("word/media/" + item.name, item.data) }
            return zip.data
        }

        static let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" "#
            + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" "#
            + #"xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing""#

        static func xml(_ body: String) -> Data {
            Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body).utf8)
        }

        static func escape(_ string: String) -> String {
            var output = ""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "&": output += "&amp;"
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "\"": output += "&quot;"
                // XML 1.0 has no form for other control characters.
                case _ where scalar.value < 0x20 && scalar != "\t" && scalar != "\n": continue
                default: output.unicodeScalars.append(scalar)
                }
            }
            return output
        }

        // MARK: Body

        mutating func document() -> String {
            let paragraphs = MarkdownRichText.paragraphs(in: text)
            for range in paragraphs { registerList(at: range) }
            var body = "", index = 0, endsWithTable = false
            while index < paragraphs.count {
                let paragraphStyle = style(at: paragraphs[index])
                if let cell = paragraphStyle.textBlocks.last as? NSTextTableBlock {
                    var cells: [[Int: [NSRange]]] = []
                    while index < paragraphs.count, let block = style(at: paragraphs[index]).textBlocks.last as? NSTextTableBlock,
                          block.table === cell.table {
                        while cells.count <= block.startingRow { cells.append([:]) }
                        cells[block.startingRow][block.startingColumn, default: []].append(paragraphs[index])
                        index += 1
                    }
                    body += table(cells, columns: cell.table.numberOfColumns)
                    endsWithTable = true
                    continue
                }
                body += paragraph(paragraphs[index])
                endsWithTable = false
                index += 1
            }
            // Word wants a paragraph between a final table and the section.
            return body + (endsWithTable || body.isEmpty ? "<w:p/>" : "")
        }

        func style(at paragraph: NSRange) -> NSParagraphStyle {
            paragraph.length > 0 ? text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default : .default
        }

        mutating func registerList(at paragraph: NSRange) {
            let lists = style(at: paragraph).textLists
            guard let top = lists.first else { return }
            var entry = self.lists[ObjectIdentifier(top)] ?? (self.lists.count + 1, [:])
            for (depth, list) in lists.enumerated() where entry.levels[depth] == nil {
                entry.levels[depth] = (list.kind, list.startingItemNumber)
            }
            self.lists[ObjectIdentifier(top)] = entry
        }

        mutating func paragraph(_ range: NSRange, inCell: Bool = false) -> String {
            let paragraphStyle = style(at: range)
            let block = paragraphStyle.textBlocks.last
            if block is MarkdownRuleBlock {
                return #"<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="auto"/></w:pBdr></w:pPr></w:p>"#
            }
            let heading = range.length > 0 ? text.attribute(.markdownHeading, at: range.location, effectiveRange: nil) as? Int : nil
            let quotes = paragraphStyle.textBlocks.filter { $0 is MarkdownQuoteBlock }.count
            // Word reads paragraph properties in schema order only.
            var style = "", numbering = "", tabs = "", spacing = "", indent = "", justification = ""
            if block is MarkdownCodeBlock { style = #"<w:pStyle w:val="Code"/>"# }
            else if let heading { style = "<w:pStyle w:val=\"Heading\(heading)\"/>" }
            else if quotes > 0 { style = #"<w:pStyle w:val="Quote"/>"# }
            // Prose carries the body's alignment and first-line indent; lists keep Normal.
            else if !inCell, block == nil, paragraphStyle.textLists.isEmpty,
                    range.length == 0 || text.attribute(.manuscriptReference, at: range.location, effectiveRange: nil) == nil {
                style = #"<w:pStyle w:val="BodyText"/>"#
            }
            else if range.length > 0, text.attribute(.manuscriptReference, at: range.location, effectiveRange: nil) != nil {
                // A reference: hanging indent, or a number set apart at a tab.
                style = #"<w:pStyle w:val="Bibliography"/>"#
                let left = Int(paragraphStyle.headIndent * 20), hanging = Int((paragraphStyle.headIndent - paragraphStyle.firstLineHeadIndent) * 20)
                if let tab = paragraphStyle.tabStops.first, paragraphStyle.tabStops.count == 1 {
                    tabs = "<w:tabs><w:tab w:val=\"left\" w:pos=\"\(Int(tab.location * 20))\"/></w:tabs>"
                }
                if left > 0 { indent = "<w:ind w:left=\"\(left)\" w:hanging=\"\(hanging)\"/>" }
            }
            let content = MarkdownRichText.contentRange(of: range, in: text)
            if let top = paragraphStyle.textLists.first, let list = lists[ObjectIdentifier(top)] {
                let depth = paragraphStyle.textLists.count - 1
                if content.location > range.location {
                    numbering = "<w:numPr><w:ilvl w:val=\"\(depth)\"/><w:numId w:val=\"\(list.id)\"/></w:numPr>"
                } else {
                    indent = "<w:ind w:left=\"\(720 * (depth + 1))\"/>"
                }
            } else if quotes > 1 || (quotes > 0 && heading != nil) {
                indent = "<w:ind w:left=\"\(720 * quotes)\"/>"
            }
            if inCell {
                spacing = #"<w:spacing w:before="0" w:after="0"/>"#
                switch paragraphStyle.alignment {
                case .center: justification = #"<w:jc w:val="center"/>"#
                case .right: justification = #"<w:jc w:val="right"/>"#
                default: break
                }
            }
            let properties = style + numbering + tabs + spacing + indent + justification
            let header = inCell && (block as? NSTextTableBlock)?.startingRow == 0
            return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs(content, bold: header) + "</w:p>"
        }

        mutating func table(_ rows: [[Int: [NSRange]]], columns: Int) -> String {
            let width = contentWidth / max(columns, 1)
            // Borders are repeated on the table for readers that skip table styles.
            var output = #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="5000" w:type="pct"/>"# + Self.tableBorders
                + "</w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
            for (row, cells) in rows.enumerated() {
                output += "<w:tr>" + (row == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                for column in 0..<columns {
                    output += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                    let paragraphs = cells[column] ?? []
                    output += paragraphs.isEmpty ? "<w:p/>" : paragraphs.map { paragraph($0, inCell: true) }.joined()
                    output += "</w:tc>"
                }
                output += "</w:tr>"
            }
            return output + "</w:tbl>"
        }

        /// Runs for a stretch of text, with links grouped into Word hyperlinks.
        mutating func runs(_ range: NSRange, bold: Bool = false) -> String {
            var output = "", openLink: String?
            text.enumerateAttributes(in: range) { attributes, subrange, _ in
                let link = attributes[.link].map { ($0 as? URL)?.absoluteString ?? "\($0)" }
                if link != openLink {
                    if openLink != nil { output += "</w:hyperlink>" }
                    if let link {
                        let id = "rIdLink\(relationships.count + 1)"
                        relationships.append((id, "hyperlink", link, true))
                        output += "<w:hyperlink r:id=\"\(id)\">"
                    }
                    openLink = link
                }
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    output += picture(attachment, span: attributes[.markdownSpan] as? String)
                    return
                }
                let inline = MarkdownInlineStyle(attributes)
                var properties = ""
                if inline.contains(.code) { properties += #"<w:rStyle w:val="CodeChar"/>"# }
                else if link != nil { properties += #"<w:rStyle w:val="Hyperlink"/>"# }
                let format = CSLFormat(rawValue: attributes[.manuscriptFormat] as? UInt8 ?? 0)
                if inline.contains(.strong) || bold { properties += "<w:b/>" }
                if inline.contains(.emphasis) { properties += "<w:i/>" }
                if format.contains(.smallCaps) { properties += "<w:smallCaps/>" }
                if inline.contains(.strikethrough) { properties += "<w:strike/>" }
                if inline.contains(.highlight) { properties += #"<w:highlight w:val="yellow"/>"# }
                if format.contains(.underline) { properties += #"<w:u w:val="single"/>"# }
                if format.contains(.superscript) { properties += #"<w:vertAlign w:val="superscript"/>"# }
                else if format.contains(.subscript) { properties += #"<w:vertAlign w:val="subscript"/>"# }
                let piece = (text.string as NSString).substring(with: subrange)
                output += "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + Self.textElements(piece) + "</w:r>"
            }
            if openLink != nil { output += "</w:hyperlink>" }
            return output
        }

        /// Text as Word elements: tabs and line breaks are elements of their own.
        static func textElements(_ piece: String) -> String {
            var output = "", current = ""
            func flush() {
                if !current.isEmpty { output += "<w:t xml:space=\"preserve\">\(escape(current))</w:t>" }
                current = ""
            }
            for character in piece {
                switch character {
                case "\t": flush(); output += "<w:tab/>"
                case "\u{2028}", "\n": flush(); output += "<w:br/>"
                case "\u{FFFC}": continue
                default: current.append(character)
                }
            }
            flush()
            return output
        }

        /// An embedded picture: the figure's own file when Word reads its format,
        /// otherwise the attachment's image drawn at three times its size.
        mutating func picture(_ attachment: NSTextAttachment, span: String?) -> String {
            var data: Data?, fileExtension = "png"
            if let span, span.hasPrefix("image:"),
               let source = span.split(separator: "\u{1F}", maxSplits: 1).last.flatMap({ URL(string: String($0), relativeTo: baseURL) }),
               source.isFileURL, ["png", "jpg", "jpeg", "gif"].contains(source.pathExtension.lowercased()) {
                data = try? Data(contentsOf: source)
                fileExtension = source.pathExtension.lowercased()
            }
            var size = attachment.bounds.size
            if data == nil, let image = attachment.image, size.width > 0, size.height > 0,
               let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                bitmap.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: CGRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                data = bitmap.representation(using: .png, properties: [:])
                fileExtension = "png"
            }
            guard let data, size.width > 0, size.height > 0 else { return "" }
            let width = CGFloat(contentWidth) / 20
            if size.width > width { size = CGSize(width: width, height: size.height * width / size.width) }
            pictures += 1
            let name = "image\(pictures).\(fileExtension)", id = "rIdImage\(pictures)"
            media.append((name, data))
            relationships.append((id, "image", "media/" + name, false))
            let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
            return """
                <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
                <wp:docPr id="\(pictures)" name="Picture \(pictures)"/>\
                <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
                <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
                <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
                <pic:nvPicPr><pic:cNvPr id="\(pictures)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """
        }

        /// Left, center and right on one line, with `{page}` and `{pages}` as live fields.
        func furniture(_ furniture: ManuscriptExportSettings.Furniture) -> String {
            func fill(_ template: String) -> String {
                var output = "", rest = Substring(template)
                while let token = rest.range(of: #"\{(page|pages|title)\}"#, options: .regularExpression) {
                    output += Self.textRun(String(rest[..<token.lowerBound]))
                    switch rest[token] {
                    case "{page}": output += #"<w:fldSimple w:instr="PAGE"><w:r><w:t>1</w:t></w:r></w:fldSimple>"#
                    case "{pages}": output += #"<w:fldSimple w:instr="NUMPAGES"><w:r><w:t>1</w:t></w:r></w:fldSimple>"#
                    default: output += Self.textRun(title)
                    }
                    rest = rest[token.upperBound...]
                }
                return output + Self.textRun(String(rest))
            }
            return "<w:p><w:pPr><w:pStyle w:val=\"Furniture\"/><w:tabs><w:tab w:val=\"center\" w:pos=\"\(contentWidth / 2)\"/>"
                + "<w:tab w:val=\"right\" w:pos=\"\(contentWidth)\"/></w:tabs></w:pPr>"
                + fill(furniture.left) + "<w:r><w:tab/></w:r>" + fill(furniture.center) + "<w:r><w:tab/></w:r>" + fill(furniture.right) + "</w:p>"
        }

        static func textRun(_ text: String) -> String {
            text.isEmpty ? "" : "<w:r>\(textElements(text))</w:r>"
        }

        // MARK: Styles and numbering

        func styles() -> String {
            let manuscript = settings.style
            let fonts = manuscript.fontFamily.map { family in
                let name = Self.escape(family)
                return "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\" w:cs=\"\(name)\" w:eastAsia=\"\(name)\"/>"
            } ?? ""
            func runProperties(_ level: ManuscriptStyle.Level, fonts: String = "") -> String {
                let size = Int((level.size * 2).rounded())
                return "<w:rPr>\(fonts)" + (level.bold ? "<w:b/><w:bCs/>" : "") + (level.italic ? "<w:i/><w:iCs/>" : "")
                    + "<w:color w:val=\"000000\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
                    + (level.underline ? #"<w:u w:val="single"/>"# : "") + "</w:rPr>"
            }
            // Word keeps line spacing as a multiple, in 240ths, so its own
            // control reads 1.15 or Double; paragraph spacing is in twentieths of a point.
            func spacing(_ level: ManuscriptStyle.Level) -> String {
                "<w:spacing w:before=\"\(Int((level.spaceBefore * 20).rounded()))\" w:after=\"\(Int((level.spaceAfter * 20).rounded()))\""
                    + " w:line=\"\(Int((manuscript.lineSpacing * 240).rounded()))\" w:lineRule=\"auto\"/>"
            }
            func justification(_ level: ManuscriptStyle.Level) -> String {
                let value = switch level.alignment {
                case .left: "left"
                case .center: "center"
                case .right: "right"
                case .justified: "both"
                }
                return "<w:jc w:val=\"\(value)\"/>"
            }
            let code = #"<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>"#
            let codeSize = Int(((manuscript.body.size - 1) * 2).rounded())
            var output = "<w:styles \(Self.namespaces)>"
                + "<w:docDefaults><w:rPrDefault>\(runProperties(manuscript.body, fonts: fonts))</w:rPrDefault>"
                + "<w:pPrDefault><w:pPr>\(spacing(manuscript.body))</w:pPr></w:pPrDefault></w:docDefaults>"
                + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
                + #"<w:style w:type="paragraph" w:styleId="BodyText"><w:name w:val="Body Text"/><w:basedOn w:val="Normal"/>"#
                + #"<w:next w:val="BodyText"/><w:qFormat/><w:pPr>"#
                + "<w:ind w:firstLine=\"\(Int((manuscript.firstLineIndent * 20).rounded()))\"/>\(justification(manuscript.body))</w:pPr></w:style>"
            for level in 1...6 {
                output += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
                    + "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"BodyText\"/><w:qFormat/>"
                    + "<w:pPr><w:keepNext/><w:keepLines/>\(spacing(manuscript.level(level)))\(justification(manuscript.level(level)))"
                    + "<w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
                    + runProperties(manuscript.level(level)) + "</w:style>"
            }
            output += #"<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>"#
                + #"<w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="A6A6A6"/></w:pBdr><w:ind w:left="720"/></w:pPr>"#
                + #"<w:rPr><w:color w:val="595959"/></w:rPr></w:style>"#
                + #"<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>"#
                + #"<w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F0F0F0"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>"#
                + "<w:rPr>\(code)<w:b w:val=\"0\"/><w:i w:val=\"0\"/><w:sz w:val=\"\(codeSize)\"/><w:szCs w:val=\"\(codeSize)\"/><w:u w:val=\"none\"/></w:rPr></w:style>"
                + #"<w:style w:type="paragraph" w:styleId="Bibliography"><w:name w:val="Bibliography"/><w:basedOn w:val="Normal"/></w:style>"#
                + #"<w:style w:type="paragraph" w:styleId="Furniture"><w:name w:val="Header and Footer"/><w:basedOn w:val="Normal"/>"#
                + "<w:pPr><w:spacing w:after=\"0\"/></w:pPr><w:rPr><w:b w:val=\"0\"/><w:i w:val=\"0\"/>"
                + "<w:sz w:val=\"\(Int((max(8, manuscript.body.size - 2) * 2).rounded()))\"/><w:u w:val=\"none\"/></w:rPr></w:style>"
                + #"<w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/>"#
                + "<w:rPr>\(code)<w:sz w:val=\"\(codeSize)\"/><w:szCs w:val=\"\(codeSize)\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F0F0\"/></w:rPr></w:style>"
                + #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>"#
                + #"<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr>"# + Self.tableBorders
                + #"<w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>"#
            return output + "</w:styles>"
        }

        static let tableBorders = "<w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>" }.joined()
            + "</w:tblBorders>"

        func numbering() -> String {
            var abstracts = "", instances = ""
            for (id, levels) in lists.values.sorted(by: { $0.id < $1.id }) {
                abstracts += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
                for depth in 0..<9 {
                    // Depths the document never reaches take the deepest kind it does, counting from 1.
                    let level = levels[depth] ?? (levels.filter { $0.key < depth }.max { $0.key < $1.key }?.value.kind ?? .bulleted, 1)
                    let format: (String, String) = switch level.kind {
                    case .numbered: ("decimal", "%\(depth + 1).")
                    case .dashed: ("bullet", "–")
                    case .bulleted: ("bullet", depth == 0 ? "•" : "◦")
                    }
                    abstracts += "<w:lvl w:ilvl=\"\(depth)\"><w:start w:val=\"\(level.start)\"/><w:numFmt w:val=\"\(format.0)\"/>"
                        + "<w:lvlText w:val=\"\(format.1)\"/><w:lvlJc w:val=\"left\"/>"
                        + "<w:pPr><w:ind w:left=\"\(720 * (depth + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }
                abstracts += "</w:abstractNum>"
                instances += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"\(id)\"/></w:num>"
            }
            return "<w:numbering \(Self.namespaces)>\(abstracts)\(instances)</w:numbering>"
        }
    }
}

/// A ZIP archive of stored (uncompressed) entries, which is all a Word package
/// needs; its figures are compressed already.
private struct StoredZip {
    private var body = Data(), directory = Data(), count: UInt16 = 0

    mutating func add(_ name: String, _ data: Data) {
        let nameData = Data(name.utf8), crc = Self.crc32(data), offset = UInt32(body.count)
        func header(central: Bool) -> Data {
            var header = Data()
            header.appendLittleEndian(central ? UInt32(0x02014b50) : 0x04034b50)
            if central { header.appendLittleEndian(UInt16(20)) }
            // Version 2.0, UTF-8 names, stored, 1980-01-01 00:00.
            for value: UInt16 in [20, 0x0800, 0, 0, 0x21] { header.appendLittleEndian(value) }
            for value: UInt32 in [crc, UInt32(data.count), UInt32(data.count)] { header.appendLittleEndian(value) }
            header.appendLittleEndian(UInt16(nameData.count))
            header.appendLittleEndian(UInt16(0))
            if central {
                for value: UInt16 in [0, 0, 0] { header.appendLittleEndian(value) }
                header.appendLittleEndian(UInt32(0))
                header.appendLittleEndian(offset)
            }
            return header + nameData
        }
        body += header(central: false) + data
        directory += header(central: true)
        count += 1
    }

    var data: Data {
        var end = Data()
        end.appendLittleEndian(UInt32(0x06054b50))
        for value: UInt16 in [0, 0, count, count] { end.appendLittleEndian(value) }
        end.appendLittleEndian(UInt32(directory.count))
        end.appendLittleEndian(UInt32(body.count))
        end.appendLittleEndian(UInt16(0))
        return body + directory + end
    }

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
