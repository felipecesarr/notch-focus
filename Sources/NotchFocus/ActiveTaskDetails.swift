import SwiftUI

struct ActiveTaskDetails: View {
    @ObservedObject var store: FocusStore
    let task: FocusTask
    let clock: String
    let phase: String

    private let secondaryText = Color(white: 0.70)

    private var nextAfterBreak: Int? {
        guard store.mode == .onBreak, let next = store.queue.first,
              next.taskID == task.id, task.cycles.indices.contains(next.cycleIndex) else { return nil }
        return next.cycleIndex
    }

    private var notesText: some View {
        Text(task.notes)
            .font(.system(size: 12)).foregroundStyle(secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(task.notes.isEmpty ? 2 : 1).help(task.title)
            if !task.notes.isEmpty {
                if task.routine == nil {
                    ScrollView { notesText }.scrollBounceBehavior(.basedOnSize)
                } else {
                    // Size the notes viewport to whole lines, even when the full note is much longer.
                    Text(task.notes)
                        .font(.system(size: 12)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .overlay(alignment: .topLeading) {
                            ScrollView { notesText }.scrollBounceBehavior(.basedOnSize)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, task.notes].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    private var timerControl: some View {
        let onBreak = store.mode == .onBreak
        let playing = store.mode == .focusing
        let action = onBreak ? "End break" : playing ? "Pause" : "Resume"
        return HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(clock).font(.system(size: 23, weight: .medium).monospacedDigit())
                Text(phase).font(.system(size: 10.5, weight: .medium)).foregroundStyle(secondaryText)
            }
            .accessibilityElement(children: .combine)
            Button {
                if onBreak { store.endBreak() } else { store.toggleFocus(task.id) }
            } label: {
                Image(systemName: onBreak ? "forward.end.fill" : playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(white: 0.08))
                    .frame(width: 30, height: 30)
                    .background(task.category.tint, in: Circle())
            }
            .accessibilityLabel(action)
            .iconTooltip(onBreak ? action : action + " focus")
        }
        .fixedSize()
    }

    private func subtaskRow(_ index: Int) -> some View {
        let active = index == store.activeCycleIndex
        let tint = task.category.tint
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(String(format: "%02d", index + 1))
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(active ? tint : secondaryText)
                .frame(minWidth: 17, alignment: .leading)
            Text(task.cycles[index])
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : Color(white: 0.78))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if active {
                Text(store.mode == .onBreak ? "Finished" : store.mode == .paused ? "Paused" : "Now")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint).fixedSize()
            }
            if index == nextAfterBreak {
                Text("Next").font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 25)
        .background(active ? tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var subtaskList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Subtasks").font(.system(size: 11.5, weight: .semibold))
                Text("\(store.activeCycleIndex + 1)/\(task.cycles.count)")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(secondaryText)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(task.cycles.indices, id: \.self) { index in
                            subtaskRow(index).id(index)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: store.activeCycleIndex, initial: true) { _, index in proxy.scrollTo(index) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtasksLabel)
        .id(task.id)
    }

    private var subtasksLabel: String {
        let items = task.cycles.enumerated().map { index, name in
            var item = "\(index + 1). \(name)"
            if index == store.activeCycleIndex {
                item += store.mode == .onBreak ? ", just finished" : ", current"
            }
            if index == nextAfterBreak { item += ", next after break" }
            return item
        }
        return (["Subtasks"] + items).joined(separator: ". ")
    }

    private var cadence: String {
        var parts = [plannerTime(task.duration) + " focus"]
        if task.routine != nil { parts.append(plannerTime(task.breakDuration) + " break") }
        if task.weeklyTarget > 0 { parts.append("\(task.weeklyTarget)× per week") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                taskSummary.frame(maxWidth: .infinity, alignment: .leading)
                timerControl
            }
            .frame(maxHeight: task.routine == nil ? .infinity : nil, alignment: .top)

            if task.routine != nil { subtaskList }

            HStack(spacing: 8) {
                Text(cadence).font(.system(size: 11)).foregroundStyle(secondaryText)
                Spacer(minLength: 6)
                TaskCompletionAndQueueButtons(store: store, task: task)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(secondaryText)
            }
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
        .accessibilityLabel("Complete " + task.title).iconTooltip("Mark task complete")
        Button {
            if let queued { store.removeQueued(queued.id) }
            else { store.enqueueRoutine(task.id) }
        } label: {
            Image(systemName: queued == nil ? "text.badge.plus" : "text.badge.checkmark")
                .frame(width: 22, height: 27).contentShape(Rectangle())
                .foregroundStyle(queued == nil ? Color(white: 0.65) : task.category.tint)
        }
        .accessibilityLabel("\(queued == nil ? "Queue" : "Remove queued") Pomodoro, \(task.title)")
        .iconTooltip(queued == nil ? "Queue this routine" : "Remove from queue")
    }
}
