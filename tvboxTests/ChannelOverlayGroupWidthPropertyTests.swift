#if os(iOS)
import Testing
import CoreGraphics
@testable import TVBox

/// Property 7: Channel overlay group width is proportional
/// For any screen width w > 0, computeGroupWidth(screenWidth: w) returns a value in [w * 0.30, w * 0.35]
///
/// **Validates: Requirements 8.3, 8.4**

@Suite("Property 7: Channel overlay group width is proportional")
struct ChannelOverlayGroupWidthPropertyTests {

    // MARK: - Parameterized tests with representative screen widths

    /// Common iOS device screen widths and edge cases
    static let screenWidths: [CGFloat] = [
        // Small values
        1.0, 10.0, 50.0,
        // iPhone SE / small phones
        320.0, 375.0,
        // iPhone standard
        390.0, 393.0,
        // iPhone Plus / Max
        414.0, 428.0, 430.0,
        // iPad
        744.0, 768.0, 810.0, 834.0, 1024.0, 1194.0,
        // Large values
        1366.0, 2048.0, 5000.0
    ]

    @Test("computeGroupWidth returns value in [w*0.30, w*0.35] for common screen widths",
          arguments: screenWidths)
    func groupWidthInProportionalRange(screenWidth: CGFloat) {
        let result = ChannelOverlayView.computeGroupWidth(screenWidth: screenWidth)
        let lowerBound = screenWidth * 0.30
        let upperBound = screenWidth * 0.35

        #expect(result >= lowerBound,
                "computeGroupWidth(\(screenWidth)) = \(result) should be >= \(lowerBound) (w * 0.30)")
        #expect(result <= upperBound,
                "computeGroupWidth(\(screenWidth)) = \(result) should be <= \(upperBound) (w * 0.35)")
    }

    // MARK: - Randomized property test

    @Test("computeGroupWidth satisfies proportional invariant for random positive widths")
    func groupWidthProportionalRandomized() {
        for _ in 0..<1000 {
            // Generate random positive screen widths across different magnitudes
            let screenWidth = CGFloat.random(in: 0.001...10000.0)

            let result = ChannelOverlayView.computeGroupWidth(screenWidth: screenWidth)
            let lowerBound = screenWidth * 0.30
            let upperBound = screenWidth * 0.35

            #expect(result >= lowerBound,
                    "Random width \(screenWidth): result \(result) should be >= \(lowerBound)")
            #expect(result <= upperBound,
                    "Random width \(screenWidth): result \(result) should be <= \(upperBound)")
        }
    }

    // MARK: - Proportionality: result scales linearly with screen width

    @Test("computeGroupWidth scales linearly with screen width")
    func groupWidthScalesLinearly() {
        let widths: [CGFloat] = [100.0, 200.0, 400.0, 800.0]

        for i in 0..<(widths.count - 1) {
            let w1 = widths[i]
            let w2 = widths[i + 1]
            let result1 = ChannelOverlayView.computeGroupWidth(screenWidth: w1)
            let result2 = ChannelOverlayView.computeGroupWidth(screenWidth: w2)

            let ratio = w2 / w1
            let resultRatio = result2 / result1

            // The ratio of results should equal the ratio of inputs (linear scaling)
            #expect(abs(resultRatio - ratio) < 0.001,
                    "Group width should scale linearly: ratio of widths = \(ratio), ratio of results = \(resultRatio)")
        }
    }

    // MARK: - Edge case: very small positive widths

    @Test("computeGroupWidth handles very small positive widths", arguments: [
        CGFloat(0.001),
        CGFloat(0.01),
        CGFloat(0.1),
        CGFloat(0.5),
    ])
    func groupWidthSmallPositiveWidths(screenWidth: CGFloat) {
        let result = ChannelOverlayView.computeGroupWidth(screenWidth: screenWidth)
        let lowerBound = screenWidth * 0.30
        let upperBound = screenWidth * 0.35

        #expect(result >= lowerBound,
                "Small width \(screenWidth): result \(result) should be >= \(lowerBound)")
        #expect(result <= upperBound,
                "Small width \(screenWidth): result \(result) should be <= \(upperBound)")
    }

    // MARK: - Edge case: very large widths

    @Test("computeGroupWidth handles very large widths", arguments: [
        CGFloat(10000.0),
        CGFloat(50000.0),
        CGFloat(100000.0),
    ])
    func groupWidthLargeWidths(screenWidth: CGFloat) {
        let result = ChannelOverlayView.computeGroupWidth(screenWidth: screenWidth)
        let lowerBound = screenWidth * 0.30
        let upperBound = screenWidth * 0.35

        #expect(result >= lowerBound,
                "Large width \(screenWidth): result \(result) should be >= \(lowerBound)")
        #expect(result <= upperBound,
                "Large width \(screenWidth): result \(result) should be <= \(upperBound)")
    }

    // MARK: - Result is always positive for positive input

    @Test("computeGroupWidth always returns positive value for positive input")
    func groupWidthAlwaysPositive() {
        for _ in 0..<500 {
            let screenWidth = CGFloat.random(in: 0.001...10000.0)
            let result = ChannelOverlayView.computeGroupWidth(screenWidth: screenWidth)
            #expect(result > 0, "computeGroupWidth(\(screenWidth)) = \(result) should be > 0")
        }
    }
}
#endif
