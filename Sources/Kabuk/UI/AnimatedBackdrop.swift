import KabukCore
import MetalKit
import SwiftUI

/// What the background should feel like, from the selected session's state.
enum BackdropMood: Equatable {
    case calm, running, claude, codex, needsYou
}

/// Slow drifting light behind the panes, drawn with Metal. Its colors and speed follow the
/// mood: warm and quicker while Claude works, teal for Codex, a pulsing amber when an agent
/// waits for you.
struct AnimatedBackdrop: NSViewRepresentable {
    let mood: BackdropMood
    let theme: TerminalTheme

    func makeCoordinator() -> BackdropRenderer? {
        BackdropRenderer()
    }

    func makeNSView(context: Context) -> NSView {
        guard let renderer = context.coordinator else { return NSView() }
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        renderer.setTarget(mood: mood, theme: theme)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator?.setTarget(mood: mood, theme: theme)
    }
}

final class BackdropRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private struct Uniforms {
        var params: SIMD4<Float>   // phase, width, height, intensity
        var color1: SIMD4<Float>
        var color2: SIMD4<Float>
        var extra: SIMD4<Float>    // pulse, time
    }

    private var current = (c1: SIMD4<Float>(0.5, 0.6, 1, 1), c2: SIMD4<Float>(0.8, 0.6, 1, 1), intensity: Float(0), speed: Float(1), pulse: Float(0))
    private var target = (c1: SIMD4<Float>(0.5, 0.6, 1, 1), c2: SIMD4<Float>(0.8, 0.6, 1, 1), intensity: Float(0.16), speed: Float(1), pulse: Float(0))
    private var phase: Float = 0
    private var lastTime = CACurrentMediaTime()
    private let start = CACurrentMediaTime()

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "kabuk_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "kabuk_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func setTarget(mood: BackdropMood, theme: TerminalTheme) {
        func rgb(_ hex: String) -> SIMD4<Float> {
            let c = TerminalTheme.rgb(hex) ?? (0.5, 0.5, 0.5)
            return SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
        }
        let claude = SIMD4<Float>(0.93, 0.55, 0.36, 1)
        let codex = SIMD4<Float>(0.36, 0.82, 0.78, 1)
        let amber = SIMD4<Float>(0.98, 0.66, 0.22, 1)
        let blue = SIMD4<Float>(0.55, 0.70, 1.0, 1)
        switch mood {
        case .calm: target = (rgb(theme.ansi[4]), rgb(theme.ansi[5]), 0.16, 1, 0)
        case .running: target = (blue, rgb(theme.ansi[6]), 0.22, 1.8, 0)
        case .claude: target = (claude, rgb(theme.ansi[5]), 0.32, 2.6, 0)
        case .codex: target = (codex, rgb(theme.ansi[4]), 0.32, 2.6, 0)
        case .needsYou: target = (amber, claude, 0.28, 1.2, 1)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        // Ease toward the target so mood changes fade instead of jumping.
        let k = min(dt * 1.5, 1)
        current.c1 += (target.c1 - current.c1) * k
        current.c2 += (target.c2 - current.c2) * k
        current.intensity += (target.intensity - current.intensity) * k
        current.speed += (target.speed - current.speed) * k
        current.pulse += (target.pulse - current.pulse) * k
        phase += dt * current.speed

        guard view.window?.occlusionState.contains(.visible) ?? false,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(
            params: SIMD4(phase, Float(view.drawableSize.width), Float(view.drawableSize.height), current.intensity),
            color1: current.c1, color2: current.c2,
            extra: SIMD4(current.pulse, Float(now - start), 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Compiled at runtime, so building Kabuk needs no Metal toolchain.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut kabuk_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut out;
        out.position = float4(p[vid], 0, 1);
        out.uv = (p[vid] + 1) * 0.5;
        return out;
    }

    struct Uniforms { float4 params; float4 color1; float4 color2; float4 extra; };

    float blob(float2 p, float2 center, float size) {
        float2 d = p - center;
        return exp(-dot(d, d) / size);
    }

    float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 kabuk_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float t = u.params.x * 0.15;
        float aspect = u.params.y / max(u.params.z, 1.0);
        float2 p = float2(in.uv.x * aspect, in.uv.y);

        float a = blob(p, float2(aspect * (0.25 + 0.20 * sin(t * 1.3)), 0.30 + 0.22 * cos(t * 1.1)), 0.18);
        float b = blob(p, float2(aspect * (0.78 + 0.16 * cos(t * 0.9)), 0.72 + 0.18 * sin(t * 1.7)), 0.15);
        float c = blob(p, float2(aspect * (0.55 + 0.28 * sin(t * 0.7 + 2.0)), 0.10 + 0.12 * cos(t * 1.3)), 0.10);
        float d = blob(p, float2(aspect * (0.10 + 0.08 * cos(t * 1.9)), 0.85 + 0.10 * sin(t * 0.8)), 0.08);

        float3 color = u.color1.rgb * (a + d * 0.8) + u.color2.rgb * b + mix(u.color1.rgb, u.color2.rgb, 0.5) * c * 0.8;
        float glow = a + b + c * 0.8 + d * 0.8;

        float pulse = 1.0 + u.extra.x * 0.35 * sin(u.extra.y * 3.2);
        float alpha = clamp(glow * u.params.w * pulse, 0.0, 0.6);
        // A little grain keeps the gradients from banding.
        alpha = max(alpha + (hash(in.position.xy) - 0.5) * 0.012, 0.0);
        float3 rgb = color / max(glow, 0.001);
        return float4(rgb * alpha, alpha);
    }
    """
}
