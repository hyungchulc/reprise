import AppKit
import SwiftUI

struct MemoryTimelineScrollInput: NSViewRepresentable {
    var excludedRects: [CGRect]
    var onScroll: (Double, Double, Bool) -> Void

    func makeNSView(context: Context) -> ScrollInputView { ScrollInputView() }
    func updateNSView(_ view: ScrollInputView, context: Context) {
        view.excludedRects = excludedRects
        view.onScroll = onScroll
    }

    final class ScrollInputView: NSView {
        var excludedRects: [CGRect] = []
        var onScroll: ((Double, Double, Bool) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), !self.excludedRects.contains(where: { $0.contains(point) }) else { return event }
                if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                    self.onScroll?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas)
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct MemoryScrollExclusions: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

extension View {
    func excludesMemoryScrolling() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: MemoryScrollExclusions.self, value: [geometry.frame(in: .named("memoryExplorer"))])
        })
    }
}
