import AVKit
import SwiftUI

@main
struct GalaxyBridgeApp: App {
    @StateObject private var link = WatchLink()
    @StateObject private var health = HealthSync()
    @StateObject private var camera = Camera()

    var body: some Scene {
        WindowGroup {
            Dashboard()
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

struct CameraScreen: View {
    @EnvironmentObject var camera: Camera
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session, onHardwareShutter: shoot)
                .ignoresSafeArea()
            Color.white.opacity(flash ? 0.8 : 0).ignoresSafeArea().allowsHitTesting(false)

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close camera")
                    Spacer()
                    Label("Watch shutter ready", systemImage: "applewatch.radiowaves.left.and.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.horizontal)

                Spacer()

                if let message = camera.message {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }

                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 5).frame(width: 80, height: 80)
                        Circle().fill(.white).frame(width: 66, height: 66)
                    }
                }
                .accessibilityLabel("Take photo")
                .padding(.vertical, 24)
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.captureCount) { _, _ in
            withAnimation(.easeOut(duration: 0.05)) { flash = true }
            withAnimation(.easeIn(duration: 0.25).delay(0.05)) { flash = false }
        }
    }

    private func shoot() { camera.capture() }
}
