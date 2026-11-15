import SwiftUI
import XCTest
import ZTronSearchEngine
import ZTronSearchFixtures
@testable import ZTronSearchEngineUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

typealias CatalogResults = ZTronSearchResultsModel<CatalogSchema>
typealias CatalogToken = ZTronSearchToken<CatalogSchema>
typealias CatalogSearch = SearchService<CatalogSchema>

/// Puts a SwiftUI view in a real window so its lifecycle runs: `onAppear`, `onChange`,
/// `onDisappear`. Tests may use platform frameworks; only the UI product may not.
@MainActor
final class HostedView<Content: View> {
    #if canImport(AppKit)
    private let window: NSWindow
    private let host: NSHostingView<Content>
    #elseif canImport(UIKit)
    private let window: UIWindow
    private let host: UIHostingController<Content>
    #endif

    init(_ content: Content, width: CGFloat = 390, height: CGFloat = 300) {
        #if canImport(AppKit)
        host = NSHostingView(rootView: content)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        #elseif canImport(UIKit)
        host = UIHostingController(rootView: content)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        #endif
    }

    /// Replaces the root view, as a parent re-render would.
    func update(_ content: Content) {
        #if canImport(AppKit)
        host.rootView = content
        host.layoutSubtreeIfNeeded()
        #elseif canImport(UIKit)
        host.rootView = content
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #endif
    }

    func close() {
        #if canImport(AppKit)
        window.contentView = nil
        window.close()
        #elseif canImport(UIKit)
        window.rootViewController = nil
        window.isHidden = true
        #endif
    }
}

/// Lets SwiftUI and the main actor's pending work run.
@MainActor
func settle(_ seconds: TimeInterval = 0.05) async {
    // While the test is suspended the main run loop turns, which is what SwiftUI needs.
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Polls a condition on the main actor until it holds or the timeout passes.
@MainActor
func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 4_000_000)
    }
    return await condition()
}

enum UIFixtures {
    static func configuration(lexicalDebounce: TimeInterval = 0, semanticDebounce: TimeInterval = 0) -> SearchEngineConfiguration {
        SearchEngineConfiguration(
            locale: Locale(identifier: "en"),
            followsSystemLocale: false,
            secondaryLanguages: .none,
            preferredLanguages: { [] },
            lexicalDebounce: lexicalDebounce,
            semanticDebounce: semanticDebounce,
            assertsOnProgrammerError: false
        )
    }

    /// Sixty tools named "Lantern n" plus a few distinct items: enough for paging.
    static let items: [AnySearchable<CatalogKind>] = {
        var items: [AnySearchable<CatalogKind>] = (0..<60).map {
            AnySearchable(Tool(id: String(format: "lantern-%02d", $0), title: "Lantern \($0)", text: "a lantern", filters: [.platform($0 % 2 == 0 ? .ios : .mac)]))
        }
        items.append(AnySearchable(MapItem(id: "map-harbor", title: "Frozen Harbor", text: "Layout of the harbor.")))
        items.append(AnySearchable(Tip(id: "tip-harbor", title: "Harbor shortcuts", text: "Cut through the harbor gate.")))
        items.append(AnySearchable(Game(id: "game-outbreak", title: "Outbreak Protocol", text: "A survival game.")))
        return items
    }()

    static func service(lexicalDebounce: TimeInterval = 0, semantic: (any SemanticSearching)? = nil) async -> CatalogSearch {
        let service = CatalogSearch(
            index: LexicalIndex(), semantic: semantic, configuration: configuration(lexicalDebounce: lexicalDebounce)
        )
        await service.index(items)
        return service
    }

    static func scanIndex() -> ScanIndex<CatalogSchema> {
        ScanIndex(items: items, locale: Locale(identifier: "en"), configuration: configuration())
    }

    /// The root of the package, found from this file.
    static func packageRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
