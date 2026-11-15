import SwiftUI
import XCTest
import ZTronSearchEngine
import ZTronSearchFixtures
@testable import ZTronSearchEngineUI

/// Section 16, "Attachment modifiers (section 13.1)", with views hosted in a real window.
@MainActor
final class AttachmentModifierTests: XCTestCase {
    /// What the host's own views observe, recorded for assertions.
    final class Probe: ObservableObject {
        var searching: [Bool] = []
        var hitCounts: [Int] = []
        var injected = false
        var footerAppearances = 0
        var suggestionCounts: [Int] = []
        var chatReadiness: [ChatReadiness] = []
    }

    /// A host row that reads the model the standard way.
    struct ResultsReader: View {
        @EnvironmentObject private var results: ZTronSearchResultsModel<CatalogSchema>
        @Environment(\.isZTronSearching) private var isSearching
        let probe: Probe

        var body: some View {
            let _ = record()
            VStack {
                ForEach(results.hits) { hit in
                    Text(hit.id.rawValue)
                }
                if results.hasMore {
                    Text("more").zTronLoadsNextPage(of: results).onAppear { probe.footerAppearances += 1 }
                }
            }
        }

        private func record() {
            probe.injected = true
            probe.searching.append(isSearching)
            probe.hitCounts.append(results.hits.count)
        }
    }

    /// The minimal host of the specification: the screen owns the state.
    struct Screen: View {
        @ObservedObject var state: ScreenState
        let results: ZTronSearchResultsModel<CatalogSchema>
        let probe: Probe

        var body: some View {
            VStack {
                if state.wrapsInExtraContainer {
                    // A structural change around the modifier.
                    HStack { ResultsReader(probe: probe) }
                } else {
                    ResultsReader(probe: probe)
                }
            }
            .zTronSearch(results, text: $state.text, tokens: $state.tokens)
        }
    }

    final class ScreenState: ObservableObject {
        @Published var text = ""
        @Published var tokens: [CatalogToken] = []
        @Published var wrapsInExtraContainer = false
    }

    // MARK: zTronSearch

    func testZTronSearchForwardsEveryChangeInjectsTheModelAndSetsIsSearching() async {
        let results = CatalogResults(service: await UIFixtures.service(lexicalDebounce: 0.05))
        let state = ScreenState()
        let probe = Probe()
        let host = HostedView(Screen(state: state, results: results, probe: probe))
        defer { host.close() }
        await settle()
        XCTAssertTrue(probe.injected, "the model is injected for descendants")

        // A text change is forwarded.
        state.text = "harbor"
        let forwarded = await eventually { results.query.text == "harbor" }
        XCTAssertTrue(forwarded)
        let loaded = await eventually { results.hits.count == 2 && !results.isLoading }
        XCTAssertTrue(loaded)
        // The environment value tracked isLoading: true while searching, false once done.
        XCTAssertTrue(probe.searching.contains(true), "isZTronSearching was set while loading")
        XCTAssertEqual(probe.searching.last, false)
        XCTAssertEqual(probe.hitCounts.last, 2)

        // A token change is forwarded too.
        state.tokens = [CatalogToken(kind: .kind(.tip), text: "Tips")]
        let filtered = await eventually { results.hits.map(\.id) == ["tip-harbor"] }
        XCTAssertTrue(filtered)
        XCTAssertEqual(results.query.kinds, [.tip])

        // Every change, in order: the model ends on the last one.
        for text in ["l", "la", "lan", "lant", "lantern"] { state.text = text; await settle(0.005) }
        state.tokens = []
        // The reader's footer pages on its own, so only a lower bound is stable here.
        let last = await eventually { results.query.text == "lantern" && results.query.kinds == nil && results.hits.count >= 20 }
        XCTAssertTrue(last)
    }

    func testIsZTronSearchingTracksIsLoading() async {
        let semantic = FakeSemanticStub()
        await semantic.setDelay(0.1)
        let results = CatalogResults(service: await UIFixtures.service(semantic: semantic))
        let state = ScreenState()
        let probe = Probe()
        let host = HostedView(Screen(state: state, results: results, probe: probe))
        defer { host.close() }
        await settle()
        XCTAssertEqual(probe.searching.last, false, "not searching at rest")

        state.text = "harbor"
        let searching = await eventually { probe.searching.last == true }
        XCTAssertTrue(searching)
        XCTAssertTrue(results.isLoading)
        let done = await eventually { !results.isLoading }
        XCTAssertTrue(done)
        let settledDown = await eventually { probe.searching.last == false }
        XCTAssertTrue(settledDown, "the environment value is a projection of isLoading")
    }

