import XCTest
@testable import StrapProtocol

final class CommandTests: XCTestCase {

    func testBuildCommandProducesAParsableFrame() throws {
        let raw = buildCommand(seq: 3, opcode: Cmd.getAlarmTime, payload: [0x01])
        let f = try XCTUnwrap(parseEnvelope(raw))
        XCTAssertTrue(f.valid)
        XCTAssertEqual(UInt8(f.packetType), PacketType.command)
        XCTAssertEqual(f.sequence, 3)
        XCTAssertEqual(UInt8(f.opcode), Cmd.getAlarmTime)
    }

    func testCommandFrameIsNotMistakenForARecord() {
        // parseR24 dispatches on inner[0]; a command frame whose SEQUENCE is 24 must not decode
        // as a v24 record.
        let raw = buildCommand(seq: 24, opcode: Cmd.runAlarm, payload: [UInt8](repeating: 0, count: 100))
        let f = parseEnvelope(raw)!
        XCTAssertNil(parseR24(f.inner))
    }

    func testAlarmSubsecondSplit() {
        // Sub-seconds are 1/32768 s units, not milliseconds.
        XCTAssertEqual(AlarmPayload.seconds(fromEpochMs: 1_700_000_000_500), 1_700_000_000)
        XCTAssertEqual(AlarmPayload.subseconds(fromEpochMs: 1_700_000_000_500), 16384)   // half a second
        XCTAssertEqual(AlarmPayload.subseconds(fromEpochMs: 1_700_000_000_000), 0)
        XCTAssertLessThan(AlarmPayload.subseconds(fromEpochMs: 1_700_000_000_999), 32768)
    }

    func testSetAlarmRev4Layout() {
        let ms: Int64 = 1_700_000_000_000
        let p = AlarmPayload.setAlarmRev4(wakeEpochMs: ms, alarmId: 2)
        XCTAssertEqual(p.count, 20)
        XCTAssertEqual(p[0], 0x04, "revision-4 form marker")
        XCTAssertEqual(p[1], 2, "slot")
        let s = UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24
        XCTAssertEqual(s, 1_700_000_000)
        XCTAssertEqual(Array(p[8...]), defaultAlarmHaptics)
    }

    func testDefaultAlarmHapticsShape() {
        XCTAssertEqual(defaultAlarmHaptics.count, 12)
        XCTAssertEqual(Array(defaultAlarmHaptics.prefix(2)), [47, 152], "two active effect slots")
        XCTAssertEqual(defaultAlarmHaptics[10], 7, "overall waveform loops")
        XCTAssertEqual(defaultAlarmHaptics[11], 30, "seconds cap")
    }

    func testDisableAndRunAreRevisionThenSlot() {
        // Every gen5 alarm opcode is rev-then-id; sending a bare id is rejected as an
        // unsupported revision, so the command silently never lands.
        XCTAssertEqual(AlarmPayload.disableRev2(), [0x02, 0xFF], "0xFF = all slots")
        XCTAssertEqual(AlarmPayload.disableRev2(alarmId: 3), [0x02, 3])
        XCTAssertEqual(AlarmPayload.runAlarmRev2(alarmId: 1), [0x02, 1])
    }

    func testNotificationBuzz() {
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 2), [2, 2, 0, 0, 0])
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 999)[1], 255, "clamped to a u8")
    }
}

final class Whoop5ConfigTests: XCTestCase {

    func testPayloadBodyLayout() {
        let b = Whoop5Config.payloadBody(name: "enable_r22_packets", value: 0x32)
        XCTAssertEqual(b.count, 40)
        XCTAssertEqual(Array(b[0..<18]), Array("enable_r22_packets".utf8))
        XCTAssertEqual(b[18], 0, "name is NUL-padded")
        XCTAssertEqual(b[32], 0x32, "value sits at offset 32")
        XCTAssertEqual(Array(b[33...]), [UInt8](repeating: 0, count: 7))
    }

    func testDeviceConfigBodyIsTheSameShapeWithoutTheTail() {
        let b = Whoop5Config.deviceConfigBody(name: "hr_ch_switching", value: 0x31)
        XCTAssertEqual(b.count, 33)
        XCTAssertEqual(b[32], 0x31)
    }

