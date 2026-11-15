# ZTronSearchEngineMLX

The reference local-LLM runtime of ZTronSearchEngine (specification section 14). It implements
core's `LocalLanguageModel` boundary on top of MLX, so the chat service in core can generate text
on the device without core ever linking MLX.

The package provides:

- `MLXLanguageModel`: the runtime. It loads a model from a local directory, applies the chat
  template that ships with the model, and streams `GenerationEvent`s.
- `Qwen3Asset`: the pinned description of the reference model, `mlx-community/Qwen3-1.7B-4bit`.
- `ChatCalibration`: the measurement behind the device gate (time to first token, decode rate).
- `ThinkBlockFilter`, `SamplingPlan`, `ModelAssetManifest`: the small pure pieces the runtime is
  built from. They are public because their rules are part of the runtime's behaviour.

## Why a separate package

mlx-swift declares `.iOS(.v17)` and `.macOS("14.0")`. Core's floor is iOS 15, and a package
cannot depend on one with a higher floor. Keeping the runtime here leaves core untouched: core
only declares the boundary, and the host injects this runtime through the `ZTronSearch` facade.

mlx-swift also needs its Metal shaders compiled into a `default.metallib`. Xcode's build engine
does that, and it needs the Metal Toolchain component of Xcode. Anything that evaluates MLX has
to come from such a build: Xcode or `xcodebuild`.

## Dependencies

Every remote dependency is pinned to an exact version. These are the versions the package was
built and tested with:

| Package | Version | Revision | Used for |
|---|---|---|---|
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.32.3 | `19601207e9a0de51e03ee6ec0c3c5f3784275075` | arrays, Metal backend (`MLX`) |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.32.3 | `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6` | model loading and token generation (`MLXLLM`, `MLXLMCommon`) |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.4.0 | `402a8a1105f52038b0949d9596981fc9e32bed17` | tokenizer and Jinja chat templates (`Tokenizers`, `Hub`) |
| ZTronSearchEngine (core) | by path | | the `LocalLanguageModel` boundary |

Notes:

- The LLM layer the specification calls "mlx-swift-lm" lives at `ml-explore/mlx-swift-lm`. It
  used to be the `Libraries/` directory of `ml-explore/mlx-swift-examples`.
- mlx-swift-lm 3.32.3 requires mlx-swift `0.32.3 ..< 0.33.0`. mlx-swift 0.33.0 exists and does
  not resolve with it.
- mlx-swift-lm 3.x no longer ships a tokenizer; the client brings one. This package uses the
  tokenizer of swift-transformers and adapts it in `LocalTokenizer.swift`. That brings these
  transitive packages: swift-jinja 3.1.0, swift-huggingface 1.0.0, swift-collections 1.7.6,
  swift-crypto 4.5.2, swift-asn1 1.7.4, yyjson 0.13.0, EventSource 1.6.0. swift-numerics 1.1.1
  comes with mlx-swift. swift-syntax 603.0.2 is resolved for a macro target of mlx-swift-lm that
  this package does not build. `Package.resolved` records all of them.
- swift-huggingface is a Hub client and is linked, but this package never creates it. Tokenizer
  files are read with Foundation, so loading a model opens no session and sends nothing.
- mlx-swift 0.32.3 needs Swift tools 6.3 and mlx-swift-lm 3.32.3 needs 6.2. This package's own
  manifest stays at tools version 6.0 and Swift 6 language mode.
- `Package.swift` points at core with an absolute path. It becomes `../..` once this package
  lives at `Adapters/ZTronSearchEngineMLX` in the ZTronSearchEngine repository.

## Link MLX once

Two copies of MLX in one process misbehave. The app must link MLX exactly once. If the app
already depends on mlx-swift for something else, it has to resolve to the same mlx-swift version
as this package (0.32.3), not add a second copy. Do not embed this package in two dynamic
frameworks that each bring their own MLX.

mlx-swift-lm's `MLXFoundationModels` product has a type that is also called `MLXLanguageModel`.
A file that imports both modules has to write `ZTronSearchEngineMLX.MLXLanguageModel`.

## Wiring it into a host

