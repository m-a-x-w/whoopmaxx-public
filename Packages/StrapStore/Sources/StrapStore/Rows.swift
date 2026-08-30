import Foundation

// The typed rows the store reads and writes. Column names and nullability follow the schema
// exactly — a mismatch here is a decode failure at runtime, not a compile error.
//
// Optionality is meaningful throughout: a nil is "the strap never measured this", not zero. The
// scoring layer distinguishes the two, so widening a field to a non-optional with a default would
// turn every gap into a confident reading of nothing.

/// One day's computed and measured metrics. The unit of everything the app displays.
public struct DailyMetric: Equatable, Codable, Sendable {
    public var day: String                  // YYYY-MM-DD, local
    public var totalSleepMin: Double?
    public var efficiency: Double?
    public var deepMin: Double?
    public var remMin: Double?
    public var lightMin: Double?
    public var disturbances: Int?
    public var restingHr: Int?
    public var avgHrv: Double?
    public var recovery: Double?
    public var strain: Double?
    public var exerciseCount: Int?
    /// Mean SpO2 (%) across the night.
    public var spo2Pct: Double?
    /// Skin-temperature DEVIATION from the user's own baseline (°C), never an absolute reading.
    public var skinTempDevC: Double?
    public var respRateBpm: Double?
    public var steps: Int?
    /// Whole-day HR-only calorie estimate (kcal). An estimate, and named like one.
    public var activeKcalEst: Double?
    /// Sleep-onset latency (min).
    public var solMin: Double?
    /// REM latency (min); nil when the night banked no REM at all.
    public var remLatencyMin: Double?
    /// Wake after sleep onset (min).
    public var wasoMin: Double?

    public init(day: String, totalSleepMin: Double? = nil, efficiency: Double? = nil,
                deepMin: Double? = nil, remMin: Double? = nil, lightMin: Double? = nil,
                disturbances: Int? = nil, restingHr: Int? = nil, avgHrv: Double? = nil,
                recovery: Double? = nil, strain: Double? = nil, exerciseCount: Int? = nil,
                spo2Pct: Double? = nil, skinTempDevC: Double? = nil, respRateBpm: Double? = nil,
                steps: Int? = nil, activeKcalEst: Double? = nil, solMin: Double? = nil,
                remLatencyMin: Double? = nil, wasoMin: Double? = nil) {
        self.day = day; self.totalSleepMin = totalSleepMin; self.efficiency = efficiency
        self.deepMin = deepMin; self.remMin = remMin; self.lightMin = lightMin
        self.disturbances = disturbances; self.restingHr = restingHr; self.avgHrv = avgHrv
        self.recovery = recovery; self.strain = strain; self.exerciseCount = exerciseCount
        self.spo2Pct = spo2Pct; self.skinTempDevC = skinTempDevC; self.respRateBpm = respRateBpm
        self.steps = steps; self.activeKcalEst = activeKcalEst; self.solMin = solMin
        self.remLatencyMin = remLatencyMin; self.wasoMin = wasoMin
    }
}

/// A staged night, cached so the stager does not re-run on every read.
public struct CachedSleepSession: Equatable, Codable, Sendable {
    public var startTs: Int
    public var endTs: Int
    public var efficiency: Double?
    public var restingHr: Int?
    public var avgHrv: Double?
    public var stagesJSON: String?
    /// The user moved the boundaries by hand. Their edit outranks any re-detection.
    public var userEdited: Bool
    /// A user-moved start. Kept SEPARATE from `startTs` so the detected boundary survives — the
    /// edit can be undone, and re-detection still has its original anchor to compare against.
    public var startTsAdjusted: Int?
    /// The stager kept this night but flagged it: the recorded span is longer than any single
    /// sleep it will vouch for. Shown with a caveat rather than hidden.
    public var lowConfidence: Bool

    /// The boundary to display and score from.
    public var effectiveStartTs: Int { startTsAdjusted ?? startTs }

