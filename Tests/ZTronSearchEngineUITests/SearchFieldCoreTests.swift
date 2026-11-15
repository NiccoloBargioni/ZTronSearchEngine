import XCTest
import ZTronSearchEngine
import ZTronSearchFixtures
@testable import ZTronSearchEngineUI

/// The field's behavior rules (specification section 12.2) and the token scripts of section 16,
/// run against the value that implements them: type, backspace-select, backspace-delete,
/// tap-select, clear, submit, cancel and text-to-token.
///
/// The event sequences asserted here are the ones the parity host recorded from the UIKit
/// reference with real touches and keys (`ParityHost/Samples/ios-*.json`, `behavior.eventProfile`).
final class SearchFieldCoreTests: XCTestCase {
    typealias Core = ZTronSearchFieldCore<CatalogSchema>
    private let sentinel = Core.sentinel

    /// What the reference does on iOS 17.5 and 18.6, as recorded.
    private let recorded = Core.Behavior(
        clearRemovesTokens: true, clearBeginsEditing: true, typingReplacesSelectedTokens: false, submitKeepsEditing: true,
        conversionSelectsToken: true
    )

    private func policies(_ configure: (inout Core.Policies) -> Void = { _ in }) -> Core.Policies {
        var policies = Core.Policies()
        policies.behavior = recorded
        configure(&policies)
        return policies
    }

    /// A core that is editing: selection changes are only reported while the field edits.
    private func editing(text: String = "", tokens: [CatalogToken] = [], selection: Set<UUID> = [], policies: Core.Policies? = nil) -> Core {
        var core = Core(text: text, tokens: tokens, selection: selection)
        _ = core.focusChanged(to: true, policies: policies ?? self.policies())
        return core
    }

    private func selected(_ labels: String...) -> ZTronSearchFieldEvent {
        .didChangeSelection(tokens: labels, textLocation: nil, textLength: nil)
    }

    private func selected(_ labels: [String] = [], at location: Int, length: Int = 0) -> ZTronSearchFieldEvent {
        .didChangeSelection(tokens: labels, textLocation: location, textLength: length)
    }

    private func token(_ label: String, _ kind: CatalogToken.Kind = .kind(.map)) -> CatalogToken {
        CatalogToken(kind: kind, text: label, systemImage: "tag")
    }

    /// Types `text` one character at a time, as a keyboard would.
    @discardableResult
    private func type(_ text: String, into core: inout Core, policies: Core.Policies? = nil) -> [ZTronSearchFieldEvent] {
        let policies = policies ?? self.policies()
        var events: [ZTronSearchFieldEvent] = []
        for character in text {
            events += core.inputChanged(to: core.buffer + String(character), policies: policies).events
        }
        return events
    }

    /// One press of the delete key with the caret at the end of the buffer.
    @discardableResult
    private func backspace(_ core: inout Core, policies: Core.Policies? = nil) -> Core.Outcome {
        core.inputChanged(to: String(core.buffer.dropLast()), policies: policies ?? self.policies())
    }

    private func assertNoSentinel(_ events: [ZTronSearchFieldEvent], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(String(describing: events).unicodeScalars.contains("\u{200B}"), "the sentinel leaked into the event log", file: file, line: line)
    }

    // MARK: Typing

    func testTypingUpdatesTheTextAndLogsEveryChange() {
        var core = Core()
        let events = type("map", into: &core)
        XCTAssertEqual(core.text, "map")
        XCTAssertEqual(core.buffer, sentinel + "map")
        XCTAssertEqual(events, [
            .shouldChange(location: 0, length: 0, replacement: "m", allowed: true), .editingChanged(text: "m"),
            .shouldChange(location: 1, length: 0, replacement: "a", allowed: true), .editingChanged(text: "ma"),
            .shouldChange(location: 2, length: 0, replacement: "p", allowed: true), .editingChanged(text: "map"),
        ])
        assertNoSentinel(events)
    }

    func testDeletingTextIsAnOrdinaryChange() {
        var core = Core(text: "map")
        let outcome = backspace(&core)
        XCTAssertEqual(core.text, "ma")
        XCTAssertEqual(outcome.events, [.shouldChange(location: 2, length: 1, replacement: "", allowed: true), .editingChanged(text: "ma")])
        XCTAssertTrue(core.selection.isEmpty)
    }

