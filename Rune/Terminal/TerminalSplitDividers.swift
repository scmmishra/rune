import AppKit
import SwiftUI

/// The gaps between split panes. Drag one to resize its two sides; double-click to halve them.
struct TerminalSplitDividers: View {
    let dividers: [TerminalSplitDivider]
    let onResize: (UUID, CGFloat) -> Void

    var body: some View {
        // Laid out in the workspace's own coordinates, like the panes the gaps sit between.
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(dividers) { divider in
                Handle(divider: divider) { onResize(divider.id, $0) }
                    .frame(width: divider.frame.width, height: divider.frame.height)
                    .offset(x: divider.frame.minX, y: divider.frame.minY)
            }
        }
    }

    private struct Handle: View {
        let divider: TerminalSplitDivider
        let onResize: (CGFloat) -> Void
        @State private var startRatio: CGFloat?
        @State private var isHovered = false

        private var isColumns: Bool { divider.axis == .columns }

        var body: some View {
            Color.clear
                .contentShape(Rectangle())
                .overlay {
                    Capsule()
                        .fill(Color.primary.opacity(isHovered || startRatio != nil ? 0.3 : 0))
                        .frame(width: isColumns ? 3 : 36, height: isColumns ? 36 : 3)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        (isColumns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    } else {
                        NSCursor.pop()
                    }
                }
                // The handle moves during the drag; measure in a fixed space so its own
                // movement cannot feed back into the next ratio.
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startRatio == nil { startRatio = divider.ratio }
                        guard divider.extent > 0 else { return }
                        let distance = isColumns ? value.translation.width : value.translation.height
                        onResize((startRatio ?? divider.ratio) + distance / divider.extent)
                    }
                    .onEnded { _ in startRatio = nil })
                .simultaneousGesture(TapGesture(count: 2).onEnded { onResize(0.5) })
                .accessibilityLabel("Resize panes")
        }
    }
}
