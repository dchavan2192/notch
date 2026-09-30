import SwiftUI
import AppKit
import Combine
import EventKit
import UniformTypeIdentifiers

// MARK: - Notch geometry

enum NotchMetrics {
    static func screen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func closedSize(for screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let w = screen.frame.width - left.width - right.width
            return CGSize(width: w, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 190, height: 32)
    }
}

// MARK: - Types

enum NotchTab: String, CaseIterable, Identifiable {
    case timer, tasks, schedule, shelf, clipboard, notes
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .timer: return "timer"
        case .tasks: return "checklist"
        case .schedule: return "calendar"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notes: return "note.text"
        }
    }
    var title: String {
        switch self {
        case .timer: return "Focus timer"
        case .tasks: return "Assignments"
        case .schedule: return "Schedule"
        case .shelf: return "File shelf"
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        }
    }
}

enum PomoMode: String, CaseIterable, Identifiable {
    case focus = "Focus"
    case short = "Break"
    case long = "Long"
    var id: String { rawValue }
}

enum CalAuth { case unknown, granted, denied }

enum DueChoice: CaseIterable {
    case noDate, today, tomorrow, threeDays, nextWeek

    var label: String {
        switch self {
        case .noDate: return "No date"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .threeDays: return "In 3 days"
        case .nextWeek: return "Next week"
        }
    }

    var next: DueChoice {
        let all = DueChoice.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    func date() -> Date? {
        let offset: Int
        switch self {
        case .noDate: return nil
        case .today: offset = 0
        case .tomorrow: offset = 1
        case .threeDays: offset = 3
        case .nextWeek: offset = 7
        }
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: offset, to: Date()) else { return nil }
        return cal.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }
}

struct TaskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var due: Date?
    var done = false
}

struct CalEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let color: Color
}

/// What shows beside the notch while it is collapsed.
struct Ear {
    let icon: String
    let color: Color
    let left: String?
    let right: String
    let width: CGFloat
}

// MARK: - Model

