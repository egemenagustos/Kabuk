import AppKit
import SwiftUI

// Looping status animations drawn with Core Animation. SwiftUI's `TimelineView(.animation)`
// and even its `repeatForever` animations re-render the whole hosting view on the main
// thread every frame, so a few spinners kept Kabuk busy while it sat idle. These layers
// are animated by the render server: once started they cost the app nothing per frame.

/// Base for a view whose layers loop forever. Subclasses build their layers once in
/// `setUp`, lay them out on resize and attach their animations whenever the view joins a
/// window. `bleed` is room around the SwiftUI frame for things that scale past it
/// (see `bleeding`).
class LoopingLayerView: NSView {
    var bleed: CGFloat = 0 { didSet { needsLayout = true } }
    /// The SwiftUI frame, inside the bleed.
    var content: CGRect { bounds.insetBy(dx: bleed, dy: bleed) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions { layoutLayers() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimations() }
    }

    func setUp() {}
    func layoutLayers() {}
    func startAnimations() {}

    func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

extension CAAnimation {
    /// Repeats forever, phase-locked to the clock so every copy of an animation (sidebar,
    /// status bar, palette) moves in step, as the old time-driven views did.
    /// `lead` puts this copy that many seconds ahead.
    func looping(period: CFTimeInterval, lead: CFTimeInterval = 0) -> Self {
        repeatCount = .infinity
        timeOffset = (CACurrentMediaTime() + lead).truncatingRemainder(dividingBy: period)
        return self
    }
}

private func basic(_ keyPath: String, from: Any, to: Any, duration: CFTimeInterval,
                   autoreverses: Bool = false, easing: CAMediaTimingFunctionName = .linear,
                   lead: CFTimeInterval = 0) -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.autoreverses = autoreverses
    animation.timingFunction = CAMediaTimingFunction(name: easing)
    return animation.looping(period: autoreverses ? duration * 2 : duration, lead: lead)
}

private func cgColor(_ color: Color, alpha: CGFloat = 1) -> CGColor {
    NSColor(color).withAlphaComponent(NSColor(color).alphaComponent * alpha).cgColor
}

// MARK: - Pane borders

/// The working-agent sweep: a conic gradient spinning under a rounded-border mask.
final class SweepBorderView: LoopingLayerView {
    var color: Color = .clear { didSet { withoutActions(recolor) } }
    let ring = CALayer()
    private let container = CALayer()
    private let gradient = CAGradientLayer()

    override func setUp() {
        ring.borderColor = .black
        ring.cornerCurve = .continuous
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        container.mask = ring
        container.addSublayer(gradient)
        layer?.addSublayer(container)
    }

    private func recolor() {
        gradient.colors = [cgColor(color, alpha: 0), cgColor(color), cgColor(color, alpha: 0.2), cgColor(color, alpha: 0)]
    }

    override func layoutLayers() {
        container.frame = bounds
        ring.frame = bounds
        // A square big enough to cover the card at any angle.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func startAnimations() {
        // Clockwise on screen, a quarter turn a second.
        gradient.add(basic("transform.rotation.z", from: 0, to: -2 * Double.pi, duration: 4), forKey: "spin")
    }
}

/// Waiting for the user: the card edge fades in and out.
final class BreathingBorderView: LoopingLayerView {
    var color: Color = .clear { didSet { withoutActions { ring.borderColor = cgColor(color) } } }
    let ring = CALayer()

    override func setUp() {
        ring.cornerCurve = .continuous
        layer?.addSublayer(ring)
    }

    override func layoutLayers() { ring.frame = bounds }

    override func startAnimations() {
        ring.add(basic("opacity", from: 0.05, to: 0.85, duration: 0.98, autoreverses: true, easing: .easeInEaseOut),
                 forKey: "breathe")
    }
}

struct SweepingBorder: NSViewRepresentable {
    let color: Color
    var cornerRadius: CGFloat = 14
    var lineWidth: CGFloat = 1.6