    func testPastingAndReplacingReportUTF16Ranges() {
        var core = Core(text: "a😀b")
        // Replace the emoji (two UTF-16 units) with "xyz".
        let outcome = core.inputChanged(to: sentinel + "axyzb", policies: .init())
        XCTAssertEqual(outcome.events.first, .shouldChange(location: 1, length: 2, replacement: "xyz", allowed: true))
        XCTAssertEqual(core.text, "axyzb")
        let change = ZTronTextChange.between("hello world", "hello brave world")
        XCTAssertEqual(change.replacement, "brave ")
        XCTAssertEqual(change.proposedText, "hello brave world")
        XCTAssertEqual(change.utf16Range.location, 6)
        XCTAssertEqual(change.utf16Range.length, 0)
    }

    func testSmartQuotesAndDashesAreUndone() {
        var core = Core()
        _ = core.inputChanged(to: sentinel + "it\u{2019}s \u{201C}m1911\u{2014}a1\u{201D} \u{2013}", policies: .init())
        XCTAssertEqual(core.text, "it's \"m1911--a1\" -", "identifiers survive typing")
    }

    // MARK: Sentinel

    func testBackspaceAtTheStartSelectsTheLastTokenAndASecondOneDeletesIt() {
        let first = token("Maps")
        let second = token("iOS", .filter(.platform(.ios)))
        var core = editing(tokens: [first, second])

        // The sentinel is all there is to delete. The reference asks its delegate about the
        // token's range, which lies before the text: location -1.
        let select = backspace(&core)
        XCTAssertEqual(core.selection, [second.id], "backspace at the start of the text selects the last token")
        XCTAssertEqual(core.tokens, [first, second])
        XCTAssertEqual(core.buffer, sentinel, "the sentinel is restored")
        XCTAssertEqual(select.events, [.shouldChange(location: -1, length: 1, replacement: "", allowed: true), selected("iOS")])
        XCTAssertTrue(select.selectionChanged)

        let delete = backspace(&core)
        XCTAssertEqual(core.tokens, [first], "a second backspace deletes it")
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertEqual(delete.events, [
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .tokensChanged(["Maps"]), selected(), .editingChanged(text: ""),
        ])
        XCTAssertEqual(core.buffer, sentinel)

        // And again, down to nothing; one more backspace then does nothing at all, and the
        // reference logs nothing either.
        backspace(&core)
        backspace(&core)
        XCTAssertTrue(core.tokens.isEmpty)
        let idle = backspace(&core)
        XCTAssertEqual(idle, Core.Outcome())
        XCTAssertEqual(core.buffer, sentinel)
    }

    func testBackspaceWithTextNeverTouchesTokens() {
        let chip = token("Maps")
        var core = Core(text: "ab", tokens: [chip])
        backspace(&core)
        backspace(&core)
        XCTAssertEqual(core.text, "")
        XCTAssertEqual(core.tokens, [chip])
        XCTAssertTrue(core.selection.isEmpty, "deleting the last character is not a backspace at the start")
        backspace(&core)
        XCTAssertEqual(core.selection, [chip.id])
    }

    func testTheSentinelNeverReachesTheTextOrTheLog() {
        var core = Core()
        var log: [ZTronSearchFieldEvent] = []
        let chip = token("Maps")
        var policies = Core.Policies()
        policies.textToToken = { $0 == "map:" ? chip : nil }

        log += type("ma", into: &core, policies: policies)
        // The user moves the caret in front of the sentinel and types there.
        log += core.inputChanged(to: "x" + core.buffer, policies: policies).events
        XCTAssertEqual(core.text, "xma")
        XCTAssertTrue(core.buffer.hasPrefix(sentinel))
        // Select all and type: the sentinel is replaced along with the text.
        log += core.inputChanged(to: "map", policies: policies).events
        XCTAssertEqual(core.text, "map")
        XCTAssertEqual(core.buffer, sentinel + "map")
        // A paste that carries a zero-width space of its own.
        log += core.inputChanged(to: sentinel + "ma\u{200B}p:", policies: policies).events
        XCTAssertEqual(core.tokens, [chip])
        XCTAssertEqual(core.text, "")
        log += backspace(&core, policies: policies).events
        log += backspace(&core, policies: policies).events
        log += core.submit(policies: policies).events
        log += core.clear(policies: policies).events
        log += core.cancel().events

        assertNoSentinel(log)
        XCTAssertFalse(core.text.unicodeScalars.contains("\u{200B}"))
        XCTAssertEqual(core.buffer.unicodeScalars.filter { $0 == "\u{200B}" }.count, 1, "exactly one sentinel, at the start")
        XCTAssertEqual(Core.strip(sentinel + "a" + sentinel + "b"), "ab")
    }

