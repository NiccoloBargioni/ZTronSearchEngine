import Foundation

/// Source-level checks the specification asks to run as tests (sections 2, 11, 13.1 and 16).
///
/// They read Swift source as text, with comments and string literals blanked out so that a rule
/// named in a doc comment is not mistaken for a violation of it.
public enum SourceLint {
    public struct Finding: Hashable, Sendable, CustomStringConvertible {
        public let file: String
        public let line: Int
        public let rule: String
        public let excerpt: String

        public var description: String { "\(file):\(line): \(rule): \(excerpt)" }
    }

    /// Every `.swift` file under a directory.
    public static func swiftFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Source with comments and string literals replaced by spaces; line structure is kept.
    public static func code(of source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let characters = Array(source)
        var index = 0
        var blockDepth = 0
        var inLineComment = false
        var inString = false
        var inMultilineString = false
        func blank(_ character: Character) -> Character { character == "\n" ? "\n" : " " }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if inLineComment {
                if character == "\n" { inLineComment = false }
                result.append(blank(character))
                index += 1
            } else if blockDepth > 0 {
                if character == "/", next == "*" {
                    blockDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", next == "/" {
                    blockDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(blank(character))
                    index += 1
                }
            } else if inMultilineString {
                if character == "\"", next == "\"", index + 2 < characters.count, characters[index + 2] == "\"" {
                    inMultilineString = false
                    result.append("   ")
                    index += 3
                } else {
                    result.append(blank(character))
                    index += 1
                }
            } else if inString {
                if character == "\\" {
                    result.append("  ")
                    index += 2
                } else {
                    if character == "\"" { inString = false }
                    result.append(blank(character))
                    index += 1
                }
            } else if character == "/", next == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
            } else if character == "/", next == "*" {
                blockDepth = 1
                result.append("  ")
                index += 2
            } else if character == "\"", next == "\"", index + 2 < characters.count, characters[index + 2] == "\"" {
                inMultilineString = true
                result.append("   ")
                index += 3
            } else if character == "\"" {
                inString = true
                result.append(" ")
                index += 1
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    private static func findings(in files: [URL], rule: String, where matches: (String) -> Bool) -> [Finding] {
        var findings: [Finding] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in code(of: source).split(separator: "\n", omittingEmptySubsequences: false).enumerated() where matches(String(line)) {
                findings.append(Finding(file: file.lastPathComponent, line: number + 1, rule: rule, excerpt: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        return findings
    }

    /// Identifiers of a line of code: runs of letters, digits and underscores.
    private static func identifiers(in line: String) -> [Substring] {
        line.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
    }

    // MARK: Rules

    /// The UI product never imports UIKit: no `import UIKit`, no `UIViewRepresentable`, no
    /// `UI`-prefixed type (section 2 and the lint test of section 16).
    public static func uiKitUsage(in files: [URL]) -> [Finding] {
        findings(in: files, rule: "UIKit in the UI product") { line in
            if line.contains("import UIKit") || line.contains("import AppKit") { return true }
            return identifiers(in: line).contains { identifier in
                guard identifier.hasPrefix("UI"), identifier.count > 2 else { return false }
                // `UI` followed by an uppercase letter is a UIKit-style type name: UIColor, UIViewRepresentable.
                return identifier.dropFirst(2).first?.isUppercase == true
            }
        }
    }

    /// `@unchecked Sendable` and `nonisolated(unsafe)` are allowed nowhere, except in files the
    /// caller names (the HNSW wrapper, the SQLite.swift adapter).
    public static func uncheckedConcurrency(in files: [URL], allowing allowed: Set<String> = []) -> [Finding] {
        findings(in: files.filter { !allowed.contains($0.lastPathComponent) }, rule: "unchecked concurrency") { line in
            line.contains("@unchecked") || line.contains("nonisolated(unsafe)")
        }
    }

    /// Nothing may block the cooperative thread pool (section 11, rule 7).
    public static func blockingCalls(in files: [URL]) -> [Finding] {
        findings(in: files, rule: "blocks the cooperative pool") { line in
            line.contains("Thread.sleep") || line.contains("DispatchSemaphore") || line.contains("DispatchGroup")
                || line.contains("usleep(") || line.contains(".sync {") || line.contains(".sync(")
        }
    }

    /// `Task.detached` only for index loading at `.utility` priority (section 11, rule 2).
    public static func detachedTasks(in files: [URL]) -> [Finding] {
        findings(in: files, rule: "Task.detached outside index loading") { line in
            line.contains("Task.detached") && !line.contains("priority: .utility")
        }
    }

    /// The modules a set of files imports.
    public static func imports(in files: [URL]) -> Set<String> {
        var modules = Set<String>()
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in code(of: source).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") || trimmed.hasPrefix("@preconcurrency import ") else { continue }
                if let module = trimmed.split(separator: " ").last { modules.insert(String(module.split(separator: ".").first ?? module)) }
            }
        }
        return modules
    }

    /// The bodies of the attachment modifiers, by name, with their length in lines
    /// (section 13.1, rule 2: each stays under 30 lines).
    public static func modifierLengths(in file: URL, prefix: String = "zTron") -> [String: Int] {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        let lines = code(of: source).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lengths: [String: Int] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let name: String?
            if let range = line.range(of: "func \(prefix)") {
                name = String(line[range.lowerBound...].dropFirst(5).prefix { $0.isLetter || $0.isNumber })
            } else if line.contains("struct ZTron"), line.contains("ViewModifier") {
                name = line.split(separator: " ").first { $0.hasPrefix("ZTron") }.map { String($0.prefix { $0.isLetter || $0.isNumber }) }
            } else {
                name = nil
            }
            guard let name else {
                index += 1
                continue
            }
            // Count lines until the braces opened by the declaration balance out.
            var depth = 0
            var opened = false
            var length = 0
            var cursor = index
            while cursor < lines.count {
                length += 1
                for character in lines[cursor] {
                    if character == "{" { depth += 1; opened = true }
                    if character == "}" { depth -= 1 }
                }
                if opened && depth == 0 { break }
                cursor += 1
            }
            lengths[name] = length
            index = cursor + 1
        }
        return lengths
    }

    /// A screen that reads a package model through `@EnvironmentObject` without an attaching
    /// modifier anywhere in the same sources would crash at run time (section 13.1, rule 3).
    public static func unattachedEnvironmentObjects(in files: [URL]) -> [Finding] {
        let attachments: [(model: String, modifiers: [String])] = [
            ("ZTronSearchResultsModel", [".zTronSearch(", ".zTronResults("]),
            ("ZTronSuggestionsModel", [".zTronSuggestions("]),
            ("ZTronChatModel", [".zTronChat("]),
        ]
        var sources: [(file: URL, code: String)] = []
        for file in files {
            if let source = try? String(contentsOf: file, encoding: .utf8) { sources.append((file, code(of: source))) }
        }
        var findings: [Finding] = []
        for attachment in attachments {
            // `.environmentObject(model)` by hand counts as an attachment too.
            let attached = sources.contains { source in
                attachment.modifiers.contains { source.code.contains($0) } || source.code.contains(".environmentObject(")
            }
            guard !attached else { continue }
            for source in sources {
                for (number, line) in source.code.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains("@EnvironmentObject") && line.contains(attachment.model) {
                    findings.append(Finding(
                        file: source.file.lastPathComponent, line: number + 1,
                        rule: "reads \(attachment.model) without an attaching modifier",
                        excerpt: line.trimmingCharacters(in: .whitespaces)
                    ))
                }
            }
        }
        return findings
    }
}
