import Foundation
import ZTronSearchEngine

/// The reference model of specification section 14.2: `mlx-community/Qwen3-1.7B-4bit`.
///
/// The asset is pinned to one commit of the repository and lists the four files the runtime
/// reads. What is known about them comes from the public Hugging Face metadata of that commit:
///
/// | File | Bytes | SHA-256 |
/// |---|---|---|
/// | `config.json` | 937 | not published; Git blob id known |
/// | `model.safetensors` | 968,080,210 | published (Git LFS) |
/// | `tokenizer.json` | 11,422,654 | published (Git LFS) |
/// | `tokenizer_config.json` | 9,706 | not published; Git blob id known |
///
/// Hugging Face publishes a SHA-256 only for files stored through Git LFS. The two small files
/// are kept in Git itself, so their SHA-256 can only be computed from the files. No value is
/// invented here: ``verifiedManifest`` leaves them out, and a `ModelAsset` exists only once a
/// complete manifest supplies them. `Scripts/pin-qwen3-asset.swift` writes that manifest from a
/// local copy of the files, after checking the copy against everything in ``verifiedManifest``.
///
/// The repository's other files (`vocab.json`, `merges.txt`, `added_tokens.json`,
/// `special_tokens_map.json`, `model.safetensors.index.json`, `README.md`, `.gitattributes`)
/// repeat what `tokenizer.json` holds or are not read at all, so they are not part of the asset.
/// The repository has no `generation_config.json`: the sampling defaults of the specification
/// apply to this model unchanged.
public enum Qwen3Asset {
    /// The identifier core knows the asset by.
    public static let id = "qwen3-1.7b-4bit"

    /// The Hugging Face repository.
    public static let repository = "mlx-community/Qwen3-1.7B-4bit"

    /// The pinned commit of ``repository``: the repository's only revision of the weights,
    /// last modified on 2025-04-28 and still the head of `main` when it was pinned on 2026-11-14.
    public static let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"

    /// The manifest of the pinned revision as far as public metadata verifies it, as JSON.
    ///
    /// `Scripts/qwen3-1.7b-4bit.verified.json` holds the same text for the pinning script; a unit
    /// test keeps the two equal.
    public static let verifiedManifestJSON = """
        {
          "files" : [
            {
              "byteCount" : 937,
              "gitBlobSHA1" : "0a78ffc3980b062021a450199988d0ed8537239d",
              "name" : "config.json"
            },
            {
              "byteCount" : 968080210,
              "name" : "model.safetensors",
              "sha256" : "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"
            },
            {
              "byteCount" : 11422654,
              "name" : "tokenizer.json",
              "sha256" : "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
            },
            {
              "byteCount" : 9706,
              "gitBlobSHA1" : "7345216a0785dc7086e8c245b2a9d3896ce2b756",
              "name" : "tokenizer_config.json"
            }
          ],
          "id" : "qwen3-1.7b-4bit",
          "repository" : "mlx-community/Qwen3-1.7B-4bit",
          "revision" : "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
        }
        """

    /// ``verifiedManifestJSON``, decoded.
    ///
    /// It is partial: `config.json` and `tokenizer_config.json` have no SHA-256, so
    /// `verifiedManifest.asset()` throws until the missing values are pinned.
    public static let verifiedManifest: ModelAssetManifest = {
        do {
            return try ModelAssetManifest(json: Data(verifiedManifestJSON.utf8))
        } catch {
            preconditionFailure("Qwen3Asset.verifiedManifestJSON does not decode: \(error)")
        }
    }()

    /// The size of the download in bytes: 979,513,507, of which the weights are 968,080,210.
    public static var totalBytes: Int64 {
        verifiedManifest.totalBytes
    }

    /// The `ModelAsset` for the pinned revision, from a complete manifest.
    ///
    /// `manifest` must describe the same asset and revision as ``verifiedManifest``, list the same
    /// files with the same sizes, agree with every checksum that is already verified, and carry a
    /// SHA-256 for every file. A SHA-256 that public metadata cannot confirm is accepted only
    /// together with the matching Git blob id, which ties it to the pinned commit.
    public static func asset(pinnedBy manifest: ModelAssetManifest) throws -> ModelAsset {
        try manifest.validate(against: verifiedManifest)
        return try manifest.asset()
    }

    /// The `ModelAsset` for the pinned revision, from the JSON file written by
    /// `Scripts/pin-qwen3-asset.swift`.
    public static func asset(pinnedManifestAt url: URL) throws -> ModelAsset {
        try asset(pinnedBy: ModelAssetManifest(contentsOf: url))
    }
}