final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    // Layout
    let openSize = CGSize(width: 680, height: 220)
    var closedSize = CGSize(width: 190, height: 32)
    var closedWidth: CGFloat { closedSize.width + 2 * (ear?.width ?? 0) }

    // UI state
    @Published var isOpen = false
    @Published var tab: NotchTab = .timer
    @Published var isDropTargeted = false
    var pinnedUntil = Date.distantPast
    var isTyping = false

    // Pomodoro timer
    @Published var mode: PomoMode = .focus
    @Published var focusMins = 25 { didSet { UserDefaults.standard.set(focusMins, forKey: "focusMins") } }
    @Published var autoStart = true { didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") } }
    @Published var total = 25 * 60
    @Published var remaining = 25 * 60
    @Published var running = false
    @Published var roundsInSet = 0
    @Published var banner: String?
    private var ticker: Timer?
    private var endDate: Date?

    // Stats
    @Published var statsMinutes: [String: Int] = [:]
    @Published var statsSessions: [String: Int] = [:]

    // Assignments
    @Published var tasks: [TaskItem] = [] { didSet { saveTasks() } }

    // Calendar
    @Published var calAuth: CalAuth = .unknown
    @Published var events: [CalEvent] = []
    private let eventStore = EKEventStore()

    // Shelf
    @Published var shelf: [URL] = [] {
        didSet { UserDefaults.standard.set(shelf.map { $0.path }, forKey: "shelf") }
    }

    // Clipboard
    @Published var clips: [String] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var clipTimer: Timer?
    private var minuteTimer: Timer?

    // Notes
    @Published var note: String = UserDefaults.standard.string(forKey: "note") ?? "" {
        didSet { UserDefaults.standard.set(note, forKey: "note") }
    }

    init() {
        let ud = UserDefaults.standard
        let savedFocus = ud.integer(forKey: "focusMins")
        if savedFocus > 0 { focusMins = savedFocus }
        if let a = ud.object(forKey: "autoStart") as? Bool { autoStart = a }
        total = focusMins * 60
        remaining = total

        statsMinutes = (ud.dictionary(forKey: "statsMinutes") as? [String: Int]) ?? [:]
        statsSessions = (ud.dictionary(forKey: "statsSessions") as? [String: Int]) ?? [:]

        if let d = ud.data(forKey: "tasks"),
           let t = try? JSONDecoder().decode([TaskItem].self, from: d) {
            tasks = t
        }

        let paths = ud.stringArray(forKey: "shelf") ?? []
        shelf = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: Background work

    func startBackground() {
        startClipboardWatch()
        refreshCalendar()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in self?.refreshCalendar() }

        // Keeps "in 12m" / "2d left" labels fresh.
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshCalendar()
            self?.objectWillChange.send()
        }
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
    }

    // MARK: Closed-notch info ("ears")

    var ear: Ear? {
        if running {
            let focus = mode == .focus
            return Ear(icon: focus ? "timer" : "cup.and.saucer.fill",
                       color: focus ? Color.orange : Color.green,
                       left: nil, right: timeString, width: 70)
        }
        let now = Date()
        if let ev = events.first(where: {
            !$0.isAllDay
            && $0.start.timeIntervalSince(now) <= 900
            && $0.start.timeIntervalSince(now) >= -300
        }) {
            let d = ev.start.timeIntervalSince(now)
            let right = d <= 0 ? "now" : "in \(max(1, Int(ceil(d / 60))))m"
            return Ear(icon: "calendar", color: Color.cyan, left: ev.title, right: right, width: 120)
        }
        if let t = nextDeadline, let due = t.due {
            let s = due.timeIntervalSince(now)
            if s < 48 * 3600 && s > -86400 {
                let over = s <= 0
                return Ear(icon: "exclamationmark.circle.fill",
                           color: over ? Color.red : Color.yellow,
                           left: t.title,
                           right: over ? "overdue" : "\(NotchModel.leftText(due)) left",
                           width: 120)
            }
        }
        return nil
    }

    // MARK: Timer logic

    var timeString: String {
        let r = remaining
        let h = r / 3600, m = (r % 3600) / 60, s = r % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    func duration(for m: PomoMode) -> Int {
        switch m {
        case .focus: return focusMins * 60
        case .short: return 5 * 60
        case .long: return 15 * 60
        }
    }

    func start() {
        if remaining <= 0 { remaining = total }
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        running = true
        ticker?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        running = false
    }

    func reset() {
        pause()
        remaining = total
    }

    func setMode(_ m: PomoMode) {
        pause()
        mode = m
        total = duration(for: m)
        remaining = total
    }

    func setFocusMins(_ n: Int) {
        focusMins = n
        if mode == .focus {
            pause()
            total = n * 60
            remaining = total
        }
    }

    func skip() {
        pause()
        advance(completed: false)
    }

    private func advance(completed: Bool) {
        let finishedMode = mode
        if completed && finishedMode == .focus { recordFocus(minutes: max(1, total / 60)) }
        switch finishedMode {
        case .focus:
            if completed { roundsInSet += 1 }
            mode = roundsInSet >= 4 ? .long : .short
        case .short:
            mode = .focus
        case .long:
            mode = .focus
            roundsInSet = 0
        }
        total = duration(for: mode)
        remaining = total
    }

    private func tick() {
        guard let end = endDate else { return }
        let left = max(0, Int(ceil(end.timeIntervalSinceNow)))
        if left != remaining { remaining = left }
        if left <= 0 { complete() }
    }

    private func complete() {
        pause()
        remaining = 0
        NSSound(named: NSSound.Name("Glass"))?.play()
        let wasFocus = mode == .focus
        advance(completed: true)
        setBanner(wasFocus ? "Focus session done - take a break!" : "Break's over - back to it!")
        tab = .timer
        pinnedUntil = Date().addingTimeInterval(5)
        isOpen = true
        if autoStart { start() }
    }

    private func setBanner(_ s: String) {
        banner = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.banner == s { self?.banner = nil }
        }
    }

    // MARK: Stats

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { dayFormatter.string(from: d) }

    static func fmt(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func recordFocus(minutes: Int) {
        let k = NotchModel.key(Date())
        statsMinutes[k, default: 0] += minutes
        statsSessions[k, default: 0] += 1
        UserDefaults.standard.set(statsMinutes, forKey: "statsMinutes")
        UserDefaults.standard.set(statsSessions, forKey: "statsSessions")
    }

    var todayMinutes: Int { statsMinutes[NotchModel.key(Date())] ?? 0 }
    var todaySessions: Int { statsSessions[NotchModel.key(Date())] ?? 0 }

    var weekMinutes: Int {
        let cal = Calendar.current
        return (0..<7).reduce(0) { sum, i in
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { return sum }
            return sum + (statsMinutes[NotchModel.key(d)] ?? 0)
        }
    }

    var streak: Int {
        let cal = Calendar.current
        var day = Date()
        if (statsMinutes[NotchModel.key(day)] ?? 0) == 0 {
            guard let y = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var n = 0
        while (statsMinutes[NotchModel.key(day)] ?? 0) > 0 {
            n += 1
            guard let p = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = p
        }
        return n
    }

    // MARK: Assignments

    private func saveTasks() {
        if let d = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(d, forKey: "tasks")
        }
    }

    var sortedTasks: [TaskItem] {
        tasks.sorted { a, b in
            if a.done != b.done { return !a.done }
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    var nextDeadline: TaskItem? {
        tasks.filter { !$0.done && $0.due != nil }
            .min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    func addTask(_ title: String, due: Date?) {
        tasks.append(TaskItem(title: title, due: due))
    }

    func toggle(_ id: UUID) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].done.toggle() }
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    static func leftText(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s <= 0 { return "overdue" }
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    // MARK: Calendar

    func refreshCalendar() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            calAuth = .granted
            loadEvents()
        case .notDetermined:
            calAuth = .unknown
            events = []
        default:
            calAuth = .denied
            events = []
        }
    }

    func requestCalendar() {
        NSApp.activate(ignoringOtherApps: true)
        eventStore.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshCalendar() }
        }
    }

    private func loadEvents() {
        let cal = Calendar.current
        let now = Date()
        guard let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) else { return }
        let pred = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = eventStore.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
        var out: [CalEvent] = []
        for ev in found {
            let loc: String? = (ev.location?.isEmpty == false) ? ev.location : nil
            out.append(CalEvent(
                id: (ev.eventIdentifier ?? UUID().uuidString) + "\(ev.startDate.timeIntervalSince1970)",
                title: ev.title ?? "Untitled",
                start: ev.startDate,
                end: ev.endDate,
                isAllDay: ev.isAllDay,
                location: loc,
                color: Color(cgColor: ev.calendar.cgColor)
            ))
        }
        events = out
    }

    // MARK: Shelf

    func addFile(_ url: URL) {
        let u = url.standardizedFileURL
        guard !shelf.contains(u) else { return }
        shelf.append(u)
    }

    func removeFile(_ url: URL) {
        shelf.removeAll { $0 == url }
    }

    // MARK: Clipboard

    private func startClipboardWatch() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(t, forMode: .common)
        clipTimer = t
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        if pb.types?.contains(concealed) == true { return }
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return }
        clips.removeAll { $0 == s }
        clips.insert(s, at: 0)
        if clips.count > 20 { clips.removeLast() }
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        lastChange = pb.changeCount
    }
}