    public init(startTs: Int, endTs: Int, efficiency: Double? = nil, restingHr: Int? = nil,
                avgHrv: Double? = nil, stagesJSON: String? = nil, userEdited: Bool = false,
                startTsAdjusted: Int? = nil, lowConfidence: Bool = false) {
        self.startTs = startTs; self.endTs = endTs; self.efficiency = efficiency
        self.restingHr = restingHr; self.avgHrv = avgHrv; self.stagesJSON = stagesJSON
        self.userEdited = userEdited; self.startTsAdjusted = startTsAdjusted
        self.lowConfidence = lowConfidence
    }
}

/// One point on one named series. The generic lane everything not worth a `DailyMetric` column
/// lives in.
public struct MetricPoint: Equatable, Codable, Sendable {
    public var day: String
    public var key: String
    public var value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

public struct WorkoutRow: Equatable, Codable, Sendable {
    public var startTs: Int
    public var endTs: Int
    public var sport: String
    /// Where the workout came from — detection, a manual add, or an import. Determines whether a
    /// re-detection may overwrite it.
    public var source: String
    public var durationS: Double?
    public var energyKcal: Double?
    public var avgHr: Int?
    public var maxHr: Int?
    public var strain: Double?
    public var distanceM: Double?
    public var zonesJSON: String?
    public var notes: String?

    public init(startTs: Int, endTs: Int, sport: String, source: String, durationS: Double? = nil,
                energyKcal: Double? = nil, avgHr: Int? = nil, maxHr: Int? = nil,
                strain: Double? = nil, distanceM: Double? = nil, zonesJSON: String? = nil,
                notes: String? = nil) {
        self.startTs = startTs; self.endTs = endTs; self.sport = sport; self.source = source
        self.durationS = durationS; self.energyKcal = energyKcal; self.avgHr = avgHr
        self.maxHr = maxHr; self.strain = strain; self.distanceM = distanceM
        self.zonesJSON = zonesJSON; self.notes = notes
    }
}

public struct AppleDaily: Equatable, Codable, Sendable {
    public var day: String
    public var steps: Int?
    public var activeKcal: Double?
    public var basalKcal: Double?
    public var vo2max: Double?
    public var avgHr: Int?
    public var maxHr: Int?
    public var walkingHr: Int?
    public var weightKg: Double?
    public init(day: String, steps: Int? = nil, activeKcal: Double? = nil, basalKcal: Double? = nil,
                vo2max: Double? = nil, avgHr: Int? = nil, maxHr: Int? = nil,
                walkingHr: Int? = nil, weightKg: Double? = nil) {
        self.day = day; self.steps = steps; self.activeKcal = activeKcal; self.basalKcal = basalKcal
        self.vo2max = vo2max; self.avgHr = avgHr; self.maxHr = maxHr
        self.walkingHr = walkingHr; self.weightKg = weightKg
    }
}

public struct JournalEntry: Equatable, Codable, Sendable {
    public var day: String
    public var question: String
    public var answeredYes: Bool
    public var notes: String?
    /// A magnitude alongside the yes/no, where the question has one.
    public var numericValue: Double?
    public init(day: String, question: String, answeredYes: Bool,
                notes: String? = nil, numericValue: Double? = nil) {
        self.day = day; self.question = question; self.answeredYes = answeredYes
        self.notes = notes; self.numericValue = numericValue
    }
}

public struct LabMarkerRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var markerKey: String
    public var category: String
    public var day: String
    public var takenAt: Int
    public var value: Double?
    /// For markers that are not numeric at all. A result of "negative" is not a 0.
    public var valueText: String?
    public var unit: String
    public var source: String
    public var note: String?
    public var referenceText: String?
    public init(id: String, deviceId: String, markerKey: String, category: String, day: String,
                takenAt: Int, value: Double? = nil, valueText: String? = nil, unit: String,
                source: String, note: String? = nil, referenceText: String? = nil) {
        self.id = id; self.deviceId = deviceId; self.markerKey = markerKey
        self.category = category; self.day = day; self.takenAt = takenAt; self.value = value
        self.valueText = valueText; self.unit = unit; self.source = source
        self.note = note; self.referenceText = referenceText
    }
}