    func testStructuralChangesAroundAModifierLeaveTheHostOwnedModelUntouched() async {
        let results = CatalogResults(service: await UIFixtures.service())
        let state = ScreenState()
        let probe = Probe()
        let host = HostedView(Screen(state: state, results: results, probe: probe))
        defer { host.close() }
        state.text = "harbor"
        let loaded = await eventually { results.hits.count == 2 && !results.isLoading }
        XCTAssertTrue(loaded)
        let identity = ObjectIdentifier(results)
        let hits = results.hits

        // The view around the modifier changes identity; the modifier created no state to lose.
        state.wrapsInExtraContainer = true
        await settle()
        state.wrapsInExtraContainer = false
        await settle()
        XCTAssertEqual(ObjectIdentifier(results), identity)
        XCTAssertEqual(results.hits, hits, "the model's state survives the modified view being recreated")
        XCTAssertEqual(results.query.text, "harbor")
        XCTAssertEqual(probe.hitCounts.last, 2)

        // Replacing the whole root does not disturb it either.
        host.update(Screen(state: state, results: results, probe: probe))
        await settle()
        XCTAssertEqual(results.hits, hits)
    }

    func testZTronResultsOnlyInjects() async {
        struct Passive: View {
            let results: ZTronSearchResultsModel<CatalogSchema>
            let probe: Probe
            var body: some View { ResultsReader(probe: probe).zTronResults(results) }
        }
        let results = CatalogResults(service: await UIFixtures.service())
        let probe = Probe()
        let host = HostedView(Passive(results: results, probe: probe))
        defer { host.close() }
        await settle()
        XCTAssertTrue(probe.injected)
        XCTAssertEqual(results.query.text, "", "injection only: the host forwards updates itself")
        results.update(text: "harbor", tokens: [])
        let shown = await eventually { probe.hitCounts.last == 2 }
        XCTAssertTrue(shown)
    }

    // MARK: zTronLoadsNextPage

    func testAFooterLoadsExactlyOnePagePerCursorHoweverOftenItAppears() async {
        struct Footer: View {
            @ObservedObject var results: ZTronSearchResultsModel<CatalogSchema>
            @ObservedObject var toggle: Toggle
            var body: some View {
                VStack {
                    // The footer marks the end of the list; it comes and goes as lists recycle rows.
                    if toggle.isVisible && results.hasMore {
                        Text("loading").zTronLoadsNextPage(of: results)
                    }
                }
            }
        }
        final class Toggle: ObservableObject { @Published var isVisible = false }

        let results = CatalogResults(service: await UIFixtures.service())
        results.update(text: "lantern", tokens: [])
        let first = await eventually { results.hits.count == 20 && !results.isLoading }
        XCTAssertTrue(first)
        let toggle = Toggle()
        let host = HostedView(Footer(results: results, toggle: toggle))
        defer { host.close() }

        toggle.isVisible = true
        let second = await eventually { results.hits.count == 40 }
        XCTAssertTrue(second)
        XCTAssertEqual(results.pageRequestCount, 1)

        // The footer reappears for the next cursor: one more page, not more.
        toggle.isVisible = false
        await settle(0.02)
        toggle.isVisible = true
        let third = await eventually { results.hits.count == 60 }
        XCTAssertTrue(third)
        XCTAssertEqual(results.pageRequestCount, 2)
        XCTAssertFalse(results.hasMore)

        // Flapping at the end of the list requests nothing.
        for _ in 0..<10 {
            toggle.isVisible.toggle()
            await settle(0.005)
        }
        XCTAssertEqual(results.pageRequestCount, 2, "exactly one page per cursor")
        XCTAssertEqual(Set(results.hits.map(\.id)).count, 60)
    }

    // MARK: zTronSuggestions

