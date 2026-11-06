import Contacts
import EventKit
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import WearLink

/// The iPhone side of the watch features added on top of the core link: contacts, notification
/// filters, reminders, alarms and timers, apps, sounds, photos, recordings, workouts and the
/// camera preview. Everything the watch sends is untrusted and checked before use.
@MainActor
final class FeatureHub: ObservableObject {
    struct NotifApp: Identifiable, Equatable { let id: String; var name: String; var muted: Bool }
    struct WatchApp: Identifiable, Equatable { let id: String; var name: String; var version: String; var system: Bool; var mb: Double }
    struct Sound: Identifiable, Hashable { var id: String { uri }; let title: String; let uri: String }
    struct Recording: Identifiable, Equatable { let id: Int64; let name: String; let ms: Int64; let bytes: Int64; let at: Date }

    @Published var toast: String?
    @Published private(set) var notifApps: [NotifApp] = []
    @Published private(set) var categories: [Int: Bool] = [:]
    @Published private(set) var apps: [WatchApp] = []
    @Published private(set) var loadingApps = false
    @Published private(set) var ringtones: [Sound] = []
    @Published private(set) var notifSounds: [Sound] = []
    @Published private(set) var ringNow = ""
    @Published private(set) var notifNow = ""
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var downloading: Int64?
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var contactsBusy = false
    @Published private(set) var photoBusy = false
    @Published var shareReminders = UserDefaults.standard.object(forKey: "shareReminders") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shareReminders, forKey: "shareReminders"); Task { await sendReminders() } }
    }
    @Published private(set) var remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

    var send: ((GBMessage) -> Void)?
    var isConnected: () -> Bool = { false }
    weak var health: HealthSync?
    weak var camera: Camera?

    private let events = EKEventStore()
    private var recordingBuffer = Data()
    private var recordingParts = 0

    static let categoryNames: [(Int, String)] = [
        (0, "Other"), (2, "Missed calls"), (3, "Voicemail"), (4, "Social & messages"), (5, "Calendar"),
        (6, "Email"), (7, "News"), (8, "Health & fitness"), (9, "Business & finance"), (10, "Location"),
        (11, "Entertainment"),
    ]

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.sendReminders() } }
        }
    }

    private func post(_ type: String, _ body: [String: Any] = [:]) {
        guard let m = GBFeature.message(type, body) else { return }
        send?(m)
    }

    /// Called on every (re)connection.
    func onConnected() {
        Task { await sendReminders() }
        post("getNotifApps")
    }

    // MARK: Incoming

    func handle(_ type: String, _ b: [String: Any]) {
        switch type {
        case "notifApps":
            notifApps = (b["items"] as? [[String: Any]] ?? []).prefix(300).compactMap {
                guard let id = $0["id"] as? String, id.count <= 200 else { return nil }
                return NotifApp(id: id, name: String(($0["name"] as? String ?? id).prefix(40)), muted: $0["muted"] as? Bool ?? false)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            var cats: [Int: Bool] = [:]
            for (k, v) in b["cats"] as? [String: Any] ?? [:] { if let i = Int(k), (0...11).contains(i) { cats[i] = v as? Bool ?? true } }
            categories = cats
        case "apps":
            loadingApps = false
            apps = (b["items"] as? [[String: Any]] ?? []).prefix(500).compactMap {
                guard let pkg = $0["pkg"] as? String, pkg.count <= 200 else { return nil }
                return WatchApp(id: pkg, name: String(($0["name"] as? String ?? pkg).prefix(40)),
                                version: String(($0["ver"] as? String ?? "").prefix(24)),
                                system: $0["system"] as? Bool ?? false, mb: ($0["mb"] as? NSNumber)?.doubleValue ?? -1)
            }
        case "sounds":
            func list(_ key: String) -> [Sound] {
                (b[key] as? [[String: Any]] ?? []).prefix(80).compactMap {
                    guard let t = $0["title"] as? String, let u = $0["uri"] as? String, u.count <= 300 else { return nil }
                    return Sound(title: String(t.prefix(40)), uri: u)
                }
            }
            ringtones = list("ring"); notifSounds = list("notif")
            ringNow = b["ringNow"] as? String ?? ""; notifNow = b["notifNow"] as? String ?? ""
        case "recordings":
            recordings = (b["items"] as? [[String: Any]] ?? []).prefix(100).compactMap {
                guard let id = ($0["id"] as? NSNumber)?.int64Value, let name = $0["name"] as? String else { return nil }
                return Recording(id: id, name: String(name.prefix(60)), ms: ($0["ms"] as? NSNumber)?.int64Value ?? 0,
                                 bytes: ($0["bytes"] as? NSNumber)?.int64Value ?? 0,
                                 at: Date(timeIntervalSince1970: (($0["at"] as? NSNumber)?.doubleValue ?? 0) / 1000))
            }
        case "recPart": receiveRecordingPart(b)
        case "workout":
            Task {
                guard let health else { return }
                if await health.saveWorkout(b), let id = b["id"] as? String {
                    post("workoutAck", ["id": id])
                    toast = "Workout saved to Apple Health"
                }
            }
        case "reminderDone":
            if let id = b["id"] as? String { completeReminder(id) }
        case "camView":
            camera?.streamToWatch = b["on"] as? Bool ?? false
            camera?.updateStreaming()
            sendCameraState()
        case "camCmd":
            switch b["cmd"] as? String {
            case "shoot": camera?.capture()
            case "flip": camera?.flip()
            case "timer": camera?.cycleTimer()
            default: break
            }
            sendCameraState()
        case "result":
            let what = b["what"] as? String ?? ""
            let ok = b["ok"] as? Bool ?? false
            let detail = String((b["detail"] as? String ?? "").prefix(120))
            if what == "contacts" { contactsBusy = false }
            if what == "photo" { photoBusy = false }
            toast = detail.isEmpty ? (ok ? "Done on watch" : "The watch couldn't do that") : detail
        default: break
        }
    }

    // MARK: Contacts

    func syncContacts() async {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                toast = "Allow Contacts for Galaxy Bridge in iPhone Settings"
                return
            }
        }
        contactsBusy = true
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactOrganizationNameKey as CNKeyDescriptor]
        let items: [[String: Any]] = await Task.detached {
            var out: [[String: Any]] = []
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                let name = CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName
                let phones = c.phoneNumbers.map(\.value.stringValue).prefix(8)
                let emails = c.emailAddresses.map { String($0.value) }.prefix(4)
                guard !name.isEmpty, !(phones.isEmpty && emails.isEmpty) else { return }
                out.append(["id": c.identifier, "n": String(name.prefix(80)), "p": Array(phones), "e": Array(emails)])
            }
            return out
        }.value
        let pageSize = 150
        let pages = max(1, (items.count + pageSize - 1) / pageSize)
        for p in 0..<pages {
            let slice = Array(items[min(items.count, p * pageSize)..<min(items.count, (p + 1) * pageSize)])
            post("contacts", ["page": p, "pages": pages, "items": slice])
        }
        toast = "Sending \(items.count) contacts…"
    }

    // MARK: Reminders

    func requestRemindersAccess() async {
        remindersAllowed = (try? await events.requestFullAccessToReminders()) ?? false
        await sendReminders()
    }

    func sendReminders() async {
        remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard shareReminders, remindersAllowed else { return }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [[String: Any]] = await withCheckedContinuation { done in
            events.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                done.resume(returning: sorted.prefix(20).map {
                    ["id": $0.calendarItemIdentifier, "title": String(($0.title ?? "").prefix(80)),
                     "due": Int64(($0.dueDateComponents?.date?.timeIntervalSince1970 ?? 0) * 1000),
                     "list": String(($0.calendar?.title ?? "").prefix(30))]
                })
            }
        }
        post("reminders", ["items": found])
    }

    private func completeReminder(_ id: String) {
        guard remindersAllowed, let r = events.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = true
        try? events.save(r, commit: true)
    }

    // MARK: Alarms, timers

    func setAlarm(_ date: Date, label: String) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        post("alarm", ["h": c.hour ?? 7, "m": c.minute ?? 0, "label": String(label.prefix(40))])
    }

    func setTimer(seconds: Int, label: String) {
        post("timer", ["secs": max(1, min(seconds, 86_400)), "label": String(label.prefix(40))])
    }

    // MARK: Apps, store, sounds

    func requestApps() { loadingApps = true; post("getApps") }
    func uninstall(_ pkg: String) { post("uninstall", ["pkg": pkg]) }
    func launch(_ pkg: String) { post("launch", ["pkg": pkg]) }
    func openStore(_ pkg: String) {
        guard isConnected() else { toast = "Connect your watch first"; return }
        post("openStore", ["pkg": pkg])
    }
    func requestSounds() { post("getSounds") }
    func setSound(_ kind: String, _ uri: String) { post("setSound", ["kind": kind, "uri": uri]) }

    // MARK: Notifications

    func requestNotifApps() { post("getNotifApps") }

    func setMuted(_ id: String, _ muted: Bool) {
        if let i = notifApps.firstIndex(where: { $0.id == id }) { notifApps[i].muted = muted }
        post("mute", ["apps": [id: muted]])
    }

    func setCategory(_ i: Int, _ on: Bool) {
        categories[i] = on
        post("mute", ["cats": [String(i): on]])
    }

    // MARK: Photos

    /// Shrinks the photo to the watch's screen size and sends it in parts.
    func sendPhoto(_ image: UIImage) {
        guard isConnected() else { toast = "Connect your watch first"; return }
        let side: CGFloat = 900
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7) else { return }
        photoBusy = true
        let id = UUID().uuidString
        let part = 32 * 1024
        let parts = (jpeg.count + part - 1) / part
        for i in 0..<parts {
            let chunk = jpeg.subdata(in: i * part..<min(jpeg.count, (i + 1) * part))
            post("photo", ["id": id, "part": i, "parts": parts, "name": "iPhone", "data": chunk.base64EncodedString()])
        }
        toast = "Sending photo (\(jpeg.count / 1024) KB)…"
    }

    // MARK: Recordings

    func requestRecordings() { post("getRecordings") }

    func download(_ r: Recording) {
        guard downloading == nil else { return }
        downloading = r.id
        downloadProgress = 0
        recordingBuffer = Data()
        recordingParts = 0
        post("getRecording", ["id": r.id])
    }

    private func receiveRecordingPart(_ b: [String: Any]) {
        guard let id = (b["id"] as? NSNumber)?.int64Value, id == downloading,
              let part = b["part"] as? Int, let parts = b["parts"] as? Int, (1...2000).contains(parts), part == recordingParts,
              let data = (b["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
        recordingBuffer.append(data)
        recordingParts += 1
        downloadProgress = Double(recordingParts) / Double(parts)
        guard recordingParts == parts else { return }
        let name = recordings.first { $0.id == id }?.name ?? "Recording-\(id).m4a"
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_. ".contains($0) }
        do {
            let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Watch recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try recordingBuffer.write(to: dir.appendingPathComponent(safe.isEmpty ? "Recording-\(id).m4a" : safe), options: .completeFileProtection)
            toast = "Saved to Files → On My iPhone → Galaxy Bridge"
        } catch {
            toast = "Couldn't save the recording"
        }
        downloading = nil
        recordingBuffer = Data()
    }

    // MARK: Camera

    func sendCameraState() {
        guard let camera else { return }
        post("camState", ["open": camera.ready, "front": camera.position == .front, "timer": camera.timerSeconds])
    }

    func sendFrame(_ jpeg: Data) {
        guard jpeg.count < 40_000 else { return }
        post("camFrame", ["data": jpeg.base64EncodedString()])
    }
}

// MARK: - Screens

struct MoreView: View {
    @EnvironmentObject var hub: FeatureHub
    @EnvironmentObject var link: WatchLink

    var body: some View {
        List {
            Section {
                NavigationLink { StoreScreen() } label: { row("Google Play", "Watch faces and apps", "bag.fill", .green) }
                NavigationLink { AppsView() } label: { row("Watch apps", "Open, update or uninstall", "square.grid.2x2.fill", .blue) }
            }
            Section {
                NavigationLink { NotificationFiltersView() } label: { row("Notifications", "Choose apps and types", "bell.badge.fill", .red) }
                NavigationLink { ContactsView() } label: { row("Contacts", "Copy to the watch's Phone app", "person.crop.circle.fill", .gray) }
                NavigationLink { RemindersView() } label: { row("Reminders", "Tile on the watch", "checklist", .orange) }
                NavigationLink { AlarmsView() } label: { row("Alarms & timers", "Set on the watch", "alarm.fill", .indigo) }
            }
            Section {
                NavigationLink { PhotosToWatchView() } label: { row("Photos", "Send to the watch's Gallery", "photo.fill", .pink) }
                NavigationLink { RecordingsView() } label: { row("Voice recordings", "Copy from the watch", "waveform", .purple) }
                NavigationLink { WorkoutsInfoView() } label: { row("Workouts", "Record on the watch, saved to Health", "figure.run", .green) }
            }
            Section {
                NavigationLink { TilesInfoView() } label: { row("Tiles", "Calendar, reminders, weather and more", "rectangle.stack.fill", .teal) }
            }
        }
        .navigationTitle("More")
        .toast($hub.toast)
    }

    private func row(_ title: String, _ sub: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NotConnected: View {
    @EnvironmentObject var link: WatchLink
    var body: some View {
        if link.status != .connected {
            Label("Connect your watch to use this.", systemImage: "applewatch.slash").foregroundStyle(.secondary)
        }
    }
}

struct NotificationFiltersView: View {
    @EnvironmentObject var hub: FeatureHub

    var body: some View {
        Form {
            NotConnected()
            Section {
                ForEach(FeatureHub.categoryNames, id: \.0) { cat in
                    Toggle(cat.1, isOn: Binding(get: { hub.categories[cat.0] ?? true }, set: { hub.setCategory(cat.0, $0) }))
                }
            } header: { Text("Types") } footer: { Text("Incoming calls always ring on the watch.") }
            Section {
                if hub.notifApps.isEmpty {
                    Text("Apps appear here after they send a notification to the watch.").foregroundStyle(.secondary)
                }
                ForEach(hub.notifApps) { app in
                    Toggle(app.name, isOn: Binding(get: { !app.muted }, set: { hub.setMuted(app.id, !$0) }))
                }
            } header: { Text("Apps") }
        }
        .navigationTitle("Notifications")
        .onAppear { hub.requestNotifApps() }
    }
}

struct ContactsView: View {
    @EnvironmentObject var hub: FeatureHub
    var body: some View {
        Form {
            NotConnected()
            Section {
                Button { Task { await hub.syncContacts() } } label: {
                    HStack { Text("Copy contacts to watch"); Spacer(); if hub.contactsBusy { ProgressView() } }
                }
                .disabled(hub.contactsBusy)
            } footer: {
                Text("Names, phone numbers and email addresses go only to your watch, over Bluetooth. Run it again after changing contacts; it replaces the previous copy.")
            }
        }
        .navigationTitle("Contacts")
        .toast($hub.toast)
    }
}

struct RemindersView: View {
    @EnvironmentObject var hub: FeatureHub
    var body: some View {
        Form {
            Section {
                Toggle("Show reminders on watch", isOn: $hub.shareReminders)
                if !hub.remindersAllowed {
                    Button("Allow access to Reminders") { Task { await hub.requestRemindersAccess() } }
                }
            } footer: {
                Text("Add the \"Reminders (iPhone)\" tile on your watch: swipe left from the watch face, then tap +. Tick a reminder on the tile to complete it on your iPhone.")
            }
        }
        .navigationTitle("Reminders")
    }
}

struct AlarmsView: View {
    @EnvironmentObject var hub: FeatureHub
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var label = ""
    @State private var minutes = 5

    var body: some View {
        Form {
            NotConnected()
            Section("Alarm") {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                TextField("Label", text: $label)
                Button("Set alarm on watch") { hub.setAlarm(time, label: label) }
            }
            Section("Timer") {
                Stepper("\(minutes) min", value: $minutes, in: 1...240)
                Button("Start timer on watch") { hub.setTimer(seconds: minutes * 60, label: label) }
            }
        }
        .navigationTitle("Alarms & timers")
        .toast($hub.toast)
    }
}

struct AppsView: View {
    @EnvironmentObject var hub: FeatureHub
    @State private var showSystem = false
    @State private var confirm: FeatureHub.WatchApp?

    var body: some View {
        List {
            NotConnected()
            Toggle("Show system apps", isOn: $showSystem)
            ForEach(hub.apps.filter { showSystem || !$0.system }) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text([app.version, app.mb >= 0 ? "\(app.mb.formatted()) MB" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Open on watch", systemImage: "arrow.up.forward.app") { hub.launch(app.id) }
                        Button("Play Store page", systemImage: "bag") { hub.openStore(app.id) }
                        if !app.system { Button("Uninstall…", systemImage: "trash", role: .destructive) { confirm = app } }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }
            }
        }
        .overlay { if hub.loadingApps && hub.apps.isEmpty { ProgressView() } }
        .navigationTitle("Watch apps")
        .refreshable { hub.requestApps() }
        .onAppear { hub.requestApps() }
        .confirmationDialog("Uninstall \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { if let a = confirm { hub.uninstall(a.id) } }
        } message: { Text("You'll confirm on the watch.") }
        .toast($hub.toast)
    }
}

struct PhotosToWatchView: View {
    @EnvironmentObject var hub: FeatureHub
    @State private var item: PhotosPickerItem?

    var body: some View {
        Form {
            NotConnected()
            Section {
                PhotosPicker(selection: $item, matching: .images) {
                    HStack { Text("Choose a photo"); Spacer(); if hub.photoBusy { ProgressView() } }
                }
            } footer: {
                Text("Photos are resized for the watch and appear in its Gallery app, in the Galaxy Bridge album. Bluetooth is slow, so each takes a few seconds.")
            }
        }
        .navigationTitle("Photos")
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self), let image = UIImage(data: data) { hub.sendPhoto(image) }
                item = nil
            }
        }
        .toast($hub.toast)
    }
}

