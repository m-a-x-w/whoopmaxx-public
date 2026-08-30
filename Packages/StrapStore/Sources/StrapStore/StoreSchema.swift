import Foundation
import GRDB

/// The schema, as migrations.
///
/// These identifiers and this DDL are an INTEROP CONTRACT, not a design choice. Every installed
/// database records the identifiers it has run in `grdb_migrations`, and every `.wmbak` backup
/// carries a database written to one of these shapes. A restored backup from an older build
/// forward-migrates through the tail of this list, so the steps must stay individually intact —
/// collapsing them into a single create-everything migration would leave an old database
/// unrestorable and no error would say so until a user tried it.
///
/// The DDL is therefore reproduced verbatim rather than rebuilt through a query builder: what
/// matters is the bytes SQLite ends up storing in `sqlite_master`, and a builder that quotes or
/// orders one column differently changes them.
enum StoreSchema {

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
CREATE TABLE "battery" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "soc" DOUBLE, "mv" INTEGER, PRIMARY KEY ("deviceId", "ts"))
""")
            try db.execute(sql: """
CREATE TABLE "device" ("id" TEXT PRIMARY KEY, "mac" TEXT, "name" TEXT, "firstSeen" INTEGER, "lastSeen" INTEGER)
""")
            try db.execute(sql: """
CREATE TABLE "event" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "kind" TEXT NOT NULL, "payloadJSON" TEXT NOT NULL, PRIMARY KEY ("deviceId", "ts", "kind"))
""")
            try db.execute(sql: """
CREATE TABLE "hrSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "bpm" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
            try db.execute(sql: """
CREATE TABLE "rawBatch" ("batchId" TEXT PRIMARY KEY, "deviceId" TEXT NOT NULL, "capturedAt" INTEGER NOT NULL, "deviceClockRef" INTEGER NOT NULL, "wallClockRef" INTEGER NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "frameCount" INTEGER NOT NULL, "byteSize" INTEGER NOT NULL, "framesBlob" BLOB NOT NULL, "syncedAt" INTEGER)
""")
            try db.execute(sql: """
CREATE TABLE "rrInterval" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "rrMs" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts", "rrMs"))
""")
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
CREATE TABLE "cursors" ("name" TEXT PRIMARY KEY, "value" INTEGER)
""")
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
CREATE TABLE "gravitySample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "x" DOUBLE NOT NULL, "y" DOUBLE NOT NULL, "z" DOUBLE NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
            try db.execute(sql: """
CREATE TABLE "respSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "raw" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
            try db.execute(sql: """
CREATE TABLE "skinTempSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "raw" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
            try db.execute(sql: """
CREATE TABLE "spo2Sample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "red" INTEGER NOT NULL, "ir" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
CREATE TABLE "dailyMetric" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "totalSleepMin" DOUBLE, "efficiency" DOUBLE, "deepMin" DOUBLE, "remMin" DOUBLE, "lightMin" DOUBLE, "disturbances" INTEGER, "restingHr" INTEGER, "avgHrv" DOUBLE, "recovery" DOUBLE, "strain" DOUBLE, "exerciseCount" INTEGER, PRIMARY KEY ("deviceId", "day"))
""")
            try db.execute(sql: """
CREATE TABLE "sleepSession" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "efficiency" DOUBLE, "restingHr" INTEGER, "avgHrv" DOUBLE, "stagesJSON" TEXT, PRIMARY KEY ("deviceId", "startTs"))
""")
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
ALTER TABLE "battery" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "event" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "gravitySample" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "hrSample" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "respSample" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "rrInterval" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "skinTempSample" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
            try db.execute(sql: """
ALTER TABLE "spo2Sample" ADD COLUMN "synced" INTEGER NOT NULL DEFAULT 0
""")
        }
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
ALTER TABLE "battery" ADD COLUMN "charging" BOOLEAN
""")
        }
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "spo2Pct" DOUBLE
""")
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "skinTempDevC" DOUBLE
""")
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "respRateBpm" DOUBLE
""")
        }
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
CREATE TABLE "appleDaily" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "steps" INTEGER, "activeKcal" DOUBLE, "basalKcal" DOUBLE, "vo2max" DOUBLE, "avgHr" INTEGER, "maxHr" INTEGER, "walkingHr" INTEGER, "weightKg" DOUBLE, PRIMARY KEY ("deviceId", "day"))
""")
            try db.execute(sql: """
CREATE TABLE "journal" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "question" TEXT NOT NULL, "answeredYes" INTEGER NOT NULL, "notes" TEXT, PRIMARY KEY ("deviceId", "day", "question"))
""")
            try db.execute(sql: """
CREATE TABLE "workout" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "sport" TEXT NOT NULL, "source" TEXT NOT NULL, "durationS" DOUBLE, "energyKcal" DOUBLE, "avgHr" INTEGER, "maxHr" INTEGER, "strain" DOUBLE, "distanceM" DOUBLE, "zonesJSON" TEXT, "notes" TEXT, PRIMARY KEY ("deviceId", "startTs", "sport"))
""")
        }
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
CREATE TABLE "metricSeries" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "key" TEXT NOT NULL, "value" DOUBLE NOT NULL, PRIMARY KEY ("deviceId", "day", "key"))
""")
            try db.execute(sql: """
