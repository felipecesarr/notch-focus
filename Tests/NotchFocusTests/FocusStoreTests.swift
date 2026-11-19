import Foundation
import XCTest
@testable import NotchFocus

@MainActor
private final class Fixture {
    var time = Date(timeIntervalSince1970: 1_752_494_400) // Noon UTC.
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { folder.appending(path: "history.json") }
    func open(seed: Bool = true) throws -> FocusStore {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return try FocusStore(url: url, calendar: utc, now: { self.time }, seed: seed)
    }
    func advance(_ seconds: Int, _ store: FocusStore) {
        time.addTimeInterval(Double(seconds))
        store.tick()
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
}

final class FocusStoreTests: XCTestCase {
    @MainActor
    func testTaskSwitchRestartsAndBreakStartsByItself() async throws {
        let f = Fixture()
        let store = try f.open()
        let a = store.tasks[0].id, b = store.tasks[1].id
        store.toggleFocus(a)
        f.advance(480, store)
        store.toggleFocus(b)
        f.advance(240, store)
        store.toggleFocus(a)
        XCTAssertEqual(store.remaining, 1500)
        XCTAssertEqual(store.focusedSeconds(for: a), 480)
        XCTAssertEqual(store.focusedSeconds(for: b), 240)
        f.advance(1500, store)
        XCTAssertEqual(store.mode, .onBreak)
        XCTAssertEqual(store.remaining, 300)
        XCTAssertEqual(store.tasks.filter(\.done).count, 0)
        XCTAssertEqual(store.historyDays.last?.completed, 1)
        XCTAssertEqual(store.historyDays.last?.seconds, 2220)
        f.advance(300, store)
        XCTAssertEqual(store.mode, .idle)
        XCTAssertEqual(store.historyDays.last?.seconds, 2220)
    }

    @MainActor
    func testPausedTaskResumesUnlessReplaced() async throws {
        let f = Fixture()
        let store = try f.open()
        let a = store.tasks[0].id, b = store.tasks[1].id
        store.toggleFocus(a)
        f.advance(480, store)
        store.toggleFocus(a)
        f.advance(55, store)
        XCTAssertEqual(store.remaining, 1020)
        store.toggleFocus(a)
        XCTAssertEqual(store.remaining, 1020)
        f.advance(5, store)
        store.interrupt()
        store.toggleFocus(b)
        store.toggleFocus(a)
        XCTAssertEqual(store.remaining, 1500)
        XCTAssertEqual(store.focusedSeconds(for: a), 485)
        store.toggleDone(a)
        XCTAssertEqual(store.mode, .idle)
        XCTAssertEqual(store.historyDays.last?.completed, 0)
    }

    @MainActor
    func testCheckpointRecoveryAndMidnight() async throws {
        let f = Fixture()
        f.time = ISO8601DateFormatter().date(from: "2026-11-19T23:59:50Z")!
        let store = try f.open()
        let a = store.tasks[0].id
        store.saveTask(id: a, title: "Read", notes: "", duration: 20, scheduledDay: f.time)
        store.toggleFocus(a)
        f.advance(12, store)
        f.time.addTimeInterval(300)
        let restored = try f.open()
        XCTAssertEqual(restored.mode, .paused)
        XCTAssertEqual(restored.remaining, 8)
        XCTAssertEqual(restored.focusedSeconds(for: a), 12)
        restored.toggleFocus(a)
        f.advance(8, restored)
        XCTAssertEqual(restored.mode, .onBreak)
        XCTAssertEqual(restored.historyDays.suffix(2).map(\.seconds), [10, 10])
        XCTAssertEqual(restored.historyDays.suffix(2).map(\.completed), [0, 1])
        let twice = try f.open()
        XCTAssertEqual(twice.historyDays.last?.completed, 1)
        XCTAssertEqual(twice.streak, 1)
    }

    @MainActor
    func testFourthCompletionStartsLongBreakAndDeletingKeepsHistory() async throws {
        let f = Fixture()
        let store = try f.open()
        let a = store.tasks[0].id
        store.saveTask(id: a, title: "Quick focus", notes: "", duration: 1, scheduledDay: nil)
        XCTAssertFalse(store.todayTasks.contains { $0.id == a })
        for index in 1...4 {
            store.toggleFocus(a)
            XCTAssertTrue(store.todayTasks.contains { $0.id == a })
            f.advance(1, store)
            XCTAssertEqual(store.remaining, index == 4 ? 900 : 300)
            XCTAssertEqual(store.historyDays.last?.completed, index)
            store.endBreak()
        }
        store.deleteTask(a)
        XCTAssertEqual(store.historyDays.last?.seconds, 4)
        XCTAssertEqual(try f.open().historyDays.last?.completed, 4)
    }
}
