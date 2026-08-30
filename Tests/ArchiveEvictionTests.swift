import XCTest
import StrapProtocol
@testable import whoopmaxx

/// `RawHistoryArchive.evictLines` had no coverage at all. It trimmed to EXACTLY the cap, so once the
/// 5 MB reject archive first filled, every later append was over again and took the full
/// read / evict / rewrite / fsync path — on the main actor, once per HISTORY_END chunk. The low-water
/// mark restores the plain append path for the next stretch of frames.
final class ArchiveEvictionTests: XCTestCase {

    /// One archived JSONL line whose stored frame carries `version` at the WHOOP-4 version index (5).
    private func line(version: Int, pad: Int = 40) -> String {
        var frame = [UInt8](repeating: 0, count: 6 + pad)
        frame[5] = UInt8(version)
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        return "{\"family\":\"whoop4\",\"frameHex\":\"\(hex)\"}\n"
    }

    private func bytes(_ lines: [String]) -> Int { lines.reduce(0) { $0 + $1.utf8.count } }

    func testUnderCapIsUntouched() {
        let lines = (0..<10).map { _ in line(version: 18) }
        let kept = RawHistoryArchive.evictLines(lines, maxBytes: 1_000_000, floor: 2)
        XCTAssertEqual(kept, lines, "nothing is evicted below the cap")
    }

    /// The regression: eviction must undershoot the cap so the fast append path can run again.
    func testEvictionUndershootsTheCapSoAppendsResume() {
        let lines = (0..<200).map { _ in line(version: 18) }
        let cap = bytes(lines) / 2

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: cap, floor: 2, headroom: cap / 4)

        XCTAssertLessThanOrEqual(bytes(kept), cap - cap / 4,
                                 "trimming to exactly the cap makes the very next append rewrite again")
        XCTAssertFalse(kept.isEmpty)
    }

    /// Eviction is oldest-first: the newest lines are the ones that survive.
    func testEvictionDropsOldestFirst() {
        let lines = (0..<50).map { _ in line(version: 18) }
        let cap = bytes(lines) / 2

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: cap, floor: 1)

        XCTAssertEqual(kept, Array(lines.suffix(kept.count)), "survivors must be the newest suffix")
    }

    /// The per-version floor is the whole point of the archive — a rare layout must never be evicted to
    /// make room for a common one, and the low-water mark must not weaken that.
    func testPerVersionFloorSurvivesAggressiveEviction() {
        // Two rare v19 lines at the very front (oldest = evicted first without the floor), then a flood.
        let rare = (0..<2).map { _ in line(version: 19) }
        let common = (0..<300).map { _ in line(version: 18) }
        let lines = rare + common

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: bytes(lines) / 10, floor: 2)

        XCTAssertEqual(kept.filter { $0 == rare[0] }.count, 2,
                       "the newest `floor` lines of a rare version are never evictable")
    }

    /// Degenerate case: everything is floor-protected, so eviction stops even while over cap rather than
    /// discarding a protected line.
    func testAllProtectedStopsOverCap() {
        let lines = (0..<4).map { _ in line(version: 18) }

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: 1, floor: 64)

        XCTAssertEqual(kept.count, 4, "the floor wins over the cap")
    }

    /// Headroom must never be able to over-trim a small injected cap into nothing.
    func testDefaultHeadroomScalesWithASmallCap() {
        let lines = (0..<100).map { _ in line(version: 18) }
        let cap = bytes(lines) / 2

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: cap, floor: 1)

        XCTAssertFalse(kept.isEmpty, "a 512KB headroom must not swallow a small test cap whole")
        XCTAssertGreaterThan(bytes(kept), cap / 2)
    }

    /// A line with no parseable frame gets NO floor slot — garbage must never occupy a slot a rare real
    /// layout could use. The shortened hex decode must not change that.
    func testMalformedLineIsEvictedBeforeAFloorProtectedLine() {
        let malformed = "{\"family\":\"whoop4\",\"notAFrame\":\"zz\"}\n"
        let real = (0..<50).map { _ in line(version: 18) }
        let lines = [malformed] + real

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: bytes(lines) / 5, floor: 4)

        XCTAssertFalse(kept.contains(malformed), "an unparseable line is never floor-protected")
        XCTAssertGreaterThanOrEqual(kept.count, 4, "the real version keeps its floor")
    }

    /// The prefix-only hex decode must bucket exactly as the full decode did: a frame too short to hold
    /// the version index still resolves to the -1 sentinel, i.e. its OWN bucket, distinct from v18.
    func testShortFrameBucketsUnderTheSentinelVersion() {
        // 4 bytes — index 5 is out of range, so versionByte returns -1.
        let shortFrame = "{\"family\":\"whoop4\",\"frameHex\":\"00112233\"}\n"
        let flood = (0..<300).map { _ in line(version: 18) }
        let lines = [shortFrame] + flood

        let kept = RawHistoryArchive.evictLines(lines, maxBytes: bytes(lines) / 10, floor: 1)

        XCTAssertTrue(kept.contains(shortFrame),
                      "the sentinel is a distinct bucket and holds its own floor slot, as before")
    }
}