// MARK: - Styles

struct PillStyle: ButtonStyle {
    var prominent = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = prominent
            ? Color.orange
            : Color.white.opacity(selected ? 0.3 : (configuration.isPressed ? 0.25 : 0.12))
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(bg))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct MessageCard: View {
    let icon: String
    let text: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
            if let b = buttonTitle, let a = action {
                Button(b, action: a).buttonStyle(PillStyle(prominent: true))
            }
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Root views

struct NotchRoot: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        let open = m.isOpen
        let w = open ? m.openSize.width : m.closedWidth
        let h = open ? m.openSize.height : m.closedSize.height
        let r: CGFloat = open ? 28 : 9
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: 0,
            style: .continuous
        )

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: w, height: h)
                .overlay(alignment: .top) {
                    OpenContent(m: m)
                        .opacity(open ? 1 : 0)
                        .allowsHitTesting(open)
                        .animation(.easeInOut(duration: 0.2).delay(open ? 0.12 : 0), value: open)
                }
                .overlay(alignment: .top) {
                    ClosedContent(m: m)
                        .opacity(open ? 0 : 1)
                        .animation(.easeInOut(duration: 0.15), value: open)
                }
                .clipShape(shape)
        }
        .frame(width: m.openSize.width, height: m.openSize.height, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: open)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: m.closedWidth)
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL], isTargeted: $m.isDropTargeted) { providers in
            var handled = false
            for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    if let url = url {
                        DispatchQueue.main.async { m.addFile(url) }
                    }
                }
            }
            return handled
        }
        .onChange(of: m.isDropTargeted) { _, targeted in
            if targeted { m.tab = .shelf }
        }
    }
}

