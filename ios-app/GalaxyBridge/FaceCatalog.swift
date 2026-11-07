import SwiftUI

// MARK: - Model

/// A design for the Wear OS Bridge watch face. Must match FaceDesign.kt in the watch app.
struct FaceDesign: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let layout: String
    let bg1: String, bg2: String, accent: String, ink: String
    /// For layout "spec": which FaceSpecs entry draws it.
    var specID: String? = nil
    /// The style this design belongs to (a layout or spec id).
    var style: String { specID ?? layout }
    var palette: FaceCatalog.Palette { FaceCatalog.Palette(id: id, name: name, bg1: bg1, bg2: bg2, accent: accent, ink: ink) }

    var json: [String: Any] {
        var j: [String: Any] = ["id": id, "name": name, "layout": layout, "bg1": bg1, "bg2": bg2, "accent": accent, "ink": ink]
        if let s = specID.flatMap(FaceSpecs.spec) { j["spec"] = s.json }
        return j
    }

    init(id: String, name: String, layout: String, bg1: String, bg2: String, accent: String, ink: String, specID: String? = nil) {
        self.id = id; self.name = name; self.layout = layout; self.bg1 = bg1; self.bg2 = bg2; self.accent = accent; self.ink = ink
        self.specID = specID
    }

    init?(json j: [String: Any]) {
        guard let id = j["id"] as? String, let name = j["name"] as? String, let layout = j["layout"] as? String,
              FaceCatalog.layouts.contains(where: { $0.id == layout }),
              let bg1 = j["bg1"] as? String, let bg2 = j["bg2"] as? String,
              let accent = j["accent"] as? String, let ink = j["ink"] as? String else { return nil }
        let specID = layout == "spec" ? FaceCatalog.all.first(where: { $0.id == id })?.specID : nil
        self.init(id: String(id.prefix(60)), name: String(name.prefix(40)), layout: layout, bg1: bg1, bg2: bg2, accent: accent, ink: ink, specID: specID)
    }
}

enum FaceCatalog {
    struct Layout: Identifiable { let id: String; let title: String; let blurb: String }
    struct Palette { let id: String; let name: String; let bg1: String; let bg2: String; let accent: String; let ink: String }

    static let layouts: [Layout] = [
        Layout(id: "classic", title: "Classic", blurb: "Batons, a sweeping seconds hand"),
        Layout(id: "minimal", title: "Minimal", blurb: "Dots and slim hands"),
        Layout(id: "bold", title: "Bold", blurb: "Chunky markers, easy to read"),
        Layout(id: "digital", title: "Digital", blurb: "Big time, seconds ring"),
        Layout(id: "ring", title: "Rings", blurb: "Hours and minutes as rings"),
        Layout(id: "orbit", title: "Orbit", blurb: "Planets mark the time"),
        Layout(id: "sport", title: "Sport", blurb: "Bezel scale, big digits"),
        Layout(id: "radar", title: "Radar", blurb: "Sweeping scanner seconds"),
        Layout(id: "spec", title: "", blurb: ""),
    ]

