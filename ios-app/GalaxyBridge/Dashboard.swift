import SafariServices
import SwiftUI
import WearLink

// MARK: Root

struct Dashboard: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var health: HealthSync
    @EnvironmentObject var phone: PhoneServices

    var body: some View {
        Group {
            if link.hasKnownWatch { MainTabs() } else { PairingView() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent2)
    }
}

private struct MainTabs: View {
    @EnvironmentObject var health: HealthSync
    @EnvironmentObject var phone: PhoneServices
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView(tab: $tab) }.tabItem { Label("Watch", systemImage: "applewatch.side.right") }.tag(0)
            NavigationStack { HealthView() }.tabItem { Label("Health", systemImage: "heart.fill") }.tag(1)
            NavigationStack { StoreScreen() }.tabItem { Label("Store", systemImage: "bag.fill") }.tag(2)
            NavigationStack { MoreView() }.tabItem { Label("More", systemImage: "square.grid.2x2.fill") }.tag(3)
            NavigationStack { WatchSettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
        }
        .task {
            await health.requestAccess()
            await phone.requestPermissions()
            phone.refresh()
        }
    }
}

// MARK: Home

private struct HomeView: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var health: HealthSync
    @EnvironmentObject var phone: PhoneServices
    @EnvironmentObject var hub: FeatureHub
    @Binding var tab: Int
    @State private var showCamera = false
    @State private var showGallery = false
    @State private var confirmForget = false

    private var connected: Bool { link.status == .connected }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack { Wordmark(); Spacer() }
                    .padding(.top, 4)

                hero

                HStack(spacing: 6) {
                    OrbButton(title: link.findingWatch ? "Stop" : "Find", symbol: link.findingWatch ? "speaker.slash.fill" : "speaker.wave.3.fill",
                              color: .orange, active: link.findingWatch) { link.findWatch(!link.findingWatch) }
                        .disabled(!connected).opacity(connected ? 1 : 0.4)
                    OrbButton(title: "Camera", symbol: "camera.fill", color: Theme.accent2) { showCamera = true }
                    OrbButton(title: "Faces", symbol: "sparkles", color: Theme.accent3) { showGallery = true }
                    OrbButton(title: "DND", symbol: "moon.fill", color: Theme.accent,
                              active: link.watchStatus?.settings[WatchSetting.doNotDisturb.rawValue] == 1) {
                        let on = link.watchStatus?.settings[WatchSetting.doNotDisturb.rawValue] == 1
                        link.set(.doNotDisturb, on ? 0 : 1)
                    }
                    .disabled(!connected || link.watchStatus?.perms.dnd != true).opacity(connected ? 1 : 0.4)
                }

                if phone.findingPhone { FindingPhoneBanner() }
                if connected, link.watchStatus?.perms.ancs == false { NotificationSetupCard() }
                if let off = link.watchStatus?.clockOffset, abs(off) > 60 { ClockWarningCard(offset: off) }
                if !health.authorized { HealthAccessCard() }

                SectionTitle(text: "Today")
                Button { tab = 1 } label: { TodayCard(summary: health.summary) }.buttonStyle(PressScale())

                SectionTitle(text: "Your watch")
                InfoGrid()
                SyncCard()

                if let error = link.lastError ?? health.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding().card()
                }

                Button(role: .destructive) { confirmForget = true } label: {
                    Text("Forget this watch").font(.footnote.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .padding(.top, 8)
                .confirmationDialog("Forget this watch?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Forget", role: .destructive) { link.forgetWatch() }
                } message: {
                    Text("Also tap Forget iPhone on the watch, then remove it in Settings → Bluetooth.")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(AuroraBackground())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showCamera) { CameraScreen() }
        .navigationDestination(isPresented: $showGallery) { FaceGalleryView() }
        .toast($hub.toast)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            WatchRender(battery: link.watchBattery, connected: connected, face: hub.faceImage)
            Text(link.watchStatus.map { WatchNames.marketingName($0.model) } ?? "Galaxy Watch")
                .font(.title2.weight(.bold)).foregroundStyle(.white)
            if let face = hub.faceName { Text(face).font(.caption).foregroundStyle(.white.opacity(0.6)) }
            StatusPill(status: link.status)
        }
        .frame(maxWidth: .infinity)
    }
}

