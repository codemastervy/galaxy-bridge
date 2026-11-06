import SwiftUI

/// First-run flow: the user puts the watch in pairing mode, picks it from the list, and confirms
/// the matching code that iOS and the watch both show (Bluetooth numeric comparison).
struct PairingView: View {
    @EnvironmentObject var link: WatchLink

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    if link.isPairing {
                        nearbyList
                    } else {
                        steps
                        Button {
                            link.startPairing()
                        } label: {
                            Label("Find my watch", systemImage: "dot.radiowaves.left.and.right").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .controlSize(.large)
                    }
                    if let error = link.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .auroraScreen()
            .toolbar {
                if link.isPairing {
                    Button("Cancel") { link.stopPairing() }
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Wordmark()
            ZStack {
                ForEach(0..<3) { i in
                    Circle().strokeBorder(Theme.accent2.opacity(0.35 - Double(i) * 0.1), lineWidth: 1.5)
                        .frame(width: 250 + CGFloat(i) * 46, height: 250 + CGFloat(i) * 46)
                        .scaleEffect(link.isPairing ? 1.06 : 1)
                        .animation(link.isPairing ? .easeInOut(duration: 1.2).repeatForever().delay(Double(i) * 0.25) : .default, value: link.isPairing)
                }
                WatchRender(battery: nil, connected: link.isPairing, size: 200)
            }
            .frame(height: 300)
            Text(link.isPairing ? "Looking for your watch" : "Pair your Galaxy Watch")
                .font(.title2.weight(.bold)).foregroundStyle(.white)
            Text(link.isPairing
                 ? "Keep the watch close and its Wear OS Bridge app in pairing mode."
                 : "Wear OS Bridge syncs your health data to Apple Health and turns your watch into a camera remote.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Step(number: 1, text: "Open **Wear OS Bridge** on your watch.")
            Step(number: 2, text: "Tap **Pair iPhone** (or **Pair new phone**).")
            Step(number: 3, text: "Tap **Find my watch** below and choose it.")
            Step(number: 4, text: "Check the **code matches** on both screens, then accept on both.")
        }
        .padding(18)
        .card()
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if link.nearby.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching… make sure the watch shows “Ready to pair”.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(18)
            } else {
                ForEach(link.nearby.sorted { $0.rssi > $1.rssi }) { watch in
                    Button { link.pair(with: watch) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "applewatch")
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 36, height: 36)
                                .background(Theme.accent.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(watch.name).font(.body.weight(.semibold))
                                Text("Ready to pair").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            SignalBars(rssi: watch.rssi)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if watch.id != link.nearby.sorted(by: { $0.rssi > $1.rssi }).last?.id { Divider().padding(.leading, 66) }
                }
            }
        }
        .card()
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}

private struct SignalBars: View {
    let rssi: Int

    var body: some View {
        let level = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Theme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 4))
            }
        }
        .accessibilityLabel("Signal \(level) of 3")
    }
}