    static let palettes: [Palette] = [
        Palette(id: "aurora", name: "Aurora", bg1: "#1B1E4B", bg2: "#05060F", accent: "#2ED1DB", ink: "#FFFFFF"),
        Palette(id: "ember", name: "Ember", bg1: "#3A1206", bg2: "#0A0302", accent: "#FF7A2E", ink: "#FFF1E6"),
        Palette(id: "kauri", name: "Kauri", bg1: "#14301F", bg2: "#040A06", accent: "#7CE38B", ink: "#EFFFF2"),
        Palette(id: "pohutukawa", name: "Pōhutukawa", bg1: "#3B0A14", bg2: "#0B0204", accent: "#FF4D6A", ink: "#FFFFFF"),
        Palette(id: "glacier", name: "Glacier", bg1: "#DDEBF5", bg2: "#9DB7CC", accent: "#1E6FD9", ink: "#0C1B2A"),
        Palette(id: "midnight", name: "Midnight", bg1: "#10131C", bg2: "#000000", accent: "#8A9BFF", ink: "#E8ECFF"),
        Palette(id: "lagoon", name: "Lagoon", bg1: "#043A40", bg2: "#011417", accent: "#3FF0D2", ink: "#E8FFFB"),
        Palette(id: "sandstone", name: "Sandstone", bg1: "#E9D8BF", bg2: "#BFA27E", accent: "#A0441B", ink: "#2B1C10"),
        Palette(id: "neon", name: "Neon", bg1: "#12001F", bg2: "#000000", accent: "#FF2BD6", ink: "#E6FF4D"),
        Palette(id: "graphite", name: "Graphite", bg1: "#2A2D33", bg2: "#0C0D10", accent: "#FFB020", ink: "#F2F2F2"),
        Palette(id: "matcha", name: "Matcha", bg1: "#DDE8C8", bg2: "#A9BE8A", accent: "#3E6B1F", ink: "#1F2A12"),
        Palette(id: "cobalt", name: "Cobalt", bg1: "#0A2A7A", bg2: "#020A24", accent: "#FFD23F", ink: "#FFFFFF"),
        Palette(id: "rose", name: "Rose Gold", bg1: "#3A2326", bg2: "#120A0B", accent: "#F2B5A0", ink: "#FFF4F0"),
        Palette(id: "volt", name: "Volt", bg1: "#141414", bg2: "#000000", accent: "#C6FF00", ink: "#FFFFFF"),
        Palette(id: "lavender", name: "Lavender", bg1: "#2B2147", bg2: "#0D0A17", accent: "#C9A8FF", ink: "#F6F0FF"),
        Palette(id: "paper", name: "Paper", bg1: "#F7F4EC", bg2: "#DCD6C6", accent: "#D7263D", ink: "#151515"),
        Palette(id: "ocean", name: "Deep Ocean", bg1: "#0B3954", bg2: "#02111B", accent: "#5AC8FA", ink: "#E6F6FF"),
        Palette(id: "sunset", name: "Sunset", bg1: "#5A1A4A", bg2: "#1A0612", accent: "#FFA94D", ink: "#FFF3E6"),
        Palette(id: "forest", name: "Night Forest", bg1: "#0F2A1D", bg2: "#030806", accent: "#E5C07B", ink: "#F3F7EF"),
        Palette(id: "arctic", name: "Arctic", bg1: "#FFFFFF", bg2: "#D8E2EA", accent: "#00A3FF", ink: "#0B1520"),
        Palette(id: "copper", name: "Copper", bg1: "#2B1A12", bg2: "#0A0604", accent: "#E08A4B", ink: "#F7E7DA"),
        Palette(id: "mint", name: "Mint", bg1: "#0E2B27", bg2: "#030B0A", accent: "#9BF6D2", ink: "#FFFFFF"),
        Palette(id: "crimson", name: "Crimson", bg1: "#1A0000", bg2: "#000000", accent: "#FF1F3D", ink: "#FFFFFF"),
        Palette(id: "sky", name: "Sky", bg1: "#7FC8F8", bg2: "#3A87C9", accent: "#FFFFFF", ink: "#0A2540"),
        Palette(id: "plum", name: "Plum", bg1: "#3D1440", bg2: "#110513", accent: "#FF8AD8", ink: "#FBEAFF"),
        Palette(id: "slate", name: "Slate", bg1: "#334155", bg2: "#0F172A", accent: "#38BDF8", ink: "#F1F5F9"),
        Palette(id: "honey", name: "Honey", bg1: "#3A2A05", bg2: "#0E0A01", accent: "#FFC233", ink: "#FFF8E6"),
        Palette(id: "teal", name: "Teal", bg1: "#00454A", bg2: "#001518", accent: "#FF6F59", ink: "#E9FFFD"),
        Palette(id: "mono", name: "Mono", bg1: "#000000", bg2: "#000000", accent: "#FFFFFF", ink: "#FFFFFF"),
        Palette(id: "blush", name: "Blush", bg1: "#F9E1E6", bg2: "#E8B8C3", accent: "#B0185E", ink: "#3A0A1F"),
        Palette(id: "galaxy", name: "Galaxy", bg1: "#2A0F5C", bg2: "#05010F", accent: "#7DF9FF", ink: "#FFFFFF"),
        Palette(id: "desert", name: "Desert Night", bg1: "#2E1F3D", bg2: "#0C0812", accent: "#FF9E64", ink: "#FFE8D6"),
        Palette(id: "jade", name: "Jade", bg1: "#0B3D2E", bg2: "#02120D", accent: "#00E09E", ink: "#E6FFF6"),
        Palette(id: "steel", name: "Steel", bg1: "#5B6470", bg2: "#22262C", accent: "#FF5A36", ink: "#FFFFFF"),
        Palette(id: "lemon", name: "Lemon", bg1: "#FFF6B8", bg2: "#F0D861", accent: "#1F1F1F", ink: "#1F1F1F"),
        Palette(id: "indigo", name: "Indigo", bg1: "#1E1B6B", bg2: "#08071F", accent: "#FF7AE0", ink: "#EEF0FF"),
        Palette(id: "rust", name: "Rust", bg1: "#4A1C0C", bg2: "#140703", accent: "#F4D35E", ink: "#FFF5E8"),
        Palette(id: "orchid", name: "Orchid", bg1: "#1A0B2E", bg2: "#06020D", accent: "#B388FF", ink: "#FFFFFF"),
        Palette(id: "fern", name: "Fern", bg1: "#1E3A14", bg2: "#081205", accent: "#B5F44A", ink: "#F4FFE8"),
        Palette(id: "carbon", name: "Carbon", bg1: "#1C1C1E", bg2: "#060606", accent: "#30D158", ink: "#FFFFFF"),
    ]

