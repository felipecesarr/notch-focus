import SwiftUI

struct DraftCycle: Identifiable {
    let id = UUID()
    var name: String
}

@MainActor
final class RoutineDraft: ObservableObject {
    let id: UUID?
    @Published var title: String
    @Published var notes: String
    @Published var category: TaskCategory
    @Published var focusTime: String
    @Published var breakTime: String
    @Published var weeklyTarget: Int
    @Published var cycles: [DraftCycle]

    init(task: FocusTask? = nil) {
        id = task?.id
        title = task?.title ?? ""
        notes = task?.notes ?? ""
        category = task?.category ?? .work
        focusTime = Self.clock(task?.duration ?? 1500)
        breakTime = Self.clock(task?.breakDuration ?? 300)
        weeklyTarget = task?.weeklyTarget ?? 0
        cycles = (task?.cycles ?? ["Focus"]).map { DraftCycle(name: $0) }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let minutes = Int(parts[0]), (0...999).contains(minutes),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let seconds = parts.count == 2 ? Int(parts[1]) : 0
        guard let seconds, (0...59).contains(seconds) else { return nil }
        let total = minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    var focusSeconds: Int? { Self.seconds(focusTime) }
    var breakSeconds: Int? { Self.seconds(breakTime) }
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            focusSeconds != nil && breakSeconds != nil &&
            !cycles.isEmpty && cycles.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func loadStudyExample() {
        title = "Study TypeScript"
        category = .study
        focusTime = "25:00"
        breakTime = "5:00"
        weeklyTarget = 3
        cycles = ["Recall yesterday’s concepts", "Learn new TypeScript methods", "Explain today’s concept and drill it"]
            .map { DraftCycle(name: $0) }
    }
}

@MainActor
struct RoutineEditor: View {
    @ObservedObject var draft: RoutineDraft
    var save: () -> Void
    var cancel: () -> Void
    @FocusState private var field: Field?
    @State private var showNotes = false

