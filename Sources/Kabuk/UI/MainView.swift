import KabukCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    static let sidebarWidth: CGFloat = 250

    var body: some View {
        ZStack(alignment: .top) {
            WindowBackdrop().ignoresSafeArea()
            if state.animatedBackground {
                AnimatedBackdrop(mood: state.backdropMood, theme: state.theme)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if state.sidebarVisible {
                    SidebarView()
                        .frame(width: Self.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                content
            }

            if state.paletteVisible || state.themeGalleryVisible || state.diffRequest != nil || state.historyVisible
                || state.worktreeReview != nil || state.subagentDetail != nil {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if state.paletteVisible {
                            state.togglePalette()
                        } else if state.historyVisible {
                            state.toggleHistory()
                        } else if state.themeGalleryVisible {
                            state.toggleThemeGallery()
                        } else if state.diffRequest != nil {
                            withAnimation(.easeOut(duration: 0.2)) { state.diffRequest = nil }
                        } else if state.subagentDetail != nil {
                            state.closeSubagentDetail()
                        } else {
                            state.closeWorktreeReview()
                        }
                    }
                    .transition(.opacity)
            }
            if state.historyVisible {
                HistorySearchView()
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if let request = state.subagentDetail {
                SubagentSheet(request: request)
                    .padding(.top, 70)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if let request = state.worktreeReview {
                WorktreeReviewSheet(request: request)
                    .padding(.top, 70)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if let request = state.diffRequest {
                DiffSheet(request: request)
                    .padding(.top, 60)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if state.paletteVisible {
                CommandPalette()
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if state.themeGalleryVisible {
                ThemeGallery()
                    .padding(.top, 70)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            if let caption = state.demoCaption {
                VStack {
                    Spacer()
                    DemoCaptionView(caption: caption)
                        .padding(.bottom, 54)
                }
                .id(caption.id)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !state.sidebarVisible {
                HStack {
                    IconButton(symbol: "sidebar.left", help: "Show sidebar (⌘\\)") { state.toggleSidebar() }
                    IconButton(symbol: "plus", help: "New session (⌘T)") { state.newSession() }
                    Spacer()
                }
                .padding(.leading, 78)
                .frame(height: 36)
                .transition(.opacity)
            }
            ZStack {
                if let session = state.selectedSession {
                    SplitView(session: session, node: session.root)
                        .id(session.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)), removal: .opacity))
                }
            }
            .padding(.top, state.sidebarVisible ? 10 : 0)
            .padding([.horizontal, .bottom], 10)
            .padding(.leading, state.sidebarVisible ? -2 : 0)
        }
    }
}
