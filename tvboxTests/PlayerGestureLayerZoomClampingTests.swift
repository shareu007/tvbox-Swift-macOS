#if os(iOS)
import Testing
import CoreGraphics
@testable import TVBox

/// Property 6: Pinch zoom clamping invariant
/// For any scale s > 0, clampZoom returns a value in [1.0, 3.0]
///
/// **Validates: Requirements 5.2, 5.3**

@Suite("Property 6: Pinch zoom clamping invariant")
struct PlayerGestureLayerZoomClampingTests {

    // MARK: - Property Test: Default bounds [1.0, 3.0]

    /// Property: For any positive scale, clampZoom with default bounds always returns a value in [1.0, 3.0]
    @Test("clampZoom clamps to [1.0, 3.0] for various positive scales", arguments: [
        // Boundary values
        CGFloat(0.001),    // very small positive
        CGFloat(0.5),      // below min
        CGFloat(0.99),     // just below min
        CGFloat(1.0),      // exactly min
        CGFloat(1.001),    // just above min
        CGFloat(1.5),      // mid-range
        CGFloat(2.0),      // mid-range
        CGFloat(2.5),      // mid-range
        CGFloat(2.99),     // just below max
        CGFloat(3.0),      // exactly max
        CGFloat(3.001),    // just above max
        CGFloat(3.5),      // above max
        CGFloat(5.0),      // well above max
        CGFloat(10.0),     // far above max
        CGFloat(100.0),    // extreme above max
        CGFloat(1000.0),   // very extreme
        CGFloat(0.0001),   // near-zero positive
    ])
    func clampZoomDefaultBounds(scale: CGFloat) {
        let result = PlayerGestureLayer.clampZoom(scale: scale)
        #expect(result >= 1.0, "clampZoom(\(scale)) = \(result) should be >= 1.0")
        #expect(result <= 3.0, "clampZoom(\(scale)) = \(result) should be <= 3.0")
    }

    // MARK: - Property Test: Custom bounds

    /// Property: For any positive scale and valid custom bounds, clampZoom returns a value in [minZoom, maxZoom]
    @Test("clampZoom respects custom min/max bounds", arguments: [
        (CGFloat(0.5), CGFloat(0.5), CGFloat(2.0)),   // scale below custom min
        (CGFloat(1.0), CGFloat(0.5), CGFloat(2.0)),   // scale within custom range
        (CGFloat(2.5), CGFloat(0.5), CGFloat(2.0)),   // scale above custom max
        (CGFloat(0.1), CGFloat(0.2), CGFloat(5.0)),   // scale below wide range min
        (CGFloat(3.0), CGFloat(0.2), CGFloat(5.0)),   // scale within wide range
        (CGFloat(6.0), CGFloat(0.2), CGFloat(5.0)),   // scale above wide range max
        (CGFloat(2.0), CGFloat(2.0), CGFloat(2.0)),   // min equals max
        (CGFloat(1.0), CGFloat(2.0), CGFloat(2.0)),   // below when min equals max
        (CGFloat(3.0), CGFloat(2.0), CGFloat(2.0)),   // above when min equals max
        (CGFloat(0.01), CGFloat(0.5), CGFloat(10.0)), // very small scale, wide range
        (CGFloat(100.0), CGFloat(0.5), CGFloat(10.0)), // very large scale, wide range
    ])
    func clampZoomCustomBounds(scale: CGFloat, minZoom: CGFloat, maxZoom: CGFloat) {
        let result = PlayerGestureLayer.clampZoom(scale: scale, minZoom: minZoom, maxZoom: maxZoom)
        #expect(result >= minZoom, "clampZoom(\(scale), min: \(minZoom), max: \(maxZoom)) = \(result) should be >= \(minZoom)")
        #expect(result <= maxZoom, "clampZoom(\(scale), min: \(minZoom), max: \(maxZoom)) = \(result) should be <= \(maxZoom)")
    }

    // MARK: - Property Test: Idempotency

    /// Property: Clamping an already-clamped value should return the same value
    @Test("clampZoom is idempotent - clamping twice gives same result", arguments: [
        CGFloat(0.5),
        CGFloat(1.0),
        CGFloat(2.0),
        CGFloat(3.0),
        CGFloat(5.0),
    ])
    func clampZoomIdempotent(scale: CGFloat) {
        let firstClamp = PlayerGestureLayer.clampZoom(scale: scale)
        let secondClamp = PlayerGestureLayer.clampZoom(scale: firstClamp)
        #expect(firstClamp == secondClamp, "clampZoom should be idempotent: clampZoom(clampZoom(\(scale))) = \(secondClamp) != clampZoom(\(scale)) = \(firstClamp)")
    }

    // MARK: - Property Test: Values within range are unchanged

    /// Property: If scale is already within [minZoom, maxZoom], it should be returned unchanged
    @Test("clampZoom preserves values already within bounds", arguments: [
        CGFloat(1.0),
        CGFloat(1.5),
        CGFloat(2.0),
        CGFloat(2.5),
        CGFloat(3.0),
    ])
    func clampZoomPreservesValidValues(scale: CGFloat) {
        let result = PlayerGestureLayer.clampZoom(scale: scale)
        #expect(result == scale, "clampZoom(\(scale)) should return \(scale) unchanged, got \(result)")
    }

    // MARK: - Randomized Property Test

    /// Property: Randomized test with many generated values to approximate property-based testing
    @Test("clampZoom satisfies clamping invariant for generated positive scales")
    func clampZoomRandomizedProperty() {
        // Generate a wide range of positive scale values to test the property
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            // Generate random positive CGFloat values across different magnitudes
            let magnitude = CGFloat.random(in: 0..<4, using: &rng) // 0 to 4 for exponent
            let scale = CGFloat(pow(10.0, Double(magnitude))) * CGFloat.random(in: 0.001..<1.0, using: &rng)

            let result = PlayerGestureLayer.clampZoom(scale: scale)
            #expect(result >= 1.0, "Random scale \(scale): result \(result) should be >= 1.0")
            #expect(result <= 3.0, "Random scale \(scale): result \(result) should be <= 3.0")
        }
    }

    /// Property: Randomized test with custom bounds
    @Test("clampZoom satisfies clamping invariant for generated scales with custom bounds")
    func clampZoomRandomizedCustomBounds() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            // Generate random bounds where minZoom <= maxZoom
            let minZoom = CGFloat.random(in: 0.1..<5.0, using: &rng)
            let maxZoom = minZoom + CGFloat.random(in: 0.0..<10.0, using: &rng)
            let scale = CGFloat.random(in: 0.001..<20.0, using: &rng)

            let result = PlayerGestureLayer.clampZoom(scale: scale, minZoom: minZoom, maxZoom: maxZoom)
            #expect(result >= minZoom, "scale=\(scale), min=\(minZoom), max=\(maxZoom): result \(result) should be >= \(minZoom)")
            #expect(result <= maxZoom, "scale=\(scale), min=\(minZoom), max=\(maxZoom): result \(result) should be <= \(maxZoom)")
        }
    }
}
#endif
