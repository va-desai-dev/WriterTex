//
//  BibTexSyntax.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 11/5/26.
//

import SwiftUI
import Foundation

enum Types: String, Identifiable, CaseIterable, Hashable, Sendable {
    var id: Self { self }
    case article, book, booklet, conference, inbook, incollection, inproceedings, manual, mastersthesis, misc, phdthesis, proceedings, techreport, unpublished

    var displayName: String {
        switch self {
            case .article, .book, .booklet, .conference, .manual, .misc, .proceedings, .techreport, .unpublished: return rawValue.localizedCapitalized
            case .inbook, .incollection, .inproceedings:
                let remainder = rawValue.dropFirst(2)
                return "In-\(remainder.localizedCapitalized)"
            case .phdthesis, .mastersthesis:
                let prefix = rawValue.dropLast(6)
                if self == .phdthesis {
                    return "\(prefix.localizedCapitalized) Dissertation"
                } else {
                    return "\(prefix.localizedCapitalized) Thesis"
                }
        }
    }
}
enum FieldLabels: String, Identifiable, CaseIterable, Hashable, Sendable {
    var id: Self { self }
    case address, annote, authors, booktitle, chapter, doi, edition, howpublished, institution, issn, isbn, journal, month, note, number, organizatiton, pages, publisher, school, series, title, url, volume, year
}

struct CitationCreatorScreens: Identifiable {
    var id: UUID?
    var label: FieldLabels
    var type: Types

    var labelsubset: [FieldLabels] {
        if type == .article {
            return [.authors, .title, .journal, .year, .volume, .number, .pages, .month, .annote]
        }
    }

    @ViewBuilder func shell(for selection: Binding<String>) -> some View {
        Form {
            Section {
                Picker("Types", selection: selection) {
                    ForEach(Types.allCases) { type in
                        Text(type.displayName)
                            .tag(type.id)
                    }
                }
            }
        }
    }

    @ViewBuilder static func innerfields(for type: Types, input: Binding<String>) -> some View {
        switch type {
            case .article: {
                Section("Fields") {
                    TextField(label.rawValue, text: input)
                        .focusEffectDisabled()
                }
            }
        }
    }
}

struct CitationViewFields: Identifiable {
    var id: UUID?
    var address: String?
    var annote: String?
    var authors: [ManualAuthor] = []

    struct ManualAuthor: Identifiable, Hashable, Codable, Sendable {
        var id = UUID()
        var firstName: String = ""
        var lastName: String = ""
        var isInstitutional: Bool = false

        var combinedName: String {
            if isInstitutional { return lastName }
            return lastName.isEmpty ? firstName : "\(lastName), \(firstName)"
        }
    }

    var booktitle: String?
    var chapter: String?

    var doi: String?
    var edition: String?
    var howpublished: String?
    var institution: String?
    var issn: String?
    var isbn: String?
    var journal: String?
    var month: String?
    var note: String?
    var number: String?
    var organization: String?
    var pages: String?
    var publisher: String?
    var school: String?
    var series: String?
    var title: String?
    var url: String?
    var volume: String?
    var year: String?


    init(
        id: UUID? = nil,
        address: String? = nil,
        annote: String? = nil,
        authors: [ManualAuthor],
        booktitle: String? = nil,
        chapter: String? = nil,
        doi: String? = nil,
        edition: String? = nil,
        howpublished: String? = nil,
        institution: String? = nil,
        issn: String? = nil,
        isbn: String? = nil,
        journal: String? = nil,
        month: String? = nil,
        note: String? = nil,
        number: String? = nil,
        organization: String? = nil,
        pages: String? = nil,
        publisher: String? = nil,
        school: String? = nil,
        series: String? = nil,
        title: String? = nil,
        url: String? = nil,
        volume: String? = nil,
        year: String? = nil
    ) {
        self.id = id
        self.address = address
        self.annote = annote
        self.authors = authors
        self.booktitle = booktitle
        self.chapter = chapter
        self.doi = doi
        self.edition = edition
        self.howpublished = howpublished
        self.institution = institution
        self.issn = issn
        self.isbn = isbn
        self.journal = journal
        self.month = month
        self.note = note
        self.number = number
        self.organization = organization
        self.pages = pages
        self.publisher = publisher
        self.school = school
        self.series = series
        self.title = title
        self.url = url
        self.volume = volume
        self.year = year
    }
}
