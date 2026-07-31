import CoreGraphics

/// Word-like maximum-width text column (Settings ▸ Appearance).
///
/// Below the cap the column fills the editor exactly as it always has;
/// above it the column clamps to the cap and the leftover space is split
/// evenly on both sides, centering the column (the iA Writer / Typora
/// approach). Pure math, no views — `MDTextView` applies the result on
/// every layout pass, so the whole policy is testable headless.
enum ColumnLayout {
    /// The historical horizontal padding on each side of the text
    /// (`MarkdownTextView`'s base inset); also the floor when centering, so
    /// a narrow window never pinches the text against the window edge.
    static let baseInset: CGFloat = 20

    /// Container width and horizontal inset for a text view of `viewWidth`.
    ///
    /// `maxWidth` nil means no cap: the column fills the view minus the
    /// base insets (the pre-limit behavior). With a cap the container is
    /// `min(available, maxWidth)` and the inset centers it, never dropping
    /// below `baseInset`. The container is floored at 1 pt: a zero-width
    /// container makes TextKit wrap every character onto its own line.
    static func containerWidthAndInset(
        viewWidth: CGFloat,
        maxWidth: CGFloat?,
        baseInset: CGFloat = ColumnLayout.baseInset
    ) -> (containerWidth: CGFloat, horizontalInset: CGFloat) {
        let base = max(baseInset, 0)
        let available = max(viewWidth - base * 2, 0)
        guard let maxWidth else { return (available, base) }
        let containerWidth = max(min(available, maxWidth), 1)
        let inset = max((viewWidth - containerWidth) / 2, base)
        return (containerWidth, inset)
    }
}