    func testOverlongNameIsTruncatedNotOverflowed() {
        let b = Whoop5Config.payloadBody(name: String(repeating: "x", count: 64), value: 0x32)
        XCTAssertEqual(b.count, 40)
        XCTAssertEqual(b[32], 0x32, "the value byte survives an overlong name")
    }

    func testFlagValuesAreAsciiDigits() {
        // 0x32/0x31 are '2'/'1'. Sending 0x00/0x01 would set the flag to NUL/SOH.
        for f in Whoop5Config.enableR22Sequence {
            XCTAssertTrue(f.value == 0x31 || f.value == 0x32, "\(f.name) carries a non-digit value")
        }
    }

    func testEnableSequenceFramesAreOnePerFlagAndAllParse() {
        let frames = Whoop5Config.enableSequenceFrames(firstSeq: 1)
        XCTAssertEqual(frames.count, Whoop5Config.enableR22Sequence.count)
        for (i, raw) in frames.enumerated() {
            let f = parseEnvelope(raw, profile: .gen5)
            XCTAssertNotNil(f, "frame \(i)")
            XCTAssertTrue(f!.valid, "frame \(i) failed its CRCs")
            XCTAssertEqual(f!.sequence, i + 1)
            XCTAssertEqual(UInt8(f!.opcode), Whoop5Config.setConfigCmd)
        }
    }
}

final class HapticClockTests: XCTestCase {

    func testHourPulsesOnTheHour() {
        let p = HapticClock.pulses(hour: 7, minute: 0)
        XCTAssertEqual(p.count, 7)
        XCTAssertTrue(p.allSatisfy(\.isLong))
    }

    func testMinuteBlocksFollowTheHour() {
        let p = HapticClock.pulses(hour: 7, minute: 20)
        XCTAssertEqual(p.filter(\.isLong).count, 7)
        XCTAssertEqual(p.filter { !$0.isLong }.count, 4, "20 minutes is four five-minute blocks")
    }

    func testBlockGapSeparatesTheTwoRuns() {
        let p = HapticClock.pulses(hour: 3, minute: 15)
        XCTAssertEqual(p[2].gapMs, HapticClock.blockGapMs, "the last hour pulse carries the long gap")
        XCTAssertEqual(p[0].gapMs, HapticClock.intraGapMs)
    }

    func testNearlyTheHourCarriesRatherThanEmittingElevenShortPulses() {
        let p = HapticClock.pulses(hour: 7, minute: 58)
        XCTAssertEqual(p.count, 8, "rounds up into the next hour")
        XCTAssertTrue(p.allSatisfy(\.isLong), "and emits no minute block at all")
    }

    func testTwelveHourDialReadsTwelveNotZero() {
        XCTAssertEqual(HapticClock.pulses(hour: 0, minute: 0).count, 12, "midnight")
        XCTAssertEqual(HapticClock.pulses(hour: 12, minute: 0).count, 12, "noon")
        XCTAssertEqual(HapticClock.pulses(hour: 13, minute: 0).count, 1, "1 pm")
    }

    func testEveryHourAndMinuteProducesAReadableSchedule() {
        for h in 0..<24 {
            for m in 0..<60 {
                let p = HapticClock.pulses(hour: h, minute: m)
                let longs = p.filter(\.isLong).count
                let shorts = p.filter { !$0.isLong }.count
                XCTAssertTrue((1...12).contains(longs), "\(h):\(m) hour count out of dial range")
                XCTAssertLessThan(shorts, 12, "\(h):\(m) minute count should have carried")
                // The long run always precedes the short run — otherwise the count is ambiguous.
                let firstShort = p.firstIndex { !$0.isLong } ?? p.count
                XCTAssertNil(p[firstShort...].firstIndex(where: \.isLong), "\(h):\(m) runs interleave")
            }
        }
    }

    func testPulseLengthsStaySeparable() {
        XCTAssertGreaterThan(HapticClock.longMs, HapticClock.shortMs * 2)
    }
}
