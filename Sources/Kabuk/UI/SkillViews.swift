import AppKit
import KabukCore
import SwiftUI

/// In an agent pane's header: opens the list of skills that agent can load.
struct SkillsButton: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let agent: AgentKind

    var body: some View {
        IconButton(symbol: "book.closed", size: 11, help: "Skills (\(agent.displayName))") {
            state.skillPickerPane = state.skillPickerPane == paneID ? nil : paneID
        }
        .popover(isPresented: Binding(
            get: { state.skillPickerPane == paneID },
            set: { if !$0, state.skillPickerPane == paneID { state.skillPickerPane = nil } }
        ), arrowEdge: .bottom) {
            SkillPicker(paneID: paneID, agent: agent)
                .environmentObject(state)
        }
    }
}

/// Search the pane agent's skills and type one at its prompt.
struct SkillPicker: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let agent: AgentKind
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let skills = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("\(agent.displayName) skills", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { insert(skills) }
                    .onKeyPress(.downArrow) { move(1, skills.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, skills.count); return .handled }
                    .onKeyPress(.escape) { state.skillPickerPane = nil; return .handled }
                    .onChange(of: query) { selected = 0 }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                            SkillRow(skill: skill, active: index == selected)
                                .id(skill.id)
                                .onTapGesture { selected = index; insert(skills) }
                                .onHover { if $0 { selected = index } }
                        }
                        if skills.isEmpty {
                            Text(query.isEmpty ? "No skills found for \(agent.displayName)" : "No results")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(16)
                        }
                    }
                    .padding(6)
                }
                // A fixed height: the popover keeps the size it opened with, so a list that grows
                // after a scan, or shrinks as the query narrows it, would be cut off or leave a gap.
                .frame(height: 320)
                .onChange(of: selected) { _, new in
                    if skills.indices.contains(new) { proxy.scrollTo(skills[new].id) }
                }
            }
        }
        .frame(width: 380)
        .environment(\.colorScheme, .dark)
        .onAppear {
            state.refreshSkills(for: paneID)
            // The popover's window isn't key yet when it appears; focusing right away is lost.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var filtered: [Skill] {
        let all = state.skills(for: paneID)
        guard !query.isEmpty else { return all }
        return all
            .compactMap { skill in skill.matchScore(query).map { (skill, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func insert(_ skills: [Skill]) {
        guard skills.indices.contains(selected) else { return }
        let skill = skills[selected]
        state.skillPickerPane = nil
        DispatchQueue.main.async { state.insertSkill(skill, into: paneID) }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(skill.insertion.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(skill.scopeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .lineLimit(1)
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(active ? 0.12 : 0)))
        .contentShape(Rectangle())
        .help(skill.path)
        .contextMenu {
            Button("Open SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.path)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.path)]) }
        }
    }
}
