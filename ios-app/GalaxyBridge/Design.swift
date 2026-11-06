import SwiftUI

// MARK: Theme

enum Theme {
    static let accent = Color(red: 0.45, green: 0.40, blue: 1.0)
    static let accent2 = Color(red: 0.16, green: 0.86, blue: 0.90)
    static let accent3 = Color(red: 0.96, green: 0.36, blue: 0.86)
    static let heart = Color(red: 1.0, green: 0.27, blue: 0.40)
    static let steps = Color(red: 0.30, green: 0.92, blue: 0.52)
    static let distance = Color(red: 0.31, green: 0.67, blue: 1.0)
    static let energy = Color(red: 1.0, green: 0.60, blue: 0.20)
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.10)

    static let headerGradient = LinearGradient(
        colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandGradient = LinearGradient(
        colors: [accent2, accent, accent3], startPoint: .leading, endPoint: .trailing)
}

// MARK: Background

/// A slow-moving aurora behind every screen.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let s = Float(sin(t / 7)), c = Float(cos(t / 9))
            if #available(iOS 18.0, *) {
                MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + 0.08 * s, 0], [1, 0],
                [0, 0.5 + 0.06 * c], [0.5 + 0.12 * c, 0.45 + 0.1 * s], [1, 0.5 - 0.06 * s],
                [0, 1], [0.5 - 0.08 * s, 1], [1, 1],
            ], colors: [
                Theme.ink, Color(red: 0.13, green: 0.10, blue: 0.36), Theme.ink,
                Color(red: 0.03, green: 0.20, blue: 0.30), Color(red: 0.20, green: 0.10, blue: 0.42), Color(red: 0.24, green: 0.05, blue: 0.30),
                Theme.ink, Color(red: 0.02, green: 0.10, blue: 0.18), Theme.ink,
            ])

            } else {
                ZStack {
                    Theme.ink
                    RadialGradient(colors: [Color(red: 0.20, green: 0.10, blue: 0.42), .clear],
                                   center: UnitPoint(x: 0.5 + 0.12 * Double(c), y: 0.45 + 0.1 * Double(s)), startRadius: 0, endRadius: 420)
                    RadialGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.30), .clear],
                                   center: UnitPoint(x: 0, y: 0.5 + 0.06 * Double(c)), startRadius: 0, endRadius: 300)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: Glass

extension View {
    /// Frosted glass panel with a soft gradient rim.
    func card(cornerRadius: CGFloat = 24) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
    }

    /// A screen in the app's style: aurora behind, transparent lists.
    func auroraScreen() -> some View {
        scrollContentBackground(.hidden).background(AuroraBackground())
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold)).tracking(1.6)
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// Round glass button with a glowing icon.
struct OrbButton: View {
    let title: String
    let symbol: String
    let color: Color
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(color.opacity(active ? 0.55 : 0.18))
                    Circle().strokeBorder(color.opacity(0.7), lineWidth: 1.2)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: active)
                }
                .frame(width: 60, height: 60)
                .shadow(color: color.opacity(0.55), radius: active ? 16 : 8)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: Watch render

/// A Galaxy Watch4 Classic: rotating bezel with minute track, live analog hands,
/// a battery arc, and a glow that breathes while connected.
struct WatchRender: View {
    let battery: Int?
    let connected: Bool
    /// A preview of the face that's active on the watch, when it has sent one.
    var face: UIImage? = nil
    var size: CGFloat = 230

