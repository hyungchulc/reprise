import AppKit
import SwiftUI
import XCTest
@testable import Reprise

final class MemorySearchResultsTests: XCTestCase {
    @MainActor func testFollowUpQuestionStaysVisibleAcrossLayoutChanges() async throws {
        let fixture = SearchResultsFixture()
        let host = NSHostingView(rootView: SearchResultsFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host) { fixture.probe?.enclosingScrollView != nil }
        let scroll = try XCTUnwrap(fixture.probe?.enclosingScrollView)
        XCTAssertLessThan(scroll.bounds.height, 200, "An initial short answer must remain compact")

        for (id, history, latest) in [("pending", 900.0, 72.0), ("answer-two", 900.0, 900.0),
                                      ("pending", 1_800.0, 72.0), ("answer-three", 1_800.0, 60.0)] {
            fixture.historyHeight = history
            fixture.latestHeight = latest
            fixture.latestID = id
            try await settle(host) {
                guard let top = fixture.topInset else { return false }
                return top >= -1 && top <= 32 && abs(scroll.bounds.height - 400) < 1
            }
            XCTAssertEqual(try XCTUnwrap(fixture.topInset), 16, accuracy: 17, "New question must be at the top for \(id), not below old results")
        }

        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 0 : document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(40))
        fixture.latestHeight += 30
        try await settle(host) { (fixture.topInset ?? 0) > 400 }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.topInset), 400, "Reading earlier turns must not snap back to the latest answer")
    }

    @MainActor private func settle(_ host: NSView, until ready: () -> Bool) async throws {
        for _ in 0..<60 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if ready() { return }
        }
        XCTFail("Search layout did not settle at the requested question")
    }
}

@MainActor private final class SearchResultsFixture: ObservableObject {
    @Published var latestID = "first"
    @Published var historyHeight = 0.0
    @Published var latestHeight = 80.0
    @Published var contentHeight: CGFloat = 100
    weak var probe: NSView?

    var topInset: CGFloat? {
        guard let probe, let scroll = probe.enclosingScrollView, let document = scroll.documentView else { return nil }
        let frame = probe.convert(probe.bounds, to: document)
        let visible = scroll.contentView.documentVisibleRect
        return document.isFlipped ? frame.minY - visible.minY : visible.maxY - frame.maxY
    }
}

private struct SearchResultsFixtureView: View {
    @ObservedObject var fixture: SearchResultsFixture
    var body: some View {
        MemorySearchResultsView(latestID: fixture.latestID, hasHistory: fixture.historyHeight > 0,
                                maxHeight: 400, contentHeight: $fixture.contentHeight) {
            if fixture.historyHeight > 0 { Text("Earlier conversation").frame(height: fixture.historyHeight) }
        } latest: {
            Text("Current question and answer").frame(height: fixture.latestHeight, alignment: .top)
                .background(SearchResultsProbe(fixture: fixture))
        }.frame(width: 640, height: 400, alignment: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: min(fixture.contentHeight, 440))
    }
}

private struct SearchResultsProbe: NSViewRepresentable {
    let fixture: SearchResultsFixture
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        fixture.probe = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
