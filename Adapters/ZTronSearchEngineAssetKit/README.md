# ZTronSearchEngineAssetKit

The model-asset boundary of ZTronSearchEngine (`ModelAssetProviding`, specification section 14.1)
implemented over ZTronAssetKit. Core never imports ZTronAssetKit; this package is the one place
where the two meet.

```swift
import ZTronAssetKit
import ZTronSearchEngine
import ZTronSearchEngineAssetKit

let assets = AssetKitModelAssetProvider(client: assetClient)   // the host's AssetClient
let search = ZTronSearch(search: service, assets: assets, languageModel: runtime)
```

ZTronAssetKit downloads, verifies, stores and resumes. The bridge adds four things: it maps each
file of a model to an asset of the host's catalog, it checks that what is stored is what the
model descriptor names, it pins the files so they are not evicted, and it gives the runtime one
directory that holds every file under its own name.

File references below are relative to the ZTronAssetKit checkout.

## The open question

> Does ZTronAssetKit provide resumable, checksum-verified background downloads, or does the
> bridge own resume and verification?

ZTronAssetKit owns verification and resume. The bridge owns neither. Background continuation
exists in ZTronAssetKit, but not in a form this boundary can use together with progress.

| Property | Answer | Where |
|---|---|---|
| Checksum verification | Yes, by ZTronAssetKit. Every download is staged, size-checked, hashed by streaming and compared with the manifest's SHA-256 before it is published. A mismatch deletes the staged bytes. | `Sources/ZTronAssetStorage/Store/AssetStore+Publish.swift:70-124`, `:435-444` |
| Content addressing | Yes. A blob is named by the SHA-256 that ZTronAssetKit computed from its bytes, never by the manifest's claim. | `AssetStore+Publish.swift:132`, `Sources/ZTronAssetStorage/Layout/StoreLayout.swift:4-20`, `:91-94`, `SPEC.md:131` (I-1) |
| No endless re-download | Yes. Repeated mismatches back off (60 s, 600 s) and the third marks the entry failed until its manifest entry changes. | `Sources/ZTronAssetModel/Policy/StoragePolicy.swift:63-68`, `Sources/ZTronAssetStorage/Integrity/StoreIntegrity.swift:47-91` |
| Resume, per file | Yes. A stored file is answered without a transfer. | `README.md:135-136` |
| Resume, within a file | Yes, with limits. A partial is kept with a `.resume` sidecar after a pause, a lost connection or a timeout, and the next attempt sends `Range` and `If-Range`. It also works across a relaunch. | `Sources/ZTronAssetTransport/Session/SessionDelegate+DataTasks.swift:355-367`, `Sources/ZTronAssetTransport/Policy/RequestFactory.swift:36-46`, `Sources/ZTronAssetSync/Engine/EngineFailures.swift:47-67`, `Sources/ZTronAssetSync/Engine/EngineLifecycle.swift:424-428` |
| Background session | Only for bulk-lane transfers, only when the host enabled it and forwards the AppDelegate hook, only for requests without the app key (unless the owner accepts redirect exposure), and never for a range resume. It is off by default. | `Sources/ZTronAssetModel/Policy/RemoteConfiguration.swift:33-40`, `:104`, `Sources/ZTronAssetSync/Engine/EngineDispatch.swift:719`, `Sources/ZTronAssetTransport/HTTPRemoteSource.swift:253-270` |
| Progress | Per asset on the user-initiated and prefetch lanes only. Bulk transfers publish no byte progress per asset. | `Sources/ZTronAssetSync/Engine/EngineDispatch.swift:906-916` |

Three limits follow, and sections 14.4 and 15.6 of the specification should be read with them.

1. **Resume within a file holds only while the engine keeps the transfer's job.** When the last
   caller withdraws, the engine cancels the transfer, and a cancel discards the partial
   (`Sources/ZTronAssetModel/Transfer/TransferUpdate.swift:62-63`, `:84-85`,
   `Sources/ZTronAssetSync/Engine/EngineJobs.swift:442-480`). A later job of the same process
   does not look for an earlier partial; only a launch does (`EngineJobs.swift:167`). So when the
   reader of a fetch stream is cancelled, or the fetch fails, and the fetch is started again in
   the same process, the file that was in transit starts at zero. For the reference model that
   file is `model.safetensors`, 968 MB of the 980 MB. Files that were stored are kept, so "a
   resumed fetch never re-downloads a verified file" holds.
2. **Resume within a file needs a checksum in the catalog and a validator from the origin.** A
   sidecar is written only for an entry that publishes a checksum, and only when the response
   carried a strong `ETag` or a `Last-Modified` (`SessionDelegate+DataTasks.swift:355-367`).
