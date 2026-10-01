import SwiftUI
import AppKit
import Combine
import EventKit
import CoreServices
import CoreAudio
import AudioToolbox
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
    case timer, tasks, schedule, music, shelf, clipboard, notes
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .timer: return "timer"
        case .tasks: return "checklist"
        case .schedule: return "calendar"
        case .music: return "music.note"
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
        case .music: return "Now playing"
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
    var icon: String? = nil
    var color: Color
    var left: String? = nil
    var right: String? = nil
    var showArt = false
    var showBars = false
    var barColor: Color = .white
    var width: CGFloat
}

// MARK: - Now playing types

enum PlayerSource: String, CaseIterable {
    case spotify, music

    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var tint: Color {
        self == .spotify ? Color(red: 0.12, green: 0.84, blue: 0.38)
                         : Color(red: 1.0, green: 0.27, blue: 0.4)
    }

    /// Returns: state, title, artist, album, artwork URL, position (s), duration (s), separated by char 31.
    var statusScript: String {
        switch self {
        case .spotify:
            return """
            set sep to character id 31
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set theState to "paused"
                if player state is playing then set theState to "playing"
                set theTitle to name of current track
                set theArtist to ""
                try
                    set theArtist to artist of current track
                end try
                set theAlbum to ""
                try
                    set theAlbum to album of current track
                end try
                set theArt to ""
                try
                    set theArt to artwork url of current track
                end try
                set thePos to player position
                set theDur to 0
                try
                    set theDur to (duration of current track) / 1000
                end try
                return theState & sep & theTitle & sep & theArtist & sep & theAlbum & sep & theArt & sep & thePos & sep & theDur
            end tell
            """
        case .music:
            return """
            set sep to character id 31
            tell application "Music"
                if player state is stopped then return "stopped"
                set theState to "paused"
                if player state is playing then set theState to "playing"
                set theTitle to name of current track
                set theArtist to ""
                try
                    set theArtist to artist of current track
                end try
                set theAlbum to ""
                try
                    set theAlbum to album of current track
                end try
                set thePos to player position
                set theDur to 0
                try
                    set theDur to duration of current track
                end try
                return theState & sep & theTitle & sep & theArtist & sep & theAlbum & sep & "" & sep & thePos & sep & theDur
            end tell
            """
        }
    }