enum WatchNames {
    static func marketingName(_ model: String) -> String {
        switch model {
        case "SM-R890", "SM-R895", "SM-R880", "SM-R885": return "Galaxy Watch4 Classic"
        case "SM-R860", "SM-R865", "SM-R870", "SM-R875": return "Galaxy Watch4"
        case "SM-R900", "SM-R905", "SM-R910", "SM-R915": return "Galaxy Watch5"
        case "SM-R920", "SM-R925": return "Galaxy Watch5 Pro"
        case "SM-R930", "SM-R935", "SM-R940", "SM-R945": return "Galaxy Watch6"
        case "SM-R950", "SM-R955", "SM-R960", "SM-R965": return "Galaxy Watch6 Classic"
        default: return model.isEmpty ? "Galaxy Watch" : model
        }
    }
}

private struct TodayCard: View {
    let summary: DaySummary

    var body: some View {
        HStack(spacing: 18) {
            ActivityRings(rings: [
                (summary.energy / 500, Theme.energy),
                (summary.steps / 10_000, Theme.steps),
                (summary.distance / 8_000, Theme.distance),
            ], lineWidth: 11)
            .frame(width: 104, height: 104)
            VStack(alignment: .leading, spacing: 7) {
                stat(summary.steps.formatted(.number.precision(.fractionLength(0))), "steps", Theme.steps)
                stat(summary.energy.formatted(.number.precision(.fractionLength(0))), "kcal", Theme.energy)
                stat((summary.distance / 1000).formatted(.number.precision(.fractionLength(2))), "km", Theme.distance)
                HStack(spacing: 6) {
                    HeartBeat(bpm: summary.heartRate).font(.subheadline)
                    Text(summary.heartRate.map { "\(Int($0.rounded()))" } ?? "–").font(.headline.monospacedDigit()).foregroundStyle(.white)
                    Text("bpm").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .card()
    }

    private func stat(_ value: String, _ unit: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.white).contentTransition(.numericText())
            Text(unit).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct InfoGrid: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var phone: PhoneServices

    var body: some View {
        let s = link.watchStatus
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile("Battery", s.map { "\($0.pct)%" } ?? "–", s?.charging == true ? "Charging" : "Watch", "battery.75percent", Theme.steps)
            tile("Signal", link.rssi.map { "\($0) dBm" } ?? "–", link.rssi.map { $0 > -65 ? "Strong" : $0 > -80 ? "Good" : "Weak" } ?? "Bluetooth",
                 "antenna.radiowaves.left.and.right", Theme.accent2)
            tile("Storage", s.map { "\(($0.freeMB / 1000).formatted()) GB" } ?? "–", "free", "internaldrive.fill", Theme.accent)
            tile("Weather", phone.weather.map { "\(Int($0.tempC.rounded()))°" } ?? "–", phone.weather?.place ?? "On watch", "cloud.sun.fill", Theme.energy)
        }
    }

    private func tile(_ title: String, _ value: String, _ sub: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                .frame(width: 32, height: 32).background(color.opacity(0.18), in: Circle())
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(cornerRadius: 20)
    }
}

// MARK: Health

private struct HealthView: View {
    @EnvironmentObject var health: HealthSync

    var body: some View {
        let s = health.summary
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    HeartBeat(bpm: s.heartRate).font(.system(size: 54))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(s.heartRate.map { "\(Int($0.rounded()))" } ?? "–")
                            .font(.system(size: 72, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("BPM").font(.headline).foregroundStyle(Theme.heart)
                    }
                    if let at = s.heartRateAt {
                        Text("Measured \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.top, 10)

                ZStack {
                    ActivityRings(rings: [(s.energy / 500, Theme.energy), (s.steps / 10_000, Theme.steps), (s.distance / 8_000, Theme.distance)],
                                  lineWidth: 22)
                        .frame(width: 230, height: 230)
                    VStack(spacing: 0) {
                        Text(s.steps.formatted(.number.precision(.fractionLength(0))))
                            .font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        Text("steps").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.vertical, 6)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Active energy", symbol: "flame.fill", color: Theme.energy,
                               value: s.energy.formatted(.number.precision(.fractionLength(0))), unit: "of 500 kcal")
                    MetricTile(title: "Steps", symbol: "figure.walk", color: Theme.steps,
                               value: s.steps.formatted(.number.precision(.fractionLength(0))), unit: "of 10,000")
                    MetricTile(title: "Distance", symbol: "location.north.line.fill", color: Theme.distance,
                               value: (s.distance / 1000).formatted(.number.precision(.fractionLength(2))), unit: "km")
                    MetricTile(title: "Heart rate", symbol: "heart.fill", color: Theme.heart,
                               value: s.heartRate.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm")
                }

                SyncCard()
                NavigationLink { WorkoutsInfoView() } label: {
                    Label("Record a workout on the watch", systemImage: "figure.run")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).card()
                }
                .buttonStyle(PressScale())
                if !health.authorized { HealthAccessCard() }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(AuroraBackground())
        .navigationTitle("Health")
    }
}

// MARK: Cards

private struct NotificationSetupCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn on watch notifications", systemImage: "bell.badge.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Open **Settings → Bluetooth**, tap ⓘ next to your watch, and switch on **Share System Notifications**. Calls and music controls use the same setting.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Android only lets system apps set the clock, so the fix happens on the watch itself.
private struct ClockWarningCard: View {
    let offset: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Watch time is wrong", systemImage: "clock.badge.exclamationmark.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("It's \(Duration.seconds(abs(offset)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))) \(offset < 0 ? "behind" : "ahead"). On the watch, open Wear OS Bridge and tap **Watch time is wrong**, or go to Settings → General → Date and time and turn on **Automatic date and time** with Wi-Fi on. Health data is corrected automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct FindingPhoneBanner: View {
    @EnvironmentObject var phone: PhoneServices

    var body: some View {
        HStack {
            Label("Your watch is ringing this iPhone", systemImage: "iphone.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Stop") { phone.findPhone(false) }.buttonStyle(.borderedProminent)
        }
        .padding(16)
        .card()
    }
}

private struct StatusPill: View {
    let status: WatchLink.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(color.opacity(0.4), lineWidth: status == .connected ? 4 : 0))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.18), in: Capsule())
    }

    private var text: String {
        switch status {
        case .connected: return "Connected"
        case .notPaired: return "Not paired"
        case .connecting: return "Connecting…"
        case .searching: return "Looking for watch"
        case .bluetoothOff: return "Bluetooth off"
        case .needsRepair: return "Re-pair needed"
        case .unauthorized: return "Bluetooth not allowed"
        }
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting, .searching: return .yellow
        case .bluetoothOff, .unauthorized, .notPaired, .needsRepair: return .red
        }
    }
}

private struct MetricTile: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String
    let unit: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.15), in: Circle())
                Spacer()
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct SyncCard: View {
    @EnvironmentObject var health: HealthSync

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.text.square.fill")
                .font(.title2)
                .foregroundStyle(Theme.heart)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Health").font(.subheadline.weight(.semibold))
                if let last = health.lastSync {
                    Text("Synced \(last.formatted(.relative(presentation: .named))) · \(health.savedCount) samples")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for the first readings from your watch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .card()
    }
}

private struct HealthAccessCard: View {
    @EnvironmentObject var health: HealthSync

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect Apple Health", systemImage: "heart.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.heart)
            Text("Allow Wear OS Bridge to write heart rate, steps, distance, energy, floors and workouts. It never reads your existing data.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Allow access") { Task { await health.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.heart)
        }
        .padding(16)
        .card()
    }
}

