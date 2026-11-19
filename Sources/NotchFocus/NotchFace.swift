import SwiftUI

private let housingBlack = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
private let faceInk = Color(white: 0.95)
private let secondaryInk = Color(white: 0.70)
private let quietInk = Color(white: 0.55)

struct CompactNotchMetrics {
    let leftWing: CGFloat
    let rightWing: CGFloat
    let heightBelowCamera: CGFloat

    init(mode: FocusMode) {
        switch mode {
        case .focusing, .paused:
            (leftWing, rightWing, heightBelowCamera) = (100, 160, 12)
        case .onBreak:
            (leftWing, rightWing, heightBelowCamera) = (16, 70, 4)
        case .idle:
            (leftWing, rightWing, heightBelowCamera) = (8, 8, 2)
        }
    }
}

struct NotchFace: View {
    @ObservedObject var store: FocusStore
    let expanded: Bool
    let cameraWidth: CGFloat
    let topInset: CGFloat
    let openPlanner: (Bool) -> Void

    private var tint: Color { store.activeTask?.category.tint ?? secondaryInk }
    private var clock: String { String(format: "%02d:%02d", store.remaining / 60, store.remaining % 60) }
    private var hasTimer: Bool { store.mode != .idle }
    private var phase: String {
        switch store.mode {
        case .focusing: return "Focusing"
        case .paused: return "Paused"
        case .onBreak: return "Break"
        case .idle: return "Ready"
        }
    }

    var body: some View {
        ZStack {
            NotchOutline(expanded: expanded).fill(housingBlack)
            if expanded {
                expandedContent
            } else if hasTimer {
                compactContent
            }
        }
        .overlay {
            if hasTimer {
                Canvas { context, size in
                    let track = progressTrack(in: size)
                    let stroke = StrokeStyle(lineWidth: 3.25, lineCap: .round, lineJoin: .round)
                    context.stroke(track, with: .color(Color(white: 0.18)), style: stroke)
                    if store.fractionRemaining > 0 {
                        context.stroke(track.trimmedPath(from: 0, to: store.fractionRemaining),
                                       with: .color(tint), style: stroke)
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .foregroundStyle(faceInk)
        .preferredColorScheme(.dark)
        .clipShape(NotchOutline(expanded: expanded))
        .contentShape(NotchOutline(expanded: expanded))
    }

    // A single open path keeps the shrinking stroke continuous through both corners.
    private func progressTrack(in size: CGSize) -> Path {
        let left, top, bottomInset, radius: CGFloat
        if expanded {
            (left, top, bottomInset, radius) = (14, 15, 5, 13)
        } else if store.mode == .onBreak {
            (left, top, bottomInset, radius) = (14, 9, 2.25, 6)
        } else {
            (left, top, bottomInset, radius) = (17, 12, 5, 8)
        }
        let right = size.width - left
        let bottom = size.height - bottomInset
        var path = Path()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom),
                          control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius),
                          control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: top))
        return path
    }

    private var compactContent: some View {
        let task = store.activeTask
        let metrics = CompactNotchMetrics(mode: store.mode)
        let onBreak = store.mode == .onBreak
        let paused = store.mode == .paused
        let number = task.map { "\(min(store.activeCycleIndex + 1, $0.cycles.count))/\($0.cycles.count)" }

        return HStack(spacing: 0) {
            if onBreak {
                Color.clear.frame(width: metrics.leftWing)
            } else {
                HStack(spacing: paused ? 3 : 5) {
                    Image(systemName: task?.category.symbol ?? "timer")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint)
                    if paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 7.5, weight: .semibold)).foregroundStyle(secondaryInk)
                    }
                    Text(clock).font(.system(size: 14.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(paused ? secondaryInk : faceInk)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.leading, 31).padding(.trailing, 4)
                .frame(width: metrics.leftWing, alignment: .leading)
            }

            Color.clear.frame(width: cameraWidth)

