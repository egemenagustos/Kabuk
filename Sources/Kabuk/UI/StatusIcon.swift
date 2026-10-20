import KabukCore
import SwiftUI

/// The small animated glyph that tells you what a session is doing.
struct StatusIcon: View {
    let status: PaneStatus
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                Circle().fill(Color.white.opacity(0.18)).frame(width: 5, height: 5)
            case .running:
                RunningBars()
            case .agentReady(let agent):
                Text("✻").font(.system(size: size * 0.95, weight: .bold)).foregroundStyle(Theme.color(for: agent).opacity(0.55))
            case .agentWorking(let agent, _):
                AgentSpinner(color: Theme.color(for: agent), size: size)
            case .agentNeedsYou:
                NeedsYouPulse()
            case .succeeded:
                DrawnCheck()
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.7, weight: .heavy))
                    .foregroundStyle(Theme.failure)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .id(kind)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: kind)
    }

    private var kind: String {
        switch status {
        case .idle: return "idle"
        case .running: return "running"
        case .agentReady: return "ready"
        case .agentWorking: return "working"
        case .agentNeedsYou: return "needs"
        case .succeeded: return "ok"
        case .failed: return "failed"
        }
    }
}

/// Ordinary commands: three bars rising and falling out of step, like a level meter.
private struct RunningBars: View {
    var body: some View {
        RunningBarsLayer(color: Theme.running)
    }
}

/// Claude/Codex thinking: the asterisk cycles through glyphs over a breathing halo.
private struct AgentSpinner: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        // The halo and the glyph's glow reach past the icon's frame.
        AgentSpinnerLayer(color: color, size: size).bleeding(size)
    }
}

/// Waiting for the user: a ring that keeps sending out pulses.
private struct NeedsYouPulse: View {
    var body: some View {
        ZStack {
            PulseRingLayer(color: Theme.needsYou, lineWidth: 1.5, bleed: 8).bleeding(8)
            Circle().stroke(Theme.needsYou, lineWidth: 1.8)
            Circle().fill(Theme.needsYou).padding(4)
        }
        .padding(1)
    }
}

/// A check mark that draws itself, then settles to a quieter tone.
private struct DrawnCheck: View {
    @State private var progress: CGFloat = 0
    @State private var settled = false

    var body: some View {
        CheckShape()
            .trim(from: 0, to: progress)
            .stroke(settled ? Color.white.opacity(0.55) : Theme.success,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .padding(2)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) { progress = 1 }
                withAnimation(.easeInOut(duration: 0.8).delay(3)) { settled = true }
            }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY + rect.height * 0.16))
        return path
    }
}

/// Horizontal shake for failures; animate `trigger` up by one to shake once.
struct ShakeEffect: GeometryEffect {
    var trigger: CGFloat

    var animatableData: CGFloat {
        get { trigger }
        set { trigger = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three wiggles per step, back to rest at every whole number.
        ProjectionTransform(CGAffineTransform(translationX: sin(trigger * .pi * 6) * 5, y: 0))
    }
}
