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
                Text("Notifications buzz on the watch with their actions. Calls can be answered or declined from the watch; audio stays on the iPhone.")
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
            } header: {
                Text("Display & sounds")
            } footer: {
                if let p = s?.perms, !p.system || !p.dnd {
                    Text("Some options need a one-time permission on the watch: Galaxy Bridge → Settings → Let iPhone change.")
                }
            }

            Section("Apple Health") {
                toggle("Heart rate", .syncHeart, symbol: "heart.fill", color: Theme.heart)
                toggle("Steps", .syncSteps, symbol: "figure.walk", color: Theme.steps)
                toggle("Active energy", .syncEnergy, symbol: "flame.fill", color: Theme.energy)
                toggle("Distance", .syncDistance, symbol: "location.north.line.fill", color: Theme.distance)
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
