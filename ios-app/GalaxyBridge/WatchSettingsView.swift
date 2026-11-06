import SwiftUI
import WearLink

/// The companion-app settings screen: everything here is applied on the watch.
struct WatchSettingsView: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var phone: PhoneServices
    @State private var brightness: Double = 128
    @State private var editingBrightness = false

    private var s: WatchStatus? { link.watchStatus }
    private var connected: Bool { link.status == .connected && s != nil }

    var body: some View {
        Form {
            if !connected {
                Section {
                    Label("Connect your watch to change its settings.", systemImage: "applewatch.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                toggle("Mirror iPhone notifications", .notifications, symbol: "bell.badge.fill", color: .red)
                toggle("Incoming calls", .calls, symbol: "phone.fill", color: .green)
                toggle("Clearing on watch clears iPhone", .clearOnIPhone, symbol: "arrow.left.arrow.right", color: .blue)
                if let perms = s?.perms, !perms.ancs {
                    Label {
                        Text("On your iPhone, open Settings → Bluetooth, tap ⓘ next to the watch, and turn on **Share System Notifications**.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Notifications buzz on the watch with their actions. Calls can be answered or declined from the watch, and talked on through its speaker and mic.")
            }

            Section("Connection") {
                Toggle(isOn: $link.alertOnDisconnect) {
                    Label { Text("Alert when disconnected") } icon: { icon("antenna.radiowaves.left.and.right.slash", .orange) }
                }
                if let rssi = link.rssi {
                    LabeledContent("Signal", value: "\(rssi) dBm · \(rssi > -65 ? "Strong" : rssi > -80 ? "Good" : "Weak")")
                }
                NavigationLink("Connection history") { ConnectionHistoryView() }
            }

            Section("Music") {
                toggle("Music controls on watch", .music, symbol: "music.note", color: .pink)
            }

            Section {
                HStack {
                    icon("sun.max.fill", .orange)
                    Slider(value: $brightness, in: 1...255) { editing in
                        editingBrightness = editing
                        if !editing { link.set(.brightness, Int(brightness)) }
                    }
                }
                .disabled(!(s?.perms.system ?? false))
                Picker(selection: binding(.screenTimeout, default: 15)) {
                    ForEach([5, 10, 15, 30, 60, 120, 300], id: \.self) { secs in
                        Text(secs < 60 ? "\(secs) seconds" : "\(secs / 60) minute\(secs == 60 ? "" : "s")").tag(secs)
                    }
                } label: {
                    Label { Text("Screen timeout") } icon: { icon("timer", .gray) }
                }
                .disabled(!(s?.perms.system ?? false))
                toggle("Do Not Disturb", .doNotDisturb, symbol: "moon.fill", color: .indigo)
                    .disabled(!(s?.perms.dnd ?? false))
                Picker(selection: binding(.soundMode, default: 0)) {
                    Text("Sound").tag(0)
                    Text("Vibrate").tag(1)
                    Text("Mute").tag(2)
                } label: {
                    Label { Text("Sound mode") } icon: { icon("bell.fill", .red) }
                }
                volume("Media volume", .mediaVolume, symbol: "speaker.wave.2.fill")
                volume("Ring volume", .ringVolume, symbol: "bell.and.waves.left.and.right.fill")
                volume("Notification volume", .notifyVolume, symbol: "bell.badge.waveform.fill")
                volume("Alarm volume", .alarmVolume, symbol: "alarm.fill")
                NavigationLink { SoundsView() } label: {
                    Label { Text("Ringtone & notification sound") } icon: { icon("music.note.list", .purple) }
                }
            } header: {
                Text("Display & sounds")
            } footer: {
                if let p = s?.perms, !p.system || !p.dnd {
                    Text("Some options need a one-time permission on the watch: Galaxy Bridge → Settings → Let iPhone change.")
                }
            }

            Section {
                toggle("Always-on display", .alwaysOn, symbol: "sun.min.fill", color: .yellow)
                toggle("Raise wrist to wake", .raiseToWake, symbol: "hand.raised.fill", color: .blue)
                toggle("Double-tap to wake", .tapToWake, symbol: "hand.tap.fill", color: .blue)
                toggle("Turn bezel to wake", .bezelWake, symbol: "circle.dashed", color: .blue)
                toggle("Touch sensitivity (gloves)", .touchSensitivity, symbol: "hand.point.up.left.fill", color: .gray)
                Picker(selection: binding(.fontSize, default: 1)) {
                    Text("Small").tag(0); Text("Default").tag(1); Text("Large").tag(2); Text("Larger").tag(3); Text("Largest").tag(4)
                } label: {
                    Label { Text("Font size") } icon: { icon("textformat.size", .gray) }
                }
            } header: {
                Text("Display & gestures")
            } footer: {
                if s?.perms.secure != true {
                    Text("Needs a one-time setup over adb (WRITE_SECURE_SETTINGS) on the watch.")
                }
            }
            .disabled(s?.perms.secure != true)

            Section {
                toggle("Theatre mode", .theatreMode, symbol: "theatermasks.fill", color: .purple)
                toggle("Bedtime mode", .bedtimeMode, symbol: "bed.double.fill", color: .indigo)
                toggle("Power saving", .batterySaver, symbol: "battery.25percent", color: .orange)
                toggle("Water lock", .waterLock, symbol: "drop.fill", color: .cyan)
            } header: {
                Text("Modes")
            }
            .disabled(s?.perms.secure != true)

            Section("Apple Health") {
                toggle("Heart rate", .syncHeart, symbol: "heart.fill", color: Theme.heart)
                toggle("Steps", .syncSteps, symbol: "figure.walk", color: Theme.steps)
                toggle("Active energy", .syncEnergy, symbol: "flame.fill", color: Theme.energy)
                toggle("Distance", .syncDistance, symbol: "location.north.line.fill", color: Theme.distance)
                toggle("Floors climbed", .syncFloors, symbol: "figure.stairs", color: .orange)
            }

            Section {
                Toggle(isOn: $phone.shareWeather) { Label { Text("Weather") } icon: { icon("cloud.sun.fill", .cyan) } }
                Toggle(isOn: $phone.shareCalendar) { Label { Text("Calendar") } icon: { icon("calendar", .red) } }
            } header: {
                Text("Show on watch")
            } footer: {
                Text("Weather comes from Open-Meteo using your approximate (~1 km) location. Calendar events go only to your watch.")
            }

            if let s {
                Section("About") {
                    row("Model", s.model)
                    row("Software", s.os)
                    row("Galaxy Bridge on watch", s.app)
                    row("Battery", "\(s.pct)%" + (s.charging ? " · charging" : ""))
                    if s.totalMB > 0 {
                        row("Storage", "\(gb(s.freeMB)) free of \(gb(s.totalMB))")
                    }
                }
            }
        }
        .navigationTitle("Watch settings")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!connected)
        .onAppear { link.send(.getStatus) }
        .onChange(of: s?.settings[WatchSetting.brightness.rawValue]) { _, v in
            if let v, !editingBrightness { brightness = Double(v) }
        }
        .task { if let v = s?.settings[WatchSetting.brightness.rawValue] { brightness = Double(v) } }
    }

    private func binding(_ key: WatchSetting, default d: Int) -> Binding<Int> {
        Binding(get: { s?.settings[key.rawValue] ?? d }, set: { link.set(key, $0) })
    }

    private func volume(_ title: String, _ key: WatchSetting, symbol: String) -> some View {
        HStack {
            icon(symbol, .pink)
            Slider(value: Binding(get: { Double(s?.settings[key.rawValue] ?? 8) },
                                  set: { link.set(key, Int($0.rounded())) }),
                   in: 0...15, step: 1) { Text(title) }
        }
        .accessibilityLabel(title)
    }

    private func toggle(_ title: String, _ key: WatchSetting, symbol: String, color: Color) -> some View {
        Toggle(isOn: Binding(get: { (s?.settings[key.rawValue] ?? 0) == 1 },
                             set: { link.set(key, $0 ? 1 : 0) })) {
            Label { Text(title) } icon: { icon(symbol, color) }
        }
    }

    private func icon(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func gb(_ mb: Int) -> String {
        (Double(mb) / 1000).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}

struct SoundsView: View {
    @EnvironmentObject var hub: FeatureHub

    var body: some View {
        Form {
            Section("Ringtone") {
                ForEach(hub.ringtones) { s in row(s, current: hub.ringNow) { hub.setSound("ring", s.uri) } }
            }
            Section("Notification sound") {
                ForEach(hub.notifSounds) { s in row(s, current: hub.notifNow) { hub.setSound("notif", s.uri) } }
            }
        }
        .overlay { if hub.ringtones.isEmpty { ProgressView() } }
        .navigationTitle("Sounds")
        .onAppear { hub.requestSounds() }
    }

    private func row(_ s: FeatureHub.Sound, current: String, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack { Text(s.title).foregroundStyle(.primary); Spacer(); if s.uri == current { Image(systemName: "checkmark") } }
        }
    }
}

struct ConnectionHistoryView: View {
    @EnvironmentObject var link: WatchLink

    var body: some View {
        List(link.history) { e in
            Label {
                VStack(alignment: .leading) {
                    Text(e.connected ? "Connected" : "Disconnected")
                    Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: e.connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(e.connected ? .green : .red)
            }
        }
        .overlay { if link.history.isEmpty { ContentUnavailableView("No history yet", systemImage: "clock") } }
        .navigationTitle("Connection history")
    }
}