3. **"Downloads continue in the background through ZTronAssetKit's own session, and the engine
   only observes progress" cannot be had as written.** The lanes that report progress run in the
   foreground session. The one lane that may use the background session reports no byte
   progress, and a transfer that continues a partial runs in the foreground session. See
   "Download policy" for how a host chooses.

What the bridge checks itself is small: that the blob ZTronAssetKit stored for an identifier is
the blob the `ModelFile` names. That is a comparison of a file name and a size, not a hash.

## Wiring

```swift
var configuration = AssetClientConfiguration(remote: remote)
// Gives DownloadPolicy.wifiOnly a lane. See "Download policy" for the other ways.
configuration.network.prefetchOnExpensive = false
precondition(AssetKitModelAssetProvider.lane(for: .wifiOnly, under: configuration.network) != nil)

let assetClient = AssetClient(configuration: configuration)   // one per store, for the app's lifetime
try await assetClient.start()

let assets = AssetKitModelAssetProvider(
    client: assetClient,
    diagnostics: { diagnostic in logger.notice("\(diagnostic.description)") }
)
let search = ZTronSearch(search: service, assets: assets, languageModel: runtime)
```

The initializer also takes the root of the model directories and the mapping from a file to its
catalog identifier. The provider needs nothing else from the host at run time: `ChatService`
calls `availability(of:)`, `fetch(_:policy:)` and `evict(_:)`.

## What the host publishes in its catalog

One catalog entry per model file. With the default mapping the identifier is
`model/<asset id>@<revision>/<file name>`. For the reference model (`qwen3-1.7b-4bit`, revision
`3b1b1768f8f8cf8351c712464f906e86c2b8269e`, 979,513,507 bytes in four files):

```json
{
  "identifier": "model/qwen3-1.7b-4bit@3b1b1768f8f8cf8351c712464f906e86c2b8269e/model.safetensors",
  "fileExtension": "bin",
  "remotePath": "media/0e86d9677e519323/model.safetensors",
  "localPathComponents": ["Models"],
  "byteSize": 968080210,
  "checksum": "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f",
  "policy": "onDemand",
  "tags": ["model"]
}
```

| Field | Rule | Why |
|---|---|---|
| `identifier` | What the provider's mapping returns for the file. Another revision needs other identifiers. | The same model id at another revision is another asset (specification 14.1). |
| `checksum` | The file's SHA-256, equal to `ModelFile.sha256`. | Without it ZTronAssetKit cannot reject a bad download and never resumes within the file. If it differs from `ModelFile.sha256`, every fetch ends with `.checksum`. |
| `byteSize` | Equal to `ModelFile.byteCount`. | ZTronAssetKit checks the size before hashing; the bridge checks it against the descriptor. |
| `fileExtension` | One to eight letters or digits. `safetensors` has eleven: publish `bin`. | `Sources/ZTronAssetModel/Identity/AssetFileExtension.swift:10-14`. An entry with a longer extension is quarantined. The directory the bridge builds gives the file its real name back. |
| `policy` | `onDemand`. | A catalog sync fetches `standard` and `essential` entries on its own, on any network the host's bulk policy allows, before the user agreed to 968 MB (`Sources/ZTronAssetSync/Planning/PlanBuilder.swift:212-213`). On-demand entries are also the first eviction candidates (`Sources/ZTronAssetModel/Manifest/ManifestEntry.swift:9-10`), which is why the bridge pins them. |
| size limit | Nothing to do: the default cap per asset is 4 GiB. | `Sources/ZTronAssetModel/Manifest/ManifestLimits.swift:35` |

The origin should send a strong `ETag` or `Last-Modified` for the files, or a dropped connection
costs the whole file.

## What the provider does

**`availability(of:)`** starts the client if needed, reads its snapshot once, and answers
`.available(directory)` only when every file's blob is named by the file's SHA-256, has the
file's size in the snapshot and on disk, and the directory holds a link to each. It then pins
the files. It never downloads and never hashes. Otherwise it answers `.downloading` while a
fetch of this provider runs, `.failed(.checksum)` for a descriptor it cannot serve or a model it
rejected, and `.missing`.

**`fetch(_:policy:)`** inspects the store the same way, asks ZTronAssetKit only for the files
that are not stored and verified (`AssetClient.resolve`, one call per file, on the lane of the
policy), follows the client's events for byte progress and device conditions, verifies each URL
it gets back, pins, links, and ends with `.available(directory)`. The byte count starts at the
bytes already stored and never falls. Fetches of one asset under one policy share one session;
when the last reader is gone the session is cancelled and every request is withdrawn.