CREATE INDEX "idx_metricSeries_device_key_day" ON "metricSeries"("deviceId", "key", "day")
""")
        }
        migrator.registerMigration("v10") { db in
            try db.execute(sql: """
CREATE TABLE "stepSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "counter" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
        }
        migrator.registerMigration("v11") { db in
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "steps" INTEGER
""")
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "activeKcalEst" DOUBLE
""")
        }
        migrator.registerMigration("v12") { db in
            try db.execute(sql: """
CREATE TABLE "ppgHrSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "bpm" DOUBLE NOT NULL, "conf" DOUBLE NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
        }
        migrator.registerMigration("v13") { db in
            try db.execute(sql: """
ALTER TABLE "sleepSession" ADD COLUMN "userEdited" BOOLEAN NOT NULL DEFAULT 0
""")
        }
        migrator.registerMigration("v14") { db in
            try db.execute(sql: """
ALTER TABLE "sleepSession" ADD COLUMN "startTsAdjusted" INTEGER
""")
        }
        migrator.registerMigration("v15-device-registry") { db in
            try db.execute(sql: """
CREATE TABLE dayOwnership (
        day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
        deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
        locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
    )
""")
            try db.execute(sql: """
CREATE TABLE pairedDevice (
        id TEXT PRIMARY KEY NOT NULL,
        brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
        sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
        status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
    )
""")
        }
        migrator.registerMigration("v16-paired-device-peripheral") { db in
            try db.execute(sql: """
ALTER TABLE "pairedDevice" ADD COLUMN peripheralId TEXT
""")
        }
        migrator.registerMigration("v17-lab-book") { db in
            try db.execute(sql: """
CREATE TABLE "labMarker" ("id" TEXT PRIMARY KEY, "deviceId" TEXT NOT NULL, "markerKey" TEXT NOT NULL, "category" TEXT NOT NULL, "day" TEXT NOT NULL, "takenAt" INTEGER NOT NULL, "value" DOUBLE, "valueText" TEXT, "unit" TEXT NOT NULL, "source" TEXT NOT NULL, "note" TEXT, "referenceText" TEXT)
""")
            try db.execute(sql: """
CREATE INDEX "idx_labMarker_device_category" ON "labMarker"("deviceId", "category")
""")
            try db.execute(sql: """
CREATE INDEX "idx_labMarker_device_marker_takenAt" ON "labMarker"("deviceId", "markerKey", "takenAt")
""")
            try db.execute(sql: """
CREATE UNIQUE INDEX "idx_labMarker_natural" ON "labMarker"("deviceId", "markerKey", "takenAt", "source")
""")
        }
        migrator.registerMigration("v18-sleep-motion-state") { db in
            try db.execute(sql: """
ALTER TABLE "sleepSession" ADD COLUMN "motionJSON" TEXT
""")
            try db.execute(sql: """
ALTER TABLE "sleepSession" ADD COLUMN "sleepStateJSON" TEXT
""")
        }
        migrator.registerMigration("v19-step-activity-class") { db in
            try db.execute(sql: """
ALTER TABLE "stepSample" ADD COLUMN "activityClass" INTEGER
""")
        }
        migrator.registerMigration("v20-journal-numeric") { db in
            try db.execute(sql: """
ALTER TABLE "journal" ADD COLUMN "numericValue" DOUBLE
""")
        }
        migrator.registerMigration("v21-sleep-state-sample") { db in
            try db.execute(sql: """
CREATE TABLE "sleepStateSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "state" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"))
""")
        }
        migrator.registerMigration("v22-live-session") { db in
            try db.execute(sql: """
CREATE TABLE "liveSession" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER, "chargeAtStart" DOUBLE, "floorBpm" DOUBLE NOT NULL, "ceilingBpm" DOUBLE NOT NULL, "inBandSec" DOUBLE NOT NULL DEFAULT 0, "belowSec" DOUBLE NOT NULL DEFAULT 0, "aboveSec" DOUBLE NOT NULL DEFAULT 0, "pushCount" INTEGER NOT NULL DEFAULT 0, "easeCount" INTEGER NOT NULL DEFAULT 0, "hrSource" TEXT NOT NULL, PRIMARY KEY ("deviceId", "startTs"))
""")
        }
        migrator.registerMigration("v23-sleep-latency-waso") { db in
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "solMin" DOUBLE
""")
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "remLatencyMin" DOUBLE
""")
            try db.execute(sql: """