    struct Style: Identifiable {
        let id: String, title: String, blurb: String
        let faces: [FaceDesign]
        var cover: FaceDesign { faces[0] }
    }

    /// Every style (the built-in layouts plus every spec in faces/specs.json), each in its palettes.
    static let styles: [Style] = {
        let specStyles = FaceSpecs.all.map { s in
            Style(id: s.id, title: s.name, blurb: s.blurb, faces: s.palettes.map { p in
                FaceDesign(id: "\(s.id)-\(p.id)", name: "\(s.name) \(p.name)", layout: "spec",
                           bg1: p.bg1, bg2: p.bg2, accent: p.accent, ink: p.ink, specID: s.id)
            })
        }
        let classic = layouts.filter { $0.id != "spec" }.map { l in
            Style(id: l.id, title: l.title, blurb: l.blurb, faces: palettes.map { p in
                FaceDesign(id: "\(p.id)-\(l.id)", name: "\(p.name) \(l.title)", layout: l.id,
                           bg1: p.bg1, bg2: p.bg2, accent: p.accent, ink: p.ink)
            })
        }
        return specStyles + classic
    }()

    static let all: [FaceDesign] = styles.flatMap(\.faces)
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Renderer (mirrors FaceDraw in BridgeFace.kt; units are fractions of the radius)

struct FaceRender: View {
    let design: FaceDesign
    var date: Date = FaceRender.sampleDate
    var showComplications = true

    static let sampleDate: Date = Calendar.current.date(bySettingHour: 10, minute: 9, second: 36, of: Date()) ?? Date()

