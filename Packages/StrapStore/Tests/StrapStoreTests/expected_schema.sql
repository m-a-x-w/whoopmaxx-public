CREATE TABLE "appleDaily" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "steps" INTEGER, "activeKcal" DOUBLE, "basalKcal" DOUBLE, "vo2max" DOUBLE, "avgHr" INTEGER, "maxHr" INTEGER, "walkingHr" INTEGER, "weightKg" DOUBLE, PRIMARY KEY ("deviceId", "day"));
CREATE TABLE "battery" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "soc" DOUBLE, "mv" INTEGER, "synced" INTEGER NOT NULL DEFAULT 0, "charging" BOOLEAN, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "cursors" ("name" TEXT PRIMARY KEY, "value" INTEGER);
CREATE TABLE "dailyMetric" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "totalSleepMin" DOUBLE, "efficiency" DOUBLE, "deepMin" DOUBLE, "remMin" DOUBLE, "lightMin" DOUBLE, "disturbances" INTEGER, "restingHr" INTEGER, "avgHrv" DOUBLE, "recovery" DOUBLE, "strain" DOUBLE, "exerciseCount" INTEGER, "spo2Pct" DOUBLE, "skinTempDevC" DOUBLE, "respRateBpm" DOUBLE, "steps" INTEGER, "activeKcalEst" DOUBLE, "solMin" DOUBLE, "remLatencyMin" DOUBLE, "wasoMin" DOUBLE, PRIMARY KEY ("deviceId", "day"));
CREATE TABLE dayOwnership (
        day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
        deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
        locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
    );
CREATE TABLE "device" ("id" TEXT PRIMARY KEY, "mac" TEXT, "name" TEXT, "firstSeen" INTEGER, "lastSeen" INTEGER);
CREATE TABLE "event" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "kind" TEXT NOT NULL, "payloadJSON" TEXT NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts", "kind"));
CREATE TABLE "gravitySample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "x" DOUBLE NOT NULL, "y" DOUBLE NOT NULL, "z" DOUBLE NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "habit" ("deviceId" TEXT NOT NULL, "id" TEXT NOT NULL, "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "cadence" TEXT NOT NULL, "cadenceN" INTEGER, "weekdaysMask" INTEGER, "targetMinutes" INTEGER, "buzzEnabled" INTEGER NOT NULL DEFAULT 0, "buzzWindowStart" INTEGER, "buzzWindowEnd" INTEGER, "pinned" INTEGER NOT NULL DEFAULT 1, "sortOrder" INTEGER NOT NULL DEFAULT 0, "archived" INTEGER NOT NULL DEFAULT 0, "createdAt" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "id"));
CREATE TABLE "habitLog" ("deviceId" TEXT NOT NULL, "habitId" TEXT NOT NULL, "day" TEXT NOT NULL, "done" INTEGER NOT NULL, "source" TEXT NOT NULL, "value" DOUBLE, "stampedAt" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "habitId", "day"));
CREATE TABLE "hrSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "bpm" INTEGER NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts"));
CREATE INDEX "idx_habitLog_device_day" ON "habitLog"("deviceId", "day");
CREATE INDEX idx_ingestionEvent_device_day ON ingestionEvent (deviceId, day);
CREATE INDEX idx_ingestionEvent_device_ts  ON ingestionEvent (deviceId, ts);
CREATE INDEX "idx_labMarker_device_category" ON "labMarker"("deviceId", "category");
CREATE INDEX "idx_labMarker_device_marker_takenAt" ON "labMarker"("deviceId", "markerKey", "takenAt");
CREATE UNIQUE INDEX "idx_labMarker_natural" ON "labMarker"("deviceId", "markerKey", "takenAt", "source");
CREATE INDEX "idx_metricSeries_device_key_day" ON "metricSeries"("deviceId", "key", "day");
CREATE INDEX idx_weedSession_device_day ON weedSession (deviceId, day);
CREATE INDEX idx_weedSession_device_ts  ON weedSession (deviceId, ts);
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
    createdAt INTEGER NOT NULL, variant TEXT, amountMg INTEGER);