    func makeNSView(context: Context) -> SweepBorderView { SweepBorderView() }
    func updateNSView(_ view: SweepBorderView, context: Context) {
        view.color = color
        view.ring.cornerRadius = cornerRadius
        view.ring.borderWidth = lineWidth
    }
}

struct BreathingBorder: NSViewRepresentable {
    let color: Color
    var cornerRadius: CGFloat = 14
    var lineWidth: CGFloat = 1.6

    func makeNSView(context: Context) -> BreathingBorderView { BreathingBorderView() }
    func updateNSView(_ view: BreathingBorderView, context: Context) {
        view.color = color
        view.ring.cornerRadius = cornerRadius
        view.ring.borderWidth = lineWidth
    }
}

// MARK: - Status icons

/// Ordinary commands: three bars rising and falling out of step, like a level meter.
final class RunningBarsView: LoopingLayerView {
    var color: Color = .clear { didSet { withoutActions { bars.forEach { $0.backgroundColor = cgColor(color) } } } }
    private let bars = (0..<3).map { _ in CALayer() }

    override func setUp() {
        bars.forEach { layer?.addSublayer($0) }
    }

    override func layoutLayers() {
        let area = content.insetBy(dx: 1, dy: 1)
        let width = area.width * 0.2, spacing = area.width * 0.14
        var x = area.midX - (3 * width + 2 * spacing) / 2
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: area.height * 0.9)
            bar.position = CGPoint(x: x + width / 2, y: area.midY)
            bar.cornerRadius = width / 2
            x += width + spacing
        }
    }

    override func startAnimations() {
        for (i, bar) in bars.enumerated() {
            // Each bar a little ahead of the one to its left.
            let lead = Double(i) * 0.18
            bar.add(basic("transform.scale.y", from: 1.0 / 3, to: 1, duration: 0.52, autoreverses: true,
                          easing: .easeInEaseOut, lead: lead), forKey: "level")
            bar.add(basic("opacity", from: 0.5, to: 1, duration: 0.52, autoreverses: true,
                          easing: .easeInEaseOut, lead: lead), forKey: "fade")
        }
    }
}

/// Claude/Codex thinking: the asterisk grows through a cycle of glyphs instead of turning,
/// over a soft halo that breathes with it.
final class AgentSpinnerView: LoopingLayerView {
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    /// Glyphs per second.
    private static let rate = 9.0
    /// One breath in or out of the halo and the glyph's glow.
    private static let breath = Double.pi / 2.2

    var color: Color = .clear { didSet { if color != oldValue { restyle() } } }
    var size: CGFloat = 14 { didSet { if size != oldValue { bleed = size; restyle() } } }
    private let halo = CAGradientLayer()
    private let glyph = CALayer()

    override func setUp() {
        bleed = size
        halo.type = .radial
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        glyph.contentsGravity = .center
        glyph.shadowOffset = .zero
        glyph.shadowRadius = 3
        layer?.addSublayer(halo)
        layer?.addSublayer(glyph)
    }

    private func restyle() {
        withoutActions(recolor)
        if window != nil { startAnimations() }
    }

    /// A blurred disc as a radial gradient: the disc's edge sits at half strength and the
    /// blur fades out about 4pt beyond it.
    private func recolor() {
        let blur: CGFloat = 4
        halo.colors = [cgColor(color, alpha: 0.8), cgColor(color, alpha: 0.5), cgColor(color, alpha: 0)]
        halo.locations = [0, NSNumber(value: Double(size / (size + 2 * blur))), 1]
        glyph.shadowColor = cgColor(color)
    }

    override func layoutLayers() {
        let center = CGPoint(x: content.midX, y: content.midY)
        let haloSide = size + 8
        halo.bounds = CGRect(x: 0, y: 0, width: haloSide, height: haloSide)
        halo.position = center
        glyph.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
        glyph.position = center
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if window != nil { startAnimations() }
    }

