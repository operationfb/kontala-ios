// A screen view's scroll depth: the deepest point its visitor reached,
// measured against the screen's height, by the tag's rules
// (tag/plugins/scroll/depth.ts) and the Flutter SDK's (scroll/depth.dart).
// Pure, so every case is a row of sdk/testdata/vectors.json.
//
// THE DEEPEST POINT AND ITS HEIGHT MOVE TOGETHER, AND ONLY ON A STRICTLY
// DEEPER READING; THE HEIGHT A DEPTH IS MEASURED AGAINST IS THE LARGER OF THAT
// AND THE LATEST. A list built lazily grows under a visitor who never scrolls,
// and is measured against its grown height, as a web page that loads more is.

/// One reading of a scroller, in points.
package struct Reading: Equatable {
    /// The bottom edge of what is visible, from the top of the content.
    package var bottom: Double
    /// The content's full height.
    package var height: Double
    /// The visible height.
    package var viewport: Double

    package init(_ bottom: Double, _ height: Double, _ viewport: Double) {
        self.bottom = bottom
        self.height = height
        self.viewport = viewport
    }
}

/// A depth as a row states it.
package struct Measured: Equatable {
    package var depthPx: Int64
    package var heightPx: Int64
    package var viewportPx: Int64

    package init(_ depthPx: Int64, _ heightPx: Int64, _ viewportPx: Int64) {
        self.depthPx = depthPx
        self.heightPx = heightPx
        self.viewportPx = viewportPx
    }

    package var depthPct: Int64 { depthPercent(depthPx, heightPx) }
}

/// How close to the end counts as the end: fractional offsets would leave a screen read to its end at 99%.
private let bottomSlack: Int64 = 2

/// The largest height or offset a reading keeps, as the collector clamps.
private let maxPixels: Int64 = 10_000_000

/// A view's depth so far.
package final class Depth {
    package private(set) var readings = 0

    private var deepest: Int64 = 0
    private var heightAtDeepest: Int64 = 0
    private var viewportAtDeepest: Int64 = 0
    private var latestHeight: Int64 = 0

    package init() {}

    /// Takes a reading in. One that is not a number says nothing.
    package func record(_ r: Reading) {
        if !r.bottom.isFinite || !r.height.isFinite { return }
        let height = whole(r.height, 1)
        var bottom = whole(r.bottom, 0)
        if bottom > height { bottom = height }
        if height - bottom <= bottomSlack { bottom = height }
        if readings == 0 || bottom > deepest {
            deepest = bottom
            heightAtDeepest = height
            viewportAtDeepest = whole(r.viewport, 0)
        }
        latestHeight = height
        readings += 1
    }

    /// The depth as a row states it, or nil before the first reading.
    package func measure() -> Measured? {
        if readings == 0 { return nil }
        let height = heightAtDeepest > latestHeight ? heightAtDeepest : latestHeight
        return Measured(deepest, height, viewportAtDeepest)
    }
}

/// How far down its content a depth reached, in whole percent, rounded half up and never past 100:
/// collector/scroll.DepthPct, in the same float operations.
package func depthPercent(_ px: Int64, _ height: Int64) -> Int64 {
    if height <= 0 || px <= 0 { return 0 }
    let pct = Int64((100.0 * Double(px) / Double(height) + 0.5).rounded(.down))
    return pct > 100 ? 100 : pct
}

/// Whether a depth says more than the row last sent for it: deeper, or a larger share of content that shrank.
package func deeper(_ now: Measured, _ sent: Measured?) -> Bool {
    guard let s = sent else { return true }
    return now.depthPx > s.depthPx || now.depthPct > s.depthPct
}

/// [v] rounded half away from zero, as Dart's `round()`, and held to [min, maxPixels].
private func whole(_ v: Double, _ min: Int64) -> Int64 {
    if !v.isFinite { return min }
    let r = v < 0 ? -(-v + 0.5).rounded(.down) : (v + 0.5).rounded(.down)
    if r < Double(min) { return min }
    if r > Double(maxPixels) { return maxPixels }
    return Int64(r)
}