struct ClosedContent: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        if let e = m.ear {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: e.icon)
                    if let l = e.left { Text(l).lineLimit(1) }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(e.color)
                .padding(.leading, e.left == nil ? 0 : 12)
                .frame(width: e.width, alignment: e.left == nil ? .center : .leading)

                Spacer(minLength: 0)

                Text(e.right)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(e.color)
                    .frame(width: e.width)
            }
            .frame(width: m.closedWidth, height: m.closedSize.height)
        }
    }
}

struct OpenContent: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotchTab.allCases) { t in
                    TabIcon(tab: t, m: m)
                }
                Spacer(minLength: m.closedSize.width + 20)
                Text(Date(), style: .time)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Quit Notch")
            }
            .padding(.horizontal, 22)
            .frame(height: m.closedSize.height)

            Group {
                switch m.tab {
                case .timer: TimerTab(m: m)
                case .tasks: TasksTab(m: m)
                case .schedule: ScheduleTab(m: m)
                case .shelf: ShelfTab(m: m)
                case .clipboard: ClipTab(m: m)
                case .notes: NotesTab(m: m)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: m.openSize.width, height: m.openSize.height, alignment: .top)
    }
}

struct TabIcon: View {
    let tab: NotchTab
    @ObservedObject var m: NotchModel
    var body: some View {
        let selected = m.tab == tab
        Button { m.tab = tab } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.clear))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

// MARK: - Timer tab (Pomodoro + stats)

struct TimerTab: View {
    @ObservedObject var m: NotchModel

    var progress: Double {
        m.total > 0 ? Double(m.remaining) / Double(m.total) : 0
    }
    var ringColor: Color {
        if m.mode != .focus { return Color.green }
        return m.running ? Color.orange : Color.white.opacity(0.7)
    }

    var body: some View {
        HStack(spacing: 26) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: m.remaining)
                VStack(spacing: 2) {
                    Text(m.mode.rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(ringColor)
                    Text(m.timeString)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Color.white)
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i < m.roundsInSet ? Color.orange : Color.white.opacity(0.2))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 122, height: 122)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(PomoMode.allCases) { md in
                        Button(md.rawValue) { m.setMode(md) }
                            .buttonStyle(PillStyle(selected: m.mode == md))
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        if m.running { m.pause() } else { m.start() }
                    } label: {
                        Label(m.running ? "Pause" : "Start",
                              systemImage: m.running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PillStyle(prominent: true))

                    Button { m.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(PillStyle())
                        .help("Reset")
                    Button { m.skip() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(PillStyle())
                        .help("Skip to next phase")
                    Button { m.autoStart.toggle() } label: {
                        Label("Auto", systemImage: m.autoStart ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(PillStyle(selected: m.autoStart))
                    .help("Automatically start the next phase")
                }

                HStack(spacing: 8) {
                    Text("Focus length")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                    ForEach([15, 25, 45, 60], id: \.self) { mins in
                        Button("\(mins)m") { m.setFocusMins(mins) }
                            .buttonStyle(PillStyle(selected: m.focusMins == mins))
                    }
                }

                if let b = m.banner {
                    Text(b)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.green)
                } else {
                    HStack(spacing: 14) {
                        stat("clock", "\(NotchModel.fmt(m.todayMinutes)) today", Color.white.opacity(0.6))
                        stat("calendar", "\(NotchModel.fmt(m.weekMinutes)) this week", Color.white.opacity(0.6))
                        stat("flame.fill", "\(m.streak)-day streak",
                             m.streak > 0 ? Color.orange : Color.white.opacity(0.4))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    func stat(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
    }
}

// MARK: - Assignments tab

struct TasksTab: View {
    @ObservedObject var m: NotchModel
    @State private var title = ""
    @State private var due: DueChoice = .tomorrow
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add an assignment...", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
                    .focused($focused)
                    .onSubmit { add() }

                Button { due = due.next } label: {
                    Label(due.label, systemImage: "calendar")
                }
                .buttonStyle(PillStyle())
                .help("Click to change the due date")

                Button("Add") { add() }
                    .buttonStyle(PillStyle(prominent: true))
            }

            if m.tasks.isEmpty {
                MessageCard(icon: "checklist",
                            text: "No assignments yet - add one above.\nThe closed notch will warn you when a deadline is close.")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(m.sortedTasks) { t in
                            TaskRow(task: t, m: m)
                        }
                    }
                }
            }
        }
        .onChange(of: focused) { _, f in m.isTyping = f }
    }

    func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        m.addTask(t, due: due.date())
        title = ""
    }
}