    func testZTronSuggestionsDrivesUpdatesOnlyAtOrAboveTheMinimumLength() async {
        struct Suggesting: View {
            @ObservedObject var state: ScreenState
            let suggestions: ZTronSuggestionsModel<CatalogSchema>
            let probe: Probe
            var body: some View { Reader(probe: probe).zTronSuggestions(suggestions, for: $state.text) }
        }
        struct Reader: View {
            @EnvironmentObject private var suggestions: ZTronSuggestionsModel<CatalogSchema>
            let probe: Probe
            var body: some View {
                let _ = probe.suggestionCounts.append(suggestions.suggestions.count)
                Text("\(suggestions.suggestions.count)")
            }
        }
        let service = await UIFixtures.service()
        let suggestions = ZTronSuggestionsModel<CatalogSchema>(service: service, minimumQueryLength: 3, pageSize: 4, debounce: 0)
        let state = ScreenState()
        let probe = Probe()
        let host = HostedView(Suggesting(state: state, suggestions: suggestions, probe: probe))
        defer { host.close() }
        await settle()

        for text in ["f", "fr"] {
            state.text = text
            await settle(0.03)
        }
        XCTAssertEqual(suggestions.requestCount, 0, "below minimumQueryLength nothing is asked")
        XCTAssertTrue(suggestions.suggestions.isEmpty)

        state.text = "fro"
        let arrived = await eventually { suggestions.suggestions.first?.text == "Frozen Harbor" }
        XCTAssertTrue(arrived)
        XCTAssertEqual(suggestions.requestCount, 1)
        XCTAssertGreaterThan(probe.suggestionCounts.last ?? 0, 0, "the model is injected for descendants")
        state.text = "fr"
        await settle(0.03)
        XCTAssertTrue(suggestions.suggestions.isEmpty)
        XCTAssertEqual(suggestions.requestCount, 1)
    }

    // MARK: zTronChat