**`evict(_:)`** stops the fetches of the asset, removes its directory and its pins, and deletes
its files with `AssetClient.purge(.scope(.identifiers(…)))`.

### Verification

A blob of ZTronAssetKit's store is `blobs/<aa>/<sha256>.<ext>`, and the name is the digest
ZTronAssetKit computed from the bytes before it put the file in place (the rows "Checksum
verification" and "Content addressing" above; `Sources/ZTronAssetStorage/Snapshot/SnapshotTable.swift:11-24`
builds every location a lookup returns from that name). So a blob named by `ModelFile.sha256`
held the model's bytes when it was written, whether or not the catalog entry published a
checksum, and 968 MB are never hashed again by the bridge.

A name cannot show damage that happened later. ZTronAssetKit drops a stored record whose blob is
missing or has another size at every launch
(`Sources/ZTronAssetStorage/Store/LaunchReconciliation.swift:153-169`) and hashes stored blobs
again in `performMaintenance`. The bridge adds a size check of each blob on disk every time it
builds or confirms the directory.

Three cases end with `.checksum`:

- ZTronAssetKit rejected a download (`AssetError.integrityFailure`). Nothing was stored. Its own
  backoff answers a retry without a transfer until it expires.
- The catalog does not list the file (`AssetError.notFound`).
- The catalog holds other bytes than the descriptor names: ZTronAssetKit stored them, since they
  match the catalog's own checksum, and the blob's name is not `ModelFile.sha256`. The bridge
  withdraws its other requests, deletes the stored asset through `AssetClient.purge`, and then
  refuses to fetch that model again until `evict(_:)` or the next launch. Without that, every
  retry would download 968 MB of the same wrong bytes, because the public API of ZTronAssetKit
  does not show a catalog entry's checksum before the download. A blob that has the described
  SHA-256 but not the described size is kept: then the descriptor contradicts itself.

The bridge deletes with `purge`, not `reportUnreadable`: a quarantine schedules a re-download on
the prefetch lane after its backoff (`Sources/ZTronAssetSync/Engine/EngineTimers.swift:435-443`),
which no download policy asked for.

### The directory

The runtime needs `config.json`, `tokenizer.json`, `model.safetensors` in one directory. The
store holds content-addressed blobs. The bridge builds
`Library/Caches/ZTronSearchEngineAssetKit/Models/<id>@<revision>-<digest>/` with one symbolic
link per file, named as the descriptor names it and pointing at the blob. A name may contain
`/`; the subdirectories are created. The directory is built next to its final place and moved
in, and a directory that is already right is not touched.

| | Symbolic links (chosen) | Hard links | Copies |
|---|---|---|---|
| Extra disk for a 968 MB model | none | none while the store keeps its blob | 968 MB; none at first on APFS, where a copy is a clone |
| Who owns the bytes | the store alone | the store and the directory | the store and the directory |
| The store evicts, prunes or purges | the bytes are freed; the link dangles | the store reports bytes freed that stay on disk | same as hard links |
| The model stays loadable after that | no | yes | yes |
| Works across volumes | yes | no | yes |

Symbolic links keep ZTronAssetKit the only owner of every byte, so its budget, its eviction
order and a host's `purge` do what they report. The price is that the directory depends on the
store. When the store drops a file, `availability(of:)` answers `.missing` as soon as the
store's snapshot no longer lists it, and removes the directory once a link is broken on disk. A
model that is already loaded keeps running, because the runtime holds the weights in memory.
The directory checks of the reference runtime (`fileExists`, `contentsOfDirectory`,
`Data(contentsOf:)`) follow links. Loading real weights through the links was not run here.

The directory lives in `Caches` because it holds nothing that cannot be rebuilt. It must not lie
inside ZTronAssetKit's store, which deletes names it does not know
(`LaunchReconciliation.swift:15-21`). Use one provider per directory root.

### Keeping the files alive

| Mechanism of ZTronAssetKit | Used | Why |
|---|---|---|
| Pins (`pin`, `unpin`) | Yes | A pinned asset is never evicted, and pins are part of the store's index, so they survive a relaunch. Pinning what is pinned already commits nothing (`Sources/ZTronAssetStorage/Eviction/StoreEviction.swift:30-53`). The provider pins whenever it reports a model available and unpins in `evict(_:)`. |
| Leases (`withAsset`) | No | A lease ends with its closure, and the boundary has no call that brackets "the model is loaded". Worse, a lease on an asset that is not stored downloads it on the user-initiated lane (`Sources/ZTronAssetSync/Engine/EngineCommands.swift:897-933`), which would break `.never` and `.wifiOnly` in a race with an eviction. |
| Retention scope | No | It is one value for the whole client and belongs to the host's paywall logic. |