struct TaskRow: View {
    let task: TaskItem
    @ObservedObject var m: NotchModel
    @State private var hover = false

    var dueColor: Color {
        guard let due = task.due else { return Color.white.opacity(0.5) }
        if task.done { return Color.white.opacity(0.3) }
        let s = due.timeIntervalSinceNow
        if s <= 0 { return Color.red }
        if s < 86400 { return Color.orange }
        return Color.white.opacity(0.55)
    }

    var dueText: String {
        guard let due = task.due else { return "" }
        let day = due.formatted(.dateTime.weekday(.abbreviated))
        if task.done { return day }
        let s = due.timeIntervalSinceNow
        return s <= 0 ? "Overdue" : "\(day) - \(NotchModel.leftText(due)) left"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { m.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.done ? Color.green : Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)

            Text(task.title)
                .font(.system(size: 13))
                .strikethrough(task.done)
                .foregroundStyle(Color.white.opacity(task.done ? 0.4 : 0.95))
                .lineLimit(1)

            Spacer()

            Text(dueText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dueColor)

            if hover {
                Button { m.delete(task.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .onHover { hover = $0 }
    }
}

// MARK: - Schedule tab (Calendar)

struct ScheduleTab: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        switch m.calAuth {
        case .unknown:
            MessageCard(icon: "calendar.badge.clock",
                        text: "See your next class or event right in the notch.",
                        buttonTitle: "Connect Calendar",
                        action: { m.requestCalendar() })
        case .denied:
            MessageCard(icon: "calendar.badge.exclamationmark",
                        text: "Calendar access is off. Allow Notch under\nPrivacy & Security > Calendars.",
                        buttonTitle: "Open Settings",
                        action: {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        })
        case .granted:
            if m.events.isEmpty {
                MessageCard(icon: "checkmark.circle", text: "Nothing else on your calendar for today or tomorrow.")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(m.events) { ev in
                            EventRow(ev: ev)
                        }
                    }
                }
            }
        }
    }
}

struct EventRow: View {
    let ev: CalEvent

    var subtitle: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(ev.start) ? "Today"
            : (cal.isDateInTomorrow(ev.start) ? "Tomorrow"
               : ev.start.formatted(.dateTime.weekday(.abbreviated)))
        var s = day
        if ev.isAllDay {
            s += " - All day"
        } else {
            let a = ev.start.formatted(date: .omitted, time: .shortened)
            let b = ev.end.formatted(date: .omitted, time: .shortened)
            s += " - \(a) to \(b)"
        }
        if let loc = ev.location { s += " - \(loc)" }
        return s
    }

    var rel: String {
        if ev.isAllDay { return "" }
        let now = Date()
        if ev.start <= now && ev.end > now { return "Now" }
        let s = ev.start.timeIntervalSince(now)
        if s < 3600 { return "in \(max(1, Int(s / 60)))m" }
        if s < 86400 { return "in \(Int(s / 3600))h" }
        return ""
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ev.color)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(ev.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Text(rel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rel == "Now" ? Color.green : Color.cyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Shelf tab

struct ShelfTab: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(m.isDropTargeted ? 0.14 : 0.05))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    m.isDropTargeted ? Color.accentColor : Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )

            if m.shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22))
                    Text("Drop files here to hold them")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.5))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(m.shelf, id: \.self) { url in
                            ShelfItem(url: url) { m.removeFile(url) }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !m.shelf.isEmpty {
                Button("Clear") { m.shelf.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(8)
            }
        }
    }
}

