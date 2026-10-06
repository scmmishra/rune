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
                card(level)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // Spelled out step by step: as one expression, Xcode 26.6 cannot type-check it in time.
    private func card(_ level: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
        let sideInset: CGFloat = Self.inset * CGFloat(level)
        let width: CGFloat = max(0, area.width - sideInset * 2)
        // Only the top edge shows; the rest lies under the zoomed pane.
        let height: CGFloat = Self.peek + WorkspaceMetrics.panelRadius * 2
        let x: CGFloat = area.minX + sideInset
        let y: CGFloat = area.minY + Self.peek * CGFloat(depth - level)
        // Cards further back sit in more shade.
        let shade: Double = 0.08 * Double(level)
        return shape.fill(TerminalSurface.color)
            .overlay { shape.fill(Color.black.opacity(shade)) }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}