    private enum Field: Hashable { case title, notes, focus, rest, cycle(UUID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                caption("Name")
                                Spacer()
                                if draft.id == nil && draft.title.isEmpty {
                                    Button {
                                        draft.loadStudyExample()
                                        field = nil
                                    } label: {
                                        Label("Use TypeScript example", systemImage: "book.closed")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(TaskCategory.study.tint)
                                    }.accessibilityLabel("Use Study TypeScript example")
                                }
                            }
                            TextField("Name your routine", text: $draft.title)
                                .font(.system(size: 20, weight: .semibold))
                                .accessibilityLabel("Routine name")
                                .focused($field, equals: .title)
                                .plannerInput(height: 33, selected: field == .title, tint: draft.category.tint)
                                .onSubmit { field = .focus }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            caption("Category")
                            HStack(spacing: 5) {
                                ForEach(TaskCategory.allCases, id: \.self) { category in
                                    let on = category == draft.category
                                    Button { draft.category = category } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: category.symbol).foregroundStyle(category.tint)
                                            Text(category.title).foregroundStyle(on ? category.tint : PlannerInk.secondary)
                                        }
                                            .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 9)
                                            .frame(height: 26)
                                            .background(on ? category.tint.opacity(0.12) : .clear, in: Capsule())
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("\(category.title) category")
                                    .accessibilityAddTraits(on ? .isSelected : [])
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: 14) {
                            timeField("Focus time", symbol: "timer", text: $draft.focusTime, target: .focus, valid: draft.focusSeconds != nil)
                            timeField("Break time", symbol: "cup.and.saucer", text: $draft.breakTime, target: .rest, valid: draft.breakSeconds != nil)
                            VStack(alignment: .leading, spacing: 5) {
                                caption("Repeat")
                                Menu {
                                    Button("One time") { draft.weeklyTarget = 0 }
                                    Divider()
                                    ForEach(1...7, id: \.self) { n in
                                        Button(n == 1 ? "1 time per week" : "\(n) times per week") { draft.weeklyTarget = n }
                                    }
                                } label: {
                                    Text(draft.weeklyTarget == 0 ? "One time" : "\(draft.weeklyTarget)× per week")
                                }
                                .font(.system(size: 11.5, weight: .medium))
                                .menuStyle(.borderlessButton)
                                .padding(.horizontal, 9)
                                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                .background(PlannerInk.field, in: RoundedRectangle(cornerRadius: 5))
                                    .accessibilityLabel("Repeat, \(draft.weeklyTarget == 0 ? "one time" : "\(draft.weeklyTarget) times per week")")
                            }.frame(maxWidth: .infinity)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Cycles").font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Button {
                                    let cycle = DraftCycle(name: "")
                                    draft.cycles.append(cycle)
                                    DispatchQueue.main.async {
                                        field = .cycle(cycle.id)
                                        proxy.scrollTo(cycle.id, anchor: .bottom)
                                    }
                                } label: {
                                    Label("Add cycle", systemImage: "plus").font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(draft.category.tint)
                                }
                            }
                            ForEach(Array(draft.cycles.enumerated()), id: \.element.id) { index, cycle in
                                HStack(spacing: 6) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                                        .foregroundStyle(draft.category.tint)
                                        .frame(width: 20, alignment: .leading)
                                    // A field editor can outlive the row after a removal or reordering.
                                    let binding = Binding<String>(
                                        get: { draft.cycles.first { $0.id == cycle.id }?.name ?? cycle.name },
                                        set: { name in
                                            if let offset = draft.cycles.firstIndex(where: { $0.id == cycle.id }) { draft.cycles[offset].name = name }
                                        })
                                    TextField("Cycle name", text: binding)
                                        .accessibilityLabel("Cycle \(index + 1) name")
                                        .focused($field, equals: .cycle(cycle.id))
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5))
                                        .tint(draft.category.tint)
                                    Menu {
                                        Button("Move up") { move(cycle, direction: -1) }.disabled(index == 0)
                                        Button("Move down") { move(cycle, direction: 1) }.disabled(index + 1 == draft.cycles.count)
                                        Divider()
                                        Button("Remove cycle", role: .destructive) {
                                            if draft.cycles.count > 1 { draft.cycles.removeAll { $0.id == cycle.id } }
                                        }.disabled(draft.cycles.count == 1)
                                    } label: {
                                        Image(systemName: "ellipsis").frame(width: 24, height: 25).foregroundStyle(PlannerInk.secondary)
                                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                        .accessibilityLabel("Options for cycle \(index + 1)")
                                }
                                .padding(.horizontal, 5).frame(height: 28)
                                .background(field == .cycle(cycle.id) ? draft.category.tint.opacity(0.09) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .id(cycle.id)
                            }
                        }
                        if showNotes || !draft.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                caption("Notes")
                                TextField("Optional notes", text: $draft.notes, axis: .vertical)
                                    .focused($field, equals: .notes)
                                    .lineLimit(1...3)
                                    .textFieldStyle(.plain)
                                    .padding(8)
                                    .background(PlannerInk.field, in: RoundedRectangle(cornerRadius: 6))
                            }
                        } else {
                            Button {
                                showNotes = true
                                DispatchQueue.main.async { field = .notes; proxy.scrollTo("notes", anchor: .bottom) }
                            } label: {
                                Label("Add notes", systemImage: "note.text")
                                    .font(.system(size: 10.5)).foregroundStyle(PlannerInk.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("notes").accessibilityHidden(true)
                    }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
                }
            }
            HStack(spacing: 15) {
                Spacer()
                Button("Cancel", action: cancel).foregroundStyle(PlannerInk.secondary)
                Button(action: save) {
                    PlannerAction(label: draft.id == nil ? "Create routine" : "Save changes", symbol: "checkmark", tint: draft.category.tint)
                }
                .disabled(!draft.isValid)
                .keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, 24).frame(height: 45)
        }
        .onAppear { DispatchQueue.main.async { field = .title } }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(PlannerInk.secondary)
    }

    private func timeField(_ label: String, symbol: String, text: Binding<String>, target: Field, valid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(label)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(PlannerInk.secondary)
                TextField("mm:ss", text: text).textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .focused($field, equals: target)
                    .accessibilityLabel("\(label), minutes and seconds")
                    .onSubmit { field = target == .focus ? .rest : nil }
            }.plannerInput(height: 29, selected: field == target || !valid, tint: valid ? draft.category.tint : Color(red: 0.99, green: 0.65, blue: 0.65))
            if !valid {
                Text("Use m:ss above zero").font(.system(size: 9)).foregroundStyle(Color(red: 0.99, green: 0.65, blue: 0.65))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func move(_ cycle: DraftCycle, direction: Int) {
        guard let source = draft.cycles.firstIndex(where: { $0.id == cycle.id }) else { return }
        let destination = source + direction
        guard draft.cycles.indices.contains(destination) else { return }
        draft.cycles.swapAt(source, destination)
    }
}

private extension View {
    func plannerInput(height: CGFloat, selected: Bool, tint: Color) -> some View {
        textFieldStyle(.plain).padding(.horizontal, 9).frame(height: height)
            .background(selected ? tint.opacity(0.10) : PlannerInk.field, in: RoundedRectangle(cornerRadius: 5))
            .tint(tint)
    }
}
