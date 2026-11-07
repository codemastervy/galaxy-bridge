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
    /// Preview and name of the face currently on the watch.
    @Published private(set) var faceImage: UIImage? = FeatureHub.loadFace()
    @Published private(set) var faceName: String? = UserDefaults.standard.string(forKey: "faceName")
    @Published private(set) var faces: [WatchFace] = []
    @Published private(set) var facePreviews: [String: UIImage] = [:]
    /// The design on the Wear OS Bridge face, and whether that face is the active one.
    @Published private(set) var design: FaceDesign? = (UserDefaults.standard.data(forKey: "design")).flatMap { try? JSONDecoder().decode(FaceDesign.self, from: $0) }
    @Published private(set) var designActive = UserDefaults.standard.bool(forKey: "designActive")
    struct WatchFace: Identifiable, Equatable { let id: String; let name: String; let active: Bool }
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
        post("getFace")
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
        case "face":
            let name = (b["name"] as? String).map { String($0.prefix(60)) }
            faceName = name
            UserDefaults.standard.set(name, forKey: "faceName")
            if let data = (b["png"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count < 60_000,
               let img = UIImage(data: data), img.size.width <= 600 {
                faceImage = img
                try? data.write(to: Self.faceURL)
            }
        case "faces":
            faces = (b["items"] as? [[String: Any]] ?? []).prefix(200).compactMap {
                guard let id = $0["pkg"] as? String, id.count <= 200 else { return nil }
                return WatchFace(id: id, name: String(($0["name"] as? String ?? id).prefix(50)), active: $0["active"] as? Bool ?? false)
            }
        case "facePreview":
            if let pkg = b["pkg"] as? String, pkg.count <= 200, facePreviews.count < 300,
               let data = (b["img"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count < 30_000,
               let img = UIImage(data: data) { facePreviews[pkg] = img }
        case "design":
            designActive = b["active"] as? Bool ?? false
            UserDefaults.standard.set(designActive, forKey: "designActive")
            if let d = (b["design"] as? [String: Any]).flatMap(FaceDesign.init(json:)) {
                design = d
                UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: "design")
            }
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

    private static var faceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("face.png")
    }

    private static func loadFace() -> UIImage? {
        try? FileManager.default.createDirectory(at: faceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? Data(contentsOf: faceURL)).flatMap(UIImage.init(data:))
    }

    func requestFaces() { post("getFaces") }
    func requestFace() { post("getFace") }
    func openFacePicker() { post("openFacePicker") }
    func requestDesign() { post("getDesign") }
    func setDesign(_ d: FaceDesign) {
        design = d
        post("setDesign", d.json)
    }

    // MARK: Contacts

    func syncContacts() async {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                toast = "Allow Contacts for Wear OS Bridge in iPhone Settings"
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
            toast = "Saved to Files → On My iPhone → Wear OS Bridge"
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

    private struct Item: Identifiable {
        let title: String, sub: String, symbol: String, color: Color
        let dest: AnyView
        var id: String { title }
    }

    private var groups: [(String, [Item])] {
        [
            ("Customise", [
                Item(title: "Face gallery", sub: "\(FaceCatalog.all.count) free faces", symbol: "sparkles", color: .pink, dest: AnyView(FaceGalleryView())),
                Item(title: "Watch faces", sub: "On your watch now", symbol: "paintpalette.fill", color: .orange, dest: AnyView(WatchFacesView())),
                Item(title: "Google Play", sub: "Faces and apps", symbol: "bag.fill", color: .green, dest: AnyView(StoreScreen())),
                Item(title: "Watch apps", sub: "Open or uninstall", symbol: "square.grid.2x2.fill", color: .blue, dest: AnyView(AppsView())),
                Item(title: "Tiles", sub: "Swipe from the face", symbol: "rectangle.stack.fill", color: .teal, dest: AnyView(TilesInfoView())),
            ]),
            ("Stay in touch", [
                Item(title: "Notifications", sub: "Apps and types", symbol: "bell.badge.fill", color: .red, dest: AnyView(NotificationFiltersView())),
                Item(title: "Contacts", sub: "Copy to the watch", symbol: "person.crop.circle.fill", color: .gray, dest: AnyView(ContactsView())),
                Item(title: "Reminders", sub: "Tile on the watch", symbol: "checklist", color: .orange, dest: AnyView(RemindersView())),
                Item(title: "Alarms & timers", sub: "Set on the watch", symbol: "alarm.fill", color: .indigo, dest: AnyView(AlarmsView())),
            ]),
            ("Media & activity", [
                Item(title: "Photos", sub: "Send to Gallery", symbol: "photo.fill", color: .purple, dest: AnyView(PhotosToWatchView())),
                Item(title: "Voice recordings", sub: "Copy from watch", symbol: "waveform", color: .cyan, dest: AnyView(RecordingsView())),
                Item(title: "Workouts", sub: "Saved to Health", symbol: "figure.run", color: .green, dest: AnyView(WorkoutsInfoView())),
                Item(title: "Sounds", sub: "Ringtone and alerts", symbol: "speaker.wave.2.fill", color: .yellow, dest: AnyView(SoundsView())),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ForEach(groups, id: \.0) { group in
                    SectionTitle(text: group.0)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(group.1) { item in
                            NavigationLink { item.dest } label: { tile(item) }.buttonStyle(PressScale())
                        }
                    }
                }
            }
            .padding(16)
        }
        .auroraScreen()
        .navigationTitle("More")
        .toast($hub.toast)
    }

    private func tile(_ i: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: i.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(i.color.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: i.color.opacity(0.5), radius: 8, y: 3)
            Spacer(minLength: 0)
            Text(i.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.85)
            Text(i.sub).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(14)
        .card(cornerRadius: 22)
    }
}

/// The face that's on the watch now, every face installed, and the watch's own picker.
/// Wear OS doesn't let other apps switch faces, so choosing happens on the watch.
struct WatchFacesView: View {
    @EnvironmentObject var hub: FeatureHub
    @EnvironmentObject var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                WatchRender(battery: link.watchBattery, connected: link.status == .connected, face: hub.faceImage, size: 210)
                    .padding(.top, 8)
                Text(hub.faceName ?? "Current face").font(.title3.weight(.bold)).foregroundStyle(.white)
                Button { hub.openFacePicker() } label: {
                    Label("Change face on watch", systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)
                .disabled(link.status != .connected)

                NavigationLink { FaceGalleryView() } label: {
                    HStack(spacing: 14) {
                        HStack(spacing: -14) {
                            ForEach(FaceCatalog.styles.prefix(4).map(\.cover)) {
                                FaceRender(design: $0, showComplications: false).frame(width: 40, height: 40)
                                    .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Face gallery").font(.headline).foregroundStyle(.white)
                            Text("\(FaceCatalog.all.count) free faces in \(FaceCatalog.styles.count) styles").font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(14).card(cornerRadius: 20)
                }
                .buttonStyle(PressScale())

                SectionTitle(text: "Installed")
                VStack(spacing: 0) {
                    if hub.faces.isEmpty {
                        Text(link.status == .connected ? "Loading…" : "Connect your watch to see its faces.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.6)).padding(18)
                    }
                    ForEach(hub.faces) { f in
                        HStack(spacing: 12) {
                            Group {
                                if let img = hub.facePreviews[f.id] {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "applewatch").foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            .frame(width: 44, height: 44).background(.black).clipShape(Circle())
                            .overlay(Circle().strokeBorder(f.active ? Theme.accent2 : .white.opacity(0.15), lineWidth: f.active ? 2.5 : 1))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).foregroundStyle(.white)
                                Text(f.id).font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                            }
                            Spacer()
                            if f.active { Text("On watch").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent2) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        if f.id != hub.faces.last?.id { Divider().padding(.leading, 72) }
                    }
                }
                .card()
                NavigationLink { StoreScreen() } label: {
                    Label("Get more faces on Google Play", systemImage: "bag.fill").frame(maxWidth: .infinity).padding(14).card(cornerRadius: 18)
                }
                .buttonStyle(PressScale()).foregroundStyle(.white)
            }
            .padding(16)
        }
        .auroraScreen()
        .navigationTitle("Watch faces")
        .navigationBarTitleDisplayMode(.inline)
        .task { hub.requestFaces(); hub.requestFace() }
        .refreshable { hub.requestFaces(); hub.requestFace() }
        .toast($hub.toast)
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
        .auroraScreen()
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
        .auroraScreen()
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
        .auroraScreen()
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
        .auroraScreen()
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
        .auroraScreen()
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
                Text("Photos are resized for the watch and appear in its Gallery app, in the Wear OS Bridge album. Bluetooth is slow, so each takes a few seconds.")
            }
        }
        .auroraScreen()
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
        .auroraScreen()
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
                Label("On the watch, open Wear OS Bridge → Workout and pick Run, Walk, Cycle, Hike or Workout.", systemImage: "1.circle")
                Label("Tap End when you finish. The workout and its GPS route go to Apple Health the next time the watch connects.", systemImage: "2.circle")
            }
            if let last = health.lastWorkout { Section("Last saved") { Text(last) } }
            Section { Button("Allow workouts in Apple Health") { Task { await health.requestAccess() } } }
        }
        .auroraScreen()
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
        .auroraScreen()
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