    var artworkScript: String {
        """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
    }
}

struct TrackInfo {
    var source: PlayerSource
    var title: String
    var artist: String
    var album: String
    var artURL: String
    var isPlaying: Bool
    var duration: Double
    var position: Double
    var stamp: Date

    var artKey: String { "\(source.rawValue)|\(title)|\(artist)|\(album)" }

    func currentPosition(at date: Date) -> Double {
        let p = isPlaying ? position + date.timeIntervalSince(stamp) : position
        if duration > 0 { return min(max(p, 0), duration) }
        return max(p, 0)
    }
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
    private var bag = Set<AnyCancellable>()

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

        // Refresh the closed notch when music starts, stops or changes track.
        NowPlaying.shared.$track
            .removeDuplicates { $0?.artKey == $1?.artKey && $0?.isPlaying == $1?.isPlaying }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: Closed-notch info ("ears")

    var musicPlaying: Bool { NowPlaying.shared.track?.isPlaying == true }
    var musicColor: Color { NowPlaying.shared.track?.source.tint ?? Color.white }

    var ear: Ear? {
        let music = musicPlaying
        if running {
            let focus = mode == .focus
            return Ear(icon: focus ? "timer" : "cup.and.saucer.fill",
                       color: focus ? Color.orange : Color.green,
                       left: nil, right: timeString,
                       showArt: music, showBars: music, barColor: musicColor,
                       width: music ? 104 : 70)
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
        if music {
            return Ear(icon: "music.note", color: musicColor,
                       showArt: true, showBars: true, barColor: musicColor, width: 70)
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

// MARK: - Now playing (Spotify + Apple Music via AppleScript)

final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    @Published var track: TrackInfo?
    @Published var art: NSImage?
    @Published var needsPermission = false

    private enum QueryResult {
        case track(TrackInfo)
        case idle
        case denied
    }

    private let queue = DispatchQueue(label: "notch.nowplaying")
    private var scripts: [PlayerSource: NSAppleScript] = [:]   // touched on `queue` only
    private var timer: Timer?
    private var polling = false
    private var lastArtKey: String?

    func start() {
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Polling

    private func poll() {
        guard !polling else { return }
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        // Only talk to players that are already running, so we never launch them.
        let candidates = PlayerSource.allCases.filter { ids.contains($0.bundleID) }
        guard !candidates.isEmpty else {
            apply(track: nil, denied: false)
            return
        }
        polling = true
        queue.async { [weak self] in
            guard let self = self else { return }
            var best: TrackInfo?
            var denied = false
            for src in candidates {
                switch self.query(src) {
                case .track(let t):
                    if best == nil || (t.isPlaying && best?.isPlaying == false) { best = t }
                case .denied:
                    denied = true
                case .idle:
                    break
                }
            }
            DispatchQueue.main.async {
                self.polling = false
                self.apply(track: best, denied: denied && best == nil)
            }
        }
    }

    private static func parseNumber(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var asked = Set<PlayerSource>()   // touched on `queue` only

    private func query(_ src: PlayerSource) -> QueryResult {
        if !asked.contains(src) {
            asked.insert(src)
            let target = NSAppleEventDescriptor(bundleIdentifier: src.bundleID)
            if let desc = target.aeDesc {
                let status = AEDeterminePermissionToAutomateTarget(
                    desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
                if status == -1743 { return .denied }
            }
        }
        let script: NSAppleScript
        if let s = scripts[src] {
            script = s
        } else {
            guard let s = NSAppleScript(source: src.statusScript) else { return .idle }
            scripts[src] = s
            script = s
        }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let e = err {
            let code = e["NSAppleScriptErrorNumber"] as? Int ?? 0
            return code == -1743 ? .denied : .idle
        }
        guard let str = result.stringValue else { return .idle }
        let parts = str.components(separatedBy: "\u{1F}")
        guard parts.count >= 7, parts[0] == "playing" || parts[0] == "paused" else { return .idle }
        return .track(TrackInfo(
            source: src,
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            artURL: parts[4],
            isPlaying: parts[0] == "playing",
            duration: NowPlaying.parseNumber(parts[6]),
            position: NowPlaying.parseNumber(parts[5]),
            stamp: Date()
        ))
    }

    private func apply(track new: TrackInfo?, denied: Bool) {
        if needsPermission != denied { needsPermission = denied }

        let was = track?.isPlaying == true
        track = new
        let isNow = new?.isPlaying == true

        if isNow != was {
            if isNow { AudioLevels.shared.start() } else { AudioLevels.shared.stop() }
        }
        if isNow { AudioLevels.shared.checkDevice() }

        if let t = new {
            if t.artKey != lastArtKey {
                lastArtKey = t.artKey
                art = nil
                fetchArt(for: t)
            }
        } else {
            lastArtKey = nil
            art = nil
        }
    }

    // MARK: Artwork

    private func fetchArt(for t: TrackInfo) {
        let key = t.artKey
        switch t.source {
        case .spotify:
            guard !t.artURL.isEmpty, let url = URL(string: t.artURL) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data = data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    if self?.lastArtKey == key { self?.art = img }
                }
            }.resume()
        case .music:
            queue.async { [weak self] in
                guard let self = self else { return }
                guard let s = NSAppleScript(source: PlayerSource.music.artworkScript) else { return }
                var err: NSDictionary?
                let res = s.executeAndReturnError(&err)
                guard err == nil else { return }
                let d = res.data
                guard d.count > 100, let img = NSImage(data: d) else { return }
                DispatchQueue.main.async {
                    if self.lastArtKey == key { self.art = img }
                }
            }
        }
    }

    // MARK: Controls

    func playPause() {
        guard var t = track else { return }
        t.position = t.currentPosition(at: Date())
        t.stamp = Date()
        t.isPlaying.toggle()
        track = t
        send("playpause", for: t.source)
    }

    func next() {
        guard let t = track else { return }
        send("next track", for: t.source)
    }

    func previous() {
        guard let t = track else { return }
        send("previous track", for: t.source)
    }

    func seek(to fraction: Double) {
        guard var t = track, t.duration > 0 else { return }
        let pos = max(0, min(1, fraction)) * t.duration
        t.position = pos
        t.stamp = Date()
        track = t
        send(String(format: "set player position to %.1f", pos), for: t.source)
    }

    private func send(_ command: String, for src: PlayerSource) {
        queue.async { [weak self] in
            var err: NSDictionary?
            let s = NSAppleScript(source: "tell application \"\(src.appName)\" to \(command)")
            _ = s?.executeAndReturnError(&err)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.poll() }
        }
    }
}

// MARK: - Live audio levels (drives the sound bars)

final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()
    static let bars = 5

    @Published var bands: [CGFloat] = Array(repeating: 0.1, count: AudioLevels.bars)
    /// True once real audio has been detected; until then bars use a simulated animation.
    @Published var live = false

    private var tap: AudioTap?
    private var confirmed = false

    func start() {
        guard tap == nil else { return }
        confirmed = false
        let t = AudioTap()
        t.onFrame = { [weak self] values, hasSound in
            DispatchQueue.main.async {
                guard let self = self, self.tap != nil else { return }
                if hasSound && !self.confirmed {
                    self.confirmed = true
                    self.live = true
                }
                if self.confirmed {
                    self.bands = values.map { CGFloat($0) }
                }
            }
        }
        if t.start() {
            tap = t
        } else {
            live = false
        }
    }

    func stop() {
        tap?.stop()
        tap = nil
        confirmed = false
        live = false
        bands = Array(repeating: 0.1, count: AudioLevels.bars)
    }

    /// Restarts the tap if the output device changed (e.g. AirPods connected).
    func checkDevice() {
        guard let t = tap,
              let uid = AudioTap.defaultOutputUID(),
              uid != t.deviceUID else { return }
        t.stop()
        if !t.start() {
            tap = nil
            live = false
        }
    }
}

/// Taps system audio output (Core Audio process tap, macOS 14.2+) and turns it
/// into 5 frequency-band levels using a Goertzel filter bank.
final class AudioTap {
    var onFrame: (([Float], Bool) -> Void)?
    private(set) var running = false
    private(set) var deviceUID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "notch.audio.tap", qos: .userInteractive)

    private let N = 1024
    private var sampleRate: Float = 48000
    private var window = [Float](repeating: 0, count: 1024)
    private var scratch = [Float](repeating: 0, count: 1024)
    private var hann = [Float](repeating: 0, count: 1024)
    private var fill = 0
    private var smooth = [Float](repeating: 0, count: 5)
    private var lastEmit: Double = 0

    private let bandFreqs: [[Float]] = [
        [50, 70, 100],
        [140, 200, 280],
        [400, 600, 900],
        [1300, 2000, 3000],
        [4500, 6500, 9500]
    ]
    private let tilt: [Float] = [0, 5, 9, 13, 17]

    init() {
        for i in 0..<1024 {
            hann[i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / 1023)
        }
    }

    static func defaultOutputUID() -> String? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devID) == noErr else { return nil }

        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, $0)
        }
        return status == noErr ? (uid as String) : nil
    }

    func start() -> Bool {
        guard !running else { return true }
        guard let outUID = AudioTap.defaultOutputUID() else { return false }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &newTap) == noErr else { return false }
        tapID = newTap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString
            ]]
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg) == noErr else {
            teardown()
            return false
        }
        aggID = newAgg

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
           asbd.mSampleRate > 0 {
            sampleRate = Float(asbd.mSampleRate)
        }

        fill = 0
        for i in 0..<smooth.count { smooth[i] = 0 }

        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard status == noErr, let proc = pid else {
            teardown()
            return false
        }
        procID = proc
        guard AudioDeviceStart(aggID, proc) == noErr else {
            teardown()
            return false
        }
        deviceUID = outUID
        running = true
        return true
    }

    func stop() {
        teardown()
        running = false
        deviceUID = nil
    }

    private func teardown() {
        if let p = procID {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            procID = nil
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Audio processing (runs on `queue`)

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if abl.count == 1 {
            let b = abl[0]
            guard let d = b.mData else { return }
            let ch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / (4 * ch)
            let p = d.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[i * ch + c] }
                push(s / Float(ch))
            }
        } else if abl.count > 1 {
            let frames = Int(abl[0].mDataByteSize) / 4
            let n = abl.count
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<n {
                    if let d = abl[c].mData {
                        s += d.assumingMemoryBound(to: Float.self)[i]
                    }
                }
                push(s / Float(n))
            }
        }
    }

    private func push(_ s: Float) {
        window[fill] = s
        fill += 1
        if fill == N {
            fill = 0
            analyze()
        }
    }

    private func analyze() {
        var peak: Float = 0
        for i in 0..<N {
            let v = window[i]
            peak = max(peak, abs(v))
            scratch[i] = v * hann[i]
        }
        let hasSound = peak > 0.00002

        var target = [Float](repeating: 0, count: bandFreqs.count)
        if hasSound {
            for (b, freqs) in bandFreqs.enumerated() {
                var amp: Float = 0
                for f in freqs { amp = max(amp, goertzel(f)) }
                let db = 20 * log10(amp + 1e-7) + tilt[b]
                let norm = max(0, min(1, (db + 62) / 48))
                target[b] = pow(norm, 1.4)
            }
        }
        for b in 0..<target.count {
            let t = target[b]
            smooth[b] += (t > smooth[b] ? 0.65 : 0.18) * (t - smooth[b])
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastEmit >= 0.03 {
            lastEmit = now
            onFrame?(smooth, hasSound)
        }
    }

    private func goertzel(_ freq: Float) -> Float {
        let w = 2 * Float.pi * freq / sampleRate
        let c = 2 * cos(w)
        var s1: Float = 0
        var s2: Float = 0
        scratch.withUnsafeBufferPointer { p in
            for i in 0..<N {
                let s = p[i] + c * s1 - s2
                s2 = s1
                s1 = s
            }
        }
        let power = s1 * s1 + s2 * s2 - c * s1 * s2
        return sqrt(max(power, 0)) * 4 / Float(N)
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

// MARK: - Sound bars + album art

struct SoundBars: View {
    @ObservedObject var levels = AudioLevels.shared
    var playing: Bool = true
    var color: Color
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var height: CGFloat = 16

    private var count: Int { AudioLevels.bars }

    var body: some View {
        if !playing {
            bars([CGFloat](repeating: 0.12, count: count))
        } else if levels.live {
            bars(levels.bands)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                bars(simulated(ctx.date))
            }
        }
    }

    func bars(_ v: [CGFloat]) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                let level: CGFloat = i < v.count ? v[i] : 0.1
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: max(barWidth, height * level))
            }
        }
        .frame(height: height)
    }

    func simulated(_ date: Date) -> [CGFloat] {
        let t = date.timeIntervalSinceReferenceDate
        var out: [CGFloat] = []
        for i in 0..<count {
            let fi = Double(i)
            let a = sin(t * (3.1 + fi * 0.9) + fi * 1.7) * 0.5 + 0.5
            let b = sin(t * (5.3 + fi * 0.4) + fi) * 0.5 + 0.5
            out.append(CGFloat(0.2 + 0.4 * a + 0.35 * b))
        }
        return out
    }
}

struct ArtThumb: View {
    @ObservedObject var np = NowPlaying.shared
    var size: CGFloat
    var radius: CGFloat = 5

    var body: some View {
        Group {
            if let img = np.art {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.2)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
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
        if let e = m.ear, !m.isOpen {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    if e.showArt {
                        ArtThumb(size: 20, radius: 5)
                    } else if let icon = e.icon {
                        Image(systemName: icon)
                    }
                    if let l = e.left { Text(l).lineLimit(1) }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(e.color)
                .padding(.leading, e.left == nil ? 0 : 12)
                .frame(width: e.width, alignment: e.left == nil ? .center : .leading)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if e.showBars {
                        SoundBars(color: e.barColor, barWidth: 3, spacing: 2, height: 15)
                    }
                    if let r = e.right {
                        Text(r)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(e.color)
                    }
                }
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
                case .music: MusicTab()
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
                .frame(width: 28, height: 26)
                .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.clear))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

// MARK: - Music tab

struct MusicTab: View {
    @ObservedObject var np = NowPlaying.shared

    var body: some View {
        if let t = np.track {
            HStack(spacing: 18) {
                ArtThumb(size: 128, radius: 14)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                            Text(t.artist.isEmpty ? t.source.appName : t.artist)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .lineLimit(1)
                            if !t.album.isEmpty {
                                Text(t.album)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        SoundBars(playing: t.isPlaying, color: t.source.tint,
                                  barWidth: 4, spacing: 3, height: 26)
                    }

                    progress(t)

                    HStack(spacing: 24) {
                        Button { np.previous() } label: { Image(systemName: "backward.fill") }
                        Button { np.playPause() } label: {
                            Image(systemName: t.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 36))
                        }
                        Button { np.next() } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                }
            }
        } else if np.needsPermission {
            MessageCard(icon: "lock.shield",
                        text: "Allow Notch to control Spotify / Music under\nPrivacy & Security > Automation.",
                        buttonTitle: "Open Settings",
                        action: {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            }
                        })
        } else {
            MessageCard(icon: "music.note",
                        text: "Play something in Spotify or Apple Music\nand it will show up here.")
        }
    }

    func progress(_ t: TrackInfo) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = t.currentPosition(at: ctx.date)
            let frac: Double = t.duration > 0 ? min(max(pos / t.duration, 0), 1) : 0
            HStack(spacing: 8) {
                Text(MusicTab.mmss(pos))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 34, alignment: .trailing)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 5)
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: max(5, geo.size.width * CGFloat(frac)), height: 5)
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { v in
                            np.seek(to: Double(v.location.x / max(geo.size.width, 1)))
                        }
                    )
                }
                .frame(height: 16)

                Text("-" + MusicTab.mmss(max(0, t.duration - pos)))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 38, alignment: .leading)
            }
        }
    }

    static func mmss(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d", t / 60, t % 60)
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
        NowPlaying.shared.start()

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

    func applicationWillTerminate(_ notification: Notification) {
        AudioLevels.shared.stop()
    }

    @objc func openNotch() { controller?.openFromMenu() }
    @objc func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