public struct LiveSessionRow: Equatable, Codable, Sendable {
    public var startTs: Int
    /// nil while the session is still running.
    public var endTs: Int?
    public var chargeAtStart: Double?
    public var floorBpm: Double
    public var ceilingBpm: Double
    public var inBandSec: Double
    public var belowSec: Double
    public var aboveSec: Double
    public var pushCount: Int
    public var easeCount: Int
    public var hrSource: String
    public init(startTs: Int, endTs: Int? = nil, chargeAtStart: Double? = nil,
                floorBpm: Double, ceilingBpm: Double, inBandSec: Double = 0,
                belowSec: Double = 0, aboveSec: Double = 0, pushCount: Int = 0,
                easeCount: Int = 0, hrSource: String) {
        self.startTs = startTs; self.endTs = endTs; self.chargeAtStart = chargeAtStart
        self.floorBpm = floorBpm; self.ceilingBpm = ceilingBpm; self.inBandSec = inBandSec
        self.belowSec = belowSec; self.aboveSec = aboveSec; self.pushCount = pushCount
        self.easeCount = easeCount; self.hrSource = hrSource
    }
}

public struct HabitDef: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    /// sleep_by · wake_by · sleep_duration · train · nap · wind_down · manual
    public var kind: String
    /// daily · weekly · weekdays · anytime
    public var cadence: String
    /// weekly: times per week.
    public var cadenceN: Int?
    /// weekdays: a bitmask over Calendar weekday numbers.
    public var weekdaysMask: Int?
    /// sleep_by/wake_by: minutes since midnight. sleep_duration: minutes.
    public var targetMinutes: Int?
    public var buzzEnabled: Bool
    public var buzzWindowStart: Int?
    public var buzzWindowEnd: Int?
    public var pinned: Bool
    public var sortOrder: Int
    public var archived: Bool
    public var createdAt: Int
    public init(id: String, name: String, kind: String, cadence: String, cadenceN: Int? = nil,
                weekdaysMask: Int? = nil, targetMinutes: Int? = nil, buzzEnabled: Bool = false,
                buzzWindowStart: Int? = nil, buzzWindowEnd: Int? = nil, pinned: Bool = true,
                sortOrder: Int = 0, archived: Bool = false, createdAt: Int) {
        self.id = id; self.name = name; self.kind = kind; self.cadence = cadence
        self.cadenceN = cadenceN; self.weekdaysMask = weekdaysMask; self.targetMinutes = targetMinutes
        self.buzzEnabled = buzzEnabled; self.buzzWindowStart = buzzWindowStart
        self.buzzWindowEnd = buzzWindowEnd; self.pinned = pinned; self.sortOrder = sortOrder
        self.archived = archived; self.createdAt = createdAt
    }
}

public struct HabitLog: Equatable, Codable, Sendable {
    public var habitId: String
    public var day: String
    public var done: Bool
    /// manual · override — an override is the user contradicting a derived result, and must win.
    public var source: String
    public var value: Double?
    public var stampedAt: Int
    public init(habitId: String, day: String, done: Bool, source: String,
                value: Double? = nil, stampedAt: Int) {
        self.habitId = habitId; self.day = day; self.done = done
        self.source = source; self.value = value; self.stampedAt = stampedAt
    }
}

