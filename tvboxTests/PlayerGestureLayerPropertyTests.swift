#if os(iOS)
import Testing
import CoreGraphics
@testable import TVBox

/// Property-based tests for PlayerGestureLayer pure computation functions.
/// These tests validate correctness properties across a wide range of inputs.

// MARK: - Property 3: Vertical gesture direction mapping preserves monotonicity

/// **Validates: Requirements 2.2, 3.2**
///
/// For any vertical translation `dy`, the computed adjustment delta SHALL be positive when
/// `dy < 0` (upward swipe) and negative when `dy > 0` (downward swipe), ensuring that
/// upward gestures always increase the controlled value and downward gestures always decrease it.

@Suite("Property 3: Vertical gesture direction mapping preserves monotonicity")
struct VerticalGestureMonotonicityPropertyTests {

    // Use a container width and threshold that ensure vertical gesture classification
    static let containerWidth: CGFloat = 400.0
    static let threshold: CGFloat = 10.0

    // MARK: - Parameterized tests with representative dy values

    /// Negative dy values (upward swipes) that exceed the threshold
    static let negativeDyValues: [CGFloat] = [
        -11.0, -20.0, -50.0, -100.0, -300.0, -500.0, -1000.0, -1500.0
    ]

    /// Positive dy values (downward swipes) that exceed the threshold
    static let positiveDyValues: [CGFloat] = [
        11.0, 20.0, 50.0, 100.0, 300.0, 500.0, 1000.0
    ]

    /// Start positions covering both left half (brightness) and right half (volume)
    static let startPositions: [CGFloat] = [0.0, 50.0, 100.0, 199.0, 200.0, 250.0, 350.0, 399.0]

    @Test("Upward swipe (negative dy) produces positive delta",
          arguments: negativeDyValues, startPositions)
    func upwardSwipeProducesPositiveDelta(dy: CGFloat, startX: CGFloat) {
        // Use dx = 0 to ensure vertical classification (|dy| > |dx|)
        let translation = CGSize(width: 0, height: dy)
        let result = PlayerGestureLayer.classifyGesture(
            startX: startX,
            containerWidth: Self.containerWidth,
            translation: translation,
            threshold: Self.threshold
        )

        switch result {
        case .adjustingBrightness(let delta):
            #expect(delta > 0,
                    "Upward swipe (dy=\(dy)) on left side should produce positive delta, got \(delta)")
        case .adjustingVolume(let delta):
            #expect(delta > 0,
                    "Upward swipe (dy=\(dy)) on right side should produce positive delta, got \(delta)")
        default:
            Issue.record("Expected brightness or volume adjustment for dy=\(dy), startX=\(startX), got \(result)")
        }
    }

    @Test("Downward swipe (positive dy) produces negative delta",
          arguments: positiveDyValues, startPositions)
    func downwardSwipeProducesNegativeDelta(dy: CGFloat, startX: CGFloat) {
        // Use dx = 0 to ensure vertical classification (|dy| > |dx|)
        let translation = CGSize(width: 0, height: dy)
        let result = PlayerGestureLayer.classifyGesture(
            startX: startX,
            containerWidth: Self.containerWidth,
            translation: translation,
            threshold: Self.threshold
        )

        switch result {
        case .adjustingBrightness(let delta):
            #expect(delta < 0,
                    "Downward swipe (dy=\(dy)) on left side should produce negative delta, got \(delta)")
        case .adjustingVolume(let delta):
            #expect(delta < 0,
                    "Downward swipe (dy=\(dy)) on right side should produce negative delta, got \(delta)")
        default:
            Issue.record("Expected brightness or volume adjustment for dy=\(dy), startX=\(startX), got \(result)")
        }
    }

    // MARK: - Randomized property test

    @Test("Monotonicity holds for random vertical translations")
    func monotonicityRandomized() {
        for _ in 0..<1000 {
            let startX = CGFloat.random(in: 0.0..<Self.containerWidth)
            // Generate dy that exceeds threshold (either positive or negative)
            let dyMagnitude = CGFloat.random(in: (Self.threshold + 1)...1000.0)
            let isUpward = Bool.random()
            let dy = isUpward ? -dyMagnitude : dyMagnitude

            // Use small dx to ensure vertical classification
            let dx = CGFloat.random(in: -Self.threshold...Self.threshold) * 0.5
            let translation = CGSize(width: dx, height: dy)

            let result = PlayerGestureLayer.classifyGesture(
                startX: startX,
                containerWidth: Self.containerWidth,
                translation: translation,
                threshold: Self.threshold
            )

            switch result {
            case .adjustingBrightness(let delta), .adjustingVolume(let delta):
                if dy < 0 {
                    #expect(delta > 0,
                            "Upward swipe (dy=\(dy)) should produce positive delta, got \(delta)")
                } else {
                    #expect(delta < 0,
                            "Downward swipe (dy=\(dy)) should produce negative delta, got \(delta)")
                }
            case .seeking:
                // If |dx| > |dy|, it classifies as seeking - this is acceptable
                // since we're testing the vertical case
                break
            case .none:
                // Below threshold - acceptable for edge cases
                break
            }
        }
    }

    // MARK: - Delta magnitude proportionality

    @Test("Larger vertical displacement produces larger absolute delta")
    func deltaMagnitudeProportional() {
        let startX: CGFloat = 100.0 // Left half for brightness

        let smallDy: CGFloat = -20.0
        let largeDy: CGFloat = -200.0

        let smallTranslation = CGSize(width: 0, height: smallDy)
        let largeTranslation = CGSize(width: 0, height: largeDy)

        let smallResult = PlayerGestureLayer.classifyGesture(
            startX: startX,
            containerWidth: Self.containerWidth,
            translation: smallTranslation,
            threshold: Self.threshold
        )
        let largeResult = PlayerGestureLayer.classifyGesture(
            startX: startX,
            containerWidth: Self.containerWidth,
            translation: largeTranslation,
            threshold: Self.threshold
        )

        if case .adjustingBrightness(let smallDelta) = smallResult,
           case .adjustingBrightness(let largeDelta) = largeResult {
            #expect(largeDelta > smallDelta,
                    "Larger upward swipe should produce larger positive delta: small=\(smallDelta), large=\(largeDelta)")
        } else {
            Issue.record("Expected brightness adjustments for both translations")
        }
    }

    // MARK: - Zero dy produces no vertical gesture

    @Test("Zero dy does not produce vertical adjustment")
    func zeroDyNoVerticalAdjustment() {
        let translation = CGSize(width: 0, height: 0)
        let result = PlayerGestureLayer.classifyGesture(
            startX: 100.0,
            containerWidth: Self.containerWidth,
            translation: translation,
            threshold: Self.threshold
        )
        #expect(result == .none,
                "Zero translation should produce .none, got \(result)")
    }
}

