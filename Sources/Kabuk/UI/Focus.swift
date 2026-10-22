import SwiftUI

extension View {
    /// Puts the keyboard focus on a field as it appears. An overlay's field isn't in the window
    /// yet during `onAppear`, so focusing it there is sometimes lost and the terminal keeps the
    /// keys; it's asked again on the next turn of the run loop and once more shortly after.
    func focusOnAppear(_ focused: FocusState<Bool>.Binding) -> some View {
        onAppear {
            focused.wrappedValue = true
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { focused.wrappedValue = true }
            }
        }
    }
}