    private static let capable = ChatDeviceProfile(
        operatingSystem: OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0),
        physicalMemory: 8 * 1024 * 1024 * 1024, freeDiskBytes: 64 * 1024 * 1024 * 1024, buildFingerprint: "ui-tests"
    )

    private func chatModel(available: Bool = true) async -> (ZTronChatModel<CatalogSchema>, FakeLanguageModel, FakeModelAssetProvider) {
        let model = FakeLanguageModel()
        let assets = FakeModelAssetProvider(available: available)
        let facade = ZTronSearch(
            search: await UIFixtures.service(), assets: assets, languageModel: model,
            chat: ChatConfiguration(availability: .on, device: Self.capable)
        )
        return (ZTronChatModel(chat: facade.chat), model, assets)
    }

    struct ChatScreen: View {
        @ObservedObject var toggle: Toggle
        let chat: ZTronChatModel<CatalogSchema>
        let policy: DownloadPolicy?
        var body: some View {
            VStack {
                if toggle.isVisible {
                    Reader().zTronChat(chat, prepare: policy)
                }
            }
        }

        struct Reader: View {
            @EnvironmentObject private var chat: ZTronChatModel<CatalogSchema>
            var body: some View { Text(chat.transcript.last?.text ?? "") }
        }

        final class Toggle: ObservableObject { @Published var isVisible = true }
    }

    func testZTronChatPreparesOnAppearUnderThePolicy() async {
        let (chat, model, assets) = await chatModel(available: false)
        let toggle = ChatScreen.Toggle()
        let host = HostedView(ChatScreen(toggle: toggle, chat: chat, policy: .allowCellular))
        defer { host.close() }
        let ready = await eventually { chat.readiness == .ready }
        XCTAssertTrue(ready)
        let policies = await assets.policies
        let loads = await model.loadCalls
        XCTAssertEqual(policies, [.allowCellular], "prepared under the given policy")
        XCTAssertEqual(loads, 1)
    }

    func testZTronChatNeverPreparesWhenThePolicyIsNil() async {
        let (chat, model, assets) = await chatModel(available: false)
        let toggle = ChatScreen.Toggle()
        let host = HostedView(ChatScreen(toggle: toggle, chat: chat, policy: nil))
        defer { host.close() }
        await settle(0.2)
        let fetches = await assets.fetchCalls
        let loads = await model.loadCalls
        XCTAssertEqual(fetches, 0, "nil = the host calls prepare")
        XCTAssertEqual(loads, 0)
        // The files are missing: the host is told consent is needed, without anything being fetched.
        XCTAssertEqual(chat.readiness, .unavailable(.downloadNotAllowed))
    }

    func testZTronChatCancelsGenerationOnDisappearAndTheModelSurvives() async {
        let (chat, model, _) = await chatModel()
        await model.setTokenDelay(seconds: 0.02)
        await model.setReply((0..<300).map { "t\($0) " })
        let toggle = ChatScreen.Toggle()
        let host = HostedView(ChatScreen(toggle: toggle, chat: chat, policy: .wifiOnly))
        defer { host.close() }
        let ready = await eventually { chat.readiness == .ready }
        XCTAssertTrue(ready)

        chat.send("where is the harbor")
        let streaming = await eventually { (chat.transcript.last?.text.count ?? 0) > 10 }
        XCTAssertTrue(streaming)
        XCTAssertTrue(chat.isGenerating)

        // The modified view goes away.
        toggle.isVisible = false
        let stopped = await eventually { !chat.isGenerating }
        XCTAssertTrue(stopped, "generation is cancelled on disappear")
        let cancelled = await eventually { await model.cancelledGenerations == 1 }
        XCTAssertTrue(cancelled)

        // The model's state survives the modifier's view being recreated.
        let transcript = chat.transcript
        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertFalse(transcript[1].text.isEmpty)
        toggle.isVisible = true
        await settle(0.1)
        XCTAssertEqual(chat.transcript, transcript)
        XCTAssertEqual(chat.readiness, .ready)
    }

    // MARK: Chat model

    func testChatModelStreamsSourcesTextAndCitationsIntoTheTranscript() async {
        let (chat, model, _) = await chatModel()
        await model.setReply(["The map ", "[map:map-harbor]", " shows it, ", "[map:atlantis]", "see ", "[map:map-harbor]", "."])
        chat.prepare(policy: .wifiOnly)
        let ready = await eventually { chat.readiness == .ready }
        XCTAssertTrue(ready)
        chat.send("frozen harbor")
        XCTAssertEqual(chat.transcript.map(\.role), [.user, .assistant], "both entries appear at once")
        XCTAssertTrue(chat.isGenerating)
        let done = await eventually { !chat.isGenerating }
        XCTAssertTrue(done)

        let answer = chat.transcript[1]
        XCTAssertEqual(answer.text, "The map  shows it, see .")
        XCTAssertEqual(answer.sources.first?.id, "map-harbor")
        XCTAssertEqual(answer.sources.first?.kind, .map, "sources are kind-aware")
        XCTAssertEqual(answer.citations, ["map-harbor"], "known citations once; unknown ones dropped")
        XCTAssertNil(chat.lastError)
        chat.send("   ")
        XCTAssertEqual(chat.transcript.count, 2, "an empty message is not sent")
    }

    func testChatModelIsUnavailableWithoutAServiceOrOnAFailingDevice() async {
        // No runtime linked, as below iOS 17: the facade has no chat service.
        let search = await UIFixtures.service()
        let none = ZTronChatModel<CatalogSchema>(chat: ZTronSearch(search: search).chat)
        XCTAssertEqual(none.readiness, .unavailable(.device), "the host shows no entry point")
        none.prepare(policy: .wifiOnly)
        none.send("hello")
        XCTAssertTrue(none.transcript.isEmpty)

        // A device that fails the gate: known without touching the asset provider.
        let assets = FakeModelAssetProvider(available: true)
        let gated = ZTronSearch(
            search: search, assets: assets, languageModel: FakeLanguageModel(),
            chat: ChatConfiguration(availability: .auto, device: .iPhone6s)
        )
        let model = ZTronChatModel(chat: gated.chat)
        let unavailable = await eventually { model.readiness == .unavailable(.device) }
        XCTAssertTrue(unavailable)
        let touched = await assets.availabilityCalls
        XCTAssertEqual(touched, 0)
    }

    func testChatModelReportsFailures() async {
        let (chat, model, _) = await chatModel()
        await model.setReply((0..<10).map { "t\($0) " })
        await model.setFailsAfterTokens(2)
        chat.send("harbor")
        let failed = await eventually { chat.lastError != nil && !chat.isGenerating }
        XCTAssertTrue(failed)
        guard case .generationFailed? = chat.lastError else { return XCTFail("expected generationFailed") }
        XCTAssertEqual(chat.transcript[1].text, "t0 t1 ", "what was generated stays in the transcript")
        await model.setFailsAfterTokens(nil)
        chat.send("harbor again")
        XCTAssertNil(chat.lastError, "cleared by the next send")
    }
}