    // MARK: Tokens

    func testTapSelectsATokenAndTappingElsewhereDeselects() {
        let first = token("Maps")
        let second = token("Tips", .kind(.tip))
        var core = editing(tokens: [first, second])
        let tap = core.tapToken(first.id, policies: policies())
        XCTAssertEqual(core.selection, [first.id])
        XCTAssertEqual(tap.events, [selected("Maps")])
        // Tapping another token moves the selection; tapping the same one changes nothing.
        _ = core.tapToken(second.id, policies: policies())
        XCTAssertEqual(core.selection, [second.id])
        XCTAssertEqual(core.tapToken(second.id, policies: policies()), Core.Outcome())
        let deselect = core.deselect(policies: policies())
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertEqual(deselect.events, [selected()])
        XCTAssertEqual(core.deselect(policies: policies()), Core.Outcome())
        XCTAssertEqual(core.tapToken(UUID(), policies: policies()), Core.Outcome(), "an unknown id selects nothing")

        // A field that is not editing reports nothing, as the reference; the host is still told.
        var idle = Core(tokens: [first])
        let quiet = idle.tapToken(first.id, policies: policies())
        XCTAssertEqual(idle.selection, [first.id])
        XCTAssertTrue(quiet.events.isEmpty)
        XCTAssertTrue(quiet.selectionChanged)
    }

    func testASelectedTokenIsDeletedByBackspaceWhenDeletionIsEnabledAndNotVetoed() {
        let keep = token("Pinned")
        let drop = token("Maps")
        var core = editing(tokens: [keep, drop])

        // Deletion disabled: the reference still asks its delegate, and leaves the token selected.
        let disabled = policies { $0.deletion = .disabled }
        _ = core.tapToken(drop.id, policies: disabled)
        let asked = backspace(&core, policies: disabled)
        XCTAssertEqual(core.tokens, [keep, drop])
        XCTAssertEqual(core.selection, [drop.id])
        XCTAssertEqual(asked.events, [.shouldChange(location: -1, length: 1, replacement: "", allowed: true)])

        // A per-token veto. The first of two tokens is two positions before the text.
        let veto = policies { $0.onTokenDelete = { $0.text != "Pinned" } }
        _ = core.tapToken(keep.id, policies: veto)
        let refused = backspace(&core, policies: veto)
        XCTAssertEqual(core.tokens, [keep, drop], "onTokenDelete vetoed it")
        XCTAssertEqual(refused.events, [.shouldChange(location: -2, length: 1, replacement: "", allowed: true)])
        _ = core.tapToken(drop.id, policies: veto)
        let allowed = backspace(&core, policies: veto)
        XCTAssertEqual(core.tokens, [keep])
        XCTAssertEqual(allowed.events, [
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .tokensChanged(["Pinned"]), selected(), .editingChanged(text: ""),
        ])

        // Removing a token at the host's request follows the same rules.
        XCTAssertEqual(core.delete(keep.id, policies: veto), Core.Outcome())
        XCTAssertEqual(core.delete(keep.id, policies: disabled), Core.Outcome())
        _ = core.delete(keep.id, policies: policies())
        XCTAssertTrue(core.tokens.isEmpty)
    }