A pin does not stop `purge(.all)`, `purge(.scope(…))` or the prune that follows a catalog that
dropped the entry. Those are decisions of the host or the publisher, and the bridge follows
them: the model becomes `.missing`. Between `.available` and the runtime's first read the files
are also covered by the store's deletion grace, 10 s by default
(`Sources/ZTronAssetModel/Policy/StoragePolicy.swift:53-55`).

## Download policy

ZTronAssetKit has no network permission per request. The engine derives the permissions of a
request from its lane and the client-wide `NetworkPolicy`
(`Sources/ZTronAssetSync/Engine/EngineDispatch.swift:559-569`), and the HTTP transport sets them
on the `URLRequest` as `allowsCellularAccess`, `allowsExpensiveNetworkAccess` and
`allowsConstrainedNetworkAccess` (`Sources/ZTronAssetTransport/Policy/RequestFactory.swift:26-28`).
So a download policy is a choice of lane, and the operating system enforces it.

| `DownloadPolicy` | What the provider does |
|---|---|
| `.never` | Reads the store only. Fails with `.policy` when a file is missing. |
| `.allowCellular` | Asks on the most urgent lane that may use expensive networks. With the default `NetworkPolicy` that is `.userInitiated`, whose requests carry no restriction. |
| `.wifiOnly` | Asks on the most urgent lane that the host's `NetworkPolicy` keeps off expensive networks: `.userInitiated` when `userInitiatedOverridesPolicy` and `prefetchOnExpensive` are both `false`, else `.prefetch` when `prefetchOnExpensive` is `false`, else `.bulk` when `bulkOnExpensive` is `false`. With no such lane the fetch fails with `.policy` and downloads nothing. |

`AssetKitModelAssetProvider.lane(for:under:)` returns the lane for a `NetworkPolicy`, so a host
can assert its configuration at launch.

**With `NetworkPolicy()`'s defaults every lane may use cellular, so `.wifiOnly`, the default of
`ChatService.prepare`, always fails with `.policy`.** The bridge does not approximate it. A gate
built on the client's `conditionsChanged` events would let bytes through between a change of
network and the event, and the engine publishes no conditions while it is idle, so the gate
could not even know the network before it starts work. The host has to give `.wifiOnly` a lane:

| Host configuration | `.wifiOnly` lane | Consequence |
|---|---|---|
| `network.prefetchOnExpensive = false` | `.prefetch` | Byte progress. The carousel's own prefetch also stays off cellular. |
| `network.bulkOnExpensive = false` | `.bulk` | Progress per whole file only. Lowest priority, and parked in Low Power Mode unless `power.bulkInLowPowerMode` is `true`. Eligible for the background session if the host enabled it. |
| A second `AssetClient` for models, with its own store location, catalog and `NetworkPolicy(prefetchOnExpensive: false)` | `.prefetch` | The carousel's client keeps its policy. Two stores, two budgets. |

What is missing in ZTronAssetKit for a policy per call: a `NetworkAccess` parameter on
`resolve` and `prefetch` (the engine already carries one per `TransferRequest`), or a lane whose
permissions the caller sets.

During a fetch the provider reads the device conditions from the client's events. The engine
parks a lane that the network in use, or Low Power Mode, refuses, and answers no waiter while it
is parked (`Sources/ZTronAssetSync/Engine/EngineJobs.swift:875-897`). The provider therefore
fails the fetch with `.policy` as soon as the conditions refuse its lane, at the start or
later, and withdraws its requests. A thermal pause is left to end by itself.

One case reports `.offline` where `.policy` would be more exact. The engine starts
user-initiated work before it has read the device conditions. When `.wifiOnly` runs on the
user-initiated lane and the device is on cellular, the operating system refuses the request,
ZTronAssetKit reports that as `AssetError.offline`
(`Sources/ZTronAssetModel/Errors/AssetError.swift:32-33`), and the boundary can say no more
unless the conditions arrived first. Nothing is downloaded either way.

Fetches of one asset under different policies run as separate sessions, each on its own lane.
They still share every transfer, and the engine runs a shared transfer on the more urgent lane.

## Errors