// MARK: - Property 4: Adjustment value clamping invariant

/// **Validates: Requirements 2.4, 3.4**
///
/// For any currentValue in [0, 1] and any delta (positive, negative, very large, very small),
/// the result of `clampAdjustment(currentValue:delta:)` must always be in [0.0, 1.0].

@Suite("Property 4: Adjustment value clamping invariant")
struct AdjustmentClampingPropertyTests {

    // MARK: - Parameterized boundary values

    static let boundaryCurrentValues: [CGFloat] = [0.0, 0.001, 0.25, 0.5, 0.75, 0.999, 1.0]
    static let boundaryDeltas: [CGFloat] = [
        -1000.0, -100.0, -10.0, -1.0, -0.5, -0.001,
        0.0,
        0.001, 0.5, 1.0, 10.0, 100.0, 1000.0
    ]

    @Test("Clamped result is always within [0, 1] for boundary values",
          arguments: boundaryCurrentValues, boundaryDeltas)
    func clampedResultInRange(currentValue: CGFloat, delta: CGFloat) {
        let result = PlayerGestureLayer.clampAdjustment(currentValue: currentValue, delta: delta)
        #expect(result >= 0.0, "Result \(result) should be >= 0.0 for currentValue=\(currentValue), delta=\(delta)")
        #expect(result <= 1.0, "Result \(result) should be <= 1.0 for currentValue=\(currentValue), delta=\(delta)")
    }

    // MARK: - Randomized property test

    @Test("Clamped result is always within [0, 1] for random inputs")
    func clampedResultInRangeRandomized() {
        // Generate many random test cases to approximate property-based testing
        for _ in 0..<1000 {
            let currentValue = CGFloat.random(in: 0.0...1.0)
            let delta = CGFloat.random(in: -1000.0...1000.0)

            let result = PlayerGestureLayer.clampAdjustment(currentValue: currentValue, delta: delta)
            #expect(result >= 0.0, "Result \(result) should be >= 0.0 for currentValue=\(currentValue), delta=\(delta)")
            #expect(result <= 1.0, "Result \(result) should be <= 1.0 for currentValue=\(currentValue), delta=\(delta)")
        }
    }

    // MARK: - Edge cases with extreme deltas

    @Test("Clamped result handles extreme positive deltas")
    func extremePositiveDeltas() {
        let extremeDeltas: [CGFloat] = [CGFloat.greatestFiniteMagnitude / 2, 1e10, 1e6]
        for delta in extremeDeltas {
            for currentValue in [0.0, 0.5, 1.0] as [CGFloat] {
                let result = PlayerGestureLayer.clampAdjustment(currentValue: currentValue, delta: delta)
                #expect(result >= 0.0 && result <= 1.0,
                        "Result \(result) out of range for currentValue=\(currentValue), delta=\(delta)")
            }
        }
    }

    @Test("Clamped result handles extreme negative deltas")
    func extremeNegativeDeltas() {
        let extremeDeltas: [CGFloat] = [-CGFloat.greatestFiniteMagnitude / 2, -1e10, -1e6]
        for delta in extremeDeltas {
            for currentValue in [0.0, 0.5, 1.0] as [CGFloat] {
                let result = PlayerGestureLayer.clampAdjustment(currentValue: currentValue, delta: delta)
                #expect(result >= 0.0 && result <= 1.0,
                        "Result \(result) out of range for currentValue=\(currentValue), delta=\(delta)")
            }
        }
    }

    // MARK: - Zero delta preserves value

    @Test("Zero delta preserves the current value",
          arguments: boundaryCurrentValues)
    func zeroDeltaPreservesValue(currentValue: CGFloat) {
        let result = PlayerGestureLayer.clampAdjustment(currentValue: currentValue, delta: 0.0)
        #expect(result == currentValue,
                "Zero delta should preserve value, got \(result) instead of \(currentValue)")
    }

    // MARK: - Idempotence at boundaries

    @Test("Result at lower bound stays at lower bound with negative delta")
    func lowerBoundIdempotence() {
        let result = PlayerGestureLayer.clampAdjustment(currentValue: 0.0, delta: -0.5)
        #expect(result == 0.0, "Should clamp to 0.0 at lower bound, got \(result)")
    }

    @Test("Result at upper bound stays at upper bound with positive delta")
    func upperBoundIdempotence() {
        let result = PlayerGestureLayer.clampAdjustment(currentValue: 1.0, delta: 0.5)
        #expect(result == 1.0, "Should clamp to 1.0 at upper bound, got \(result)")
    }
}
#endif
