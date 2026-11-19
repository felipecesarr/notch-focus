import SwiftUI

struct ActiveTaskDetails: View {
    @ObservedObject var store: FocusStore
    let task: FocusTask
    let clock: String
    let phase: String

    private let secondaryText = Color(white: 0.70)

    private var afterBreak: String? {
        guard store.mode == .onBreak, let next = store.queue.first,
              next.taskID == task.id, task.cycles.indices.contains(next.cycleIndex) else { return nil }
        return "After break · " + task.cycles[next.cycleIndex]
    }

    private var detailsLabel: String {
        var parts = [task.title]
        if task.routine != nil {
            parts.append("Cycle \(store.activeCycleIndex + 1) of \(task.cycles.count), \(store.activeCycleTitle)")
        }
        if !task.notes.isEmpty { parts.append(task.notes) }
        if let afterBreak { parts.append(afterBreak) }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(task.title)
                            .font(.system(size: 21, weight: .semibold))
                        if task.routine != nil, !store.activeCycleTitle.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("\(store.activeCycleIndex + 1)/\(task.cycles.count)")
                                    .monospacedDigit().fixedSize().foregroundStyle(task.category.tint)
                                Text(store.activeCycleTitle)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .accessibilityElement(children: .combine)
                        }
                        if !task.notes.isEmpty {
                            Text(task.notes).font(.system(size: 12)).foregroundStyle(secondaryText)
                        }
                        if let afterBreak {
                            Text(afterBreak)
                                .font(.system(size: 11.5)).foregroundStyle(secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(detailsLabel)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(clock).font(.system(size: 23, weight: .semibold).monospacedDigit())
                    Text(phase).font(.system(size: 11, weight: .medium)).foregroundStyle(secondaryText)
                }
                .fixedSize().accessibilityElement(children: .combine)
            }
            HStack(spacing: 14) {
                Label(plannerTime(task.duration) + " focus", systemImage: "timer")
                if task.routine != nil {
                    Label(plannerTime(task.breakDuration) + " break", systemImage: "cup.and.saucer")
                }
                if task.weeklyTarget > 0 {
                    Label("\(task.weeklyTarget)× per week", systemImage: "repeat")
                }
                Spacer(minLength: 6)
                TaskCompletionAndQueueButtons(store: store, task: task)
                Button {
                    if store.mode == .onBreak { store.endBreak() }
                    else { store.toggleFocus(task.id) }
                } label: {
                    let onBreak = store.mode == .onBreak
                    let playing = store.mode == .focusing
                    Label(onBreak ? "End break" : playing ? "Pause" : "Resume",
                          systemImage: onBreak ? "forward.end.fill" : playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(minHeight: 27).contentShape(Rectangle())
                }
                .foregroundStyle(task.category.tint)
            }
            .font(.system(size: 11)).foregroundStyle(secondaryText)
        }
    }
}

struct TaskCompletionAndQueueButtons: View {
    @ObservedObject var store: FocusStore
    let task: FocusTask

    var body: some View {
        let queued = store.queue.first { $0.taskID == task.id && $0.isWholeRoutine && $0.cycleIndex == 0 }
        Button { store.toggleDone(task.id) } label: {
            Image(systemName: "checkmark").frame(width: 22, height: 27).contentShape(Rectangle())
        }
        .accessibilityLabel("Complete " + task.title).help("Mark as done")
        Button {
            if let queued { store.removeQueued(queued.id) }
            else { store.enqueueRoutine(task.id) }
        } label: {
            Image(systemName: queued == nil ? "text.badge.plus" : "text.badge.checkmark")
                .frame(width: 22, height: 27).contentShape(Rectangle())
                .foregroundStyle(queued == nil ? Color(white: 0.65) : task.category.tint)
        }
        .accessibilityLabel("\(queued == nil ? "Queue" : "Remove queued") Pomodoro, \(task.title)")
        .help(queued == nil ? "Queue this Pomodoro" : "Remove Pomodoro from queue")
    }
}
