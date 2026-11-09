//
//  CSLNode.swift
//  WriterTex
//
//  A CSL style or locale is plain XML. It's read once into this small tree and
//  then walked by the renderer; nothing else about the XML matters.
//

import Foundation

/// One element of a style or locale file.
nonisolated struct CSLNode: Sendable {
    var name: String
    var attributes: [String: String]
    var children: [CSLNode]
    /// Character data directly inside the element, kept untrimmed: a term such
    /// as `<term name="ad"> C.E.</term>` depends on its leading space.
    var text: String

    subscript(attribute: String) -> String? { attributes[attribute] }

    func child(_ name: String) -> CSLNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [CSLNode] { children.filter { $0.name == name } }

    /// Parses XML data into its root element.
    static func parse(_ data: Data) throws -> CSLNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw CSLError.malformed(parser.parserError?.localizedDescription ?? "Not a CSL file.")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [CSLNode] = []
        var root: CSLNode?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(CSLNode(name: elementName, attributes: attributeDict, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}

nonisolated enum CSLError: LocalizedError, Equatable {
    case malformed(String)
    case notAStyle
    case dependent(parent: String)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): "The style couldn't be read: \(reason)"
        case .notAStyle: "This file isn't a CSL style."
        case .dependent(let parent): "This style borrows its rules from “\(parent)”, which isn't installed."
        }
    }
}
