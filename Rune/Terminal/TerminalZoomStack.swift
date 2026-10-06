import SwiftUI

/// The edges of the cards under a zoomed pane, so it reads as the top of a stack and not
/// as the tab's only terminal.
struct TerminalZoomStack: View {
    /// The room the tab's panes share.
    let area: CGRect
    /// How many cards show under the zoomed pane.
    let depth: Int

    /// How much of each card shows above the one in front of it.
    static let peek: CGFloat = 6
    /// How much narrower each card is, per side, than the one in front of it.
    private static let inset: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            // The card furthest back is drawn first, highest and narrowest.
            ForEach((1...max(1, depth)).reversed(), id: \.self) { level in
                let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
                shape.fill(TerminalSurface.color)
                    // Cards further back sit in more shade.
                    .overlay { shape.fill(Color.black.opacity(0.08 * Double(level))) }
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
                    // Only the top edge shows; the rest lies under the zoomed pane.
                    .frame(width: max(0, area.width - Self.inset * 2 * CGFloat(level)),
                           height: Self.peek + WorkspaceMetrics.panelRadius * 2)
                    .offset(x: area.minX + Self.inset * CGFloat(level),
                            y: area.minY + Self.peek * CGFloat(depth - level))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