| ZTronAssetKit | Boundary | |
|---|---|---|
| `.offline`, `.serverUnavailable`, `.authRejected`, `.shutDown` | `.offline` | The bytes cannot be had from the origin now. |
| `.integrityFailure`, `.notFound`, a blob that is not the described one | `.checksum` | The origin does not hold the bytes the descriptor names. |
| `.insufficientSpace`, `.storageUnavailable`, a directory that cannot be written | `.diskFull` | The device's store cannot take or serve the bytes. |
| (device conditions, `.never`, no lane for `.wifiOnly`) | `.policy` | |
| `.cancelled`, `evict(_:)` during a fetch | `CancellationError` | |

Four cases cannot carry nine errors. The provider reports the exact cause to the `diagnostics`
closure of its initializer (`AssetKitBridgeDiagnostic`) and to the unified log, subsystem
`com.ztron.searchengine.assetkit`.

## Limits, and what the host still decides

- **A lane for `.wifiOnly`**, as above.
- **Background continuation or progress.** Not both. With the bulk lane and
  `HTTPSourceConfiguration.background = .enabled(…)` a transfer that starts from zero may
  continue while the app is suspended; the fetch stream then reports whole files.
- **The catalog manifest follows the host's bulk policy, not the download policy.** A fetch of a
  model the applied catalog does not list makes the engine fetch the manifest first, with the
  bulk lane's permissions (`Sources/ZTronAssetSync/Engine/EngineManifest.swift:165`). With
  `bulkOnExpensive == true` that request, not the model, may use cellular.
- **In-process retries lose the file in transit** (limit 1 of the open question).
- **The prefetch and bulk lanes wait where the user-initiated lane fails.** On them the engine
  waits through an origin throttle (HTTP 429, up to `RetryPolicy.maxRetryAfter`) and through a
  thermal pause, and the fetch stream reports nothing meanwhile. On the user-initiated lane a
  request fails after two attempts.
- **`availability(of:)` can trail a fetch by about 0.2 s.** It reads the client's main-actor
  snapshot, which prefetch and bulk work update at a bounded rate (`README.md:131-136`). The
  last element of the fetch stream is exact. A directory whose links hold is never removed on a
  missing listing.
- **`evict(_:)` is a purge.** It ends a catalog sync that is running and makes the next one due
  (`Sources/ZTronAssetSync/Engine/EngineCommands.swift:966-968`). A purge returns once the store
  has unlinked the files, which it does after its deletion grace, so `evict(_:)` takes about
  10 s with the default `StoragePolicy` (measured: the grace plus 0.3 to 0.5 s). The same wait
  precedes the `.checksum` of a fetch that had to delete mismatched bytes.
- **A `.custom` store location must exist.** The store creates `ZTronAssetKit/v1` inside the
  base directory, not the base itself; a missing base fails `start()` with
  `.storageUnavailable(.ioFailure)`, which the boundary reports as `.diskFull`.
- **A wrong catalog entry costs one download per launch.** The rejection of a model whose
  catalog bytes contradict the descriptor is kept in memory.
- **`.checksum` should not be retried automatically by the UI.**
- **Progress of content shared with another catalog entry** can be reported under that entry's
  identifier (`EngineDispatch.swift:914`); the file then counts when it is complete.
- **The Apple-hosted tier** works through the same calls. It cannot resume within a file, and
  the engine gates its lanes by the device conditions instead of the operating system.
- **Toolchain.** ZTronAssetKit's manifest declares tools version 6.3, so this package does too.
  ZTronAssetKit's README still says 6.0.

## Tests

```sh
swift test
```

- Unit tests drive the provider through a scripted `ModelAssetClient`
  (`Tests/…/Support/ScriptedAssetClient.swift`) and assert on its call log: every availability
  state, progress, resume, both checksum paths, the error mapping, each policy and lane, device
  conditions, cancellation, shared work, eviction, revisions and the directory.
- `RealClientTests` run the provider over a real `AssetClient`: ZTronAssetKit's engine, store,
  index and snapshot, with an origin in memory. ZTronAssetKit's HTTP transport accepts HTTPS
  origins only (`Sources/ZTronAssetTransport/Policy/TransportSecurity.swift:70-88`; the loopback
  policy is `package`), and its fakes are not part of its product (`Package.swift:19-21`,
  `:39-43`). The tests use neither. They plug conformers of the public `RemoteSourceFactory` and
  `DeviceConditionsSource` protocols into the public `AssetEnvironment`, which is the seam the
  HTTP transport itself uses. They pin what the bridge takes on trust: that a blob is named by
  its SHA-256, that a `.wifiOnly` request carries `allowsExpensive == false`, that a parked lane
  sends nothing, that a sync leaves `onDemand` entries alone, and that pins survive a relaunch.
  No socket is opened.
