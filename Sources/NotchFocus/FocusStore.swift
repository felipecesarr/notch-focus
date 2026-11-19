import Combine
import Foundation

enum FocusMode: String, Codable {
    case idle, focusing, paused, onBreak
}

struct FocusDay: Identifiable {
    var id: Date { date }
    let date: Date
    let seconds: Int
    let completed: Int
}

private struct Segment: Codable {
    var taskID: UUID
    var start: Date
    var end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

private struct CompletedRun: Codable {
    let taskID: UUID
    let ended: Date
}

private struct RunProgress: Codable {
    let taskID: UUID
    var completed: Set<Int>
    var updated: Date
}

private struct Snapshot: Codable {
    var tasks: [FocusTask]
    var segments: [Segment]
    var completions: [Date]
    var mode: FocusMode
    var taskID: UUID?
    var length: Int
    var budget: TimeInterval
    var started: Date?
    var checkpoint: Date
    var queue: [FocusQueueItem]?
    var runProgress: [UUID: RunProgress]?
    var activeSequenceID: UUID?
    var standalone: Bool?
    var completedRuns: [CompletedRun]?
    var activeCycleIndex: Int?
    var holdAfterBreak: Bool?
    var focusReminderCount: Int?
}

@MainActor
final class FocusStore: ObservableObject {
    @Published private(set) var tasks: [FocusTask] = []
    @Published private(set) var mode: FocusMode = .idle
    @Published private(set) var remaining = 0

    @Published private(set) var queue: [FocusQueueItem] = []
    @Published private(set) var activeCycleIndex = 0

    private var runProgress: [UUID: RunProgress] = [:]
    private var activeSequenceID: UUID?
    private var completedRuns: [CompletedRun] = []
    private var holdAfterBreak = false
    private var taskID: UUID?
    private var length = 0
    private var budget: TimeInterval = 0
    private var started: Date?
    private static let focusReminderSeconds = 5 * 60
    private var focusReminderCount = 0
    private var segments: [Segment] = []
    private var completions: [Date] = []
    private var lastSave = Date.distantPast
    private var renderedDay: Date?
    private var saveFailed = false
    private let url: URL
    private let now: () -> Date
    private let calendar: Calendar
    var onBoundary: ((FocusBoundary) -> Void)?
    var reportSaveError: ((Error) -> Void)?

    nonisolated static var dataURL: URL {
        URL.applicationSupportDirectory.appending(path: "NotchFocus/sessions.json")
    }

    init(url: URL = FocusStore.dataURL, calendar: Calendar = .autoupdatingCurrent,
         now: @escaping () -> Date = Date.init, seed: Bool = true) throws {
        self.url = url
        self.now = now
        self.calendar = calendar
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            tasks = saved.tasks
            segments = saved.segments
            completions = saved.completions
            mode = saved.mode
            taskID = saved.taskID
            length = saved.length
            budget = saved.budget
            started = saved.started
            lastSave = saved.checkpoint
            queue = saved.queue ?? []
            runProgress = saved.runProgress ?? [:]
            activeSequenceID = saved.activeSequenceID
            if activeSequenceID == nil, saved.standalone != true, let taskID, mode != .idle {
                // In the original file format every active interval was a whole one-cycle task.
                let sequence = UUID()
                activeSequenceID = sequence
                runProgress[sequence] = RunProgress(taskID: taskID, completed: [], updated: saved.checkpoint)
            }
            completedRuns = saved.completedRuns ?? []
            activeCycleIndex = saved.activeCycleIndex ?? 0
            holdAfterBreak = saved.holdAfterBreak ?? false
            queue.removeAll { !isAvailable($0) }
            if mode == .focusing {
                // Crash recovery credits work only through the most recent durable checkpoint.
                advance(to: saved.checkpoint, live: false)
                pause(at: saved.checkpoint)
            }
            advance(to: now(), live: false)
            if mode == .paused {
                // Older files already record elapsed focus through their remaining budget.
                focusReminderCount = max(saved.focusReminderCount ?? 0, (length - remaining) / Self.focusReminderSeconds)
            }
        } else if seed {
            let today = calendar.startOfDay(for: now())
            tasks = [
                FocusTask(title: "Plan today’s work", notes: "Choose what to focus on first.", duration: 1500, scheduledDay: today),
                FocusTask(title: "Review the first build", notes: "Try the notch while you work.", duration: 1500, scheduledDay: today)
            ]
        }
        refreshRecurringTasks(at: now())
        try write(at: now())
    }

