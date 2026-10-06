import SwiftUI

/// What a card drag draws over the workspace: a hollow shell where the card was picked up,
/// and a line where it would land.
struct WorkspaceCardDragOverlay: View {
    @ObservedObject var drag: WorkspaceCardDrag

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let origin = drag.origin {
                RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: origin.width, height: origin.height)
                    .offset(x: origin.minX, y: origin.minY)
                    .transition(.opacity)
            }
            if let marker = drag.target?.marker {
                // A quiet rule in the text colour: enough to read the landing place, without
                // an accent colour pulling the eye from the card being moved.
                Capsule()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
                    .animation(.snappy(duration: 0.12), value: marker)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Carries a card with the pointer while it is dragged. Each card watches the drag itself,
/// so the workspace's body does not run on every mouse move.
struct WorkspaceDraggedCard: ViewModifier {
    @ObservedObject var drag: WorkspaceCardDrag
    let id: WorkspaceCardID

    func body(content: Content) -> some View {
        let isDragged = drag.card == id
        content
            // Lifted off the page, and faint enough to read the landing line through it.
            .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 18, y: 8)
            .opacity(isDragged ? 0.92 : 1)
            .offset(isDragged ? drag.translation : .zero)
            .zIndex(isDragged ? 1 : 0)
    }
}