public struct IngestionEventRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var day: String
    public var ts: Int
    /// Whether `ts` is a real logged moment or a placeholder for the day. A back-dated entry has
    /// no exact time, and drawing signal around a made-up minute would be a fabrication.
    public var tsExact: Bool
    public var kind: String
    public var countValue: Int?
    public var sizeOrdinal: Int?
    public var variant: String?
    public var amountMg: Int?
    public var source: String
    public var createdAt: Int
    public init(id: String, deviceId: String, day: String, ts: Int, tsExact: Bool, kind: String,
                countValue: Int? = nil, sizeOrdinal: Int? = nil, variant: String? = nil,
                amountMg: Int? = nil, source: String, createdAt: Int) {
        self.id = id; self.deviceId = deviceId; self.day = day; self.ts = ts
        self.tsExact = tsExact; self.kind = kind; self.countValue = countValue
        self.sizeOrdinal = sizeOrdinal; self.variant = variant; self.amountMg = amountMg
        self.source = source; self.createdAt = createdAt
    }
}

public struct WeedSessionRow: Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    public var day: String
    public var ts: Int
    public var tsExact: Bool
    public var method: String?
    public var potency: Int?
    public var source: String
    public var createdAt: Int
    public init(id: String, deviceId: String, day: String, ts: Int, tsExact: Bool,
                method: String? = nil, potency: Int? = nil, source: String, createdAt: Int) {
        self.id = id; self.deviceId = deviceId; self.day = day; self.ts = ts
        self.tsExact = tsExact; self.method = method; self.potency = potency
        self.source = source; self.createdAt = createdAt
    }
}

/// The device clock paired with the wall clock at one instant. Everything time-related on the
/// offload path is expressed against this pair — a strap's own clock drifts and can be wildly stale.
public struct ClockRef: Equatable, Codable, Sendable {
    public var device: Int
    public var wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}

/// The header for one archived batch of raw frames.
public struct RawBatchMeta: Equatable, Sendable {
    public var batchId: String
    public var deviceId: String
    public var clockRef: ClockRef
    public var capturedAt: Int
    public var startTs: Int
    public var endTs: Int
    public var frameCount: Int
    public var byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int) {
        self.batchId = batchId; self.deviceId = deviceId; self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }
}

/// A downsampled heart-rate point.
public struct HRBucket: Sendable, Equatable {
    public var ts: Int
    public var bpm: Double
    public init(ts: Int, bpm: Double) { self.ts = ts; self.bpm = bpm }
}

// MARK: - Device registry

public enum SourceKind: String, Sendable, CaseIterable, Codable {
    case liveBLE, historyBLE, cloudImport, fileImport, ftms, huami, liveAppleWatch, oura
}

public enum Metric: String, Sendable, CaseIterable, Codable {
    case hr, hrv, spo2, skinTemp, steps, sleep, strainLoad
}

public enum DeviceStatus: String, Sendable, CaseIterable, Codable {
    case active, paired, archived
}

public struct PairedDevice: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var brand: String
    public var model: String
    /// User-renamable; nil shows brand and model instead.
    public var nickname: String?
    /// The platform's peripheral identifier; nil until the device has actually been adopted.
    public var peripheralId: String?
    public var sourceKind: SourceKind
    public var capabilities: Set<Metric>
    public var status: DeviceStatus
    public var addedAt: Int
    public var lastSeenAt: Int

    public var displayName: String { nickname ?? "\(brand) \(model)" }

    public init(id: String, brand: String, model: String, nickname: String? = nil,
                peripheralId: String? = nil, sourceKind: SourceKind,
                capabilities: Set<Metric> = [], status: DeviceStatus = .paired,
                addedAt: Int, lastSeenAt: Int) {
        self.id = id; self.brand = brand; self.model = model; self.nickname = nickname
        self.peripheralId = peripheralId; self.sourceKind = sourceKind
        self.capabilities = capabilities; self.status = status
        self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
    }
}

/// Which device owns a day's displayed metrics.
///
/// `locked` marks a decision someone made — an import-overlap resolution, or the user choosing —
/// as opposed to the resolver's default. A locked day must survive the next resolve.
public struct DayOwner: Equatable, Sendable {
    public let deviceId: String
    public let locked: Bool
    public init(deviceId: String, locked: Bool) { self.deviceId = deviceId; self.locked = locked }
}
