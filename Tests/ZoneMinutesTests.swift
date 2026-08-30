import XCTest
import StrapProtocol
@testable import whoopmaxx

/// Regression pins for `ZoneModel.minutes` — the Core adapter over the vendored
/// `StrapAnalytics.HRZones` time-in-zone engine, expressed as Z1…Z5 MINUTES. Each sample is credited
/// the duration until the next reading, capped at the median inter-sample gap so one wall-clock hole
/// can't blow up a bucket; the tail sample gets the median gap; below-Z1 time is dropped.
/// Age 30 → Tanaka HRmax 208 − 0.7·30 = 187.
final class ZoneMinutesTests: XCTestCase {

    private let age = 30.0                 // HRmax = 187; edges at 0.5/0.6/0.7/0.8/0.9/1.0 · 187
    private func hr(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func assertClose(_ a: [Double], _ b: [Double], accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "array length", file: file, line: line)
        for i in a.indices { XCTAssertEqual(a[i], b[i], accuracy: accuracy, "index \(i)", file: file, line: line) }
    }

    /// Empty stream → all-zero, five buckets.
    func testEmptyStreamIsAllZero() {
        XCTAssertEqual(ZoneModel.minutes([], age: age), [0, 0, 0, 0, 0])
    }

    /// A single sample credits only the fallback tail (~1s) to its zone — nothing else to bound it.
    /// bpm 140 sits in Z3 (index 2): 130.9 ≤ 140 < 149.6.
    func testSingleSampleCreditsOnlyTailSecond() {
        let m = ZoneModel.minutes([hr(0, 140)], age: age)
        XCTAssertEqual(m[2], 1.0 / 60.0, accuracy: 1e-9)   // 1 second → 1/60 min
        XCTAssertEqual(m[0] + m[1] + m[3] + m[4], 0, accuracy: 1e-12)
    }

    /// Two Z3 samples 10s apart → ~20s in Z3 (first sample credited the 10s gap, tail sample the 10s
    /// median). Total 20s = 20/60 min.
    func testTwoSamplesTenSecondsApart() {
        let m = ZoneModel.minutes([hr(0, 140), hr(10, 140)], age: age)
        XCTAssertEqual(m[2], 20.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(m[0] + m[1] + m[3] + m[4], 0, accuracy: 1e-12)
    }

    /// A 4000s wall-clock hole credits the pre-hole sample only the median tail (2s here), NOT 4000s —
    /// the cap is what stops one gap from dominating the bucket. Five Z3 samples → 5·2s = 10s total.
    /// (The 4000s gap is also excluded from the median itself: only (0, 300 s) gaps are plausible.)
    func testWallClockHoleIsCappedAtMedianTail() {
        let samples = [hr(0, 140), hr(2, 140), hr(4, 140), hr(6, 140), hr(4006, 140)]
        let m = ZoneModel.minutes(samples, age: age)
        XCTAssertEqual(m[2], 10.0 / 60.0, accuracy: 1e-9)
        XCTAssertLessThan(m[2], 1.0)   // nowhere near 4000/60 ≈ 66.7 min if the hole were credited whole
    }

    /// A bpm below Z1 (80 bpm → 80/187 ≈ 0.43 < 0.50) contributes zero — its time is dropped while the
    /// Z3 sample after it is still credited the tail second.
    func testBelowZ1ContributesZero() {
        let m = ZoneModel.minutes([hr(0, 80), hr(10, 140)], age: age)
        assertClose(m, [0, 0, 10.0 / 60.0, 0, 0])
    }

    /// A lone below-Z1 sample yields an all-zero result.
    func testSingleBelowZ1IsAllZero() {
        let m = ZoneModel.minutes([hr(0, 80)], age: age)
        XCTAssertEqual(m.reduce(0, +), 0, accuracy: 1e-12)
    }

    /// The age-30 Tanaka HRmax (187) fixes the Z4/Z5 boundary at 0.90·187 = 168.3 bpm. 168 → Z4 (index
    /// 3), 169 → Z5 (index 4). NOTE the caller `workoutZoneMinutes` substitutes age 30 whenever the
    /// profile age is ≤ 0, so this is the effective HRmax for an unknown-age user.
    func testTanakaHRmaxBoundaryAtAge30() {
        XCTAssertEqual(ZoneModel.minutes([hr(0, 168)], age: age)[3], 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(ZoneModel.minutes([hr(0, 169)], age: age)[4], 1.0 / 60.0, accuracy: 1e-9)
    }
}