    func testTypingWithATokenSelectedKeepsOrReplacesItAsTheReferenceDoes() {
        // On iOS 17.5 and 18.6 the reference proposes to replace the token's range, then keeps
        // the token and puts what was typed after it.
        let chip = token("Maps")
        var core = editing(tokens: [chip])
        _ = core.tapToken(chip.id, policies: policies())
        let events = type("x", into: &core)
        XCTAssertEqual(core.tokens, [chip])
        XCTAssertEqual(core.text, "x")
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertEqual(events, [
            .shouldChange(location: -1, length: 1, replacement: "x", allowed: true), selected(), .editingChanged(text: "x"),
        ])

        // With text in the field the reference types at its end, wherever the caret was
        // before the token was selected: here the inner input had it at the start.
        var behind = editing(text: "ab", tokens: [chip])
        _ = behind.tapToken(chip.id, policies: policies())
        let typed = behind.inputChanged(to: sentinel + "xab", policies: policies())
        XCTAssertEqual(behind.text, "abx")
        XCTAssertEqual(behind.buffer, sentinel + "abx")
        XCTAssertEqual(typed.events, [
            .shouldChange(location: -1, length: 1, replacement: "x", allowed: true), selected(), .editingChanged(text: "abx"),
        ])

        // Where the reference replaces the token, so does the field.
        let replacing = policies { $0.behavior.typingReplacesSelectedTokens = true }
        var other = editing(tokens: [chip])
        _ = other.tapToken(chip.id, policies: replacing)
        let replaced = type("x", into: &other, policies: replacing)
        XCTAssertTrue(other.tokens.isEmpty)
        XCTAssertEqual(other.text, "x")
        XCTAssertEqual(replaced, [
            .shouldChange(location: -1, length: 1, replacement: "x", allowed: true),
            .tokensChanged([]), selected(), .editingChanged(text: "x"),
        ])
    }

    func testTheDeleteKeyDeletesTheSelectedTokenAndNotTheText() {
        let chip = token("Maps")
        // The hardware delete key.
        var core = editing(text: "abc", tokens: [chip], selection: [chip.id])
        let outcome = core.deleteSelection(policies: policies())
        XCTAssertTrue(core.tokens.isEmpty)
        XCTAssertEqual(core.text, "abc", "the text is untouched")
        XCTAssertEqual(outcome.events, [
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .tokensChanged([]), selected(), .editingChanged(text: "abc"),
        ])
        XCTAssertEqual(core.deleteSelection(policies: policies()), Core.Outcome(), "nothing selected, nothing deleted")

        // The on-screen delete key removes a character from the input; with a token selected
        // the character is put back and the token goes, as in the reference.
        var other = editing(text: "abc", tokens: [chip], selection: [chip.id])
        let same = backspace(&other)
        XCTAssertTrue(other.tokens.isEmpty)
        XCTAssertEqual(other.text, "abc")
        XCTAssertEqual(other.buffer, sentinel + "abc")
        XCTAssertEqual(same.events, outcome.events)
    }

    // MARK: Text to token

    func testTextToTokenIsEvaluatedOnEveryChangeAndReplacesTheTextualPortion() {
        var evaluated: [String] = []
        let policies = policies { policies in
            policies.textToToken = { typed in
                evaluated.append(typed)
                guard typed.hasPrefix("platform:"), let platform = Platform(rawValue: String(typed.dropFirst(9))) else { return nil }
                return CatalogToken(kind: .filter(.platform(platform)), text: platform.rawValue.uppercased(), systemImage: "line.3.horizontal.decrease")
            }
        }
        var core = editing()
        var last = Core.Outcome()
        for character in "platform:ios" {
            last = core.inputChanged(to: core.buffer + String(character), policies: policies)
        }
        XCTAssertEqual(evaluated.count, 12, "evaluated on every text change")
        XCTAssertEqual(core.tokens.map(\.text), ["IOS"])
        XCTAssertEqual(core.tokens.first?.kind, .filter(.platform(.ios)))
        XCTAssertEqual(core.text, "", "the returned token replaces the textual portion")
        XCTAssertEqual(core.buffer, sentinel)
        XCTAssertTrue(last.insertedToken, "the view animates the insertion, when the reference animates it")
        // The reference leaves the new token selected and sends no text notification for the
        // replacement, which its host made in code.
        XCTAssertEqual(core.selection, Set(core.tokens.map(\.id)))
        XCTAssertEqual(last.events.suffix(3), [.editingChanged(text: "platform:ios"), .tokensChanged(["IOS"]), selected("IOS")])
        // Tokens always precede text: typing goes on after the token, which stays.
        type("harbor", into: &core, policies: policies)
        XCTAssertEqual(core.tokens.count, 1)
        XCTAssertEqual(core.text, "harbor")
        XCTAssertTrue(core.selection.isEmpty)

        // Where the reference does not select the new token, neither does the field.
        var plain = editing()
        let unselecting = self.policies { $0.behavior.conversionSelectsToken = false; $0.textToToken = { $0 == "a" ? CatalogToken(kind: .kind(.map), text: "A") : nil } }
        let converted = plain.inputChanged(to: plain.buffer + "a", policies: unselecting)
        XCTAssertTrue(plain.selection.isEmpty)
        XCTAssertEqual(converted.events.suffix(2), [.editingChanged(text: "a"), .tokensChanged(["A"])])
    }