CREATE TABLE "journal" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "question" TEXT NOT NULL, "answeredYes" INTEGER NOT NULL, "notes" TEXT, "numericValue" DOUBLE, PRIMARY KEY ("deviceId", "day", "question"));
CREATE TABLE "labMarker" ("id" TEXT PRIMARY KEY, "deviceId" TEXT NOT NULL, "markerKey" TEXT NOT NULL, "category" TEXT NOT NULL, "day" TEXT NOT NULL, "takenAt" INTEGER NOT NULL, "value" DOUBLE, "valueText" TEXT, "unit" TEXT NOT NULL, "source" TEXT NOT NULL, "note" TEXT, "referenceText" TEXT);
CREATE TABLE "liveSession" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER, "chargeAtStart" DOUBLE, "floorBpm" DOUBLE NOT NULL, "ceilingBpm" DOUBLE NOT NULL, "inBandSec" DOUBLE NOT NULL DEFAULT 0, "belowSec" DOUBLE NOT NULL DEFAULT 0, "aboveSec" DOUBLE NOT NULL DEFAULT 0, "pushCount" INTEGER NOT NULL DEFAULT 0, "easeCount" INTEGER NOT NULL DEFAULT 0, "hrSource" TEXT NOT NULL, PRIMARY KEY ("deviceId", "startTs"));
CREATE TABLE "metricSeries" ("deviceId" TEXT NOT NULL, "day" TEXT NOT NULL, "key" TEXT NOT NULL, "value" DOUBLE NOT NULL, PRIMARY KEY ("deviceId", "day", "key"));
CREATE TABLE pairedDevice (
        id TEXT PRIMARY KEY NOT NULL,
        brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
        sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
        status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
    , peripheralId TEXT);
CREATE TABLE "ppgHrSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "bpm" DOUBLE NOT NULL, "conf" DOUBLE NOT NULL, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "rawBatch" ("batchId" TEXT PRIMARY KEY, "deviceId" TEXT NOT NULL, "capturedAt" INTEGER NOT NULL, "deviceClockRef" INTEGER NOT NULL, "wallClockRef" INTEGER NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "frameCount" INTEGER NOT NULL, "byteSize" INTEGER NOT NULL, "framesBlob" BLOB NOT NULL, "syncedAt" INTEGER);
CREATE TABLE "respSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "raw" INTEGER NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "rrInterval" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "rrMs" INTEGER NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts", "rrMs"));
CREATE TABLE "skinTempSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "raw" INTEGER NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "sleepSession" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "efficiency" DOUBLE, "restingHr" INTEGER, "avgHrv" DOUBLE, "stagesJSON" TEXT, "userEdited" BOOLEAN NOT NULL DEFAULT 0, "startTsAdjusted" INTEGER, "motionJSON" TEXT, "sleepStateJSON" TEXT, "lowConfidence" BOOLEAN NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "startTs"));
CREATE TABLE "sleepStateSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "state" INTEGER NOT NULL, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "spo2Sample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "red" INTEGER NOT NULL, "ir" INTEGER NOT NULL, "synced" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE "stepSample" ("deviceId" TEXT NOT NULL, "ts" INTEGER NOT NULL, "counter" INTEGER NOT NULL, "activityClass" INTEGER, PRIMARY KEY ("deviceId", "ts"));
CREATE TABLE weedSession (
    id TEXT PRIMARY KEY NOT NULL,
    deviceId TEXT NOT NULL,
    day TEXT NOT NULL,          -- yyyy-MM-dd, the chip's day key
    ts INTEGER NOT NULL,        -- epoch seconds
    tsExact INTEGER NOT NULL DEFAULT 1,
    method TEXT,                -- flower|vape|edible|concentrate|other, NULL = not recorded
    potency INTEGER,            -- 1|2|3 ordinal the USER sets, NULL = not recorded
    source TEXT NOT NULL,       -- manual | demo
    createdAt INTEGER NOT NULL);
CREATE TABLE "workout" ("deviceId" TEXT NOT NULL, "startTs" INTEGER NOT NULL, "endTs" INTEGER NOT NULL, "sport" TEXT NOT NULL, "source" TEXT NOT NULL, "durationS" DOUBLE, "energyKcal" DOUBLE, "avgHr" INTEGER, "maxHr" INTEGER, "strain" DOUBLE, "distanceM" DOUBLE, "zonesJSON" TEXT, "notes" TEXT, PRIMARY KEY ("deviceId", "startTs", "sport"));

-- migrations: v1,v2,v3,v4,v5,v6,v7,v8,v9,v10,v11,v12,v13,v14,v15-device-registry,v16-paired-device-peripheral,v17-lab-book,v18-sleep-motion-state,v19-step-activity-class,v20-journal-numeric,v21-sleep-state-sample,v22-live-session,v23-sleep-latency-waso,v24-sleep-low-confidence,v25-habits,v26-weed-session,v27-ingestion-event,v28-intake-variant-mg
