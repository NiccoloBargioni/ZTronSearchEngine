import CryptoKit
import Foundation

/// The two checksums a manifest carries, computed from a local file.
enum FileDigests {
    /// Lowercase hexadecimal SHA-256 of the file, read in 8 MB pieces.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    /// Lowercase hexadecimal Git blob id of the file: the SHA-1 of `"blob <size>\0"` followed by
    /// the content. Meant for the small files Git stores itself.
    static func gitBlobSHA1(of url: URL) throws -> String {
        let content = try Data(contentsOf: url)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(content.count)\u{0}".utf8))
        hasher.update(data: content)
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
