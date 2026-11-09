//
//  CSLBundled.swift
//  WriterTex
//
//  The style and locale that ship inside CSLKit, so a document can be
//  formatted before the user has downloaded anything.
//

import Foundation

nonisolated extension CSLLocale {
    /// American English, also the fallback for languages without a locale file.
    static let englishUS: CSLLocale = {
        let url = Bundle.main.url(forResource: "locales-en-US", withExtension: "xml")!
        return try! CSLLocale(xml: Data(contentsOf: url))
    }()
}

nonisolated extension CSLStyle {
    /// Ids of the styles CSLKit carries.
    static let bundledIDs = ["apa"]

    /// The `.csl` source of a bundled style.
    static func bundledData(_ id: String) -> Data? {
        guard bundledIDs.contains(id),
              let url = Bundle.main.url(forResource: id, withExtension: "csl") else { return nil }
        return try? Data(contentsOf: url)
    }
}
