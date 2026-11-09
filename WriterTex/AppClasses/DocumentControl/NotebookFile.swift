import SwiftUI
import UniformTypeIdentifiers
import Combine

/// The contents of a `.wrstatx` package:
///
///     Name.wrstatx/
///       notebook.json      steps and missing-value codes
///       Datasets/
///         survey.csv       each table the steps read, copied in
///
/// Datasets are copies, so the notebook opens the same anywhere it is sent.
nonisolated struct NotebookPackage: Hashable, Sendable {
    static let notebookName = "notebook.json"
    static let datasetsName = "Datasets"
    static let datasetLimit = 64
    static let datasetByteLimit = 32 * 1_024 * 1_024

    var notebook = AnalysisNotebookFile()
    /// CSV bytes by file name.
    var datasets: [String: Data] = [:]

    var datasetNames: [String] {
        datasets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    init() {}

    init(_ package: FileWrapper) throws {
        guard package.isDirectory, let children = package.fileWrappers else { throw CocoaError(.fileReadCorruptFile) }
        if let file = children[Self.notebookName] {
            guard let data = file.regularFileContents, data.count <= AnalysisNotebookFile.byteLimit else {
                throw CSVAnalysisError.unsupportedNotebook("The notebook’s steps must be a file smaller than 1 MB.")
            }
            notebook = try JSONDecoder().decode(AnalysisNotebookFile.self, from: data)
            try notebook.validate()
        }
        for (name, file) in children[Self.datasetsName]?.fileWrappers ?? [:] where Self.isDatasetName(name) {
            guard let data = file.regularFileContents else { continue }
            guard data.count <= Self.datasetByteLimit else {
                throw CSVAnalysisError.unsupportedNotebook("“\(name)” is larger than the \(Self.datasetByteLimit >> 20) MB dataset limit.")
            }
            datasets[name] = data
        }
    }

    /// `existing` is the package as last written; datasets it already holds
    /// unchanged are reused rather than written again.
    func fileWrapper(reusing existing: FileWrapper?) throws -> FileWrapper {
        try notebook.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let notebookFile = FileWrapper(regularFileWithContents: try encoder.encode(notebook))
        notebookFile.preferredFilename = Self.notebookName

        let previous = existing?.fileWrappers?[Self.datasetsName]?.fileWrappers ?? [:]
        var files: [String: FileWrapper] = [:]
        for (name, data) in datasets {
            if let kept = previous[name], kept.isRegularFile, kept.regularFileContents == data {
                files[name] = kept
            } else {
                let file = FileWrapper(regularFileWithContents: data)
                file.preferredFilename = name
                files[name] = file
            }
        }
        let folder = FileWrapper(directoryWithFileWrappers: files)
        folder.preferredFilename = Self.datasetsName
        return FileWrapper(directoryWithFileWrappers: [Self.notebookName: notebookFile, Self.datasetsName: folder])
    }

    /// A plain `.csv` file name, nothing that reaches out of the folder.
    static func isDatasetName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.contains("/") && URL(fileURLWithPath: name).pathExtension.lowercased() == "csv"
    }
}

/// A `.wrstatx` analysis notebook: one per window. `NotebookModel` edits
/// `package` and registers each change with the window's Undo, which is what
/// marks the notebook edited.
final class NotebookFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.writerTexNotebook] }

    var package: NotebookPackage

    nonisolated init() {
        package = NotebookPackage()
    }

    nonisolated init(configuration: ReadConfiguration) throws {
        package = try NotebookPackage(configuration.file)
    }

    func snapshot(contentType: UTType) throws -> NotebookPackage { package }

    nonisolated func fileWrapper(snapshot: NotebookPackage, configuration: WriteConfiguration) throws -> FileWrapper {
        try snapshot.fileWrapper(reusing: configuration.existingFile)
    }
}
