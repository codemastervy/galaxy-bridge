import SwiftUI

/// Face designs described as element lists (faces/specs.json), drawn the same way as SpecDraw.kt
/// on the watch. Units are fractions of the face radius; angles are degrees clockwise from 12.
enum FaceSpecs {
    struct Spec {
        let id: String, name: String, blurb: String
        let json: [String: Any]
        let palettes: [FaceCatalog.Palette]
    }

    static let all: [Spec] = {
        guard let data = faceSpecsJSON.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let id = s["id"] as? String, let name = s["name"] as? String else { return nil }
            let own = (s["own"] as? [[String: String]] ?? []).compactMap { o -> FaceCatalog.Palette? in
                guard let pid = o["id"], let n = o["name"], let b1 = o["bg1"], let b2 = o["bg2"], let a = o["accent"], let i = o["ink"] else { return nil }
                return FaceCatalog.Palette(id: pid, name: n, bg1: b1, bg2: b2, accent: a, ink: i)
            }
            let pal: [FaceCatalog.Palette]
            switch s["pal"] as? String {
            case "own": pal = own
            case "own+all": pal = own + FaceCatalog.palettes
            default: pal = FaceCatalog.palettes
            }
            var body = s
            for k in ["id", "name", "blurb", "pal", "own"] { body.removeValue(forKey: k) }
            return Spec(id: id, name: name, blurb: s["blurb"] as? String ?? "", json: body, palettes: pal)
        }
    }()

    static func spec(_ id: String) -> Spec? { all.first { $0.id == id } }

    /// Complication centres and radii per arrangement; must match ARRANGEMENTS in BridgeFace.kt.
    static let slotPositions: [String: [String: (Double, Double, Double)]] = [
        "std": ["left": (-0.4, 0, 0.2), "right": (0.4, 0, 0.2), "bottom": (0, 0.5, 0.2)],
        "low": ["left": (-0.48, 0.3, 0.18), "right": (0.48, 0.3, 0.18), "bottom": (0, 0.64, 0.17)],
        "top": ["left": (-0.42, -0.42, 0.18), "right": (0.42, -0.42, 0.18), "bottom": (0, 0.58, 0.19)],
        "wide": ["left": (-0.56, 0, 0.17), "right": (0.56, 0, 0.17), "bottom": (0, 0.6, 0.18)],
    ]

    private static let hours = ["TWELVE", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN"]
    private static let mins = [5: "FIVE", 10: "TEN", 15: "QUARTER", 20: "TWENTY", 25: "TWENTY-FIVE", 30: "HALF"]

    /// Must match SpecDraw.words on the watch.
    static func words(_ h24: Int, _ m: Int) -> String {
        var m5 = ((m + 2) / 5) * 5
        var h = h24 % 12
        if m5 == 60 { m5 = 0; h = (h + 1) % 12 }
        if m5 == 0 { return "\(hours[h])\nO'CLOCK" }
        if m5 <= 30 { return "\(mins[m5]!)\nPAST\n\(hours[h])" }
        return "\(mins[60 - m5]!)\nTO\n\(hours[(h + 1) % 12])"
    }
}