    override func startAnimations() {
        let scale = window?.backingScaleFactor ?? 2
        glyph.contentsScale = scale
        let images = Self.frames.map { Self.render($0, size: size, color: NSColor(color), scale: scale) }
        let cycle = CAKeyframeAnimation(keyPath: "contents")
        cycle.values = images as [Any]
        cycle.calculationMode = .discrete
        cycle.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
        cycle.duration = Double(images.count) / Self.rate
        glyph.add(cycle.looping(period: cycle.duration), forKey: "cycle")
        withoutActions { glyph.contents = images.first ?? nil }

        halo.add(basic("transform.scale", from: 0.75, to: 1.2, duration: Self.breath, autoreverses: true,
                       easing: .easeInEaseOut), forKey: "grow")
        halo.add(basic("opacity", from: 0.1, to: 0.26, duration: Self.breath, autoreverses: true,
                       easing: .easeInEaseOut), forKey: "glow")
        glyph.add(basic("shadowOpacity", from: 0, to: 0.6, duration: Self.breath, autoreverses: true,
                        easing: .easeInEaseOut), forKey: "glow")
    }

    private static func render(_ text: String, size: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        let side = size * 2
        let pixels = Int((side * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size * 1.05, weight: .heavy),
            .foregroundColor: color,
        ])
        let box = string.size()
        string.draw(at: CGPoint(x: (side - box.width) / 2, y: (side - box.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Waiting for the user: a ring that keeps sending out pulses.
final class PulseRingView: LoopingLayerView {
    var color: Color = .clear { didSet { withoutActions { ring.strokeColor = cgColor(color) } } }
    let ring = CAShapeLayer()

    override func setUp() {
        ring.fillColor = nil
        layer?.addSublayer(ring)
    }

    override func layoutLayers() {
        ring.bounds = CGRect(origin: .zero, size: content.size)
        ring.position = CGPoint(x: content.midX, y: content.midY)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
    }

    override func startAnimations() {
        ring.add(basic("transform.scale", from: 1, to: 1.9, duration: 1.4), forKey: "grow")
        ring.add(basic("opacity", from: 1, to: 0, duration: 1.4), forKey: "fade")
    }
}

struct RunningBarsLayer: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> RunningBarsView { RunningBarsView() }
    func updateNSView(_ view: RunningBarsView, context: Context) { view.color = color }
}

struct AgentSpinnerLayer: NSViewRepresentable {
    let color: Color
    let size: CGFloat

    func makeNSView(context: Context) -> AgentSpinnerView { AgentSpinnerView() }
    func updateNSView(_ view: AgentSpinnerView, context: Context) {
        view.size = size
        view.color = color
    }
}

struct PulseRingLayer: NSViewRepresentable {
    let color: Color
    let lineWidth: CGFloat
    let bleed: CGFloat

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }
    func updateNSView(_ view: PulseRingView, context: Context) {
        view.color = color
        view.ring.lineWidth = lineWidth
        view.bleed = bleed
    }
}

// MARK: - Sidebar

/// A sweep of light across a row while an agent works.
final class ShimmerView: LoopingLayerView {
    var color: Color = .clear {
        didSet { withoutActions { band.colors = [cgColor(.clear), cgColor(color, alpha: 0.16), cgColor(.clear)] } }
    }
    let clip = CALayer()
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = 0

    override func setUp() {
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        clip.addSublayer(band)
        layer?.addSublayer(clip)
    }

    override func layoutLayers() {
        clip.frame = bounds
        band.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.5, height: bounds.height)
        // The sweep's distance depends on the row's width.
        if bounds.width != sweptWidth, window != nil { startAnimations() }
    }

    override func startAnimations() {
        sweptWidth = bounds.width
        band.add(basic("transform.translation.x", from: -bounds.width * 0.5, to: bounds.width, duration: 2.2),
                 forKey: "sweep")
    }
}

struct Shimmer: NSViewRepresentable {
    let color: Color
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }
    func updateNSView(_ view: ShimmerView, context: Context) {
        view.color = color
        view.clip.cornerRadius = cornerRadius
    }
}

extension View {
    /// Gives a looping layer room to draw past this view's frame without changing its layout.
    func bleeding(_ amount: CGFloat) -> some View {
        padding(-amount)
    }
}