            HStack(spacing: 6) {
                if onBreak {
                    Text("Break").font(.system(size: 12, weight: .medium))
                } else {
                    Text(task?.title ?? phase)
                        .font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    if let number {
                        Text(number).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(secondaryInk).fixedSize()
                    }
                }
            }
            .padding(.leading, onBreak ? 4 : 6).padding(.trailing, onBreak ? 20 : 31)
            .frame(width: metrics.rightWing, alignment: .trailing)
        }
        .padding(.bottom, onBreak ? metrics.heightBelowCamera : 6)
        .frame(height: topInset + metrics.heightBelowCamera)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(onBreak ? "Break" :
            [task?.category.title, task?.title, number, phase, clock].compactMap { $0 }.joined(separator: ", "))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 13) {
                if let task = store.activeTask {
                    Label(task.category.title, systemImage: task.category.symbol)
                        .foregroundStyle(task.category.tint)
                } else {
                    Text(hasTimer ? phase : "Today")
                }
                Spacer()
                Button { openPlanner(true) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .accessibilityLabel("Add a task").help("Add a task")
                Button { openPlanner(false) } label: {
                    HStack(spacing: 4) {
                        Text("Planner")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    }
                    .frame(minHeight: 22).contentShape(Rectangle())
                }
                .accessibilityLabel("Open task planner").help("Open task planner")
            }
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(secondaryInk)

            if let task = store.activeTask {
                ActiveTaskDetails(store: store, task: task, clock: clock, phase: phase)
            } else if store.mode == .onBreak {
                Text(clock).font(.system(size: 25, weight: .semibold).monospacedDigit())
                Spacer()
                Button("End break", action: store.endBreak)
            } else {
                HStack(alignment: .top, spacing: 28) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if store.todayTasks.isEmpty {
                                Text("No tasks for today").foregroundStyle(quietInk).padding(.top, 6)
                            }
                            ForEach(store.todayTasks) { task in idleTaskRow(task) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    if let item = store.queue.first, let task = store.tasks.first(where: { $0.id == item.taskID }) {
                        queuedItem(item, task: task).frame(width: 192, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 30)
        .padding(.top, topInset + 3)
        .padding(.bottom, hasTimer ? 16 : 12)
        .buttonStyle(.plain)
    }

    private func idleTaskRow(_ task: FocusTask) -> some View {
        let index = store.nextCycleIndex(for: task.id)
        let cycle = task.cycles.indices.contains(index) ? task.cycles[index] : ""
        let detail = task.routine == nil ? task.notes : cycle
        return HStack(spacing: 9) {
            Image(systemName: task.category.symbol)
                .font(.system(size: 13)).foregroundStyle(task.category.tint)
                .accessibilityLabel(task.category.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(1).help(task.title)
                if !detail.isEmpty {
                    HStack(spacing: 5) {
                        if task.routine != nil {
                            Text("\(index + 1)/\(task.cycles.count)")
                                .monospacedDigit().fixedSize().foregroundStyle(task.category.tint)
                        }
                        Text(detail).lineLimit(1)
                    }
                    .font(.system(size: 10.5)).foregroundStyle(secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TaskCompletionAndQueueButtons(store: store, task: task)
            Button { store.toggleFocus(task.id) } label: {
                Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 27).contentShape(Rectangle()).foregroundStyle(task.category.tint)
            }
            .accessibilityLabel("Start " + task.title).help("Start focus")
        }
        .frame(minHeight: 40)
    }

    private func queuedItem(_ item: FocusQueueItem, task: FocusTask) -> some View {
        let whole = item.isWholeRoutine && item.cycleIndex == 0
        let name = !whole && task.cycles.indices.contains(item.cycleIndex) ? task.cycles[item.cycleIndex] : task.title
        return VStack(alignment: .leading, spacing: 5) {
            Text("Up next").font(.system(size: 11, weight: .medium)).foregroundStyle(secondaryInk)
            HStack(spacing: 7) {
                Image(systemName: task.category.symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(task.category.tint)
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                Spacer(minLength: 1)
                Button(action: store.startNext) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 27).contentShape(Rectangle()).foregroundStyle(task.category.tint)
                }
                .accessibilityLabel("Start next queued cycle").help("Start next queued cycle")
            }
            .help(whole ? task.title : "\(task.title) · \(name)")
        }
    }
}

// The top corners turn out into the menu bar like the shoulders of the camera housing.
struct NotchOutline: Shape {
    let expanded: Bool
    func path(in rect: CGRect) -> Path {
        let wing: CGFloat = 8
        let radius: CGFloat = expanded ? 19 : 11
        let left = rect.minX + wing, right = rect.maxX - wing
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + wing), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - radius), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + wing))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