ALTER TABLE "dailyMetric" ADD COLUMN "wasoMin" DOUBLE
""")
        }
        migrator.registerMigration("v24-sleep-low-confidence") { db in
            try db.execute(sql: """
ALTER TABLE "sleepSession" ADD COLUMN "lowConfidence" BOOLEAN NOT NULL DEFAULT 0
""")
        }
        migrator.registerMigration("v25-habits") { db in
            try db.execute(sql: """
CREATE TABLE "habit" ("deviceId" TEXT NOT NULL, "id" TEXT NOT NULL, "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "cadence" TEXT NOT NULL, "cadenceN" INTEGER, "weekdaysMask" INTEGER, "targetMinutes" INTEGER, "buzzEnabled" INTEGER NOT NULL DEFAULT 0, "buzzWindowStart" INTEGER, "buzzWindowEnd" INTEGER, "pinned" INTEGER NOT NULL DEFAULT 1, "sortOrder" INTEGER NOT NULL DEFAULT 0, "archived" INTEGER NOT NULL DEFAULT 0, "createdAt" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "id"))
""")
            try db.execute(sql: """
CREATE TABLE "habitLog" ("deviceId" TEXT NOT NULL, "habitId" TEXT NOT NULL, "day" TEXT NOT NULL, "done" INTEGER NOT NULL, "source" TEXT NOT NULL, "value" DOUBLE, "stampedAt" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "habitId", "day"))
""")
            try db.execute(sql: """
CREATE INDEX "idx_habitLog_device_day" ON "habitLog"("deviceId", "day")
""")
        }
        migrator.registerMigration("v26-weed-session") { db in
            try db.execute(sql: """
CREATE TABLE weedSession (
    id TEXT PRIMARY KEY NOT NULL,
    deviceId TEXT NOT NULL,
    day TEXT NOT NULL,          -- yyyy-MM-dd, the chip's day key
    ts INTEGER NOT NULL,        -- epoch seconds
    tsExact INTEGER NOT NULL DEFAULT 1,
    method TEXT,                -- flower|vape|edible|concentrate|other, NULL = not recorded
    potency INTEGER,            -- 1|2|3 ordinal the USER sets, NULL = not recorded
    source TEXT NOT NULL,       -- manual | demo
    createdAt INTEGER NOT NULL)
""")
            try db.execute(sql: "CREATE INDEX idx_weedSession_device_day ON weedSession (deviceId, day)")
            try db.execute(sql: "CREATE INDEX idx_weedSession_device_ts  ON weedSession (deviceId, ts)")
        }
        migrator.registerMigration("v27-ingestion-event") { db in
            try db.execute(sql: """
CREATE TABLE ingestionEvent (
    id TEXT PRIMARY KEY NOT NULL,
    deviceId TEXT NOT NULL,
    day TEXT NOT NULL,          -- yyyy-MM-dd, the key the caller wrote
    ts INTEGER NOT NULL,        -- epoch seconds
    tsExact INTEGER NOT NULL DEFAULT 1,
    kind TEXT NOT NULL,         -- meal|caffeine|alcohol|water
    countValue INTEGER,         -- drinks|cups|glasses, NULL = not recorded
    sizeOrdinal INTEGER,        -- meal only, 1|2|3, NULL = not recorded
    source TEXT NOT NULL,       -- manual | demo
    createdAt INTEGER NOT NULL)
""")
            try db.execute(sql: "CREATE INDEX idx_ingestionEvent_device_day ON ingestionEvent (deviceId, day)")
            try db.execute(sql: "CREATE INDEX idx_ingestionEvent_device_ts  ON ingestionEvent (deviceId, ts)")
        }
        migrator.registerMigration("v28-intake-variant-mg") { db in
            try db.execute(sql: """
ALTER TABLE "ingestionEvent" ADD COLUMN variant TEXT
""")
            try db.execute(sql: """
ALTER TABLE "ingestionEvent" ADD COLUMN amountMg INTEGER
""")
        }
        return migrator
    }

    /// Every migration identifier, oldest first. Public so a restore can report exactly how far a
    /// recovered database is behind rather than just failing to open it.
    static let identifiers: [String] = [
        "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14",
        "v15-device-registry", "v16-paired-device-peripheral", "v17-lab-book",
        "v18-sleep-motion-state", "v19-step-activity-class", "v20-journal-numeric",
        "v21-sleep-state-sample", "v22-live-session", "v23-sleep-latency-waso",
        "v24-sleep-low-confidence", "v25-habits", "v26-weed-session",
        "v27-ingestion-event", "v28-intake-variant-mg",
    ]
}