    var body: some View {
        ZStack {
            // Glow
            Circle()
                .fill(RadialGradient(colors: [(connected ? Theme.accent2 : Color.gray).opacity(0.55), .clear],
                                     center: .center, startRadius: size * 0.3, endRadius: size * 0.72))
                .frame(width: size * 1.45, height: size * 1.45)
                .phaseAnimator([0.75, 1.0]) { v, p in v.opacity(connected ? p : 0.4) } animation: { _ in .easeInOut(duration: 2.2) }

            // Lugs
            ForEach([0.0, 180.0], id: \.self) { angle in
                RoundedRectangle(cornerRadius: size * 0.05)
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.5, height: size * 0.22)
                    .offset(y: -size * 0.5)
                    .rotationEffect(.degrees(angle))
            }
            // Side buttons
            ForEach([-18.0, 18.0], id: \.self) { a in
                Capsule().fill(Color(white: 0.25)).frame(width: size * 0.07, height: size * 0.13)
                    .offset(x: size * 0.53).rotationEffect(.degrees(a))
            }

            // Case + bezel
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.55), Color(white: 0.16), Color(white: 0.42), Color(white: 0.12), Color(white: 0.55)],
                                      center: .center))
                .frame(width: size, height: size)
            Circle()
                .fill(Color(white: 0.07))
                .frame(width: size * 0.9, height: size * 0.9)
            BezelTrack(size: size * 0.9)

            // Dial
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.10, green: 0.10, blue: 0.20), .black], center: .center,
                                     startRadius: 0, endRadius: size * 0.36))
                .frame(width: size * 0.72, height: size * 0.72)
            Circle()
                .trim(from: 0, to: CGFloat(battery ?? 0) / 100)
                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: size * 0.022, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.64, height: size * 0.64)
                .animation(.easeOut(duration: 0.8), value: battery)

            if let face {
                Image(uiImage: face).resizable().scaledToFill()
                    .frame(width: size * 0.6, height: size * 0.6)
                    .clipShape(Circle())
            } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: context.date)
                let h = Double(comps.hour ?? 0 % 12), m = Double(comps.minute ?? 0), s = Double(comps.second ?? 0)
                ZStack {
                    VStack(spacing: 2) {
                        Text(context.date, format: .dateTime.weekday(.abbreviated).day())
                            .font(.system(size: size * 0.055, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent2)
                        Text(battery.map { "\($0)%" } ?? "—")
                            .font(.system(size: size * 0.05, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .offset(y: size * 0.13)
                    hand(width: size * 0.028, length: size * 0.17, color: .white, angle: (h.truncatingRemainder(dividingBy: 12) + m / 60) * 30)
                    hand(width: size * 0.02, length: size * 0.25, color: .white, angle: (m + s / 60) * 6)
                    hand(width: size * 0.008, length: size * 0.28, color: Theme.accent3, angle: s * 6)
                    Circle().fill(Theme.accent3).frame(width: size * 0.035)
                }
            }
            }

            // Glass sheen
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .center))
                .frame(width: size * 0.72, height: size * 0.72)
                .allowsHitTesting(false)
        }
        .frame(width: size * 1.1, height: size * 1.25)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "Watch connected" + (battery.map { ", battery \($0) percent" } ?? "") : "Watch not connected")
    }

    private func hand(width: CGFloat, length: CGFloat, color: Color, angle: Double) -> some View {
        Capsule().fill(color)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }
}

private struct BezelTrack: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            ForEach(0..<60, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i % 5 == 0 ? 0.95 : 0.4))
                    .frame(width: i % 5 == 0 ? size * 0.014 : size * 0.007, height: i % 5 == 0 ? size * 0.06 : size * 0.03)
                    .offset(y: -size * 0.44)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            ForEach(1..<12, id: \.self) { i in
                if i % 2 == 0 {
                    Text("\(i * 5)")
                        .font(.system(size: size * 0.055, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .rotationEffect(.degrees(-Double(i) * 30))
                        .offset(y: -size * 0.37)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
            }
            Triangle().fill(Theme.accent3).frame(width: size * 0.06, height: size * 0.05).offset(y: -size * 0.37)
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath() }
    }
}

// MARK: Activity rings

struct ActivityRings: View {
    let rings: [(progress: Double, color: Color)]
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            ForEach(rings.indices, id: \.self) { i in
                let inset = CGFloat(i) * (lineWidth + 4)
                Circle().stroke(rings[i].color.opacity(0.18), lineWidth: lineWidth).padding(inset)
                Circle()
                    .trim(from: 0, to: min(1, max(0.001, rings[i].progress)))
                    .stroke(AngularGradient(colors: [rings[i].color.opacity(0.7), rings[i].color], center: .center),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
                    .shadow(color: rings[i].color.opacity(0.6), radius: 6)
                    .animation(.spring(duration: 1.2), value: rings[i].progress)
            }
        }
        .padding(lineWidth / 2)
    }
}

/// A beating heart; speed follows the latest heart rate.
struct HeartBeat: View {
    let bpm: Double?
    var body: some View {
        Image(systemName: "heart.fill")
            .foregroundStyle(Theme.heart)
            .phaseAnimator([1.0, 1.22, 1.0]) { v, s in v.scaleEffect(s) } animation: { _ in
                .easeInOut(duration: 60 / max(40, bpm ?? 70) / 3)
            }
            .shadow(color: Theme.heart.opacity(0.7), radius: 8)
    }
}

/// Wordmark: "Wear OS Bridge".
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(Theme.brandGradient)
            Text("Wear OS \(Text("Bridge").foregroundStyle(Theme.accent2))").font(.title2.weight(.heavy)).foregroundStyle(.white)
        }
    }
}
