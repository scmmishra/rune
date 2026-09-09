import CoreGraphics

/// Geometry shared by the workspace's three columns.
///
/// The file tree, terminal and Git panel each used to carry their own insets, so
/// section labels and the first row of every column landed on different lines.
/// These constants keep them on one grid.
enum WorkspaceMetrics {
    /// Corner radius of a column panel.
    static let panelRadius: CGFloat = 14
    /// Space between a panel's edge and its content.
    static let panelInset: CGFloat = 12
    /// Half of `gap` minus the resizer that sits between two columns.
    static let panelGap: CGFloat = (gap - 4) / 2
    /// Corner radius of a group card stacked inside a sidebar column.
    static let groupRadius: CGFloat = 10
    /// Gap between stacked group cards.
    static let groupGap: CGFloat = gap

    /// Horizontal inset for a column's own content: section labels and headers sit here.
    /// Matches `panelInset` so labels line up with the panel edge that now frames them.
    static let columnInset: CGFloat = panelInset
    /// Corner radius for selectable rows in the sidebars.
    static let rowRadius: CGFloat = 5
    /// Height of the band holding each column's first control.
    static let headerHeight: CGFloat = 28
    /// Space between that band and the content below it.
    static let headerGap: CGFloat = 8

    /// Margin around the whole workspace: equal on every side, except that a windowed
    /// title bar needs room for the traffic lights, which sit where the top-left panel
    /// corner would otherwise be. Full screen has no such constraint.
    /// One gap value for the whole workspace: outside the columns, between them, and
    /// between the cards stacked inside them.
    static let outerMargin: CGFloat = gap
    static let gap: CGFloat = 8

    static func titleBarClearance(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? outerMargin : 38
    }
}