    var body: some View {
        Canvas { ctx, size in
            if let spec = design.specID.flatMap(FaceSpecs.spec) {
                SpecPainter(spec: spec.json, pal: design.palette, date: date, showComplications: showComplications).draw(&ctx, size)
            } else {
                draw(&ctx, size)
            }
        }
            .clipShape(Circle())
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel(design.name)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = Color(hex: design.accent), ink = Color(hex: design.ink)
        let dim = ink.opacity(0.44), faint = ink.opacity(0.15)
        let cal = Calendar.current
        let h = cal.component(.hour, from: date), m = cal.component(.minute, from: date), s = Double(cal.component(.second, from: date))
        let minute = Double(m) + s / 60, hour = Double(h % 12) + minute / 60
        let h12 = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
        let hhmm = h12 ? String(format: "%d:%02d", (h + 11) % 12 + 1, m) : String(format: "%02d:%02d", h, m)
        let df = DateFormatter(); df.dateFormat = "EEE d"
        let dateText = df.string(from: date).uppercased()

        func pt(_ deg: Double, _ rad: Double) -> CGPoint {
            CGPoint(x: c.x + sin(deg * .pi / 180) * rad * r, y: c.y - cos(deg * .pi / 180) * rad * r)
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ w: Double, _ col: Color, round: Bool = true) {
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w * r, lineCap: round ? .round : .butt))
        }
        func tick(_ deg: Double, _ from: Double, _ to: Double, _ w: Double, _ col: Color, round: Bool = true) {
            line(pt(deg, from), pt(deg, to), w, col, round: round)
        }
        func hand(_ deg: Double, _ len: Double, _ w: Double, _ col: Color, tail: Double = 0, from: Double = 0) {
            line(pt(deg, from > 0 ? from : -tail), pt(deg, len), w, col)
        }
        func dot(_ deg: Double, _ at: Double, _ rad: Double, _ col: Color) {
            let p = pt(deg, at)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad * r, y: p.y - rad * r, width: 2 * rad * r, height: 2 * rad * r)), with: .color(col))
        }
        func ring(_ rad: Double, _ w: Double, _ col: Color) {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rad * r, y: c.y - rad * r, width: 2 * rad * r, height: 2 * rad * r)),
                       with: .color(col), lineWidth: w * r)
        }
        func arc(_ rad: Double, _ w: Double, _ sweep: Double, _ col: Color) {
            guard sweep > 0 else { return }
            var p = Path()
            p.addArc(center: c, radius: rad * r, startAngle: .degrees(-90), endAngle: .degrees(-90 + sweep), clockwise: false)
            ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: w * r, lineCap: .round))
        }
        func text(_ s: String, _ x: Double, _ y: Double, _ size: Double, _ col: Color) {
            ctx.draw(Text(s).font(.system(size: size * r, weight: .bold)).foregroundColor(col),
                     at: CGPoint(x: c.x + x * r, y: c.y + y * r), anchor: .center)
        }

        // Background
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .radialGradient(Gradient(colors: [Color(hex: design.bg1), Color(hex: design.bg2)]),
                                       center: c, startRadius: 0, endRadius: r))

        // Dial
        switch design.layout {
        case "classic":
            for i in 0..<60 {
                if i % 5 == 0 { tick(Double(i) * 6, 0.82, 0.95, 0.022, ink) } else { tick(Double(i) * 6, 0.90, 0.95, 0.008, dim) }
            }
            text("12", 0, -0.66, 0.20, accent)
        case "minimal":
            for i in 0..<12 { dot(Double(i) * 30, 0.88, i == 0 ? 0.04 : 0.025, i == 0 ? accent : dim) }
        case "bold":
            for i in 0..<12 { tick(Double(i) * 30, 0.74, 0.95, 0.07, i % 3 == 0 ? accent : ink, round: false) }
        case "digital":
            ring(0.93, 0.035, faint); arc(0.93, 0.035, s * 6, accent)
            text(dateText, 0, -0.70, 0.11, accent)
        case "ring":
            ring(0.90, 0.08, faint); arc(0.90, 0.08, minute * 6, accent)
            ring(0.76, 0.08, faint); arc(0.76, 0.08, hour * 30, ink)
        case "orbit":
            ring(0.90, 0.006, dim); ring(0.70, 0.006, dim)
            text(dateText, 0, -0.56, 0.10, dim)
        case "sport":
            for i in 0..<60 { tick(Double(i) * 6, 0.94, 0.99, 0.008, dim) }
            for i in 1...12 { let p = pt(Double(i) * 30, 0.84); text("\(i * 5)", (p.x - c.x) / r, (p.y - c.y) / r, 0.09, dim) }
            text(dateText, 0, -0.64, 0.09, accent)
        case "radar":
            for rr in [0.30, 0.55, 0.80] { ring(rr, 0.006, dim) }
            line(pt(0, 0.95), pt(180, 0.95), 0.004, dim); line(pt(270, 0.95), pt(90, 0.95), 0.004, dim)
            for i in 0..<12 { tick(Double(i) * 30, 0.84, 0.94, 0.015, ink) }
            for k in 0..<10 {
                var p = Path(); p.move(to: c)
                let start = s * 6 - 90 - Double(k + 1) * 6
                p.addArc(center: c, radius: 0.95 * r, startAngle: .degrees(start), endAngle: .degrees(start + 6.5), clockwise: false)
                p.closeSubpath()
                ctx.fill(p, with: .color(accent.opacity(0.35 * (1 - Double(k) / 10))))
            }
        default: break
        }

        // Sample complications (on the watch these are whatever the wearer picks)
        if showComplications {
            let samples: [(CGPoint, Double, String)] = [
                (CGPoint(x: c.x - 0.4 * r, y: c.y), 0.86, "86"), (CGPoint(x: c.x + 0.4 * r, y: c.y), 0.72, "72"),
                (CGPoint(x: c.x, y: c.y + 0.5 * r), 0.0, "6.2k"),
            ]
            for (p, v, label) in samples {
                if v > 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 0.15 * r, y: p.y - 0.15 * r, width: 0.3 * r, height: 0.3 * r)),
                               with: .color(faint), lineWidth: 0.025 * r)
                    var a = Path()
                    a.addArc(center: p, radius: 0.15 * r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * v), clockwise: false)
                    ctx.stroke(a, with: .color(accent), style: StrokeStyle(lineWidth: 0.025 * r, lineCap: .round))
                }
                ctx.draw(Text(label).font(.system(size: 0.10 * r, weight: .semibold)).foregroundColor(ink), at: p, anchor: .center)
            }
        }

        // Hands and time
        switch design.layout {
        case "classic":
            hand(hour * 30, 0.50, 0.07, ink); hand(minute * 6, 0.78, 0.045, ink)
            hand(s * 6, 0.86, 0.016, accent, tail: 0.18); dot(0, 0, 0.05, accent)
        case "minimal":
            hand(hour * 30, 0.48, 0.04, ink); hand(minute * 6, 0.80, 0.025, ink)
            hand(s * 6, 0.85, 0.01, accent); dot(0, 0, 0.03, accent)
        case "bold":
            hand(hour * 30, 0.52, 0.10, ink); hand(minute * 6, 0.82, 0.07, ink)
            hand(minute * 6, 0.82, 0.07, accent, from: 0.62); hand(s * 6, 0.88, 0.012, accent); dot(0, 0, 0.07, ink)
        case "digital": text(hhmm, 0, -0.36, 0.42, ink)
        case "ring": text(hhmm, 0, -0.40, 0.20, ink)
        case "orbit":
            text(hhmm, 0, -0.36, 0.18, ink)
            dot(hour * 30, 0.70, 0.07, accent); dot(minute * 6, 0.90, 0.05, ink); dot(s * 6, 0.90, 0.02, accent)
        case "sport":
            text(hhmm, 0, -0.36, 0.34, ink); tick(s * 6, 0.90, 0.99, 0.02, accent)
        case "radar":
            hand(hour * 30, 0.50, 0.05, ink); hand(minute * 6, 0.80, 0.03, ink); dot(0, 0, 0.04, accent)
        default: break
        }
    }
}

