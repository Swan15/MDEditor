import XCTest
@testable import MDEditor

/// ColumnLayout math: below/at/above the cap, inset centering, the base
/// inset floor, degenerate widths and the limit-off passthrough.
final class ColumnLayoutTests: XCTestCase {
    // MARK: - Limit off

    /// Nil cap is the pre-limit behavior: full width minus the base insets.
    func testNoCapFillsWidth() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 1000, maxWidth: nil)
        XCTAssertEqual(layout.containerWidth, 960, accuracy: 0.001)
        XCTAssertEqual(layout.horizontalInset, ColumnLayout.baseInset, accuracy: 0.001)
    }

    // MARK: - Below / at / above the cap

    /// Below the cap the column fills the width (base insets only).
    func testBelowCapFillsWidth() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 500, maxWidth: 760)
        XCTAssertEqual(layout.containerWidth, 460, accuracy: 0.001)
        XCTAssertEqual(layout.horizontalInset, 20, accuracy: 0.001)
    }

    /// Exactly at the boundary (viewWidth = cap + 2 × base inset) the column
    /// reaches the cap without any centering yet.
    func testAtCapIsTheBoundary() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 800, maxWidth: 760)
        XCTAssertEqual(layout.containerWidth, 760, accuracy: 0.001)
        XCTAssertEqual(layout.horizontalInset, 20, accuracy: 0.001)
    }

    /// Above the cap the container clamps and the leftover splits evenly.
    func testAboveCapCenters() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 1200, maxWidth: 760)
        XCTAssertEqual(layout.containerWidth, 760, accuracy: 0.001)
        XCTAssertEqual(layout.horizontalInset, 220, accuracy: 0.001)
    }

    /// Centering is exact: the inset is half the slack for any width.
    func testCenteringSplitsTheSlackEvenly() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 1234.5, maxWidth: 700)
        XCTAssertEqual(layout.containerWidth, 700, accuracy: 0.001)
        XCTAssertEqual(layout.horizontalInset, (1234.5 - 700) / 2, accuracy: 0.001)
    }

    // MARK: - Floors and degenerate input

    /// A window narrower than two base insets still gets the base inset and
    /// a non-zero container (a zero-width container wraps every character).
    func testInsetFloorAndContainerFloor() {
        let layout = ColumnLayout.containerWidthAndInset(viewWidth: 30, maxWidth: 760)
        XCTAssertEqual(layout.horizontalInset, ColumnLayout.baseInset, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(layout.containerWidth, 1)
    }

    /// A custom base inset flows through to both branches.
    func testCustomBaseInset() {
        let capped = ColumnLayout.containerWidthAndInset(viewWidth: 1000, maxWidth: 500, baseInset: 10)
        XCTAssertEqual(capped.containerWidth, 500, accuracy: 0.001)
        XCTAssertEqual(capped.horizontalInset, 250, accuracy: 0.001)
        let belowCap = ColumnLayout.containerWidthAndInset(viewWidth: 300, maxWidth: 500, baseInset: 10)
        XCTAssertEqual(belowCap.containerWidth, 280, accuracy: 0.001)
        XCTAssertEqual(belowCap.horizontalInset, 10, accuracy: 0.001)
    }
}
