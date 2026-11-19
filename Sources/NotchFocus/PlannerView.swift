import SwiftUI

extension Notification.Name {
    static let notchFocusCompose = Notification.Name("NotchFocus.compose")
}

enum PlannerInk {
    static let background = Color(red: 0.085, green: 0.087, blue: 0.094)
    static let sidebar = Color(red: 0.064, green: 0.066, blue: 0.073)
    static let field = Color.white.opacity(0.055)
    static let text = Color(white: 0.94)
    static let secondary = Color(white: 0.68)
    static let tertiary = Color(white: 0.53)
}

func plannerTime(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds % 60 == 0 { return "\(seconds / 60)m" }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct PlannerGlyph: View {
    let category: TaskCategory
    let size: CGFloat
    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: size * 0.70, weight: .regular))
            .foregroundStyle(category.tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PlannerIconButton: View {
    let symbol: String
    let label: String
    var color = PlannerInk.secondary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .help(label).accessibilityLabel(label)
    }
}

struct PlannerAction: View {
    var label: String
    var symbol: String
    var tint: Color?
    var body: some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(tint == nil ? PlannerInk.secondary : Color(white: 0.09))
            .padding(.horizontal, tint == nil ? 6 : 13)
            .frame(height: 30)
            .background(tint ?? .clear, in: Capsule())
            .contentShape(Rectangle())
    }
}

private enum PlannerPane { case detail, editor, queue }

@MainActor
private final class PlannerState: ObservableObject {
    static let shared = PlannerState()
    @Published var selectedID: UUID?
    @Published var pane: PlannerPane = .detail
    @Published var draft: RoutineDraft?
}

@MainActor
struct PlannerView: View {
    @ObservedObject var store: FocusStore
    let compose: Bool
    let close: () -> Void
    @ObservedObject private var state = PlannerState.shared
    @State private var confirmDelete = false