```swift
import ZTronSearchEngine
import ZTronSearchEngineMLX

// The pinned asset. The manifest file is written once by Scripts/pin-qwen3-asset.swift
// and shipped with the app; see "The asset" below.
let manifestURL = Bundle.main.url(forResource: "qwen3-1.7b-4bit.manifest", withExtension: "json")!
let asset = try Qwen3Asset.asset(pinnedManifestAt: manifestURL)

let runtime = MLXLanguageModel(asset: asset)

let engine = ZTronSearch(
    search: searchService,
    assets: assetKitAdapter,     // the host's ModelAssetProviding over ZTronAssetKit
    languageModel: runtime
)
```

`runtime.descriptor` is what the device gate reads: the asset, a 4,096-token working window,
6 GB of physical memory (`6 * 1024^3` bytes) and the OS floor. The floor is iOS 17.0 in an iOS
build and macOS 14.0 in a macOS build, because the gate compares it with the version the process
runs on and a Mac reports its macOS version. Core then drives the runtime through the boundary
alone: `load(from:)` with the directory the asset provider reports as available,
`countTokens(_:)`, `generate(_:)`, `unload()`.

## How the runtime behaves

**Local files only.** `load(from:)` reads `config.json`, `tokenizer.json`,
`tokenizer_config.json` and the `.safetensors` weights from the directory. It first checks, with
plain file inspection, that these exist and that the directory ships a chat template; a directory
that cannot work fails with an `MLXLanguageModelError` before MLX is touched. The tokenizer files
are parsed with Foundation while mlx-swift-lm reads the weights (about 0.27 s for a tokenizer of
Qwen3's size on an M3, measured on a synthetic `tokenizer.json`).

**Its own thread.** `MLXLanguageModel` is an actor with a custom executor backed by one dedicated
thread. Applying the chat template, the prompt prefill and every decode step run on that thread,
never on Swift's cooperative pool. A generation is one uninterrupted job on it; other calls to
the same instance wait behind it. mlx-swift-lm reads the weight files on a global dispatch queue.

**Chat template.** Messages are rendered with the template of the asset (the `chat_template` of
`tokenizer_config.json`, or `chat_template.jinja` / `chat_template.json` when the asset has one).
No template is written by hand anywhere. A directory without a template does not load.

**Thinking.** The template receives `enable_thinking`, `false` unless `options.thinking` is set.
With `false`, Qwen3's template closes an empty think block in the prompt and the model answers
directly. Whatever the model does, `ThinkBlockFilter` removes every `<think>…</think>` block
before `.delta`, also when a tag is split across tokens. Tokens inside a block still count in
`.usage`.

**Events.** `.delta` for each decoded piece of visible text, then one `.usage(prompt:generated:)`,
then one `.finished`. `.endOfTurn` when the model emits an end-of-sequence token, `.maxTokens`
when the token budget is spent, `.cancelled` when the generation was stopped. Errors found before
the first token (no model loaded, an empty request, a prompt that does not fit) end the stream by
throwing.

**Sampling.** Defaults are temperature 0.7, top-p 0.8 and at most 512 new tokens. The asset's
`generation_config.json` wins over those defaults when it is present, and an explicit request
option wins over both: `temperature` and `topP` are optional in `GenerationOptions`, and `nil`
means the request leaves the choice to the asset and the defaults. `top_k` and `repetition_penalty` come
from the asset alone. `maxNewTokens` is the caller's budget: the asset can lower the default but
never raise it. `options.seed` seeds the sampler; `nil` uses system entropy. The full rule is on
`SamplingPlan`. The Qwen3 repository has no `generation_config.json`, so the defaults apply to
the reference model as they are.

**Context window.** The prompt plus the reply never exceed `descriptor.contextWindow`. A prompt
that leaves no room throws `promptTooLong`; a reply that reaches the edge of the window ends with
`.maxTokens`.

**Cancellation.** A generation stops when the consumer of its stream goes away (its task is
cancelled or it stops iterating), when `cancelGenerations()` is called and when `unload()` is
called. The flag is checked before every token: after it is set, no token is requested and no
text is emitted; at most the token that was being computed completes. During the prompt prefill,
cancellation takes effect between two prefill chunks (512 tokens by default,
`Tuning.prefillStepSize` to change it).

A consumer whose task was cancelled cannot receive anything more: `AsyncThrowingStream` ends for
it at that moment. So `.usage` and `.finished(.cancelled)` reach only consumers that keep reading
after the generation was stopped by `cancelGenerations()` or `unload()`. `cancelGenerations()` is
not part of core's protocol; it is the way to stop a generation and still learn how many tokens it
produced.

Cancel generation before the app goes to the background: iOS does not let a backgrounded app
submit GPU work.

**Unload.** `unload()` cancels running and waiting generations, frees the weights, the tokenizer
and the template, and clears MLX's buffer cache. The files stay on disk.

**Token counts.** `countTokens(_:)` uses the model's tokenizer. After `unload()` the tokenizer
alone is loaded again from the last directory on first use, so counts stay exact between an idle
unload and the next load. Before the first successful load there is no tokenizer; the result is
then the number of UTF-8 bytes, an upper bound for a byte-level tokenizer, not a count.

**MLX buffer cache.** `load` sets MLX's process-wide buffer cache limit to 32 MB
(`Tuning.bufferCacheLimit`; `nil` leaves MLX's setting alone). MLX's default lets the cache grow
to gigabytes.

## Calibration

Core owns the device gate and stores its verdict (specification section 14.4). This package
provides the measurement, and it uses nothing beyond `countTokens` and `generate`:

```swift
let calibration = try await runtime.calibrate()          // after the first load
let enabled = calibration.passes()                       // <= 3 s to first token, >= 8 tokens/s
```

`ChatCalibration.measure(_:)` does the same for any `LocalLanguageModel`. Core cannot import this
package, so here is the request for core to issue itself:

- One `user` message whose text has at least 512 tokens by `countTokens` (grow a passage word by
  word until the count reaches 512) and ends with an instruction that asks for a long answer.
  The chat template adds about a dozen tokens, so slightly more than 512 tokens are prefilled;
  `.usage` reports the exact number.
- `GenerationOptions(temperature: 0, topP: 1, maxNewTokens: 64, seed: 0, thinking: false)`.
- Time to first token: from the call to `generate` to the first `.delta`.
- Decode rate: `(generated - 1) / (time of .finished - time of the first .delta)`, with
  `generated` from `.usage`.

The first generation after a load also compiles MLX's GPU kernels, so the calibration run is the
slowest generation the device will see.

## The asset

`mlx-community/Qwen3-1.7B-4bit`, pinned to commit `3b1b1768f8f8cf8351c712464f906e86c2b8269e`
(2025-04-28, the head of `main` when it was pinned on 2026-11-14). The asset lists the four files
the runtime reads. What is known about them comes from the public Hugging Face metadata of that
commit; no file was downloaded.

| File | Bytes | SHA-256 | Git blob id |
|---|---:|---|---|
| `config.json` | 937 | **not published** | `0a78ffc3980b062021a450199988d0ed8537239d` |
| `model.safetensors` | 968,080,210 | `0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f` | (LFS) |
| `tokenizer.json` | 11,422,654 | `aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4` | (LFS) |
| `tokenizer_config.json` | 9,706 | **not published** | `7345216a0785dc7086e8c245b2a9d3896ce2b756` |

Total: 979,513,507 bytes. The specification's "968 MB" is the weights file alone
(968,080,210 bytes); the whole repository is 984,015,687 bytes.

Hugging Face publishes a SHA-256 only for files stored through Git LFS. `config.json` and
`tokenizer_config.json` are kept in Git itself, so their SHA-256 can only be computed from the
files. Nothing is invented: `Qwen3Asset.verifiedManifest` leaves the two values out, and
`Qwen3Asset.verifiedManifest.asset()` throws until they are pinned. The two LFS checksums were
cross-checked: the Git LFS pointer rebuilt from each SHA-256 and size hashes to the blob id the
commit's tree lists for that file.

The repository's other files are not part of the asset: `vocab.json` (2,776,833 bytes),
`merges.txt` (1,671,853), `model.safetensors.index.json` (49,731), `added_tokens.json` (707),
`special_tokens_map.json` (613), `README.md` (873), `.gitattributes` (1,570). The tokenizer is
built from `tokenizer.json`, and the weights are found by name. The repository has no
`generation_config.json` and no separate chat template file: the template is inside
`tokenizer_config.json`.

### Pinning the two missing checksums

Once the files exist locally (downloaded by the host's asset provider, or by any other means, at
the pinned revision):

```sh
swift Scripts/pin-qwen3-asset.swift /path/to/Qwen3-1.7B-4bit --output qwen3-1.7b-4bit.manifest.json
```

The script reads `Scripts/qwen3-1.7b-4bit.verified.json` (the same content as
`Qwen3Asset.verifiedManifestJSON`; a unit test keeps them equal), checks every local file against
it (size, SHA-256 where published, Git blob id otherwise) and writes a manifest in which every
file has a SHA-256. A copy that is not byte-for-byte the pinned commit is rejected with the list
of differences. Nothing is downloaded.

Ship the resulting JSON with the app and build the asset from it:

```swift
let asset = try Qwen3Asset.asset(pinnedManifestAt: manifestURL)
```

`asset(pinnedManifestAt:)` validates the file against `verifiedManifest` again: same asset and
revision, same files and sizes, no contradiction with a verified checksum, and each new SHA-256
accompanied by the matching Git blob id. The integration test `testDirectoryIsThePinnedRevision`
performs the same verification and prints the complete manifest.

## Tests

### Unit tests

149 tests. They need no weights and never evaluate MLX: the think filter, sampling precedence and
`generation_config.json` parsing, the token loop (stop reasons, usage, cancellation), the asset
manifest, the descriptor, load failures, the tokenizer bridge and chat template on a tiny
tokenizer written to a temporary directory, the dedicated thread, and the calibration arithmetic
on scripted event streams.

With the Metal Toolchain component of Xcode installed:

```sh
xcodebuild test -scheme ZTronSearchEngineMLX -destination 'platform=macOS' -derivedDataPath .build/xcode
```

Without it, the unit tests still run through SwiftPM's legacy build system, which skips the
Metal shaders:

```sh
swift test --build-system native
```

With Xcode 27 (Swift 6.4) the default `swift build` / `swift test` use the same build engine as
Xcode: they also try to compile mlx-swift's Metal shaders and fail when the Metal Toolchain is
missing (`xcodebuild -showComponent MetalToolchain` shows whether it is installed). Whether a
plain `swift test` build with the toolchain installed yields a metallib MLX can load has not been
tried; `xcodebuild` is the path the specification names. `--build-system native` is deprecated
in Swift 6.4 and prints a warning to that effect.

### Integration tests

`Qwen3IntegrationTests` runs the real model against specification section 15.6: load time, time
to first token and decode rate over 20 runs, cancellation latency, footprint during generation,
seed reproducibility, thinking mode, the context window, and the verification of the local files
against the pinned revision. They need MLX's Metal shaders, so they run through `xcodebuild` on an
Apple-silicon Mac, and they need the model directory:

```sh
TEST_RUNNER_ZTRON_QWEN3_DIR=/path/to/Qwen3-1.7B-4bit \
  xcodebuild test -scheme ZTronSearchEngineMLX -destination 'platform=macOS' -derivedDataPath .build/xcode
```

`xcodebuild` passes variables prefixed with `TEST_RUNNER_` to the test process without the
prefix. When `ZTRON_QWEN3_DIR` is not set, every integration test is skipped with a message that
says so. In a build without the Metal shaders they are skipped as well, except
`testDirectoryIsThePinnedRevision`, which only hashes files:

```sh
ZTRON_QWEN3_DIR=/path/to/Qwen3-1.7B-4bit \
  swift test --build-system native --filter testDirectoryIsThePinnedRevision
```

## Layout

```
Package.swift
Sources/ZTronSearchEngineMLX/
  MLXLanguageModel.swift          the actor: load, unload, countTokens, generate
  DedicatedThreadExecutor.swift   the serial executor on the runtime's own thread
  GenerationLoop.swift            the token loop, free of MLX types
  GenerationCancellation.swift    cancellation flags of running and waiting generations
  ThinkBlockFilter.swift          streaming removal of <think> blocks
  SamplingPlan.swift              generation_config.json and option precedence
  LocalTokenizer.swift            directory checks, tokenizer bridge, local tokenizer loader, JSON conversion
  ChatCalibration.swift           the calibration request and measurement
  ModelAssetManifest.swift        manifest of a pinned repository revision
  Qwen3Asset.swift                the reference model's verified manifest
  MLXLanguageModelError.swift     errors
Scripts/
  pin-qwen3-asset.swift           completes the manifest from a local copy of the files
  qwen3-1.7b-4bit.verified.json   the verified manifest the script completes
Tests/ZTronSearchEngineMLXTests/  unit tests and Qwen3IntegrationTests
```
