import XCTest
import GRDB
@testable import StrapStore

/// The schema is an interop contract with every database already on a user's phone and inside
/// every backup they hold. These tests compare against a dump taken from the shipped schema, so a
/// drift shows up here rather than as an unrestorable backup.
final class SchemaTests: XCTestCase {

    private func schemaText(_ q: DatabaseQueue) throws -> String {
        try q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name
                """).map { ($0["sql"] as String? ?? "") + ";" }.joined(separator: "\n") + "\n"
        }
    }

    func testFullMigrationProducesTheShippedSchema() throws {
        let q = try DatabaseQueue()
        try StoreSchema.migrator().migrate(q)

        let expectedURL = try XCTUnwrap(Bundle.module.url(forResource: "expected_schema", withExtension: "sql"))
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .components(separatedBy: "\n-- migrations:")[0]

        let actual = try schemaText(q)
        // Compare object by object so a failure names the table that drifted.
        let exp = expected.split(separator: ";\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let act = actual.split(separator: ";\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        XCTAssertEqual(act.count, exp.count, "object count differs")
        for (a, e) in zip(act, exp) { XCTAssertEqual(a, e) }
    }

    func testEveryMigrationIdentifierIsRecordedInOrder() throws {
        let q = try DatabaseQueue()
        try StoreSchema.migrator().migrate(q)
        let applied = try q.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        XCTAssertEqual(Set(applied), Set(StoreSchema.identifiers))
        XCTAssertEqual(StoreSchema.identifiers.count, 28)
    }

    func testMigratingStepByStepReachesTheSameSchema() throws {
        // A restored backup enters partway down this list and walks the rest. If an incremental
        // path diverges from the all-at-once path, only the restore breaks — and only for users
        // who actually had an older build.
        let stepped = try DatabaseQueue()
        for id in StoreSchema.identifiers {
            try StoreSchema.migrator().migrate(stepped, upTo: id)
        }
        let full = try DatabaseQueue()
        try StoreSchema.migrator().migrate(full)
        XCTAssertEqual(try schemaText(stepped), try schemaText(full))
    }

    func testAnOldDatabaseForwardMigrates() throws {
        // Stop at v14 — the last of the bare numeric migrations — then carry it the rest of the way.
        let q = try DatabaseQueue()
        try StoreSchema.migrator().migrate(q, upTo: "v14")
        let partial = try q.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        XCTAssertEqual(partial.count, 14)
        try StoreSchema.migrator().migrate(q)
        let full = try q.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        XCTAssertEqual(full.count, 28)
    }
}
