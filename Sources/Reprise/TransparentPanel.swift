import AppKit
import SwiftUI

class TransparentPanel: NSPanel {
    var overlayBackgroundColor: NSColor { .clear }
    // SwiftUI can reapply a window background when hosting content or changing appearance.
    override var backgroundColor: NSColor! {
        get { overlayBackgroundColor }
        set { super.backgroundColor = overlayBackgroundColor }
    }
    override var isOpaque: Bool {
        get { false }
        set { super.isOpaque = false }
    }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        focusRingType = .none
        layer?.backgroundColor = NSColor.clear.cgColor
        safeAreaRegions = []
        window?.backgroundColor = .clear
    }
}
