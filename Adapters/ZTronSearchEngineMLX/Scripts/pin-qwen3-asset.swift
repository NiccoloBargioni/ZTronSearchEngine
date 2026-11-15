#!/usr/bin/env swift
//
// pin-qwen3-asset.swift — completes the manifest of the Qwen3 asset from a local copy of its files.
//
// Hugging Face publishes a SHA-256 only for files stored through Git LFS. For the small files
// kept in Git itself (config.json, tokenizer_config.json) it publishes the Git blob id, a SHA-1.
// This script reads the local files, checks every one of them against what is already verified
// (size, SHA-256 where known, Git blob id where known), and writes a manifest in which every
// file has a SHA-256. The Git blob ids are what tie the newly computed values to the pinned
// commit: a file that is not byte-for-byte the one of that commit is rejected.
//
// Usage:
//   swift Scripts/pin-qwen3-asset.swift <model-directory> [--verified <manifest.json>] [--output <manifest.json>]
//
//   <model-directory>  directory holding the files of mlx-community/Qwen3-1.7B-4bit at the pinned revision
//   --verified         the partial manifest to complete; default: qwen3-1.7b-4bit.verified.json next to this script
//   --output           where to write the complete manifest; default: standard output
//
// The output is what `Qwen3Asset.asset(pinnedManifestAt:)` reads. Nothing is downloaded.

import CryptoKit
import Foundation

struct Manifest: Codable {
    struct File: Codable {
        var name: String
        var byteCount: Int64
        var sha256: String?
        var gitBlobSHA1: String?
    }

    var id: String
    var repository: String
    var revision: String
    var files: [File]
}

struct Failure: Error, CustomStringConvertible {
    var description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Size, SHA-256 and Git blob id of a file, read once in 8 MB pieces.
func digests(of url: URL) throws -> (byteCount: Int64, sha256: String, gitBlobSHA1: String) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
        throw Failure(description: "cannot read the size of \(url.path)")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var sha256 = SHA256()
    var sha1 = Insecure.SHA1()
    // A Git blob id is the SHA-1 of "blob <size>\0" followed by the content.
    sha1.update(data: Data("blob \(size)\u{0}".utf8))
    var read: Int64 = 0
    while let chunk = try handle.read(upToCount: 8 * 1_024 * 1_024), !chunk.isEmpty {
        sha256.update(data: chunk)
        sha1.update(data: chunk)
        read += Int64(chunk.count)
    }
    guard read == size else {
        throw Failure(description: "\(url.lastPathComponent) changed while it was being read")
    }
    return (size, hex(sha256.finalize()), hex(sha1.finalize()))
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var verifiedPath: String?
var outputPath: String?
var positional: [String] = []

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--verified":
        guard !arguments.isEmpty else { fail("--verified needs a path") }
        verifiedPath = arguments.removeFirst()
    case "--output":
        guard !arguments.isEmpty else { fail("--output needs a path") }
        outputPath = arguments.removeFirst()
    case "-h", "--help":
        print("usage: swift pin-qwen3-asset.swift <model-directory> [--verified <manifest.json>] [--output <manifest.json>]")
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)") }
        positional.append(argument)
    }
}

guard positional.count == 1 else {
    fail("expected exactly one model directory; see --help")
}
let directory = URL(fileURLWithPath: positional[0], isDirectory: true)
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("\(directory.path) is not a directory")
}

let verifiedURL = verifiedPath.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("qwen3-1.7b-4bit.verified.json")

// MARK: - Verification

let verified: Manifest
do {
    verified = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: verifiedURL))
} catch {
    fail("cannot read the verified manifest at \(verifiedURL.path): \(error)")
}
if ["", "main", "master", "head", "latest"].contains(verified.revision.lowercased()) {
    fail("the verified manifest is not pinned to a commit or tag (revision \"\(verified.revision)\")")
}

var complete = verified
var problems: [String] = []
var newlyPinned: [String] = []

for (index, expected) in verified.files.enumerated() {
    let url = directory.appendingPathComponent(expected.name)
    guard FileManager.default.fileExists(atPath: url.path) else {
        problems.append("\(expected.name): missing")
        continue
    }
    let actual: (byteCount: Int64, sha256: String, gitBlobSHA1: String)
    do {
        actual = try digests(of: url)
    } catch {
        problems.append("\(expected.name): \(error)")
        continue
    }

    if actual.byteCount != expected.byteCount {
        problems.append("\(expected.name): \(actual.byteCount) bytes, expected \(expected.byteCount)")
    }
    if let sha256 = expected.sha256, sha256 != actual.sha256 {
        problems.append("\(expected.name): SHA-256 \(actual.sha256), expected \(sha256)")
    }
    if let gitBlobSHA1 = expected.gitBlobSHA1, gitBlobSHA1 != actual.gitBlobSHA1 {
        problems.append("\(expected.name): Git blob id \(actual.gitBlobSHA1), expected \(gitBlobSHA1)")
    }
    if expected.sha256 == nil && expected.gitBlobSHA1 == nil {
        problems.append("\(expected.name): the verified manifest has neither a SHA-256 nor a Git blob id to check against")
    }

    if expected.sha256 == nil {
        newlyPinned.append(expected.name)
    }
    complete.files[index].sha256 = actual.sha256
}

guard problems.isEmpty else {
    let list = problems.map { "  - \($0)" }.joined(separator: "\n")
    fail("\(directory.path) is not \(verified.repository) at \(verified.revision):\n\(list)")
}

// MARK: - Output

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let json: Data
do {
    json = try encoder.encode(complete)
} catch {
    fail("cannot encode the manifest: \(error)")
}

if let outputPath {
    do {
        try (json + Data("\n".utf8)).write(to: URL(fileURLWithPath: outputPath))
    } catch {
        fail("cannot write \(outputPath): \(error)")
    }
} else {
    FileHandle.standardOutput.write(json + Data("\n".utf8))
}

let total = complete.files.reduce(Int64(0)) { $0 + $1.byteCount }
var summary = "verified \(complete.files.count) files (\(total) bytes) of \(verified.repository) at \(verified.revision)\n"
summary += newlyPinned.isEmpty
    ? "every SHA-256 was already known\n"
    : "newly pinned SHA-256: \(newlyPinned.joined(separator: ", "))\n"
FileHandle.standardError.write(Data(summary.utf8))