// MARK: - Gallery

struct FaceGalleryView: View {
    @EnvironmentObject var hub: FeatureHub
    @State private var query = ""
    @State private var selected: FaceDesign?

    private var styles: [FaceCatalog.Style] {
        query.isEmpty ? FaceCatalog.styles : FaceCatalog.styles.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.blurb.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let d = hub.design, let style = FaceCatalog.styles.first(where: { $0.id == d.style }) {
                    NavigationLink { FaceStyleView(style: style) } label: {
                        HStack(spacing: 14) {
                            FaceRender(design: d).frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("On your watch").font(.caption).foregroundStyle(Theme.accent2)
                                Text(d.name).font(.headline).foregroundStyle(.white)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(14).card(cornerRadius: 22)
                    }
                    .buttonStyle(PressScale())
                    .padding(.horizontal, 16)
                }
                SectionTitle(text: "\(styles.count) styles · \(FaceCatalog.all.count) faces").padding(.horizontal, 16)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                    ForEach(styles) { style in
                        NavigationLink { FaceStyleView(style: style) } label: {
                            VStack(spacing: 8) {
                                FaceRender(design: style.cover)
                                    .shadow(color: Color(hex: style.cover.accent).opacity(0.4), radius: 10)
                                Text(style.title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                                Text("\(style.faces.count) colours").font(.caption2).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(.horizontal, 16)
                Text("All free. Designed for Wear OS Bridge.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity).padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .auroraScreen()
        .navigationTitle("Face gallery")
        .searchable(text: $query, prompt: "Search styles")
        .task { hub.requestDesign() }
        .toast($hub.toast)
    }
}

/// Every colour of one style.
struct FaceStyleView: View {
    @EnvironmentObject var hub: FeatureHub
    let style: FaceCatalog.Style
    @State private var selected: FaceDesign?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(style.blurb).font(.subheadline).foregroundStyle(.white.opacity(0.65)).padding(.horizontal, 16)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                    ForEach(style.faces) { f in
                        Button { selected = f } label: {
                            VStack(spacing: 6) {
                                FaceRender(design: f)
                                    .overlay(Circle().strokeBorder(hub.design?.id == f.id ? Theme.accent2 : .white.opacity(0.12),
                                                                   lineWidth: hub.design?.id == f.id ? 3 : 1))
                                    .shadow(color: Color(hex: f.accent).opacity(0.35), radius: 8)
                                Text(f.name.replacingOccurrences(of: style.title + " ", with: ""))
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 10)
        }
        .auroraScreen()
        .navigationTitle(style.title)
        .sheet(item: $selected) { FaceDetailView(design: $0).presentationDetents([.large]) }
        .toast($hub.toast)
    }
}

struct FaceDetailView: View {
    @EnvironmentObject var hub: FeatureHub
    @EnvironmentObject var link: WatchLink
    @Environment(\.dismiss) private var dismiss
    let design: FaceDesign

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        FaceRender(design: design, date: ctx.date)
                    }
                    .frame(width: 270, height: 270)
                    .shadow(color: Color(hex: design.accent).opacity(0.5), radius: 30)
                    .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text(design.name).font(.title2.weight(.bold)).foregroundStyle(.white)
                        Text(FaceCatalog.styles.first { $0.id == design.style }?.blurb ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    }

                    Button {
                        hub.setDesign(design)
                        dismiss()
                    } label: {
                        Label(hub.design?.id == design.id && hub.designActive ? "On your watch" : "Set on watch",
                              systemImage: "applewatch.and.arrow.forward").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Color(hex: design.accent))
                    .foregroundStyle(Color(hex: design.bg2))
                    .disabled(link.status != .connected)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Complications: on the watch, press and hold the face → Customise.", systemImage: "circle.grid.3x3")
                        Label("Always-on display uses a dimmed, low-power version.", systemImage: "moon")
                        if !hub.designActive {
                            Label("First time only: choose the **Wear OS Bridge** face when your watch asks. After that, designs switch instantly.",
                                  systemImage: "hand.tap")
                        }
                    }
                    .font(.footnote).foregroundStyle(.white.opacity(0.75))
                    .padding(16).card()
                }
                .padding(20)
            }
            .auroraScreen()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
