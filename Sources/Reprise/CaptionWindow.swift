import AppKit
import Combine
import SwiftUI

/// The floating captions over every app and full-screen video. Clicks pass through them, except
/// while they are being moved.
@MainActor
final class CaptionWindowController {
    private let captions: LiveCaptions
    private let savePosition: ([Double]) -> Void
    private var panel: CaptionPanel?
    private var frameBeforeMoving: NSRect?
    private var subscriptions = Set<AnyCancellable>()

    init(captions: LiveCaptions, savePosition: @escaping ([Double]) -> Void) {
        self.captions = captions
        self.savePosition = savePosition
        // Published values arrive before they are stored, so each handler takes the new value.
        captions.$isRunning.removeDuplicates().sink { [weak self] running in
            guard let self else { return }
            if running { self.show() } else if !self.captions.moving { self.panel?.orderOut(nil) }
        }.store(in: &subscriptions)
        captions.$moving.removeDuplicates().dropFirst().sink { [weak self] moving in self?.setMoving(moving) }.store(in: &subscriptions)
        captions.$style.removeDuplicates().dropFirst().sink { [weak self] style in self?.place(style) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in guard let self else { return }; self.place(self.captions.style) }.store(in: &subscriptions)
    }

    private func show() {
        if panel == nil {
            let panel = CaptionPanel()
            panel.contentView = NSHostingView(rootView: CaptionOverlay(captions: captions, done: { [weak self] in self?.captions.moving = false }))
            panel.onCancel = { [weak self] in self?.captions.moving = false }
            self.panel = panel
        }
        place(captions.style)
        panel?.orderFrontRegardless()
    }

    private func setMoving(_ moving: Bool) {
        if moving { show() }
        guard let panel else { return }
        panel.ignoresMouseEvents = !moving
        if moving {
            frameBeforeMoving = panel.frame
            panel.makeKeyAndOrderFront(nil)
        } else {
            if panel.frame != frameBeforeMoving { savePosition([panel.frame.midX, panel.frame.midY]) }
            if !captions.isRunning { panel.orderOut(nil) }
        }
    }

    private func place(_ style: CaptionPreferences) {
        guard let panel, !panel.isMoving else { return }
        let screen = screen(for: style)
        let visible = screen.visibleFrame
        let width = min(visible.width * 0.84, 1_280)
        let height = style.textSize * 1.35 * Double(style.lines) + (style.showOriginal ? style.textSize * 0.9 : 0) + 76
        var origin = CGPoint(x: visible.midX - width / 2, y: visible.minY + 36)
        switch style.position {
        case .bottom: break
        case .top: origin.y = visible.maxY - height - 24
        case .custom:
            if let center = style.center, center.count == 2 { origin = CGPoint(x: center[0] - width / 2, y: center[1] - height / 2) }
        }
        // Moved captions stay on their screen when the screens change.
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }

    /// The screen the captions were moved to, else the one in use.
    private func screen(for style: CaptionPreferences) -> NSScreen {
        if style.position == .custom, let center = style.center, center.count == 2,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: center[0], y: center[1])) }) { return screen }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

final class CaptionPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Being dragged into place; the saved position follows the panel then, not the other way round.
    var isMoving: Bool { !ignoresMouseEvents }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { isMoving }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Caption lines at the bottom of the panel, newest last; while moving, a Done button above them.
struct CaptionOverlay: View {
    @ObservedObject var captions: LiveCaptions
    let done: () -> Void
    var body: some View {
        let style = captions.style
        GeometryReader { proxy in
            VStack(spacing: 6) {
                if captions.moving {
                    HStack(spacing: 10) {
                        Text("Drag the captions where you want them.")
                        Button("Done", action: done).keyboardShortcut(.defaultAction)
                    }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                }
                Spacer(minLength: 0)
                CaptionBlock(text: shown, spoken: captions.spokenText, notice: captions.problem ?? captions.notice,
                             moving: captions.moving, style: style, width: proxy.size.width - 48)
                    .overlay { if captions.moving { WindowDragArea() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shown: String {
        if captions.moving && captions.text.isEmpty { return "Captions appear here" }
        return captions.text
    }
}

/// Moves its window when dragged.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// The styled caption box; also the preview in Settings.
struct CaptionBlock: View {
    let text: String
    var spoken = ""
    var notice: String?
    var moving = false
    let style: CaptionPreferences
    let width: Double
    var body: some View {
        let lines = Array(CaptionLayout.wrap(text, width: max(200, width - 40), size: style.textSize).suffix(max(1, style.lines)))
        let spokenLine = style.showOriginal ? CaptionLayout.wrap(spoken, width: max(200, width - 40), size: style.textSize * 0.62).last : nil
        let shade = lines.isEmpty && notice == nil ? 0 : (moving ? max(0.35, style.backgroundOpacity) : style.backgroundOpacity)
        VStack(spacing: 4) {
            if let notice, lines.isEmpty {
                Text(notice).font(.system(size: max(13, style.textSize * 0.5), weight: .medium)).foregroundStyle(style.color.opacity(0.85))
                    .lineLimit(3)
            }
            if let spokenLine, !lines.isEmpty {
                Text(spokenLine).font(.system(size: style.textSize * 0.62, weight: .regular)).foregroundStyle(style.color.opacity(0.72)).lineLimit(1)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: style.textSize, weight: .semibold)).foregroundStyle(style.color).lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(shade)))
        .overlay {
            if moving { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4])) }
        }
        .animation(.easeOut(duration: 0.15), value: lines)
        .accessibilityElement(children: .combine).accessibilityLabel(lines.joined(separator: " "))
    }
}