    func testTextToTokenIsEvaluatedOnSubmit() {
        var submitting = false
        let policies = policies { $0.textToToken = { typed in submitting && typed == "maps" ? CatalogToken(kind: .kind(.map), text: "Maps") : nil } }
        var core = editing()
        type("maps", into: &core, policies: policies)
        XCTAssertTrue(core.tokens.isEmpty)
        submitting = true
        let outcome = core.submit(policies: policies)
        XCTAssertEqual(core.tokens.map(\.text), ["Maps"])
        XCTAssertEqual(core.text, "")
        XCTAssertEqual(outcome.events, [.shouldReturn, .tokensChanged(["Maps"]), selected("Maps"), .editingDidEndOnExit])
        XCTAssertFalse(outcome.resignsFocus, "the search key leaves the field editing, as the reference")
        // Without a rule a submit only reports the key.
        var plain = Core(text: "x")
        XCTAssertEqual(plain.submit(policies: self.policies()).events, [.shouldReturn, .editingDidEndOnExit])
        XCTAssertEqual(plain.text, "x")
    }

    func testProgrammaticConversionThroughTheBindings() {
        // The host appends to `tokens` and clears `text`; the field adopts both.
        var core = Core(text: "maps")
        let chip = token("Maps")
        core.adopt(text: "", tokens: [chip])
        XCTAssertEqual(core.tokens, [chip])
        XCTAssertEqual(core.text, "")
        XCTAssertEqual(core.buffer, sentinel)
        // Removing a selected token through the binding drops it from the selection.
        _ = core.tapToken(chip.id)
        core.adopt(text: "", tokens: [])
        XCTAssertTrue(core.selection.isEmpty)
        // An external selection binding is adopted, restricted to existing tokens.
        let other = token("Tips")
        core.adopt(text: "", tokens: [other], selection: [other.id, UUID()])
        XCTAssertEqual(core.selection, [other.id])
    }

    // MARK: Policies

    func testTextInputPolicyRevertsADeniedChange() {
        var policies = Core.Policies()
        var seen: [ZTronTextChange] = []
        policies.textInputPolicy = { change in
            seen.append(change)
            return !change.replacement.contains(where: \.isNumber)
        }
        var core = Core()
        type("ab", into: &core, policies: policies)
        let denied = core.inputChanged(to: core.buffer + "1", policies: policies)
        XCTAssertEqual(core.text, "ab", "the change is reverted")
        XCTAssertEqual(core.buffer, sentinel + "ab")
        XCTAssertEqual(denied.events, [.shouldChange(location: 2, length: 0, replacement: "1", allowed: false)])
        XCTAssertEqual(seen.last?.text, "ab")
        XCTAssertEqual(seen.last?.replacement, "1")
        XCTAssertEqual(seen.last?.proposedText, "ab1")
        type("c", into: &core, policies: policies)
        XCTAssertEqual(core.text, "abc")
    }

