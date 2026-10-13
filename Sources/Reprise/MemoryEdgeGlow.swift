import AppKit
import QuartzCore
import SwiftUI

struct MemoryEdgeGlow: NSViewRepresentable {
    let accent: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> MemoryEdgeGlowView { MemoryEdgeGlowView() }
    func updateNSView(_ view: MemoryEdgeGlowView, context: Context) {
        view.configure(accent: NSColor(accent), cornerRadius: cornerRadius, animated: !reduceMotion)
    }
}

final class MemoryEdgeGlowView: NSView {
    private let edgeLayers = (0..<4).map { _ in CAGradientLayer() }
    private let outlineMask = CALayer()
    private let strokes = [CGFloat(16), 10, 6, 2].map { width -> CAShapeLayer in
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = NSColor.white.cgColor
        shape.lineWidth = width
        shape.opacity = width == 2 ? 1 : (width == 6 ? 0.26 : (width == 10 ? 0.14 : 0.08))
        return shape
    }
    private var accent: NSColor?
    private var cornerRadius: CGFloat = 0
    private var animate = false
    private var animating = false
    private var visibilityObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        layer?.mask = outlineMask
        for stroke in strokes { outlineMask.addSublayer(stroke) }
        // Four narrow native gradients avoid rasterizing a full-screen conic gradient
        // on the main thread for every SwiftUI animation frame.
        let directions: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
            (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
            (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        ]
        for (index, edge) in edgeLayers.enumerated() {
            edge.startPoint = directions[index].0
            edge.endPoint = directions[index].1
            layer?.addSublayer(edge)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(accent: NSColor, cornerRadius: CGFloat, animated: Bool) {
        let resolved = accent.usingColorSpace(.deviceRGB) ?? accent
        let colorChanged = self.accent != resolved
        if colorChanged { self.accent = resolved }
        if self.cornerRadius != cornerRadius { self.cornerRadius = cornerRadius; needsLayout = true }
        animate = animated
        updateAnimation(force: colorChanged)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = bounds.width, height = bounds.height
        let thickness = min(16, min(width, height) / 2)
        let frames = [CGRect(x: 0, y: 0, width: width, height: thickness),
                      CGRect(x: width - thickness, y: thickness, width: thickness, height: max(0, height - 2 * thickness)),
                      CGRect(x: 0, y: height - thickness, width: width, height: thickness),
                      CGRect(x: 0, y: thickness, width: thickness, height: max(0, height - 2 * thickness))]
        for (edge, frame) in zip(edgeLayers, frames) { edge.frame = frame }
        outlineMask.frame = bounds
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        for stroke in strokes {
            stroke.frame = bounds
            stroke.path = path
            stroke.contentsScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        if let window {
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateAnimation()
            }
        }
        needsLayout = true
        updateAnimation()
    }

    private func updateAnimation(force: Bool = false) {
        let active = animate && window?.occlusionState.contains(.visible) == true
        guard force || active != animating else { return }
        animating = active
        guard let accent else { return }
        let palette = [accent, .systemCyan, .systemPink, .systemOrange].map { $0.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, edge) in edgeLayers.enumerated() {
            let frames = (0...4).map { phase in [palette[(index + phase) % 4], palette[(index + phase + 1) % 4]] }
            edge.colors = frames[0]
            edge.removeAnimation(forKey: "edgeColors")
            if active {
                let animation = CAKeyframeAnimation(keyPath: "colors")
                animation.values = frames
                animation.duration = 8
                animation.repeatCount = .infinity
                edge.add(animation, forKey: "edgeColors")
            }
        }
        CATransaction.commit()
    }

    deinit { if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) } }
}
