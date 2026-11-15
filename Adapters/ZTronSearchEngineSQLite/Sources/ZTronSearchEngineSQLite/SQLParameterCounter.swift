import Foundation

/// Counts the parameters of a statement the way SQLite numbers them.
///
/// SQLite.swift compares the number of bindings with the statement's parameters in a
/// `fatalError`, and it does not expose the number the statement expects. Counting it here lets
/// the adapter throw ``SQLiteSearchError/bindingCountMismatch(expected:provided:statement:)``
/// for a fragment whose bindings do not match its placeholders, instead of taking the process
/// down.
///
/// The scan follows SQLite's tokenizer and its numbering rules:
/// - a bare `?` takes the next number, and `?NNN` takes the number `NNN`;
/// - `:name`, `@name`, `$name` and `#name` take the next number the first time a name appears
///   and reuse it afterwards;
/// - the count is the highest number given out;
/// - nothing inside a string literal, a quoted identifier or a comment is a parameter;
/// - SQLite compiles the first statement of a text only, so the scan stops at the `;` that
///   ends it.
///
/// It is only ever run on text SQLite has already compiled, so it does not have to judge
/// whether the text is valid SQL.
enum SQLParameterCounter {
    static func parameterCount(in sql: String) -> Int {
        let bytes = Array(sql.utf8)
        let end = bytes.count
        var index = 0
        var highest = 0
        var numbers: [ArraySlice<UInt8>: Int] = [:]
        // A `;` before the first token is an empty statement, which SQLite skips.
        var sawToken = false

        while index < end {
            let byte = bytes[index]
            switch byte {
            case Byte.space, Byte.tab ... Byte.carriageReturn:
                index += 1

            case Byte.singleQuote, Byte.doubleQuote, Byte.backtick:
                // A literal or a quoted identifier; a doubled delimiter is an escaped one.
                index += 1
                while index < end {
                    if bytes[index] == byte {
                        if index + 1 < end, bytes[index + 1] == byte {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                sawToken = true

            case Byte.openBracket:
                // `[identifier]`, which has no escape.
                while index < end, bytes[index] != Byte.closeBracket { index += 1 }
                index = min(end, index + 1)
                sawToken = true

            case Byte.minus where index + 1 < end && bytes[index + 1] == Byte.minus:
                // `-- comment` to the end of the line.
                while index < end, bytes[index] != Byte.newline { index += 1 }

            case Byte.slash where index + 1 < end && bytes[index + 1] == Byte.star:
                // `/* comment */`; an unterminated one runs to the end.
                index += 2
                while index < end, !(bytes[index] == Byte.star && index + 1 < end && bytes[index + 1] == Byte.slash) {
                    index += 1
                }
                index = min(end, index + 2)

            case Byte.semicolon:
                if sawToken { return highest }
                index += 1

            case Byte.question:
                index += 1
                let digits = index
                while index < end, isDigit(bytes[index]) { index += 1 }
                if index == digits {
                    highest += 1
                } else {
                    // SQLite refuses numbers above its limit, far below this cap; the cap only
                    // keeps the arithmetic from overflowing on a long run of digits.
                    var number = 0
                    for digit in bytes[digits..<index] where number < 1_000_000_000 {
                        number = number * 10 + Int(digit - Byte.zero)
                    }
                    highest = max(highest, number)
                }
                sawToken = true

            case Byte.colon, Byte.at, Byte.dollar, Byte.hash:
                var cursor = index + 1
                var nameLength = 0
                name: while cursor < end {
                    let character = bytes[cursor]
                    if isIdentifier(character) {
                        nameLength += 1
                        cursor += 1
                    } else if character == Byte.openParenthesis, nameLength > 0 {
                        // Tcl array syntax: `$name(index)`.
                        repeat { cursor += 1 } while cursor < end && !isSpace(bytes[cursor]) && bytes[cursor] != Byte.closeParenthesis
                        if cursor < end, bytes[cursor] == Byte.closeParenthesis { cursor += 1 }
                        break name
                    } else if character == Byte.colon, cursor + 1 < end, bytes[cursor + 1] == Byte.colon {
                        // Tcl namespace syntax: `$namespace::name`.
                        cursor += 2
                    } else {
                        break name
                    }
                }
                if nameLength == 0 {
                    index += 1
                } else {
                    let name = bytes[index..<cursor]
                    if numbers[name] == nil {
                        highest += 1
                        numbers[name] = highest
                    }
                    index = cursor
                }
                sawToken = true

            default:
                if isIdentifier(byte) {
                    // A keyword, an identifier or a number. `$` continues an identifier but
                    // does not start one.
                    while index < end, isIdentifier(bytes[index]) { index += 1 }
                } else {
                    index += 1
                }
                sawToken = true
            }
        }
        return highest
    }

    private enum Byte {
        static let tab: UInt8 = 0x09
        static let newline: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let space: UInt8 = 0x20
        static let doubleQuote: UInt8 = 0x22
        static let hash: UInt8 = 0x23
        static let dollar: UInt8 = 0x24
        static let singleQuote: UInt8 = 0x27
        static let openParenthesis: UInt8 = 0x28
        static let closeParenthesis: UInt8 = 0x29
        static let star: UInt8 = 0x2A
        static let minus: UInt8 = 0x2D
        static let slash: UInt8 = 0x2F
        static let zero: UInt8 = 0x30
        static let colon: UInt8 = 0x3A
        static let semicolon: UInt8 = 0x3B
        static let question: UInt8 = 0x3F
        static let at: UInt8 = 0x40
        static let openBracket: UInt8 = 0x5B
        static let closeBracket: UInt8 = 0x5D
        static let underscore: UInt8 = 0x5F
        static let backtick: UInt8 = 0x60
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == Byte.space || (Byte.tab ... Byte.carriageReturn).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    /// SQLite's `IdChar`: letters, digits, `_`, `$` and every byte of a non-ASCII character.
    private static func isIdentifier(_ byte: UInt8) -> Bool {
        byte >= 0x80 || isDigit(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
            || byte == Byte.underscore || byte == Byte.dollar
    }
}
