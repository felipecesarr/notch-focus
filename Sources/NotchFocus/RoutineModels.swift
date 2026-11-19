import Foundation

enum TaskCategory: String, Codable, CaseIterable {
    case study, work, creative, personal
}

enum FocusBoundary {
    case focusReminder, breakStarted, breakEnded
}

struct FocusQueueItem: Identifiable, Codable, Equatable {
    var id = UUID()
    let taskID: UUID
    var cycleIndex: Int
    // A sequence ID follows its continuations even when two runs of a task are interleaved.
    let sequenceID: UUID?
    var isWholeRoutine: Bool { sequenceID != nil }
}

struct RoutineConfiguration: Codable, Equatable {
    let breakDuration: Int
    let cycles: [String]
    let category: TaskCategory
    let weeklyTarget: Int
}

struct FocusTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var notes: String
    var duration: Int
    var scheduledDay: Date?
    var done = false
    // Older saves have no routine configuration; their original fourth-interval break still applies.
    var routine: RoutineConfiguration?
    var closedForWeek: Date?

    var breakDuration: Int { routine?.breakDuration ?? 300 }
    var category: TaskCategory { routine?.category ?? .work }
    var cycles: [String] { routine?.cycles ?? ["Focus"] }
    var weeklyTarget: Int { routine?.weeklyTarget ?? 0 }
}
