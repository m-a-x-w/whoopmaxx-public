import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SignalLabMathTests: XCTestCase {

    func testShortWindowsReadRaw() {
        XCTAssertEqual(SignalLabMath.hrRead(windowSeconds: 60), .raw(limit: SignalLabMath.hrRawLimit))
        XCTAssertEqual(SignalLabMath.hrRead(windowSeconds: SignalLabMath.hrRawWindowSeconds),
                       .raw(limit: SignalLabMath.hrRawLimit))
    }

    func testLongWindowsBucket() {
        guard case .buckets(let secs, _) = SignalLabMath.hrRead(windowSeconds: 86_400) else {
            return XCTFail("a day must bucket")
        }
        XCTAssertGreaterThan(secs, 1)
    }

    func testBucketWidthFitsTheBudgetForEveryWindowTheLadderCanServe() {
        for w in [3601, 7200, 86_400, 604_800, 2_592_000] {
            let b = SignalLabMath.bucketSeconds(windowSeconds: w)
            let points = (w + b - 1) / b
            XCTAssertLessThanOrEqual(points, SignalLabMath.maxDrawPoints, "window \(w)")
        }
    }

    func testAYearFallsBackToTheWidestBucketAndOverrunsTheBudget() {
        // Pinned as a known limit rather than left to be discovered. The ladder stops at an hour
        // because widening it further would merge separate nights into one bar, which is a worse
        // answer than drawing more points than intended.
        let b = SignalLabMath.bucketSeconds(windowSeconds: 31_536_000)
        XCTAssertEqual(b, 3600, "the widest rung")
        XCTAssertGreaterThan((31_536_000 + b - 1) / b, SignalLabMath.maxDrawPoints)
    }

    func testBucketWidthIsStableForTheSameWindow() {
        // A width that drifted with the data would redraw the same range differently.
        XCTAssertEqual(SignalLabMath.bucketSeconds(windowSeconds: 86_400),
                       SignalLabMath.bucketSeconds(windowSeconds: 86_400))
    }

    func testBucketWidthIsMonotonicInWindow() {
        var last = 0
        for w in [7200, 86_400, 604_800, 2_592_000] {
            let b = SignalLabMath.bucketSeconds(windowSeconds: w)
            XCTAssertGreaterThanOrEqual(b, last)
            last = b
        }
    }

    func testRawChannelLimitIsCappedButNeverBelowTwo() {
        XCTAssertEqual(SignalLabMath.rawChannelLimit(windowSeconds: 10, nativeHz: 0), 2)
        XCTAssertEqual(SignalLabMath.rawChannelLimit(windowSeconds: 60, nativeHz: 1), 62)
        XCTAssertEqual(SignalLabMath.rawChannelLimit(windowSeconds: 86_400, nativeHz: 100),
                       SignalLabMath.rawChannelHardCap)
    }

    func testDecimateKeepsBothEndpoints() {
        // The endpoints are what make the drawn range match the requested one.
        let xs = Array(0..<10_000)
        let out = SignalLabMath.decimate(xs, to: 100)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 9999)
        XCTAssertLessThanOrEqual(out.count, 100)
    }

    func testDecimateLeavesShortSeriesAlone() {
        let xs = Array(0..<50)
        XCTAssertEqual(SignalLabMath.decimate(xs, to: 100), xs)
    }

    func testDecimatePreservesOrderAndUniqueness() {
        let out = SignalLabMath.decimate(Array(0..<1000), to: 37)
        XCTAssertEqual(out, out.sorted())
        XCTAssertEqual(out.count, Set(out).count)
    }

    func testGravityUnits() {
        XCTAssertEqual(SignalLabMath.gravityValue(g: 1, unit: .physical), 1)
        XCTAssertEqual(SignalLabMath.gravityValue(g: 1, unit: .raw), SignalLabMath.gravityI16PerG)
        XCTAssertEqual(SignalLabMath.gravityMagnitude(x: 0, y: 0, z: 1, unit: .physical), 1, accuracy: 1e-12)
        XCTAssertEqual(SignalLabMath.gravityMagnitude(x: 3, y: 4, z: 0, unit: .physical), 5, accuracy: 1e-12)
    }

    func testRawSkinTempIsTheCountItself() {
        // Raw is the honest rendering for a channel whose conversion is disputed, not a debug mode.
        XCTAssertEqual(SignalLabMath.skinTempValue(raw: 830, family: .whoop4, unit: .raw), 830)
        XCTAssertEqual(SignalLabMath.skinTempValue(raw: 3057, family: .whoop5, unit: .physical), 30.57, accuracy: 1e-9)
    }

    func testInterpolationBetweenSamples() {
        let s = [SignalLabMath.ScopeSample(t: 0, v: 0), SignalLabMath.ScopeSample(t: 10, v: 100)]
        XCTAssertEqual(SignalLabMath.interpolatedValue(at: 5, in: s)!, 50, accuracy: 1e-9)
        XCTAssertEqual(SignalLabMath.interpolatedValue(at: 0, in: s)!, 0, accuracy: 1e-9)
        XCTAssertEqual(SignalLabMath.interpolatedValue(at: 10, in: s)!, 100, accuracy: 1e-9)
    }

    func testOutsideTheSeriesReadsAsNoDataNotAFlatLine() {
        // Clamping to the last value is indistinguishable from a real steady reading.
        let s = [SignalLabMath.ScopeSample(t: 0, v: 5), SignalLabMath.ScopeSample(t: 10, v: 9)]
        XCTAssertNil(SignalLabMath.interpolatedValue(at: -1, in: s))
        XCTAssertNil(SignalLabMath.interpolatedValue(at: 11, in: s))
        XCTAssertNil(SignalLabMath.interpolatedValue(at: 0, in: []))
    }

    func testHoldDoesNotInventIntermediateStates() {
        // A stage or a battery reading has no meaningful value between samples.
        let s = [SignalLabMath.ScopeSample(t: 0, v: 1), SignalLabMath.ScopeSample(t: 10, v: 2)]
        XCTAssertEqual(SignalLabMath.holdValue(at: 5, in: s), 1)
        XCTAssertEqual(SignalLabMath.holdValue(at: 10, in: s), 2)
        XCTAssertEqual(SignalLabMath.holdValue(at: 99, in: s), 2, "held past the end")
        XCTAssertNil(SignalLabMath.holdValue(at: -1, in: s), "but never before the first")
    }

    func testLookupOnALongSeriesIsCorrectAtEveryPoint() {
        let s = (0..<1000).map { SignalLabMath.ScopeSample(t: Double($0), v: Double($0) * 2) }
        for t in stride(from: 0.0, to: 999.0, by: 97.0) {
            XCTAssertEqual(SignalLabMath.interpolatedValue(at: t, in: s)!, t * 2, accuracy: 1e-9)
        }
    }
}