    func testClearFollowsOnClearAndTheRecordedTokenBehavior() {
        let chip = token("Maps")
        var core = editing(text: "harbor", tokens: [chip])
        // onClear returns false: the text stays.
        let keep = policies { $0.onClear = { false } }
        XCTAssertEqual(core.clear(policies: keep).events, [.shouldClear(allowed: false)])
        XCTAssertEqual(core.text, "harbor")
        XCTAssertEqual(core.tokens, [chip])

        // The reference clears by selecting everything and deleting the selection, and always
        // sends the text notification.
        let full = core.clear(policies: policies())
        XCTAssertEqual(core.text, "")
        XCTAssertTrue(core.tokens.isEmpty)
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertEqual(core.buffer, sentinel)
        XCTAssertEqual(full.events, [.shouldClear(allowed: true), selected("Maps"), .tokensChanged([]), selected(), .editingChanged(text: "")])
        XCTAssertFalse(full.takesFocus, "the field was editing already")
        // With nothing left the button still asks and still notifies.
        XCTAssertEqual(core.clear(policies: policies()).events, [.shouldClear(allowed: true), .editingChanged(text: "")])

        // A selected token is deselected before everything is selected.
        let tips = token("Tips", .kind(.tip))
        var chosen = editing(tokens: [chip, tips])
        _ = chosen.tapToken(chip.id, policies: policies())
        XCTAssertEqual(chosen.clear(policies: policies()).events, [
            .shouldClear(allowed: true), selected(), selected("Maps", "Tips"), .tokensChanged([]), selected(), .editingChanged(text: ""),
        ])

        // Where the reference keeps tokens on clear, so does the clone.
        let textOnly = policies { $0.behavior.clearRemovesTokens = false }
        var partial = editing(text: "harbor", tokens: [chip])
        XCTAssertEqual(partial.clear(policies: textOnly).events, [.shouldClear(allowed: true), .editingChanged(text: "")])
        XCTAssertEqual(partial.text, "")
        XCTAssertEqual(partial.tokens, [chip])

        // Tapped while the field is not editing, the button clears without a word about the
        // selection and begins editing, where the reference does.
        var idle = Core(text: "harbor", tokens: [chip])
        let outcome = idle.clear(policies: policies())
        XCTAssertEqual(outcome.events, [.shouldClear(allowed: true), .tokensChanged([]), .editingChanged(text: "")])
        XCTAssertTrue(outcome.takesFocus)
        XCTAssertFalse(idle.clear(policies: policies { $0.behavior.clearBeginsEditing = false }).takesFocus)
    }

    func testCancelClearsTextAndTokensAndDropsFocus() {
        let chip = token("Maps")
        var core = editing(text: "harbor", tokens: [chip], selection: [chip.id])
        let outcome = core.cancel(policies: policies())
        XCTAssertEqual(core.text, "")
        XCTAssertTrue(core.tokens.isEmpty)
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertTrue(outcome.resignsFocus)
        XCTAssertTrue(outcome.cancelled, "onSearchCancel is called")
        // A host clears a search bar in code, which sends no text notification.
        XCTAssertEqual(outcome.events, [.cancelButtonClicked, .tokensChanged([]), selected()])
        let end = core.focusChanged(to: false, policies: policies())
        XCTAssertEqual(end.outcome.events, [.shouldEndEditing(allowed: true), .didEndEditing])
        XCTAssertFalse(core.isEditing)

        // Without a selected token the log is the click and the tokens.
        var plain = editing(text: "ab", tokens: [chip])
        XCTAssertEqual(plain.cancel(policies: policies()).events, [.cancelButtonClicked, .tokensChanged([])])
    }

    func testEditingPolicyGatesBeginAndEnd() {
        var policies = Core.Policies()
        var allowBegin = false
        var allowEnd = false
        policies.editingPolicy = { $0 == .begin ? allowBegin : allowEnd }
        var core = Core()
        // Denied before the input is enabled.
        XCTAssertEqual(core.mayBeginEditing(policies: policies).allowed, false)
        XCTAssertEqual(core.mayBeginEditing(policies: policies).event, .shouldBeginEditing(allowed: false))
        XCTAssertFalse(core.isEditing)
        allowBegin = true
        XCTAssertTrue(core.mayBeginEditing(policies: policies).allowed)
        let began = core.focusChanged(to: true, policies: policies)
        XCTAssertEqual(began.outcome.events, [.didBeginEditing])
        XCTAssertTrue(core.isEditing)

        // The policy refuses to end editing: the field keeps focus.
        let refused = core.focusChanged(to: false, policies: policies)
        XCTAssertTrue(refused.keepsFocus)
        XCTAssertTrue(core.isEditing)
        XCTAssertEqual(refused.outcome.events, [.shouldEndEditing(allowed: false)])
        allowEnd = true
        let ended = core.focusChanged(to: false, policies: policies)
        XCTAssertFalse(ended.keepsFocus)
        XCTAssertEqual(ended.outcome.events, [.shouldEndEditing(allowed: true), .didEndEditing])
        // The same transition twice is one event, not two.
        XCTAssertTrue(core.focusChanged(to: false, policies: policies).outcome.events.isEmpty)
    }

