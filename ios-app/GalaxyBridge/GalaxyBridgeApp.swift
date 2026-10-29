import SwiftUI

@main
struct GalaxyBridgeApp: App {
    @StateObject private var link = WatchLink()
    @StateObject private var health = HealthSync()
    @StateObject private var camera = Camera()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(health)
                .environmentObject(camera)
                .task {
                    link.onSamples = { [health] id, items in await health.save(batchId: id, items) }
                    link.onShutter = { [camera] in camera.capture() }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var link: WatchLink
    @EnvironmentObject var health: HealthSync
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            List {
                Section("Watch") {
                    LabeledContent("Status", value: statusText)
                    if let battery = link.watchBattery {
                        LabeledContent("Battery", value: "\(battery)%")
                    }
                    if let version = link.watchAppVersion {
                        LabeledContent("Watch app", value: version)
                    }
                    if let error = link.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section("Apple Health") {
                    if health.authorized {
                        LabeledContent("Samples saved", value: "\(health.savedCount)")
                        if let last = health.lastSync {
                            LabeledContent("Last sync") { Text(last, style: .relative) }
                        }
                    } else {
                        Button("Allow writing to Apple Health") {
                            Task { await health.requestAccess() }
                        }
                    }
                    if let error = health.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Open camera") { showCamera = true }
                } footer: {
                    Text("Press Shutter in Galaxy Bridge on the watch to take a photo.")
                }
            }
            .navigationTitle("Galaxy Bridge")
            .fullScreenCover(isPresented: $showCamera) { CameraScreen() }
            .task { await health.requestAccess() }
        }
    }

    private var statusText: String {
        switch link.status {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access needed"
        case .searching: return "Looking for watch"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }
}

struct CameraScreen: View {
    @EnvironmentObject var camera: Camera
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: camera.session).ignoresSafeArea()
            VStack(spacing: 16) {
                if let message = camera.message {
                    Text(message)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                HStack {
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { camera.capture() } label: {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                    }
                    .accessibilityLabel("Take photo")
                    Spacer()
                    Color.clear.frame(width: 60)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .background(.black)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }
}