    var activeTask: FocusTask? { tasks.first { $0.id == taskID } }
    var activeCycleTitle: String {
        guard let task = activeTask, task.cycles.indices.contains(activeCycleIndex) else { return "" }
        return task.cycles[activeCycleIndex]
    }

    var fractionRemaining: Double { length > 0 ? min(1, Double(remaining) / Double(length)) : 0 }

    var todayTasks: [FocusTask] {
        let today = now()
        return tasks.filter { task in
            if task.done { return false }
            if task.id == taskID || queue.contains(where: { $0.taskID == task.id }) { return true }
            if task.routine != nil {
                return task.weeklyTarget == 0 || completedRunsThisWeek(for: task.id) < task.weeklyTarget
            }
            return task.scheduledDay.map { calendar.isDate($0, inSameDayAs: today) } == true
        }
    }

    func completedRunsThisWeek(for id: UUID) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now()) else { return 0 }
        return completedRuns.filter { $0.taskID == id && $0.ended >= week.start && $0.ended < week.end }.count
    }

    func nextCycleIndex(for id: UUID) -> Int {
        guard let task = tasks.first(where: { $0.id == id }) else { return 0 }
        if id == taskID && (mode == .paused || mode == .focusing) { return activeCycleIndex }
        return resumableEntry(for: task)?.cycleIndex ?? 0
    }

    // Retain the old day-based editing path for existing tasks and callers.
    func saveTask(id: UUID?, title: String, notes: String, duration: Int, scheduledDay: Date?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let day = scheduledDay.map { calendar.startOfDay(for: $0) }
        if let id {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].title = title
            tasks[i].notes = notes
            tasks[i].duration = max(1, duration)
            tasks[i].scheduledDay = day
        } else {
            tasks.append(FocusTask(title: title, notes: notes, duration: max(1, duration), scheduledDay: day))
        }
        persist(at: now())
    }

    @discardableResult
    func saveRoutine(id: UUID?, title: String, notes: String, duration: Int, breakDuration: Int,
                     cycles: [String], category: TaskCategory, weeklyTarget: Int) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let names = cycles.enumerated().map { index, name in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? "Cycle \(index + 1)" : clean
        }
        let configuration = RoutineConfiguration(breakDuration: max(1, breakDuration),
                                                 cycles: names.isEmpty ? ["Focus"] : names,
                                                 category: category, weeklyTarget: min(7, max(0, weeklyTarget)))
        let time = now()
        advance(to: time)
        let taskID = id ?? UUID()
        if let id {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return nil }
            if tasks[i].cycles != configuration.cycles {
                remapCycles(for: tasks[i], to: configuration.cycles, at: time)
            }
            tasks[i].title = title
            tasks[i].notes = notes
            tasks[i].duration = max(1, duration)
            tasks[i].scheduledDay = nil
            tasks[i].routine = configuration
            if tasks[i].done && configuration.weeklyTarget > 0 {
                tasks[i].closedForWeek = calendar.dateInterval(of: .weekOfYear, for: time)?.start
            }
        } else {
            tasks.append(FocusTask(id: taskID, title: title, notes: notes, duration: max(1, duration),
                                   scheduledDay: nil, routine: configuration))
        }
        persist(at: time)
        return taskID
    }

    private func remapCycles(for task: FocusTask, to names: [String], at time: Date) {
        var available = Array(names.indices)
        var mapping: [Int: Int] = [:]
        // Preserve named cycles through movement or deletion, then match renames by position.
        for (old, name) in task.cycles.enumerated() {
            if let match = available.firstIndex(where: { names[$0] == name }) {
                mapping[old] = available.remove(at: match)
            }
        }
        for i in available where task.cycles.indices.contains(i) && mapping[i] == nil { mapping[i] = i }
        for (sequence, progress) in runProgress where progress.taskID == task.id {
            runProgress[sequence]?.completed = Set(progress.completed.compactMap { mapping[$0] })
        }
        queue = queue.compactMap { item in
            guard item.taskID == task.id else { return item }
            guard let index = mapping[item.cycleIndex] else { return nil }
            var item = item
            item.cycleIndex = index
            return item
        }
        if taskID == task.id {
            if let mapped = mapping[activeCycleIndex] { activeCycleIndex = mapped }
            else if mode == .onBreak { activeCycleIndex = min(activeCycleIndex, names.count - 1) }
            else { finishEarly(at: time) }
        }
    }

    func toggleDone(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let time = now()
        advance(to: time)
        if id == taskID { finishEarly(at: time) }
        tasks[i].done.toggle()
        tasks[i].closedForWeek = tasks[i].done && tasks[i].weeklyTarget > 0
            ? calendar.dateInterval(of: .weekOfYear, for: time)?.start : nil
        if tasks[i].done {
            queue.removeAll { $0.taskID == id }
            runProgress = runProgress.filter { $0.value.taskID != id }
        }
        persist(at: time)
    }

    func deleteTask(_ id: UUID) {
        let time = now()
        advance(to: time)
        if id == taskID { finishEarly(at: time) }
        tasks.removeAll { $0.id == id }
        queue.removeAll { $0.taskID == id }
        runProgress = runProgress.filter { $0.value.taskID != id }
        persist(at: time)
    }

    func toggleFocus(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id && !$0.done }) else { return }
        let time = now()
        let requestedPause = id == taskID && mode == .focusing
        let transitioned = advance(to: time)
        if requestedPause {
            // A click on Pause at the deadline must not skip the new break or pause a different cycle.
            if !transitioned { pause(at: time) }
        } else if id == taskID && mode == .paused {
            started = time
            mode = .focusing
            updateRemaining(at: time)
        } else if !(transitioned && mode == .focusing && id == taskID) {
            let entry = resumableEntry(for: task) ?? FocusQueueItem(taskID: id, cycleIndex: 0, sequenceID: UUID())
            if mode == .onBreak { onBoundary?(.breakEnded) }
            recordSegment(through: time)
            queue.removeAll { $0.id == entry.id }
            begin(task, entry: entry, at: time)
        }
        persist(at: time)
    }

    private func resumableEntry(for task: FocusTask) -> FocusQueueItem? {
        let latest = runProgress.filter { $0.value.taskID == task.id }
            .max { $0.value.updated < $1.value.updated }
        if let (sequence, progress) = latest {
            if let continuation = queue.first(where: { $0.sequenceID == sequence }) { return continuation }
            let index = task.cycles.indices.first { !progress.completed.contains($0) } ?? 0
            return FocusQueueItem(taskID: task.id, cycleIndex: index, sequenceID: sequence)
        }
        return queue.first { $0.taskID == task.id && $0.isWholeRoutine }
    }

    func enqueueRoutine(_ taskID: UUID) {
        appendToQueue(FocusQueueItem(taskID: taskID, cycleIndex: 0, sequenceID: UUID()))
    }

    func enqueue(_ taskID: UUID, cycleIndex: Int = 0) {
        appendToQueue(FocusQueueItem(taskID: taskID, cycleIndex: cycleIndex, sequenceID: nil))
    }

    private func appendToQueue(_ entry: FocusQueueItem) {
        guard isAvailable(entry), !queue.contains(where: {
            $0.taskID == entry.taskID && $0.cycleIndex == entry.cycleIndex && $0.isWholeRoutine == entry.isWholeRoutine
        }) else { return }
        queue.append(entry)
        persist(at: now())
    }

    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
        persist(at: now())
    }

    func startNext() {
        guard mode == .idle || mode == .onBreak, !queue.isEmpty else { return }
        let time = now()
        if mode == .onBreak { onBoundary?(.breakEnded) }
        startQueueHead(at: time)
        persist(at: time)
    }

    private func isAvailable(_ item: FocusQueueItem) -> Bool {
        tasks.contains { $0.id == item.taskID && !$0.done && $0.cycles.indices.contains(item.cycleIndex) }
    }

    private func begin(_ task: FocusTask, entry: FocusQueueItem, at time: Date) {
        if activeSequenceID != entry.sequenceID { discardEmptyRun() }
        taskID = task.id
        activeSequenceID = entry.sequenceID
        if let sequence = entry.sequenceID, runProgress[sequence] == nil {
            runProgress[sequence] = RunProgress(taskID: task.id, completed: [], updated: time)
        }
        activeCycleIndex = entry.cycleIndex
        focusReminderCount = 0
        length = task.duration
        budget = Double(length)
        started = time
        holdAfterBreak = false
        mode = .focusing
        updateRemaining(at: time)
    }

    private func startQueueHead(at time: Date) {
        queue.removeAll { !isAvailable($0) }
        guard let head = queue.first, let task = tasks.first(where: { $0.id == head.taskID }) else {
            setIdle()
            return
        }
        queue.removeFirst()
        begin(task, entry: head, at: time)
    }

    func endBreak() {
        guard mode == .onBreak else { return }
        let time = now()
        onBoundary?(.breakEnded)
        startQueueHead(at: time)
        persist(at: time)
    }

    func interrupt() {
        let time = now()
        advance(to: time, live: false)
        pause(at: time)
        if mode == .onBreak { holdAfterBreak = true }
        persist(at: time)
    }

    func tick() {
        let time = now()
        let transitioned = advance(to: time)
        let day = calendar.startOfDay(for: time)
        var newDay = false
        if day != renderedDay {
            renderedDay = day
            refreshRecurringTasks(at: time)
            objectWillChange.send()
            newDay = true
        }
        if transitioned || newDay || saveFailed || (mode == .focusing && time.timeIntervalSince(lastSave) >= 10) {
            persist(at: time)
        }
    }

    private func refreshRecurringTasks(at time: Date) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: time) else { return }
        for i in tasks.indices where tasks[i].weeklyTarget > 0 && tasks[i].done {
            if let closed = tasks[i].closedForWeek, closed < week.start {
                tasks[i].done = false
                tasks[i].closedForWeek = nil
            }
        }
    }

    @discardableResult
    private func advance(to time: Date, live: Bool = true) -> Bool {
        guard let start = started else { updateRemaining(at: time); return false }
        let deadline = start.addingTimeInterval(budget)
        guard time >= deadline else {
            updateRemaining(at: time)
            if mode == .focusing {
                let completedBlocks = (length - remaining) / Self.focusReminderSeconds
                if completedBlocks > focusReminderCount {
                    focusReminderCount = completedBlocks
                    if live {
                        // Checkpoint before ringing so a relaunch cannot replay this cue.
                        persist(at: time)
                        onBoundary?(.focusReminder)
                    }
                }
            }
            return false
        }
        if mode == .focusing, let task = activeTask {
            recordSegment(through: deadline)
            completions.append(deadline)
            completeCycle(of: task, at: deadline)
            length = task.routine == nil && completions.count.isMultiple(of: 4) ? 900 : task.breakDuration
            budget = Double(length)
            started = deadline
            mode = .onBreak
            // One delayed wake-up can span the entire break. Keep the next cycle queued for an explicit start.
            if time >= deadline.addingTimeInterval(budget) {
                setIdle()
            } else if live {
                onBoundary?(.breakStarted)
            }
        } else if mode == .onBreak {
            if live && !holdAfterBreak {
                onBoundary?(.breakEnded)
                // Focus begins when the app actually handles the boundary; never backdate a queued run.
                startQueueHead(at: time)
            } else {
                setIdle()
            }
        } else {
            setIdle()
        }
        updateRemaining(at: time)
        return true
    }

    private func completeCycle(of task: FocusTask, at time: Date) {
        guard let sequence = activeSequenceID else {
            if task.cycles.count == 1 { completedRuns.append(CompletedRun(taskID: task.id, ended: time)) }
            return
        }
        var finished = runProgress[sequence]?.completed ?? []
        finished.insert(activeCycleIndex)
        if finished.count == task.cycles.count {
            completedRuns.append(CompletedRun(taskID: task.id, ended: time))
            runProgress[sequence] = nil
            return
        }
        runProgress[sequence] = RunProgress(taskID: task.id, completed: finished, updated: time)
        let rest = task.cycles.indices.filter { !finished.contains($0) }
        if let next = rest.first(where: { $0 > activeCycleIndex }) ?? rest.first {
            // Respect explicit FIFO choices. A continuation carries its own run identity.
            queue.append(FocusQueueItem(taskID: task.id, cycleIndex: next, sequenceID: sequence))
        }
    }

    private func updateRemaining(at time: Date) {
        let elapsed = started.map { max(0, time.timeIntervalSince($0)) } ?? 0
        let value = Int(ceil(max(0, budget - elapsed)))
        if remaining != value { remaining = value }
    }

    private func recordSegment(through time: Date) {
        guard mode == .focusing, let id = taskID, let start = started else { return }
        let end = min(time, start.addingTimeInterval(budget))
        if end > start { segments.append(Segment(taskID: id, start: start, end: end)) }
    }

    private func pause(at time: Date) {
        guard mode == .focusing, let start = started else { return }
        recordSegment(through: time)
        budget = max(0, budget - max(0, time.timeIntervalSince(start)))
        started = nil
        mode = .paused
        updateRemaining(at: time)
    }

    private func finishEarly(at time: Date) {
        recordSegment(through: time)
        setIdle()
    }

    private func discardEmptyRun() {
        if let sequence = activeSequenceID, runProgress[sequence]?.completed.isEmpty == true {
            runProgress[sequence] = nil
        }
    }

    private func setIdle() {
        discardEmptyRun()
        taskID = nil
        activeCycleIndex = 0
        activeSequenceID = nil
        holdAfterBreak = false
        started = nil
        length = 0
        budget = 0
        mode = .idle
        remaining = 0
    }

    private var allSegments: [Segment] {
        guard mode == .focusing, let taskID, let start = started else { return segments }
        let end = min(now(), start.addingTimeInterval(budget))
        guard end > start else { return segments }
        return segments + [Segment(taskID: taskID, start: start, end: end)]
    }

    func focusedSeconds(for id: UUID) -> Int {
        Int(allSegments.lazy.filter { $0.taskID == id }.reduce(0) { $0 + $1.duration })
    }

    var historyDays: [FocusDay] {
        let today = calendar.startOfDay(for: now())
        let days = (-47...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let oldest = days.first else { return [] }
        var dayTime: [Date: TimeInterval] = [:]
        for interval in allSegments where interval.end > oldest {
            var cursor = max(oldest, interval.start)
            while cursor < interval.end, let day = calendar.dateInterval(of: .day, for: cursor) {
                let end = min(interval.end, day.end)
                dayTime[day.start, default: 0] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
        let counts = Dictionary(grouping: completions.filter { $0 >= oldest }) { calendar.startOfDay(for: $0) }
        return days.map { FocusDay(date: $0, seconds: Int(dayTime[$0] ?? 0), completed: counts[$0]?.count ?? 0) }
    }

    var streak: Int {
        let days = Set(completions.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now())
        if !days.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor), let previous = calendar.date(byAdding: .day, value: -1, to: cursor) {
            count += 1
            cursor = previous
        }
        return count
    }

    private func persist(at time: Date) {
        do { try write(at: time); saveFailed = false }
        catch {
            let firstFailure = !saveFailed
            saveFailed = true
            if firstFailure { reportSaveError?(error) }
        }
    }

    private func write(at time: Date) throws {
        let snapshot = Snapshot(tasks: tasks, segments: segments, completions: completions, mode: mode,
                                taskID: taskID, length: length, budget: budget, started: started, checkpoint: time,
                                queue: queue, runProgress: runProgress, activeSequenceID: activeSequenceID,
                                standalone: activeSequenceID == nil, completedRuns: completedRuns,
                                activeCycleIndex: activeCycleIndex, holdAfterBreak: holdAfterBreak,
                                focusReminderCount: mode == .focusing || mode == .paused ? focusReminderCount : nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        lastSave = time
    }
}
