//
//  PreviewProvider.swift
//  WriterTexPreview
//
//  Created by Vedant A. Desai on 11/8/26.
//

import Cocoa
import Quartz
import UniformTypeIdentifiers

/// Quick Look for `.wrtx` manuscripts: the saved text, shown as RTF.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// The one field of a saved `ManuscriptDocument` a preview needs; the
    /// decoder skips the runs, blocks, lists and bibliography.
    private struct Saved: Decodable { let rtfd: Data }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let text = try Self.text(from: data)
        // Re-exported as RTF, which Quick Look renders natively.
        let rtf = try text.data(from: NSRange(location: 0, length: text.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return QLPreviewReply(dataOfContentType: .rtf, contentSize: CGSize(width: 800, height: 1000)) { _ in rtf }
    }

    /// The manuscript's text: older files are raw RTF, newer ones wrap RTFD in a plist.
    private static func text(from data: Data) throws -> NSAttributedString {
        if data.isEmpty { return NSAttributedString() }
        if data.starts(with: Data("{\\rtf".utf8)) {
            return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        let saved = try PropertyListDecoder().decode(Saved.self, from: data)
        return try NSAttributedString(data: saved.rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }
}