    private var selected: FocusTask? {
        store.tasks.first { $0.id == state.selectedID } ?? store.activeTask ?? store.tasks.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 180)
            VStack(alignment: .leading, spacing: 0) {
                switch state.pane {
                case .editor:
                    HStack {
                        Text(state.draft?.id == nil ? "New routine" : "Edit routine")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        closeButton
                    }
                    .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    if let draft = state.draft {
                        RoutineEditor(draft: draft, save: { save(draft) }, cancel: cancelDraft)
                            .id(ObjectIdentifier(draft))
                    }
                case .queue:
                    queueDetail
                case .detail:
                    if let selected {
                        routineDetail(selected).id(selected.id)
                    } else {
                        HStack { Spacer(); closeButton }.padding(.horizontal, 18).frame(height: 38)
                        emptyView(symbol: "list.bullet", label: "No routines yet")
                        HStack {
                            Spacer()
                            Button(action: beginAdding) { PlannerAction(label: "New routine", symbol: "plus", tint: TaskCategory.study.tint) }
                            Spacer()
                        }.padding(.bottom, 22)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PlannerInk.background)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(PlannerInk.text)
        .preferredColorScheme(.dark)
        .background(PlannerInk.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onAppear { if compose { beginAdding() } }
        .onReceive(NotificationCenter.default.publisher(for: .notchFocusCompose)) { _ in beginAdding() }
        .onExitCommand(perform: close)
    }

    private var closeButton: some View {
        PlannerIconButton(symbol: "xmark", label: "Close planner", action: close)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Routines").font(.system(size: 15, weight: .semibold))
                Spacer()
                PlannerIconButton(symbol: "plus", label: state.draft == nil ? "New routine" : "Continue draft", action: beginAdding)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.leading, 18).padding(.trailing, 10).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.tasks) { task in
                        let selectedRow = selected?.id == task.id && state.pane == .detail
                        Button {
                            state.selectedID = task.id
                            state.pane = .detail
                        } label: {
                            HStack(spacing: 9) {
                                PlannerGlyph(category: task.category, size: 21)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.title).font(.system(size: 12, weight: selectedRow ? .semibold : .medium)).lineLimit(2)
                                    Text(task.done ? "Completed" : cadence(task))
                                        .font(.system(size: 10)).foregroundStyle(PlannerInk.secondary)
                                }
                                Spacer(minLength: 0)
                                if store.activeTask?.id == task.id {
                                    Circle().fill(task.category.tint).frame(width: 5, height: 5)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedRow ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(task.title).accessibilityAddTraits(selectedRow ? .isSelected : [])
                        .contextMenu {
                            Button("Queue routine") { store.enqueueRoutine(task.id) }.disabled(task.done)
                            Button("Edit routine") { edit(task) }.disabled(state.draft != nil)
                        }
                    }
                }.padding(.horizontal, 7)
            }
            Spacer(minLength: 4)
            if state.draft != nil && state.pane != .editor {
                Button { state.pane = .editor } label: {
                    Label("Continue draft", systemImage: "pencil").font(.system(size: 11, weight: .medium))
                }.padding(.horizontal, 15).padding(.vertical, 8)
            }
            Button { state.pane = .queue } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.below.rectangle")
                    Text("Play queue").fontWeight(.medium)
                    Spacer()
                    Text("\(store.queue.count)").monospacedDigit().foregroundStyle(PlannerInk.secondary)
                }.padding(.horizontal, 11).frame(height: 35)
                    .background(state.pane == .queue ? PlannerInk.field : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }.accessibilityLabel("Play queue, \(store.queue.count) items")
                .padding(.horizontal, 7).padding(.bottom, 10)
        }.frame(maxHeight: .infinity).background(PlannerInk.sidebar)
    }

    private func cadence(_ task: FocusTask) -> String {
        task.weeklyTarget == 0 ? "One time" : "\(task.weeklyTarget)× per week"
    }

    private func routineDetail(_ task: FocusTask) -> some View {
        let wholeQueued = store.queue.contains { $0.taskID == task.id && $0.isWholeRoutine && $0.cycleIndex == 0 }
        let playing = store.activeTask?.id == task.id && store.mode == .focusing
        let paused = store.activeTask?.id == task.id && store.mode == .paused
        let current = (playing || paused || (store.activeTask?.id == task.id && store.mode == .onBreak))
            ? store.activeCycleIndex : store.nextCycleIndex(for: task.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    PlannerGlyph(category: task.category, size: 16)
                    Text(task.category.title)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(task.category.tint)
                    Spacer()
                    PlannerIconButton(symbol: "pencil", label: "Edit routine") { edit(task) }
                        .disabled(state.draft != nil)
                    Menu {
                        Button(task.done ? "Reopen routine" : "Mark complete") { store.toggleDone(task.id) }
                        Divider()
                        Button("Delete routine", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 27, height: 24)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More options for \(task.title)")
                        .popover(isPresented: $confirmDelete) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Delete this routine?").fontWeight(.semibold)
                                HStack {
                                    Button("Cancel") { confirmDelete = false }
                                    Button("Delete", role: .destructive) {
                                        confirmDelete = false
                                        if state.draft?.id == task.id { state.draft = nil }
                                        store.deleteTask(task.id)
                                    }
                                }
                            }.padding(14)
                        }
                    closeButton
                }
                Text(task.title)
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.65)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                if !task.notes.isEmpty {
                    Text(task.notes).font(.system(size: 12.5)).foregroundStyle(PlannerInk.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { routineFacts(task) }
                    VStack(alignment: .leading, spacing: 5) { routineFacts(task) }
                }.font(.system(size: 11.5)).foregroundStyle(PlannerInk.secondary).padding(.top, 10)

                HStack(spacing: 12) {
                    Button {
                        if task.done { store.toggleDone(task.id) }
                        else {
                            store.toggleFocus(task.id)
                            if store.mode == .focusing { close() }
                        }
                    } label: {
                        PlannerAction(label: task.done ? "Reopen" : playing ? "Pause" : paused ? "Resume" : "Start focus",
                                      symbol: task.done ? "arrow.uturn.backward" : playing ? "pause.fill" : "play.fill", tint: task.category.tint)
                    }
                    Button { store.enqueueRoutine(task.id) } label: {
                        PlannerAction(label: wholeQueued ? "Queued" : "Queue routine", symbol: wholeQueued ? "checkmark" : "text.badge.plus")
                    }.disabled(task.done || wholeQueued)
                }.padding(.top, 19)

                HStack(alignment: .firstTextBaseline) {
                    Text("Cycles").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(plannerTime(store.focusedSeconds(for: task.id))) focused")
                        .font(.system(size: 11)).foregroundStyle(PlannerInk.tertiary)
                }.padding(.top, 29).padding(.bottom, 5)
                ForEach(task.cycles.indices, id: \.self) { index in
                    let queued = store.queue.contains { $0.taskID == task.id && $0.cycleIndex == index && !$0.isWholeRoutine }
                    let active = current == index && !task.done
                    HStack(alignment: .center, spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(active ? task.category.tint : PlannerInk.tertiary)
                            .frame(width: 20, alignment: .leading)
                        Text(task.cycles[index])
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        PlannerIconButton(symbol: queued ? "checkmark" : "text.badge.plus",
                                          label: queued ? "Cycle \(index + 1) queued" : "Queue cycle \(index + 1), \(task.cycles[index])",
                                          color: queued ? task.category.tint : PlannerInk.tertiary) { store.enqueue(task.id, cycleIndex: index) }
                            .disabled(task.done || queued)
                    }.padding(.vertical, 5)
                }
            }.padding(.horizontal, 25).padding(.top, 18).padding(.bottom, 23)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func routineFacts(_ task: FocusTask) -> some View {
        Label("\(plannerTime(task.duration)) focus", systemImage: "timer")
        Label("\(plannerTime(task.breakDuration)) break", systemImage: "cup.and.saucer")
        Label(task.weeklyTarget > 0 ? "\(store.completedRunsThisWeek(for: task.id))/\(task.weeklyTarget) this week" : "One time",
              systemImage: "repeat")
    }

    private var queueDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Play queue").font(.system(size: 19, weight: .semibold))
                Text("\(store.queue.count)").foregroundStyle(PlannerInk.secondary).monospacedDigit()
                Spacer()
                closeButton
            }.padding(.horizontal, 24).padding(.top, 19).padding(.bottom, 15)
            if store.queue.isEmpty {
                emptyView(symbol: "list.bullet.below.rectangle", label: "Your queue is empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.queue) { item in
                            if let task = store.tasks.first(where: { $0.id == item.taskID }), task.cycles.indices.contains(item.cycleIndex) {
                                let name = item.isWholeRoutine ? task.title : task.cycles[item.cycleIndex]
                                HStack(spacing: 10) {
                                    PlannerGlyph(category: task.category, size: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name).fontWeight(.semibold)
                                        Text(queueSubtitle(item, task: task))
                                            .font(.system(size: 10.5)).foregroundStyle(PlannerInk.secondary)
                                    }
                                    Spacer()
                                    Text(plannerTime(task.duration)).help("Focus time per cycle").font(.system(size: 11).monospacedDigit()).foregroundStyle(PlannerInk.secondary)
                                    PlannerIconButton(symbol: "minus.circle", label: "Remove \(name) from queue") { store.removeQueued(item.id) }
                                }.padding(.vertical, 11)
                            }
                        }
                    }.padding(.horizontal, 20)
                }.frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button {
                        store.startNext()
                        if store.mode == .focusing { close() }
                    } label: {
                        PlannerAction(label: "Start next", symbol: "play.fill", tint: store.queue.first.flatMap { item in store.tasks.first { $0.id == item.taskID }?.category.tint } ?? TaskCategory.study.tint)
                    }
                    .disabled(store.mode == .focusing || store.mode == .paused)
                    .help("Start the next entry when idle or during a break")
                }.padding(.horizontal, 23).frame(height: 52)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func queueSubtitle(_ item: FocusQueueItem, task: FocusTask) -> String {
        if item.isWholeRoutine {
            if item.cycleIndex == 0 { return task.cycles.count == 1 ? "Full routine · 1 cycle" : "Full routine · \(task.cycles.count) cycles" }
            return "Continue at cycle \(item.cycleIndex + 1) of \(task.cycles.count)"
        }
        return "\(task.title) · Cycle \(item.cycleIndex + 1) only"
    }

    private func emptyView(symbol: String, label: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light))
            Text(label).font(.system(size: 12))
        }.foregroundStyle(PlannerInk.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginAdding() {
        if state.draft == nil { state.draft = RoutineDraft() }
        state.pane = .editor
    }

    private func edit(_ task: FocusTask) {
        guard state.draft == nil else { return }
        state.draft = RoutineDraft(task: task)
        state.pane = .editor
    }

    private func cancelDraft() {
        state.draft = nil
        state.pane = .detail
    }

    private func save(_ draft: RoutineDraft) {
        guard state.draft === draft, draft.isValid,
              let focus = draft.focusSeconds, let rest = draft.breakSeconds else { return }
        guard let savedID = store.saveRoutine(id: draft.id, title: draft.title, notes: draft.notes, duration: focus, breakDuration: rest,
                          cycles: draft.cycles.map(\.name), category: draft.category, weeklyTarget: draft.weeklyTarget) else { return }
        state.selectedID = savedID
        state.draft = nil
        state.pane = .detail
    }
}