/// Draws one spec into a SwiftUI Canvas context.
struct SpecPainter {
    let spec: [String: Any]
    let pal: FaceCatalog.Palette
    let date: Date
    var battery = 72
    var showComplications = true

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        var p = P(ctx: ctx, r: r, c: c, pal: pal, values: V(date: date, battery: battery))
        p.background(spec["bg"] as? [String: Any])
        let els = (spec["els"] as? [[String: Any]] ?? []).prefix(160)
        for e in els where !(e["t"] as? String == "hand" || e["top"] as? Bool == true) { p.element(e) }
        if showComplications { p.complications(spec) }
        for e in els where e["t"] as? String == "hand" || e["top"] as? Bool == true { p.element(e) }
        ctx = p.ctx
    }

    struct V {
        let hour24: Int, minuteInt: Int, sec: Double, min: Double, hour: Double, day: Int
        let wd: String, weekday: String, month: String, h24: Bool, battery: Int
        init(date: Date, battery: Int) {
            let cal = Calendar.current
            hour24 = cal.component(.hour, from: date); minuteInt = cal.component(.minute, from: date)
            sec = Double(cal.component(.second, from: date)); min = Double(minuteInt) + sec / 60
            hour = Double(hour24 % 12) + min / 60; day = cal.component(.day, from: date)
            let f = DateFormatter()
            f.dateFormat = "EEE"; wd = String(f.string(from: date).uppercased().prefix(3))
            f.dateFormat = "EEEE"; weekday = f.string(from: date).uppercased()
            f.dateFormat = "MMM"; month = String(f.string(from: date).uppercased().prefix(3))
            h24 = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false)
            self.battery = battery
        }
    }

    struct P {
        var ctx: GraphicsContext
        let r: Double, c: CGPoint, pal: FaceCatalog.Palette, values: V

        func num(_ e: [String: Any], _ k: String, _ def: Double, _ lo: Double = -3, _ hi: Double = 3) -> Double {
            guard let n = e[k] as? NSNumber else { return def }
            return min(max(n.doubleValue, lo), hi)
        }
        func str(_ e: [String: Any], _ k: String, _ def: String = "") -> String { String((e[k] as? String ?? def).prefix(40)) }

        func col(_ name: String?, _ alpha: Double = 1) -> Color {
            let base: Color
            switch name ?? "ink" {
            case "", "ink": base = Color(hex: pal.ink)
            case "accent": base = Color(hex: pal.accent)
            case "dim": base = Color(hex: pal.ink).opacity(0.44)
            case "faint": base = Color(hex: pal.ink).opacity(0.15)
            case "bg1": base = Color(hex: pal.bg1)
            case "bg2": base = Color(hex: pal.bg2)
            case "black": base = .black
            case "white": base = .white
            case let s where s.count == 9 && s.hasPrefix("#"):
                let v = UInt64(s.dropFirst(), radix: 16) ?? 0xFFFFFFFF
                base = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                             blue: Double(v & 0xFF) / 255).opacity(Double((v >> 24) & 0xFF) / 255)
            case let s where s.count == 7 && s.hasPrefix("#"): base = Color(hex: s)
            default: base = Color(hex: pal.ink)
            }
            return alpha >= 1 ? base : base.opacity(alpha)
        }
        func ec(_ e: [String: Any], _ k: String = "c", _ def: String = "ink") -> Color {
            col((e[k] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? def, num(e, "a", 1, 0, 1))
        }

        func frac(_ name: String) -> Double {
            switch name {
            case "hour": return values.hour / 12
            case "minute": return values.min / 60
            case "second": return values.sec / 60
            case "battery": return Double(values.battery) / 100
            case "day24": return (Double(values.hour24) + values.min / 60) / 24
            case "month": return Double(values.day) / 31
            default: return 1
            }
        }
        var h12: Int { (values.hour24 + 11) % 12 + 1 }
        func text(_ name: String, _ e: [String: Any]) -> String {
            switch name {
            case "time": return values.h24 ? String(format: "%02d:%02d", values.hour24, values.minuteInt) : String(format: "%d:%02d", h12, values.minuteInt)
            case "time0": return String(format: "%02d:%02d", values.h24 ? values.hour24 : h12, values.minuteInt)
            case "hh": return values.h24 ? String(format: "%02d", values.hour24) : "\(h12)"
            case "h": return values.h24 ? "\(values.hour24)" : "\(h12)"
            case "mm": return String(format: "%02d", values.minuteInt)
            case "ss": return String(format: "%02d", Int(values.sec))
            case "date": return "\(values.wd) \(values.day)"
            case "wd": return values.wd
            case "weekday": return values.weekday
            case "day": return "\(values.day)"
            case "dd": return String(format: "%02d", values.day)
            case "month": return values.month
            case "ampm": return values.hour24 < 12 ? "AM" : "PM"
            case "battery": return "\(values.battery)%"
            case "words": return FaceSpecs.words(values.hour24, values.minuteInt)
            default: return str(e, "text")
            }
        }

        func pt(_ deg: Double, _ rad: Double) -> CGPoint {
            CGPoint(x: c.x + sin(deg * .pi / 180) * rad * r, y: c.y - cos(deg * .pi / 180) * rad * r)
        }
        func at(_ e: [String: Any]) -> CGPoint { CGPoint(x: c.x + num(e, "x", 0) * r, y: c.y + num(e, "y", 0) * r) }
        func style(_ w: Double, _ cap: String = "round") -> StrokeStyle {
            StrokeStyle(lineWidth: w * r, lineCap: cap == "butt" ? .butt : .round, lineJoin: .round)
        }

        func font(_ name: String, _ size: Double) -> Font {
            switch name {
            case "black": return .system(size: size, weight: .black)
            case "light": return .system(size: size, weight: .light)
            case "thin": return .system(size: size, weight: .thin)
            case "medium": return .system(size: size, weight: .medium)
            case "rounded": return .system(size: size, weight: .semibold, design: .rounded)
            case "condensed": return .system(size: size, weight: .bold).width(.condensed)
            case "mono": return .system(size: size, weight: .bold, design: .monospaced)
            case "serif": return .system(size: size, weight: .regular, design: .serif)
            case "serifbold": return .system(size: size, weight: .bold, design: .serif)
            default: return .system(size: size, weight: .bold)
            }
        }

        mutating func background(_ bg: [String: Any]?) {
            let b = bg ?? [:]
            let c1 = col(b["c1"] as? String ?? "bg1"), c2 = col(b["c2"] as? String ?? "bg2")
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            switch b["style"] as? String ?? "radial" {
            case "solid": ctx.fill(disc, with: .color(c1))
            case "linear":
                let a = num(b, "angle", 180, -360, 360)
                ctx.fill(disc, with: .linearGradient(Gradient(colors: [c1, c2]), startPoint: pt(a + 180, 1), endPoint: pt(a, 1)))
            default:
                ctx.fill(disc, with: .radialGradient(Gradient(colors: [c1, c2]), center: at(b), startRadius: 0, endRadius: r * num(b, "r", 1, 0.1, 3)))
            }
        }

        mutating func element(_ e: [String: Any]) {
            switch e["t"] as? String {
            case "ticks": ticks(e)
            case "nums": nums(e)
            case "hand": hand(e)
            case "text":
                var s = text(str(e, "v", "custom"), e)
                switch e["case"] as? String { case "lower": s = s.lowercased(); case "upper": s = s.uppercased(); default: break }
                drawText(s, at(e), num(e, "size", 0.2, 0, 2), ec(e), e, align: str(e, "align", "center"))
            case "arc": arc(e)
            case "ring":
                let rad = num(e, "r", 0.9, 0) * r, o = at(e)
                ctx.stroke(Path(ellipseIn: CGRect(x: o.x - rad, y: o.y - rad, width: 2 * rad, height: 2 * rad)), with: .color(ec(e)), lineWidth: num(e, "w", 0.01, 0, 1) * r)
            case "disc": disc(e)
            case "rect": rect(e)
            case "dot":
                let a = frac(str(e, "v", "hour")) * 360, p = pt(a, num(e, "r", 0.8)), s = num(e, "size", 0.04, 0, 1) * r
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: 2 * s, height: 2 * s)), with: .color(ec(e, "c", "accent")))
            case "sweep": sweep(e)
            case "rays": rays(e)
            case "marker": marker(e)
            case "line":
                var path = Path()
                path.move(to: CGPoint(x: c.x + num(e, "x1", 0) * r, y: c.y + num(e, "y1", 0) * r))
                path.addLine(to: CGPoint(x: c.x + num(e, "x2", 0) * r, y: c.y + num(e, "y2", 0) * r))
                ctx.stroke(path, with: .color(ec(e)), style: style(num(e, "w", 0.01, 0, 1), str(e, "cap", "round")))
            case "binary": binary(e)
            default: break
            }
        }

        /// Elements with "win" only draw within that many degrees either side of 12 o'clock.
        func outside(_ e: [String: Any], _ a: Double) -> Bool {
            let win = num(e, "win", 0, 0, 180)
            guard win > 0 else { return false }
            let norm = (a.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
            return abs(norm) > win
        }

        func offset(_ e: [String: Any]) -> Double {
            switch e["rotate"] as? String { case "hour": return -frac("hour") * 360; case "minute": return -frac("minute") * 360; default: return 0 }
        }

        mutating func ticks(_ e: [String: Any]) {
            let n = Int(num(e, "n", 60, 1, 120)), skip = Set(e["skip"] as? [Int] ?? [])
            let every = Int(num(e, "every", 0, 0, 120)), off = offset(e)
            let lit = e["lit"] as? String
            let litCount = lit.map { Int(floor(frac($0) * Double(n))) } ?? -1
            for i in 0..<n where !skip.contains(i) {
                let major = every > 0 && i % every == 0
                let r1 = num(e, major ? "r1b" : "r1", 0.9), r2 = num(e, major ? "r2b" : "r2", 0.95)
                let w = num(e, major ? "wb" : "w", 0.01, 0, 1)
                var color = major ? ec(e, "cb", e["c"] as? String ?? "ink") : ec(e)
                if litCount >= 0 && i <= litCount { color = col(e["lc"] as? String ?? "accent") }
                let a = Double(i) * 360 / Double(n) + off
                if outside(e, a) { continue }
                if str(e, "shape", "line") == "dot" {
                    let p = pt(a, r2), s = w / 2 * r
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: 2 * s, height: 2 * s)), with: .color(color))
                } else {
                    var path = Path(); path.move(to: pt(a, r1)); path.addLine(to: pt(a, r2))
                    ctx.stroke(path, with: .color(color), style: style(w, str(e, "cap", "butt")))
                }
            }
        }

        mutating func nums(_ e: [String: Any]) {
            let labels = e["labels"] as? [String]
            let n = labels.map { min(max($0.count, 1), 60) } ?? Int(num(e, "n", 12, 1, 60))
            let skip = Set(e["skip"] as? [Int] ?? []), off = offset(e)
            let rad = num(e, "r", 0.78), size = num(e, "size", 0.16, 0, 2)
            let cur = e["hl"] as? String == "hour" ? values.hour24 % 12 : -1
            for i in 0..<n where !skip.contains(i) {
                let label = labels.map { String($0[i].prefix(8)) } ?? (n == 12 ? "\(i == 0 ? 12 : i)" : "\(i)")
                let a = Double(i) * 360 / Double(n) + off
                if outside(e, a) { continue }
                let isCur = i == cur && n == 12
                let s = isCur ? size * num(e, "hs", 1.3, 0, 4) : size
                let color = isCur ? col(e["hc"] as? String ?? "accent") : ec(e)
                let p = pt(a, rad)
                if e["orient"] as? String == "radial" {
                    var g = ctx
                    g.translateBy(x: p.x, y: p.y); g.rotate(by: .degrees(a))
                    P.text(&g, label, .zero, s * r, color, e, font(str(e, "font", "bold"), s * r), align: "center", track: num(e, "track", 0, -0.5, 2), glow: 0, lh: 1.05)
                } else {
                    drawText(label, p, s, color, e)
                }
            }
        }

        mutating func drawText(_ s: String, _ p: CGPoint, _ size: Double, _ color: Color, _ e: [String: Any], align: String = "center") {
            P.text(&ctx, s, p, size * r, color, e, font(str(e, "font", "bold"), size * r), align: align,
                   track: num(e, "track", 0, -0.5, 2), glow: num(e, "glow", 0, 0, 0.5) * r, lh: num(e, "lh", 1.05, 0.5, 3))
        }

        static func text(_ ctx: inout GraphicsContext, _ s: String, _ p: CGPoint, _ px: Double, _ color: Color, _ e: [String: Any],
                         _ font: Font, align: String, track: Double, glow: Double, lh: Double) {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
            let step = px * lh
            var g = ctx
            if glow > 0 { g.addFilter(.shadow(color: color, radius: glow / 2)) }
            for (i, line) in lines.enumerated() {
                let y = p.y + (Double(i) - Double(lines.count - 1) / 2) * step
                let anchor: UnitPoint = align == "left" ? .leading : align == "right" ? .trailing : .center
                g.draw(Text(String(line)).font(font).tracking(track * px).foregroundColor(color), at: CGPoint(x: p.x, y: y), anchor: anchor)
            }
        }

        mutating func hand(_ e: [String: Any]) {
            let a = frac(str(e, "v", "hour")) * 360
            let len = num(e, "len", 0.6, 0, 1.5) * r, w = num(e, "w", 0.04, 0, 1) * r, tail = num(e, "tail", 0, 0, 1) * r
            let color = ec(e)
            var g = ctx
            g.translateBy(x: c.x, y: c.y); g.rotate(by: .degrees(a))
            let tip = -len
            switch e["style"] as? String {
            case "taper", "outline":
                var path = Path()
                path.move(to: CGPoint(x: -w / 2, y: tail)); path.addLine(to: CGPoint(x: -w * 0.15, y: tip))
                path.addLine(to: CGPoint(x: w * 0.15, y: tip)); path.addLine(to: CGPoint(x: w / 2, y: tail)); path.closeSubpath()
                if e["style"] as? String == "outline" { g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 0.012 * r, lineJoin: .round)) }
                else { g.fill(path, with: .color(color)) }
            case "sword":
                var path = Path()
                path.move(to: CGPoint(x: 0, y: tail)); path.addLine(to: CGPoint(x: -w / 2, y: -len * 0.25))
                path.addLine(to: CGPoint(x: 0, y: tip)); path.addLine(to: CGPoint(x: w / 2, y: -len * 0.25)); path.closeSubpath()
                g.fill(path, with: .color(color))
            case "lollipop":
                var path = Path(); path.move(to: CGPoint(x: 0, y: tail)); path.addLine(to: CGPoint(x: 0, y: tip + w * 1.6))
                g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * 0.5, lineCap: .round))
                g.fill(Path(ellipseIn: CGRect(x: -w * 1.6, y: tip, width: w * 3.2, height: w * 3.2)), with: .color(color))
            case "arrow":
                var path = Path(); path.move(to: CGPoint(x: 0, y: tail)); path.addLine(to: CGPoint(x: 0, y: tip + len * 0.18))
                g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
                var head = Path()
                head.move(to: CGPoint(x: -w * 1.8, y: tip + len * 0.2)); head.addLine(to: CGPoint(x: 0, y: tip))
                head.addLine(to: CGPoint(x: w * 1.8, y: tip + len * 0.2)); head.closeSubpath()
                g.fill(head, with: .color(color))
            default:
                var path = Path(); path.move(to: CGPoint(x: 0, y: tail)); path.addLine(to: CGPoint(x: 0, y: tip))
                g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: e["style"] as? String == "butt" ? .butt : .round))
            }
            if let t = e["tip"] as? String, !t.isEmpty {
                var path = Path(); path.move(to: CGPoint(x: 0, y: tip + len * num(e, "tiplen", 0.25, 0, 1))); path.addLine(to: CGPoint(x: 0, y: tip))
                g.stroke(path, with: .color(col(t)), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }

        mutating func arc(_ e: [String: Any]) {
            let rad = num(e, "r", 0.9, 0) * r, w = num(e, "w", 0.04, 0, 1)
            let start = num(e, "start", 0, -720, 720), span = num(e, "span", 360, -360, 360)
            let o = at(e), cap = str(e, "cap", "round")
            func path(_ sweep: Double) -> Path {
                var p = Path()
                p.addArc(center: o, radius: rad, startAngle: .degrees(start - 90), endAngle: .degrees(start - 90 + sweep), clockwise: sweep < 0)
                return p
            }
            if let t = e["track"] as? String, !t.isEmpty { ctx.stroke(path(span), with: .color(col(t)), style: style(w, cap)) }
            let sweep = span * frac(str(e, "v", "full"))
            if sweep != 0 { ctx.stroke(path(sweep), with: .color(ec(e, "c", "accent")), style: style(w, cap)) }
        }

        mutating func disc(_ e: [String: Any]) {
            let o = at(e), rad = num(e, "r", 0.1, 0) * r
            let rect = CGRect(x: o.x - rad, y: o.y - rad, width: 2 * rad, height: 2 * rad)
            if e["c"] != nil {
                if let c2 = e["c2"] as? String, !c2.isEmpty {
                    ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [ec(e), col(c2)]),
                             center: CGPoint(x: o.x, y: o.y - rad * 0.3), startRadius: 0, endRadius: rad * 1.2))
                } else { ctx.fill(Path(ellipseIn: rect), with: .color(ec(e))) }
            }
            if let sc = e["sc"] as? String, !sc.isEmpty { ctx.stroke(Path(ellipseIn: rect), with: .color(col(sc)), lineWidth: num(e, "sw", 0.01, 0, 1) * r) }
        }

        mutating func rect(_ e: [String: Any]) {
            let o = at(e), w = num(e, "w", 0.3, 0) * r, h = num(e, "h", 0.2, 0) * r, rad = num(e, "rad", 0.05, 0) * r
            let path = Path(roundedRect: CGRect(x: o.x - w / 2, y: o.y - h / 2, width: w, height: h), cornerRadius: rad)
            if e["c"] != nil { ctx.fill(path, with: .color(ec(e))) }
            if let sc = e["sc"] as? String, !sc.isEmpty { ctx.stroke(path, with: .color(col(sc, num(e, "a", 1, 0, 1))), lineWidth: num(e, "sw", 0.01, 0, 1) * r) }
        }

        mutating func sweep(_ e: [String: Any]) {
            let a = frac(str(e, "v", "second")) * 360, rad = num(e, "r", 0.95, 0) * r
            let span = num(e, "span", 60, 0, 360), alpha = num(e, "alpha", 0.35, 0, 1)
            for k in 0..<12 {
                var p = Path(); p.move(to: c)
                let s = a - 90 - Double(k + 1) * span / 12
                p.addArc(center: c, radius: rad, startAngle: .degrees(s), endAngle: .degrees(s + span / 12 + 0.5), clockwise: false)
                p.closeSubpath()
                ctx.fill(p, with: .color(col(e["c"] as? String ?? "accent", alpha * (1 - Double(k) / 12))))
            }
        }

        mutating func rays(_ e: [String: Any]) {
            let n = Int(num(e, "n", 24, 2, 120)), rad = num(e, "r", 1.2, 0) * r
            var p = Path()
            for i in stride(from: 0, to: n, by: 2) {
                p.move(to: c)
                let s = Double(i) * 360 / Double(n) - 90
                p.addArc(center: c, radius: rad, startAngle: .degrees(s), endAngle: .degrees(s + 360 / Double(n)), clockwise: false)
                p.closeSubpath()
            }
            ctx.fill(p, with: .color(ec(e)))
        }

        mutating func marker(_ e: [String: Any]) {
            let a = num(e, "a", 0, -720, 720) + ((e["v"] as? String).map { frac($0) * 360 } ?? 0)
            let p = pt(a, num(e, "r", 0.9)), s = num(e, "size", 0.06, 0, 1) * r
            var g = ctx
            g.translateBy(x: p.x, y: p.y); g.rotate(by: .degrees(a))
            var path = Path()
            switch e["shape"] as? String {
            case "dia": path.move(to: CGPoint(x: 0, y: -s)); path.addLine(to: CGPoint(x: s * 0.6, y: 0)); path.addLine(to: CGPoint(x: 0, y: s)); path.addLine(to: CGPoint(x: -s * 0.6, y: 0)); path.closeSubpath()
            case "bar": path = Path(roundedRect: CGRect(x: -s * 0.25, y: -s, width: s * 0.5, height: 2 * s), cornerRadius: s * 0.2)
            case "circle": path = Path(ellipseIn: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
            default: path.move(to: CGPoint(x: -s * 0.6, y: -s * 0.5)); path.addLine(to: CGPoint(x: s * 0.6, y: -s * 0.5)); path.addLine(to: CGPoint(x: 0, y: s * 0.5)); path.closeSubpath()
            }
            g.fill(path, with: .color(ec(e, "c", "accent")))
        }

        mutating func binary(_ e: [String: Any]) {
            let value: Int
            switch e["v"] as? String { case "minute": value = values.minuteInt; case "second": value = Int(values.sec); default: value = values.hour24 }
            let bits = Int(num(e, "n", 6, 1, 8)), s = num(e, "size", 0.05, 0, 1) * r, gap = num(e, "gap", 0.14, 0, 1) * r
            let x0 = c.x + num(e, "x", 0) * r - Double(bits - 1) * gap / 2, y = c.y + num(e, "y", 0) * r
            for b in 0..<bits {
                let on = (value >> (bits - 1 - b)) & 1 == 1
                let x = x0 + Double(b) * gap
                ctx.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s)),
                         with: .color(on ? ec(e, "c", "accent") : col(e["c2"] as? String ?? "faint")))
            }
        }

        /// Sample complications, where the watch will draw the real ones.
        mutating func complications(_ spec: [String: Any]) {
            let shown = Set(spec["slots"] as? [String] ?? ["left", "right", "bottom"])
            let pos = FaceSpecs.slotPositions[spec["slotpos"] as? String ?? "std"] ?? FaceSpecs.slotPositions["std"]!
            let samples = ["left": (0.86, "86"), "right": (0.72, "72"), "bottom": (0.0, "6.2k")]
            for name in ["left", "right", "bottom"] where shown.contains(name) {
                guard let (x, y, rr) = pos[name], let (v, label) = samples[name] else { continue }
                let p = CGPoint(x: c.x + x * r, y: c.y + y * r), rad = rr * 0.75 * r
                if v > 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2 * rad, height: 2 * rad)), with: .color(col("faint")), lineWidth: 0.025 * r)
                    var a = Path()
                    a.addArc(center: p, radius: rad, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * v), clockwise: false)
                    ctx.stroke(a, with: .color(col("accent")), style: StrokeStyle(lineWidth: 0.025 * r, lineCap: .round))
                }
                ctx.draw(Text(label).font(.system(size: 0.1 * r, weight: .semibold)).foregroundColor(col("ink")), at: p, anchor: .center)
            }
        }
    }
}
