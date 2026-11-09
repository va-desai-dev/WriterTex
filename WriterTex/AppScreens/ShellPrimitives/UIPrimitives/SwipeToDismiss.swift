import SwiftUI

struct MacOSDismissActionModifier: ViewModifier {
    /// Called once the swipe completes. Not `\.dismiss`: outside a sheet that closes the window.
    let onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    private let dismissThreshold: CGFloat = 120
    private let offscreenWidth: CGFloat = 400

    func body(content: Content) -> some View {
        content
            .offset(x: max(0, dragOffset)) // Track rightward gesture only
            .opacity(max(0.1, 1.0 - Double(max(0, dragOffset) / dismissThreshold)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let predictedX = value.predictedEndTranslation.width
                        let finalX = value.translation.width

                        if finalX > dismissThreshold || predictedX > dismissThreshold {
                            // 1. Move the banner entirely offscreen to the right first
                            withAnimation(.spring(response: 0.23, dampingFraction: 0.75)) {
                                dragOffset = offscreenWidth
                            }
                            // 2. Fire the dismiss handler right as the view exits
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onDismiss()
                            }
                        } else {
                            // Snap back if gesture wasn't decisive
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }
}

extension View {
    /// Slides the view offscreen when swiped right, then calls `onDismiss` so the owner can remove it.
    func macOSSwipeToDismiss(onDismiss: @escaping () -> Void) -> some View {
        self.modifier(MacOSDismissActionModifier(onDismiss: onDismiss))
    }
}
