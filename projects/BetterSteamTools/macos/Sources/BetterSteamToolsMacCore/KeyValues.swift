import Foundation

/// Text Valve KeyValues with source ranges, so edits keep unrelated configuration verbatim.
public struct KeyValuesDocument: Sendable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: String?
        public let children: [Entry]?
        fileprivate let range: Range<Int>
        fileprivate let closingBrace: Int?

        public func entry(_ key: String) throws -> Entry? {
            let matches = (children ?? []).filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            guard matches.count <= 1 else { throw ParseError.duplicateKey(key) }
            return matches.first
        }
        public func string(_ key: String) throws -> String? { try entry(key)?.value }
    }
    public enum ParseError: Error, LocalizedError, Equatable {
        case malformed(Int), duplicateKey(String), expectedObject(String)
        public var errorDescription: String? {
            switch self {
            case .malformed(let offset): "KeyValues mal formado en la posición \(offset)."
            case .duplicateKey(let key): "La clave KeyValues \(key) está duplicada."
            case .expectedObject(let key): "La clave \(key) debe contener un objeto."
            }
        }
    }
    public let source: String
    public let entries: [Entry]

    public init(_ source: String) throws {
        var parser = Parser(characters: Array(source))
        self.entries = try parser.object(nested: false).0
        self.source = source
    }
    public func entry(at path: [String]) throws -> Entry? {
        var level = entries
        var found: Entry?
        for (index, key) in path.enumerated() {
            let matches = level.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            guard matches.count <= 1 else { throw ParseError.duplicateKey(key) }
            guard let entry = matches.first else { return nil }
            found = entry
            if index < path.count - 1 {
                guard let children = entry.children else { throw ParseError.expectedObject(key) }
                level = children
            }
        }
        return found
    }
    /// Adds missing parent objects, replaces only the selected entry, or removes it.
    public func setting(_ path: [String], to value: String?) throws -> String {
        guard let key = path.last, !key.isEmpty else { throw ParseError.malformed(0) }
        if let existing = try entry(at: path) {
            return replacing(existing.range, with: value.map { Self.quote(key) + "\t\t" + Self.quote($0) } ?? "")
        }
        guard let value else { return source }
        var parentPath = Array(path.dropLast())
        var suffix = Self.quote(key) + "\t\t" + Self.quote(value)
        while !parentPath.isEmpty, try entry(at: parentPath) == nil {
            let parent = parentPath.removeLast()
            suffix = Self.quote(parent) + "\n{\n" + suffix + "\n}"
        }
        if parentPath.isEmpty {
            return source + "\n" + suffix + "\n"
        }
        guard let parent = try entry(at: parentPath), let close = parent.closingBrace else {
            throw ParseError.expectedObject(parentPath.last ?? "")
        }
        return replacing(close..<close, with: "\n" + suffix + "\n")
    }
    public func removingObject(_ path: [String]) throws -> String {
        guard let existing = try entry(at: path) else { return source }
        return replacing(existing.range, with: "")
    }
    private func replacing(_ range: Range<Int>, with replacement: String) -> String {
        let chars = Array(source)
        return String(chars[..<range.lowerBound]) + replacement + String(chars[range.upperBound...])
    }
    public static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
    private struct Parser {
        let characters: [Character]
        var position = 0
        mutating func whitespace() {
            while position < characters.count {
                if characters[position].isWhitespace { position += 1; continue }
                if characters[position] == "/", position + 1 < characters.count, characters[position + 1] == "/" {
                    while position < characters.count, characters[position] != "\n" { position += 1 }
                    continue
                }
                break
            }
        }
        mutating func token() throws -> String {
            whitespace()
            guard position < characters.count else { throw ParseError.malformed(position) }
            if characters[position] != "\"" {
                let start = position
                while position < characters.count, !characters[position].isWhitespace, !["{", "}"].contains(characters[position]) { position += 1 }
                guard position > start else { throw ParseError.malformed(position) }
                return String(characters[start..<position])
            }
            position += 1
            var value = ""
            while position < characters.count {
                let char = characters[position]; position += 1
                if char == "\"" { return value }
                if char == "\\" {
                    guard position < characters.count else { throw ParseError.malformed(position) }
                    let escaped = characters[position]; position += 1
                    switch escaped {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\\", "\"": value.append(escaped)
                    default: value.append("\\"); value.append(escaped)
                    }
                } else { value.append(char) }
            }
            throw ParseError.malformed(position)
        }
        mutating func object(nested: Bool, depth: Int = 0) throws -> ([Entry], Int?) {
            guard depth < 64 else { throw ParseError.malformed(position) }
            var entries: [Entry] = []
            while true {
                whitespace()
                if position == characters.count {
                    guard !nested else { throw ParseError.malformed(position) }
                    return (entries, nil)
                }
                if characters[position] == "}" {
                    guard nested else { throw ParseError.malformed(position) }
                    let close = position; position += 1
                    return (entries, close)
                }
                let start = position
                let key = try token()
                whitespace()
                guard position < characters.count else { throw ParseError.malformed(position) }
                if characters[position] == "{" {
                    position += 1
                    let (children, close) = try object(nested: true, depth: depth + 1)
                    entries.append(Entry(key: key, value: nil, children: children, range: start..<position, closingBrace: close))
                } else {
                    let value = try token()
                    entries.append(Entry(key: key, value: value, children: nil, range: start..<position, closingBrace: nil))
                }
            }
        }
    }
}