    func testLosingFocusDropsTheTokenSelection() {
        let chip = token("Maps")
        var core = Core(tokens: [chip])
        _ = core.focusChanged(to: true, policies: .init())
        _ = core.tapToken(chip.id)
        let ended = core.focusChanged(to: false, policies: .init())
        XCTAssertTrue(core.selection.isEmpty)
        XCTAssertTrue(ended.outcome.selectionChanged)
    }

    // MARK: Text selection (iOS 18 and later)

    func testTheTextSelectionIsReportedInTheReferencesOrder() {
        let text = policies { $0.reportsTextSelection = true }
        let maps = token("Maps")
        let tips = token("Tips", .kind(.tip))

        // Editing begins with the caret at the end of the text; the reference reports that
        // before it reports that editing began, and says nothing when the caret did not move.
        var core = Core(text: "harbor")
        XCTAssertEqual(core.focusChanged(to: true, policies: text).outcome.events, [selected(at: 6), .didBeginEditing])
        var empty = Core(tokens: [maps])
        XCTAssertEqual(empty.focusChanged(to: true, policies: text).outcome.events, [.didBeginEditing])

        // Typing and deleting: the caret between the question and the notification.
        XCTAssertEqual(type("ab", into: &empty, policies: text), [
            .shouldChange(location: 0, length: 0, replacement: "a", allowed: true), selected(at: 1), .editingChanged(text: "a"),
            .shouldChange(location: 1, length: 0, replacement: "b", allowed: true), selected(at: 2), .editingChanged(text: "ab"),
        ])
        XCTAssertEqual(backspace(&empty, policies: text).events, [
            .shouldChange(location: 1, length: 1, replacement: "", allowed: true), selected(at: 1), .editingChanged(text: "a"),
        ])
        // A caret the user moves is reported; one that did not move is not.
        XCTAssertEqual(empty.textSelectionChanged(to: 0..<1, policies: text).events, [selected(at: 0, length: 1)])
        XCTAssertEqual(empty.textSelectionChanged(to: 0..<1, policies: text), Core.Outcome())
        XCTAssertEqual(empty.textSelectionChanged(to: 5..<9, policies: text).events, [selected(at: 1)], "clamped to the text")

        // A selected token is the whole selection: the text range is empty, at 0.
        var tokens = Core(tokens: [maps, tips])
        _ = tokens.focusChanged(to: true, policies: text)
        XCTAssertEqual(backspace(&tokens, policies: text).events, [
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true), selected(["Tips"], at: 0),
        ])
        XCTAssertEqual(backspace(&tokens, policies: text).events, [
            .shouldChange(location: -1, length: 1, replacement: "", allowed: true),
            .tokensChanged(["Maps"]), selected(at: 0), .editingChanged(text: ""),
        ])

        // Clear selects everything, then deletes it.
        var both = Core(text: "harbor", tokens: [maps])
        _ = both.focusChanged(to: true, policies: text)
        XCTAssertEqual(both.clear(policies: text).events, [
            .shouldClear(allowed: true), selected(["Maps"], at: 0, length: 6), .tokensChanged([]), selected(at: 0), .editingChanged(text: ""),
        ])

        // Cancel: removing the token before the caret moves the selection in the reference's
        // document although the caret stays where it is in the text.
        var cancelled = Core(text: "ab", tokens: [maps])
        _ = cancelled.focusChanged(to: true, policies: text)
        XCTAssertEqual(cancelled.cancel(policies: text).events, [.cancelButtonClicked, .tokensChanged([]), selected(at: 2), selected(at: 0)])

