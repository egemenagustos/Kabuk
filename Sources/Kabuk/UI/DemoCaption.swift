import SwiftUI

/// A caption for the recorded demo: what's being shown and the shortcut that does it.
struct DemoCaption: Equatable {
    let id = UUID()
    var title: String
    var keys: [String]

    /// "Parallel agents in worktrees|⌥ ⌘ T": the title, then space-separated keycaps.
    init?(_ spec: String) {
        let parts = spec.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let title = parts.first, !title.isEmpty else { return nil }
        self.title = title
        keys = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
    }
}

struct DemoCaptionView: View {
    let caption: DemoCaption

    var body: some View {
        HStack(spacing: 14) {
            Text(caption.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            if !caption.keys.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(caption.keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(minWidth: 26, minHeight: 26)
                            .padding(.horizontal, key.count > 1 ? 6 : 0)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.22)))
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}