struct ShelfItem: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 50, height: 50)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 76)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hover ? 0.12 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from Shelf", action: onRemove)
        }
    }
}

// MARK: - Clipboard tab

struct ClipTab: View {
    @ObservedObject var m: NotchModel
    @State private var copied: String?

    var body: some View {
        if m.clips.isEmpty {
            MessageCard(icon: "doc.on.clipboard", text: "Copied text will show up here")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(m.clips, id: \.self) { clip in
                        Button {
                            m.copy(clip)
                            copied = clip
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                if copied == clip { copied = nil }
                            }
                        } label: {
                            HStack {
                                Text(clip.replacingOccurrences(of: "\n", with: " "))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Image(systemName: copied == clip ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copied == clip ? Color.green : Color.white.opacity(0.4))
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Notes tab

struct NotesTab: View {
    @ObservedObject var m: NotchModel
    var body: some View {
        TextEditor(text: $m.note)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .foregroundStyle(Color.white)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Window + controller

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchController {
    private let model = NotchModel.shared
    private var panel: NotchPanel!
    private var screen: NSScreen = NotchMetrics.screen()
    private var monitors: [Any?] = []
    private var cancellables = Set<AnyCancellable>()
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var poll: Timer?

    func setup() {
        screen = NotchMetrics.screen()
        model.closedSize = NotchMetrics.closedSize(for: screen)

        let size = model.openSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        panel = NotchPanel(contentRect: frame,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: NotchRoot(m: model).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        model.$isOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in self?.panel.ignoresMouseEvents = !open }
            .store(in: &cancellables)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.evaluate()
        })
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.evaluate()
            return event
        })
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.evaluate()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    func reposition() {
        screen = NotchMetrics.screen()
        model.closedSize = NotchMetrics.closedSize(for: screen)
        let size = model.openSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        model.objectWillChange.send()
    }

    func openFromMenu() {
        model.pinnedUntil = Date().addingTimeInterval(5)
        model.isOpen = true
    }

    private func dragHasFiles() -> Bool {
        NSPasteboard(name: .drag).types?.contains(.fileURL) == true
    }

    private func evaluate() {
        let p = NSEvent.mouseLocation
        let f = screen.frame
        let ow = model.openSize.width, oh = model.openSize.height
        let cw = model.closedWidth, ch = model.closedSize.height

        let openRect = NSRect(x: f.midX - ow / 2 - 8, y: f.maxY - oh - 8, width: ow + 16, height: oh + 40)
        let closedRect = NSRect(x: f.midX - cw / 2 - 6, y: f.maxY - ch - 4, width: cw + 12, height: ch + 40)
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let now = Date()

        if model.isOpen {
            let editing = panel.isKeyWindow
                && (model.tab == .notes || (model.tab == .tasks && model.isTyping))
            let hold = openRect.contains(p) || pressed || now < model.pinnedUntil || editing
            if hold {
                outsideSince = nil
            } else {
                if outsideSince == nil { outsideSince = now }
                if let s = outsideSince, now.timeIntervalSince(s) > 0.3 { close() }
            }
        } else {
            if closedRect.contains(p) {
                if hoverSince == nil { hoverSince = now }
                let dragging = pressed && dragHasFiles()
                if let s = hoverSince, dragging || now.timeIntervalSince(s) > 0.15 {
                    open(forDrag: dragging)
                }
            } else {
                hoverSince = nil
            }
        }
    }

    private func open(forDrag: Bool) {
        hoverSince = nil
        outsideSince = nil
        if forDrag { model.tab = .shelf }
        model.refreshCalendar()
        model.isOpen = true
    }

    private func close() {
        outsideSince = nil
        model.isTyping = false
        model.isOpen = false
        panel.makeFirstResponder(nil)
        panel.resignKey()
    }
}

// MARK: - App entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.setup()
        NotchModel.shared.startBackground()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                            accessibilityDescription: "Notch")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Notch", action: #selector(openNotch), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notch", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc func openNotch() { controller?.openFromMenu() }
    @objc func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
