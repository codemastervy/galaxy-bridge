import SafariServices
import SwiftUI

// MARK: Theme

enum Theme {
    static let accent = Color(red: 0.36, green: 0.42, blue: 1.0)
    static let accent2 = Color(red: 0.18, green: 0.82, blue: 0.86)
    static let heart = Color(red: 1.0, green: 0.27, blue: 0.38)
    static let steps = Color(red: 0.25, green: 0.85, blue: 0.48)
    static let distance = Color(red: 0.31, green: 0.67, blue: 1.0)
    static let energy = Color(red: 1.0, green: 0.62, blue: 0.2)

    static let headerGradient = LinearGradient(
        colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: Dashboard

struct Dashboard: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var health: HealthSync
    @EnvironmentObject var phone: PhoneServices
    @State private var showCamera = false
    @State private var confirmForget = false
    @State private var showStore = false

    var body: some View {
        if link.hasKnownWatch {
            home
        } else {
            PairingView()
        }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    WatchCard()
                    QuickActions(openCamera: { showCamera = true }, openStore: { showStore = true })
                    if link.status == .connected, link.watchStatus?.perms.ancs == false { NotificationSetupCard() }
                    if phone.findingPhone { FindingPhoneBanner() }
                    if !health.authorized { HealthAccessCard() }
                    MetricsGrid(summary: health.summary)
                    ShutterCard { showCamera = true }
                    SyncCard()
                    if let error = link.lastError ?? health.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .card()
                    }
                    Button(role: .destructive) { confirmForget = true } label: {
                        Text("Forget this watch").frame(maxWidth: .infinity)
                    }
                    .padding(.top, 8)
                    .confirmationDialog("Forget this watch?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { link.forgetWatch() }
                    } message: {
                        Text("Also tap Forget iPhone on the watch, then remove it in Settings → Bluetooth.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Galaxy Bridge")
            .fullScreenCover(isPresented: $showCamera) { CameraScreen() }
            .sheet(isPresented: $showStore) {
                SafariView(url: PlayStore.watchFaces).ignoresSafeArea()
            }
            .toolbar {
                NavigationLink { WatchSettingsView() } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Watch settings")
            }
            .task {
                await health.requestAccess()
                await phone.requestPermissions()
                phone.refresh()
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: Quick actions

private struct QuickActions: View {
    @EnvironmentObject var link: WatchLink
    let openCamera: () -> Void
    let openStore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            action(link.findingWatch ? "Stop" : "Find watch", link.findingWatch ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   .orange, enabled: link.status == .connected) { link.findWatch(!link.findingWatch) }
            action("Camera", "camera.fill", Theme.accent2) { openCamera() }
            NavigationLink { WatchSettingsView() } label: { tile("Settings", "slider.horizontal.3", Theme.accent) }
                .buttonStyle(.plain)
            action("Faces", "paintpalette.fill", .pink) { openStore() }
        }
    }

    private func action(_ title: String, _ symbol: String, _ color: Color, enabled: Bool = true,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) { tile(title, symbol, color) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
    }

    private func tile(_ title: String, _ symbol: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color.gradient, in: Circle())
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .card()
    }
}

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

// MARK: Watch card

private struct WatchCard: View {
    @EnvironmentObject var link: WatchLink

    var body: some View {
        HStack(spacing: 20) {
            WatchFace(battery: link.watchBattery, connected: link.status == .connected)
                .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                Text(link.watchStatus.map { Self.marketingName($0.model) } ?? "Galaxy Watch")
                    .font(.headline)
                    .foregroundStyle(.white)
                StatusPill(status: link.status)
                if let battery = link.watchBattery {
                    Label("\(battery)% battery", systemImage: batterySymbol(battery))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                if let version = link.watchAppVersion {
                    Text("Watch app \(version)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.headerGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 8)
    }

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

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// A round watch face with a bezel, echoing the Watch4 Classic's rotating bezel.
private struct WatchFace: View {
    let battery: Int?
    let connected: Bool

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.85))
            ForEach(0..<60, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i % 5 == 0 ? 0.9 : 0.35))
                    .frame(width: i % 5 == 0 ? 2.5 : 1.2, height: i % 5 == 0 ? 7 : 4)
                    .offset(y: -47)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            Circle()
                .trim(from: 0, to: CGFloat(battery ?? 0) / 100)
                .stroke(Theme.accent2, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(18)
                .animation(.easeOut(duration: 0.6), value: battery)
            VStack(spacing: 2) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(connected ? Theme.accent2 : .white.opacity(0.5))
            }
        }
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "Watch connected" : "Watch not connected")
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

// MARK: Metrics

private struct MetricsGrid: View {
    let summary: DaySummary

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricTile(title: "Heart rate", symbol: "heart.fill", color: Theme.heart,
                       value: summary.heartRate.map { "\(Int($0.rounded()))" } ?? "–", unit: "bpm",
                       footnote: summary.heartRateAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" })
            MetricTile(title: "Steps", symbol: "figure.walk", color: Theme.steps,
                       value: summary.steps.formatted(.number.precision(.fractionLength(0))), unit: "today")
            MetricTile(title: "Distance", symbol: "location.north.line.fill", color: Theme.distance,
                       value: (summary.distance / 1000).formatted(.number.precision(.fractionLength(2))), unit: "km")
            MetricTile(title: "Active energy", symbol: "flame.fill", color: Theme.energy,
                       value: summary.energy.formatted(.number.precision(.fractionLength(0))), unit: "kcal")
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

// MARK: Shutter, sync, access

private struct ShutterCard: View {
    let openCamera: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Remote shutter", systemImage: "camera.shutter.button.fill")
                .font(.headline)
            Text("Open the Camera app (or the camera below), then tap Shutter on your watch. The first time, accept the Bluetooth keyboard request on your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: openCamera) {
                Label("Open Galaxy Bridge camera", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .card()
    }
}

enum PlayStore {
    static let watchFaces = URL(string: "https://play.google.com/store/apps/category/WATCH_FACE")!
}

private struct WatchFacesCard: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "paintpalette.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get watch faces").font(.subheadline.weight(.semibold))
                    Text("Browse Google Play and install to your watch")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Safari's own view: Google sign-in stays inside Safari and is never visible to this app.
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
            Text("Allow Galaxy Bridge to write heart rate, steps, distance and active energy. It never reads your existing data.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Allow access") { Task { await health.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.heart)
        }
        .padding(16)
        .card()
    }
}

extension View {
    func card() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