        // Typing with a token selected: the selection collapses to the end of the text, and
        // what is typed goes there.
        var behind = Core(text: "ab", tokens: [maps])
        _ = behind.focusChanged(to: true, policies: text)
        XCTAssertEqual(behind.tapToken(maps.id, policies: text).events, [selected(["Maps"], at: 0)])
        XCTAssertEqual(type("x", into: &behind, policies: text), [
            .shouldChange(location: -1, length: 1, replacement: "x", allowed: true), selected(at: 2), selected(at: 3), .editingChanged(text: "abx"),
        ])
        // Tapping outside the tokens gives the selection up for a caret at the end.
        _ = behind.tapToken(maps.id, policies: text)
        XCTAssertEqual(behind.deselect(policies: text).events, [selected(at: 3)])
        XCTAssertEqual(behind.deselect(policies: text), Core.Outcome(), "nothing selected: the input places its own caret")

        // Typing after a conversion: the selection collapses behind the token, then moves on.
        let rule = policies { $0.reportsTextSelection = true; $0.textToToken = { $0 == "ab " ? CatalogToken(kind: .kind(.map), text: "ab") : nil } }
        var converted = Core()
        _ = converted.focusChanged(to: true, policies: rule)
        XCTAssertEqual(type("ab ", into: &converted, policies: rule).suffix(3), [.editingChanged(text: "ab "), .tokensChanged(["ab"]), selected(["ab"], at: 0)])
        XCTAssertEqual(type("x", into: &converted, policies: rule), [
            .shouldChange(location: -1, length: 1, replacement: "x", allowed: true), selected(at: 0), selected(at: 1), .editingChanged(text: "x"),
        ])
    }

    func testWhatChangedWhileNotEditingIsReportedWhenEditingBegins() {
        // The clear button, tapped while the field is not editing, empties it in silence; the
        // reference then reports the selection as editing begins.
        let text = policies { $0.reportsTextSelection = true }
        var core = Core(text: "harbor", tokens: [token("Maps")])
        XCTAssertEqual(core.clear(policies: text).events, [.shouldClear(allowed: true), .tokensChanged([]), .editingChanged(text: "")])
        XCTAssertEqual(core.focusChanged(to: true, policies: text).outcome.events, [selected(at: 0), .didBeginEditing])
        // The host's own changes are where the field starts from: nothing to report.
        var adopted = Core()
        adopted.adopt(text: "", tokens: [token("Tips")])
        XCTAssertEqual(adopted.focusChanged(to: true, policies: text).outcome.events, [.didBeginEditing])
        // Below iOS 18 only the token selection is reported, so neither says a word.
        var quiet = Core(text: "harbor")
        XCTAssertEqual(quiet.focusChanged(to: true, policies: policies()).outcome.events, [.didBeginEditing])
    }

    // MARK: Token-to-query mapping

    func testTokenToQueryMappingIsAPureFunction() {
        let tokens: [CatalogToken] = [
            CatalogToken(kind: .filter(.platform(.ios)), text: "iOS", systemImage: "iphone"),
            CatalogToken(kind: .kind(.map), text: "Maps"),
            CatalogToken(kind: .phrase("power switch"), text: "\u{201C}power switch\u{201D}"),
            CatalogToken(kind: .filter(.category(.maps)), text: "Maps category"),
        ]
        let query = SearchQuery<CatalogSchema>(text: "harbor", tokens: tokens)
        XCTAssertEqual(query.text, "harbor")
        XCTAssertEqual(query.filters, [.platform(.ios), .category(.maps)], ".filter joins SearchQuery.filters")
        XCTAssertEqual(query.kinds, [.map], ".kind joins SearchQuery.kinds")
        XCTAssertEqual(query.phrases, ["power switch"], ".phrase becomes a required exact phrase")
        // The display label is the host's; only the canonical value reaches the query.
        XCTAssertEqual(query.tokens, [.filter(.platform(.ios)), .kind(.map), .phrase("power switch"), .filter(.category(.maps))])
        XCTAssertEqual(query, SearchQuery<CatalogSchema>(text: "harbor", tokens: tokens), "same input, same query")
        // The token id is not part of the query: two chips for the same filter are the same query.
        let twin = [CatalogToken(kind: .filter(.platform(.ios)), text: "iPhone")]
        XCTAssertEqual(SearchQuery<CatalogSchema>(text: "", tokens: twin), SearchQuery<CatalogSchema>(text: "", tokens: [tokens[0]]))
        XCTAssertNil(SearchQuery<CatalogSchema>(text: "x", tokens: [CatalogToken]()).kinds)
    }
}