struct RecordingsView: View {
    @EnvironmentObject var hub: FeatureHub

    var body: some View {
        List {
            NotConnected()
            if hub.recordings.isEmpty {
                Text("No recordings found on the watch. Make one with the watch's Voice Recorder app.").foregroundStyle(.secondary)
            }
            ForEach(hub.recordings) { r in
                Button { hub.download(r) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).foregroundStyle(.primary)
                            Text("\(Duration.milliseconds(r.ms).formatted(.time(pattern: .minuteSecond))) · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)) · \(r.at.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if hub.downloading == r.id { ProgressView(value: hub.downloadProgress).frame(width: 60) }
                        else { Image(systemName: "arrow.down.circle") }
                    }
                }
                .disabled(hub.downloading != nil)
            }
        }
        .navigationTitle("Voice recordings")
        .refreshable { hub.requestRecordings() }
        .onAppear { hub.requestRecordings() }
        .toast($hub.toast)
    }
}

struct WorkoutsInfoView: View {
    @EnvironmentObject var health: HealthSync
    var body: some View {
        Form {
            Section {
                Label("On the watch, open Galaxy Bridge → Workout and pick Run, Walk, Cycle, Hike or Workout.", systemImage: "1.circle")
                Label("Tap End when you finish. The workout and its GPS route go to Apple Health the next time the watch connects.", systemImage: "2.circle")
            }
            if let last = health.lastWorkout { Section("Last saved") { Text(last) } }
            Section { Button("Allow workouts in Apple Health") { Task { await health.requestAccess() } } }
        }
        .navigationTitle("Workouts")
    }
}

struct TilesInfoView: View {
    var body: some View {
        Form {
            Section {
                Label("Calendar (iPhone)", systemImage: "calendar")
                Label("Reminders (iPhone): tap to tick off", systemImage: "checklist")
                Label("Weather (iPhone)", systemImage: "cloud.sun")
                Label("iPhone battery", systemImage: "battery.75percent")
                Label("Now playing (iPhone): play, pause, skip", systemImage: "music.note")
            } footer: {
                Text("On the watch, swipe left from the watch face to the end of your tiles, tap +, and add any of these.")
            }
        }
        .navigationTitle("Tiles")
    }
}

// MARK: - Toast

private struct Toast: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) { try? await Task.sleep(for: .seconds(3)); withAnimation { self.text = nil } }
            }
        }
        .animation(.default, value: text)
    }
}

extension View {
    func toast(_ text: Binding<String?>) -> some View { modifier(Toast(text: text)) }
}
