import AppKit
import XCTest
@testable import NotchFocus

@MainActor
private final class RoutineFixture {
    var time = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { folder.appending(path: "sessions.json") }
    func open() throws -> FocusStore {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try FocusStore(url: url, calendar: calendar, now: { self.time }, seed: false)
    }
    func advance(_ seconds: Int, _ store: FocusStore) {
        time.addTimeInterval(Double(seconds))
        store.tick()
    }
    func create(_ title: String, cycles: [String], in store: FocusStore, weekly: Int = 0) throws -> UUID {
        try XCTUnwrap(store.saveRoutine(id: nil, title: title, notes: "", duration: 8, breakDuration: 3,
                                        cycles: cycles, category: .study, weeklyTarget: weekly))
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
}

final class RoutineFlowTests: XCTestCase {
    @MainActor
    func testNamedCyclesCustomBreaksCuesAndWeeklyReset() async throws {
        let f = RoutineFixture(), store = try f.open()
        let names = ["Recall yesterday’s concepts", "Learn new TypeScript methods", "Explain and drill"]
        let id = try f.create("Study TypeScript", cycles: names, in: store, weekly: 1)
        var boundaries = [FocusBoundary]()
        store.onBoundary = { boundaries.append($0) }
        store.toggleFocus(id)
        for index in names.indices {
            XCTAssertEqual(store.activeTask?.category, .study)
            XCTAssertEqual(store.activeCycleIndex, index)
            XCTAssertEqual(store.activeCycleTitle, names[index])
            XCTAssertEqual(store.remaining, 8)
            f.advance(8, store)
            XCTAssertEqual(store.mode, .onBreak)
            XCTAssertEqual(store.remaining, 3)
            XCTAssertEqual(store.activeTask?.id, id)
            XCTAssertEqual(store.activeCycleIndex, index)
            f.advance(3, store)
        }
        XCTAssertEqual(store.mode, .idle)
        XCTAssertEqual(store.queue.count, 0)
        XCTAssertEqual(store.focusedSeconds(for: id), 24)
        XCTAssertEqual(store.historyDays.last?.completed, 3)
        XCTAssertEqual(store.completedRunsThisWeek(for: id), 1)
        XCTAssertFalse(store.todayTasks.contains { $0.id == id })
        XCTAssertEqual(boundaries, [.breakStarted, .breakEnded, .breakStarted, .breakEnded, .breakStarted, .breakEnded])
        XCTAssertEqual(try f.open().completedRunsThisWeek(for: id), 1)
        f.advance(7 * 86400, store)
        XCTAssertEqual(store.completedRunsThisWeek(for: id), 0)
        XCTAssertTrue(store.todayTasks.contains { $0.id == id })
    }

    @MainActor
    func testQueueCanRunOneSelectedCycleOrAnEntireRoutine() async throws {
        let f = RoutineFixture(), store = try f.open()
        let a = try f.create("Study", cycles: ["Recall", "Learn"], in: store)
        let b = try f.create("Design", cycles: ["Sketch", "Refine", "Polish"], in: store)
        store.toggleFocus(a)
        store.enqueue(b, cycleIndex: 1)
        XCTAssertEqual(store.queue.map(\.cycleIndex), [1])
        f.advance(8, store)
        XCTAssertEqual(store.queue.map(\.taskID), [b, a])
        f.advance(3, store)
        XCTAssertEqual(store.activeCycleTitle, "Refine")
        f.advance(8, store)
        XCTAssertEqual(store.queue.map(\.taskID), [a], "A standalone cycle must not enqueue the next Design cycle.")
        f.advance(3, store)
        XCTAssertEqual(store.activeCycleTitle, "Learn")
        f.advance(8, store)
        f.advance(3, store)
        store.enqueueRoutine(b)
        store.startNext()
        XCTAssertEqual(store.activeCycleTitle, "Sketch")
        f.advance(8, store)
        XCTAssertEqual(store.queue.first?.taskID, b)
        XCTAssertEqual(store.mode, .onBreak)
    }

    @MainActor
    func testQueueAndBreakSurviveRelaunchWithoutPhantomFocus() async throws {
        let f = RoutineFixture(), store = try f.open()
        let id = try f.create("Study", cycles: ["Recall", "Learn"], in: store)
        store.toggleFocus(id)
        f.advance(8, store)
        store.interrupt()
        f.time.addTimeInterval(7200)
        let reopened = try f.open()
        XCTAssertEqual(reopened.mode, .idle)
        XCTAssertEqual(reopened.queue.map(\.cycleIndex), [1])
        XCTAssertEqual(reopened.focusedSeconds(for: id), 8)
        reopened.startNext()
        XCTAssertEqual(reopened.activeCycleTitle, "Learn")
        XCTAssertEqual(reopened.remaining, 8)
    }

    @MainActor
    func testMigrationReadsOriginalTimerAndHistory() async throws {
        let f = RoutineFixture(), id = UUID()
        let timestamp = f.time.timeIntervalSinceReferenceDate
        let legacy: [String:Any] = [
            "tasks": [["id":id.uuidString, "title":"Existing task", "notes":"", "duration":1500, "done":false, "scheduledDay":timestamp]],
            "segments": [["taskID":id.uuidString,"start":timestamp-420,"end":timestamp]],
            "completions":[timestamp-600], "mode":"paused", "taskID":id.uuidString, "length":1500, "budget":1080, "checkpoint":timestamp
        ]
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: f.url)
        let migrated = try f.open()
        XCTAssertEqual(migrated.activeTask?.id, id)
        XCTAssertEqual(migrated.remaining, 1080)
        XCTAssertEqual(migrated.focusedSeconds(for: id), 420)
        XCTAssertEqual(migrated.activeTask?.category, .work)
        XCTAssertEqual(migrated.activeTask?.cycles, ["Focus"])
        var sounds: [FocusBoundary] = []
        migrated.onBoundary = { sounds.append($0) }
        migrated.toggleFocus(id)
        XCTAssertEqual(migrated.mode, .focusing)
        XCTAssertEqual(migrated.remaining, 1080)
        XCTAssertEqual(migrated.historyDays.last?.completed, 1)
        f.advance(179, migrated)
        XCTAssertTrue(sounds.isEmpty, "The old file already contains seven minutes of focus.")
        f.advance(1, migrated)
        XCTAssertEqual(sounds, [.focusReminder])
    }

    @MainActor
    func testFiveMinuteRemindersFollowFocusedTimeAcrossPauseAndRelaunch() async throws {
        let f = RoutineFixture()
        let first = try f.open()
        let id = try XCTUnwrap(first.saveRoutine(id: nil, title: "Study", notes: "", duration: 1200,
                                                 breakDuration: 600, cycles: ["Recall", "Learn"],
                                                 category: .study, weeklyTarget: 0))
        var sounds: [FocusBoundary] = []
        first.onBoundary = { sounds.append($0) }
        first.toggleFocus(id)
        f.advance(299, first)
        first.toggleFocus(id)
        f.advance(340, first)
        XCTAssertTrue(sounds.isEmpty)
        first.toggleFocus(id)
        f.advance(1, first)
        first.tick()
        XCTAssertEqual(sounds, [.focusReminder])

        // Simulate reopening after an abrupt exit immediately after the first chime.
        f.time.addTimeInterval(7200)
        let restored = try f.open()
        restored.onBoundary = { sounds.append($0) }
        XCTAssertEqual(restored.mode, .paused)
        XCTAssertEqual(restored.remaining, 900)
        restored.toggleFocus(id)
        f.advance(299, restored)
        XCTAssertEqual(sounds, [.focusReminder])
        f.advance(1, restored)
        f.advance(300, restored)
        f.advance(300, restored)
        XCTAssertEqual(sounds, [.focusReminder, .focusReminder, .focusReminder, .breakStarted])
        f.advance(300, restored)
        XCTAssertEqual(sounds.count, 4)
        f.advance(300, restored)
        XCTAssertEqual(sounds.last, .breakEnded)
        XCTAssertEqual(restored.activeCycleIndex, 1)
        f.advance(300, restored)
        XCTAssertEqual(sounds.count, 6)
        XCTAssertEqual(sounds.last, .focusReminder)
    }

    @MainActor
    func testSwitchingLegacyTasksRestartsReminderCadenceWithoutBacklog() async throws {
        let f = RoutineFixture(), store = try f.open()
        for title in ["One", "Two"] {
            store.saveTask(id: nil, title: title, notes: "", duration: 1500, scheduledDay: f.time)
        }
        let a = store.tasks[0].id, b = store.tasks[1].id
        var sounds: [FocusBoundary] = []
        store.onBoundary = { sounds.append($0) }
        store.toggleFocus(a)
        f.advance(905, store)
        XCTAssertEqual(sounds, [.focusReminder], "Delayed ticks coalesce missed intervals.")
        store.toggleFocus(b)
        f.advance(200, store)
        store.toggleFocus(a)
        f.advance(299, store)
        XCTAssertEqual(sounds, [.focusReminder])
        f.advance(1, store)
        XCTAssertEqual(sounds, [.focusReminder, .focusReminder])
    }

    @MainActor
    func testTimerSoundsArePlayableAndDistinct() async throws {
        let sounds = try ["Rest", "Return", "FocusReminder"].map { name -> Data in
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "wav"))
            let data = try Data(contentsOf: url)
            let sound = try XCTUnwrap(NSSound(data: data))
            XCTAssertGreaterThan(sound.duration, 0.5)
            return data
        }
        XCTAssertEqual(Set(sounds).count, sounds.count)
    }
}
