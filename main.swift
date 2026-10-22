// Uso de Claude — widget flotante para macOS
// Muestra el consumo de la sesión (5 h) y semanal de tu plan de Claude.
// Origen de datos: credenciales de Claude Code (Llavero) o, opcionalmente, la cookie sessionKey de claude.ai.

import AppKit
import SwiftUI
import Security

// MARK: - Modelo de datos

struct UsageRow: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    let window: TimeInterval
}

enum UsageError: LocalizedError, Equatable {
    case noCredentials, unauthorized, http(Int), badData, noOrg

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No encuentro credenciales. Inicia sesión en Claude Code o añade tu sessionKey (clic derecho)."
        case .unauthorized: return "Sesión caducada. Abre Claude Code para renovarla o actualiza la sessionKey."
        case .http(let code): return "El servidor respondió con un error \(code)."
        case .badData: return "Respuesta inesperada del servidor."
        case .noOrg: return "No encuentro tu organización en claude.ai."
        }
    }
}

// MARK: - Llavero (sessionKey propia del widget)

enum KeychainStore {
    static let service = "info.jorgemora.claudeusage"
    static let account = "sessionKey"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static func save(_ value: String) {
        delete()
        var q = baseQuery
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Credenciales de Claude Code

enum ClaudeCodeCredentials {
    static func accessToken() -> String? {
        if let raw = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           let token = extract(raw) {
            return token
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let s = String(data: data, encoding: .utf8),
           let token = extract(s) {
            return token
        }
        return nil
    }

    private static func extract(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - API

enum UsageAPI {
    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let windows: [(key: String, label: String, span: TimeInterval)] = [
        ("five_hour", "Sesión (5 h)", 5 * 3600),
        ("seven_day", "Semana · todos los modelos", 7 * 86400),
        ("seven_day_opus", "Semana · Opus", 7 * 86400),
        ("seven_day_sonnet", "Semana · Sonnet", 7 * 86400),
    ]

    static func get(_ url: URL, headers: [String: String], completion: @escaping (Result<Data, Error>) -> Void) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return completion(.failure(UsageError.unauthorized)) }
            guard (200..<300).contains(code), let data = data else { return completion(.failure(UsageError.http(code))) }
            completion(.success(data))
        }.resume()
    }

    static func viaClaudeCode(_ completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        guard let token = ClaudeCodeCredentials.accessToken() else {
            return completion(.failure(UsageError.noCredentials))
        }
        let headers = ["Authorization": "Bearer \(token)",
                       "anthropic-beta": "oauth-2025-04-20",
                       "Accept": "application/json"]
        get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: headers) { r in
            completion(r.flatMap { d in Result { try parse(d) } })
        }
    }

    static func viaWeb(key: String, _ completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        let headers = ["Cookie": "sessionKey=\(key)",
                       "User-Agent": browserUA,
                       "Accept": "application/json"]

        let fetchUsage: (String) -> Void = { org in
            get(URL(string: "https://claude.ai/api/organizations/\(org)/usage")!, headers: headers) { r in
                if case .failure(let e) = r, (e as? UsageError) == .unauthorized {
                    UserDefaults.standard.removeObject(forKey: "orgId")
                }
                completion(r.flatMap { d in Result { try parse(d) } })
            }
        }

        if let org = UserDefaults.standard.string(forKey: "orgId") {
            return fetchUsage(org)
        }

        get(URL(string: "https://claude.ai/api/organizations")!, headers: headers) { r in
            switch r {
            case .failure(let e):
                completion(.failure(e))
            case .success(let d):
                guard let orgs = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else {
                    return completion(.failure(UsageError.noOrg))
                }
                let pick = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? orgs.first
                guard let id = pick?["uuid"] as? String else { return completion(.failure(UsageError.noOrg)) }
                UserDefaults.standard.set(id, forKey: "orgId")
                fetchUsage(id)
            }
        }
    }

    static func parse(_ data: Data) throws -> [UsageRow] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badData
        }
        let rows = windows.compactMap { w -> UsageRow? in
            guard let d = obj[w.key] as? [String: Any],
                  let u = (d["utilization"] as? NSNumber)?.doubleValue else { return nil }
            // Las ventanas por modelo solo se muestran si tienen consumo
            if w.key != "five_hour" && w.key != "seven_day" && u <= 0 { return nil }
            return UsageRow(id: w.key, label: w.label, percent: u,
                            resetsAt: parseDate(d["resets_at"] as? String), window: w.span)
        }
        if rows.isEmpty { throw UsageError.badData }
        return rows
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return f.date(from: stripped)
    }
}

// MARK: - Actualización automática desde GitHub

enum Updater {
    static let repo = "jorgemoraz/claude-usage-widget"

    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsage")
    }

    static func read(_ name: String) -> String? {
        (try? String(contentsOf: support.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var installed: String? { read("version") }

    static func latest(_ completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/commits/main")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsageWidget", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  sha.count == 40 else { return completion(nil) }
            completion(sha)
        }.resume()
    }

    /// Lanza el instalador en su propia sesión para que sobreviva al reinicio del widget.
    static func install(_ sha: String) -> Bool {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeUsage-update.log").path
        let cmd = "curl -fsSL https://raw.githubusercontent.com/\(repo)/\(sha)/instalar.sh | /bin/bash -s -- --auto \(sha) >> '\(log)' 2>&1"
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(0x0400)) // POSIX_SPAWN_SETSID
        defer { posix_spawnattr_destroy(&attr) }
        var args: [UnsafeMutablePointer<CChar>?] = ["/bin/bash", "-c", cmd].map { strdup($0) }
        args.append(nil)
        defer { args.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/bash", nil, &attr, args, environ) == 0
    }
}

// MARK: - Estado

final class UsageModel: ObservableObject {
    @Published var rows: [UsageRow] = []
    @Published var error: String?
    @Published var loading = false
    @Published var lastUpdate: Date?
    @Published var source = ""
    @Published var celebrateUntil: Date = .distantPast
    @Published var updating = false
    let version = Updater.installed.map { String($0.prefix(7)) } ?? "local"
    @Published var alwaysOnTop: Bool = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            onLevelChange?()
        }
    }

    var onChange: (() -> Void)?
    var onLevelChange: (() -> Void)?
    private var timer: Timer?
    private var updateTimer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkForUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    func checkForUpdate() {
        guard !updating, Updater.installed != nil else { return }
        Updater.latest { sha in
            DispatchQueue.main.async {
                guard let sha = sha, sha != Updater.installed, sha != Updater.read("failed") else { return }
                if Updater.install(sha) {
                    self.updating = true
                    // Si el instalador falla, se vuelve al estado normal al cabo de un rato
                    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { self.updating = false }
                }
            }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            if let key = KeychainStore.read() {
                UsageAPI.viaWeb(key: key) { r in
                    if case .success = r { return self.finish(r, "claude.ai") }
                    UsageAPI.viaClaudeCode { r2 in
                        if case .success = r2 { self.finish(r2, "Claude Code") } else { self.finish(r, "claude.ai") }
                    }
                }
            } else {
                UsageAPI.viaClaudeCode { self.finish($0, "Claude Code") }
            }
        }
    }

    private func finish(_ r: Result<[UsageRow], Error>, _ src: String) {
        DispatchQueue.main.async {
            self.loading = false
            switch r {
            case .success(let rows):
                // Si el uso de la sesión cae de golpe, es que se ha reiniciado: toca fiesta
                if let old = self.rows.first(where: { $0.id == "five_hour" })?.percent,
                   let new = rows.first(where: { $0.id == "five_hour" })?.percent,
                   old - new >= 15 {
                    self.celebrateUntil = Date().addingTimeInterval(6)
                }
                self.rows = rows
                self.error = nil
                self.lastUpdate = Date()
                self.source = src
            case .failure(let e):
                self.error = e.localizedDescription
            }
            self.onChange?()
        }
    }
}

// MARK: - Vistas

func usageColor(_ p: Double) -> Color {
    if p < 60 { return Color(red: 0.36, green: 0.80, blue: 0.50) }
    if p < 85 { return Color(red: 1.00, green: 0.68, blue: 0.26) }
    return Color(red: 1.00, green: 0.38, blue: 0.35)
}

func hourText(_ date: Date, now: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_ES")
    f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "H.mm" : "EEE H.mm"
    return f.string(from: date)
}

func resetText(_ date: Date, now: Date) -> String {
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "Reiniciándose…" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    let rel = d > 0 ? "\(d) d \(h) h" : (h > 0 ? "\(h) h \(m) min" : "\(max(m, 1)) min")
    return "Se reinicia en \(rel) · \(hourText(date, now: now))"
}

func agoText(_ date: Date, now: Date) -> String {
    let m = Int(now.timeIntervalSince(date)) / 60
    return m < 1 ? "ahora" : "hace \(m) min"
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: Estado de ánimo

enum Mood: Equatable {
    case feliz, tranquilo, preocupado, panico, agotado, confuso

    static func from(_ p: Double?) -> Mood {
        guard let p = p else { return .confuso }
        if p >= 100 { return .agotado }
        if p >= 90 { return .panico }
        if p >= 70 { return .preocupado }
        if p >= 40 { return .tranquilo }
        return .feliz
    }

    var phrases: [String] {
        switch self {
        case .feliz: return ["A tope de energía", "Pídeme lo que quieras", "Fresco como una lechuga"]
        case .tranquilo: return ["Vamos bien", "Ritmo de crucero", "Aún queda gasolina"]
        case .preocupado: return ["Ojo, que se acaba", "Dosifícame un poco", "Esto baja rápido"]
        case .panico: return ["¡Últimas gotas!", "¡Que me apago!", "Solo para lo importante"]
        case .agotado: return ["Fuera de combate", "Zzz… vuelvo pronto"]
        case .confuso: return ["No encuentro tus datos"]
        }
    }

    var tint: Color {
        switch self {
        case .feliz: return Color(red: 0.36, green: 0.80, blue: 0.50)
        case .tranquilo: return Color(red: 0.45, green: 0.70, blue: 0.95)
        case .preocupado: return Color(red: 1.00, green: 0.68, blue: 0.26)
        case .panico: return Color(red: 1.00, green: 0.38, blue: 0.35)
        case .agotado: return Color(red: 0.55, green: 0.55, blue: 0.62)
        case .confuso: return Color(red: 0.70, green: 0.60, blue: 0.90)
        }
    }
}

// MARK: Mascota (personaje original dibujado a mano)

struct Mascot: View {
    let mood: Mood
    let accent: Color
    let celebrating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .frame(width: 64, height: 64)
    }

    let ink = Color(red: 0.16, green: 0.10, blue: 0.09)

    func drop(_ x: Double, _ y: Double) -> Path {
        Path { p in
            p.move(to: CGPoint(x: x, y: y - 3.5))
            p.addCurve(to: CGPoint(x: x, y: y + 2.5), control1: CGPoint(x: x + 3.2, y: y), control2: CGPoint(x: x + 2.6, y: y + 2.5))
            p.addCurve(to: CGPoint(x: x, y: y - 3.5), control1: CGPoint(x: x - 2.6, y: y + 2.5), control2: CGPoint(x: x - 3.2, y: y))
        }
    }

    func draw(_ base: GraphicsContext, _ size: CGSize, _ t: Double) {
        var root = base
        root.scaleBy(x: size.width / 64, y: size.height / 64)

        // Movimiento según el ánimo
        var dx = 0.0, dy = 0.0, tilt = 0.0
        switch mood {
        case .feliz: dy = -abs(sin(t * 2.6)) * 3
        case .tranquilo: dy = sin(t * 1.6) * 1.2
        case .preocupado: dy = sin(t * 2.2) * 1; dx = sin(t * 1.1) * 0.8
        case .panico: dx = sin(t * 38) * 1.3; dy = sin(t * 29) * 0.6
        case .agotado: dy = 1.5 + sin(t * 0.9) * 0.6
        case .confuso: tilt = sin(t * 1.2) * 0.1
        }
        if celebrating { dy = -abs(sin(t * 6)) * 7; tilt = sin(t * 6) * 0.08 }

        // Sombra en el suelo
        let shadowW = 30 + dy * 1.2
        root.fill(Path(ellipseIn: CGRect(x: 32 - shadowW / 2, y: 58, width: shadowW, height: 4)),
                  with: .color(.black.opacity(0.25)))

        var ctx = root
        ctx.translateBy(x: dx, y: dy)
        ctx.translateBy(x: 32, y: 40); ctx.rotate(by: .radians(tilt)); ctx.translateBy(x: -32, y: -40)

        let tired = mood == .agotado
        let bodyTop = tired ? Color(red: 0.66, green: 0.58, blue: 0.56) : Color(red: 0.93, green: 0.58, blue: 0.44)
        let bodyBottom = tired ? Color(red: 0.50, green: 0.44, blue: 0.43) : Color(red: 0.80, green: 0.40, blue: 0.29)

        // Pies
        let footLift = mood == .feliz || celebrating ? abs(sin(t * 5.2)) * 1.2 : 0
        ctx.fill(Path(ellipseIn: CGRect(x: 17, y: 50 - footLift, width: 10, height: 6)), with: .color(bodyBottom))
        ctx.fill(Path(ellipseIn: CGRect(x: 37, y: 50, width: 10, height: 6)), with: .color(bodyBottom))

        // Antena con lucecita del color del consumo
        let tipX = 32 + sin(t * 2) * 2.2
        var antenna = Path()
        antenna.move(to: CGPoint(x: 32, y: 17))
        antenna.addQuadCurve(to: CGPoint(x: tipX, y: 6.5), control: CGPoint(x: 29.5, y: 11))
        ctx.stroke(antenna, with: .color(bodyBottom), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let ballColor = tired ? Color.gray : accent
        if !tired {
            let glow = 5 + sin(t * 4) * 1.2
            ctx.fill(Path(ellipseIn: CGRect(x: tipX - glow, y: 6.5 - glow, width: glow * 2, height: glow * 2)),
                     with: .color(accent.opacity(0.28)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: tipX - 3.2, y: 3.3, width: 6.4, height: 6.4)), with: .color(ballColor))

        // Cuerpo
        let bodyRect = CGRect(x: 11, y: 16, width: 42, height: 38)
        ctx.fill(Path(roundedRect: bodyRect, cornerRadius: 15),
                 with: .linearGradient(Gradient(colors: [bodyTop, bodyBottom]),
                                       startPoint: CGPoint(x: 32, y: 16), endPoint: CGPoint(x: 32, y: 54)))
        ctx.fill(Path(ellipseIn: CGRect(x: 17, y: 20, width: 11, height: 6)), with: .color(.white.opacity(0.22)))

        let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.13
        let lw = StrokeStyle(lineWidth: 2, lineCap: .round)

        func eye(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double, shine: Bool = true) {
            if blink {
                var p = Path(); p.move(to: CGPoint(x: cx - w / 2, y: cy)); p.addLine(to: CGPoint(x: cx + w / 2, y: cy))
                ctx.stroke(p, with: .color(ink), style: lw)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)), with: .color(ink))
                if shine {
                    ctx.fill(Path(ellipseIn: CGRect(x: cx, y: cy - h / 2 + 0.6, width: 2, height: 2)), with: .color(.white))
                }
            }
        }
        func line(_ a: CGPoint, _ b: CGPoint) {
            var p = Path(); p.move(to: a); p.addLine(to: b); ctx.stroke(p, with: .color(ink), style: lw)
        }
        func mouth(_ from: CGPoint, _ to: CGPoint, _ control: CGPoint) {
            var p = Path(); p.move(to: from); p.addQuadCurve(to: to, control: control)
            ctx.stroke(p, with: .color(ink), style: lw)
        }
        func cheeks() {
            ctx.fill(Path(ellipseIn: CGRect(x: 15, y: 38, width: 7, height: 4)), with: .color(Color.pink.opacity(0.45)))
            ctx.fill(Path(ellipseIn: CGRect(x: 42, y: 38, width: 7, height: 4)), with: .color(Color.pink.opacity(0.45)))
        }
        func sweat(_ x: Double, phase: Double) {
            let k = (t * 0.6 + phase).truncatingRemainder(dividingBy: 1)
            ctx.fill(drop(x, 22 + k * 14), with: .color(Color(red: 0.55, green: 0.80, blue: 1).opacity(1 - k)))
        }
        func floating(_ s: String, x: Double, y: Double, size: Double, phase: Double, color: Color) {
            let k = (t * 0.45 + phase).truncatingRemainder(dividingBy: 1)
            ctx.draw(Text(s).font(.system(size: size, weight: .heavy, design: .rounded)).foregroundColor(color.opacity(1 - k)),
                     at: CGPoint(x: x + k * 6, y: y - k * 12))
        }

        let pupil = CGPoint(x: sin(t * 0.7) * 0.8, y: 0)

        switch mood {
        case .feliz:
            if celebrating || Int(t / 6) % 3 == 0 {
                mouth(CGPoint(x: 21, y: 34), CGPoint(x: 27, y: 34), CGPoint(x: 24, y: 29))  // ojos ^ ^
                mouth(CGPoint(x: 37, y: 34), CGPoint(x: 43, y: 34), CGPoint(x: 40, y: 29))
            } else {
                eye(24 + pupil.x, 33, 5, 6.5); eye(40 + pupil.x, 33, 5, 6.5)
            }
            cheeks()
            var smile = Path()
            smile.move(to: CGPoint(x: 26, y: 40)); smile.addQuadCurve(to: CGPoint(x: 38, y: 40), control: CGPoint(x: 32, y: 48))
            smile.closeSubpath()
            ctx.fill(smile, with: .color(ink))
        case .tranquilo:
            eye(24 + pupil.x, 33, 4.6, 5.8); eye(40 + pupil.x, 33, 4.6, 5.8)
            cheeks()
            mouth(CGPoint(x: 28, y: 41), CGPoint(x: 36, y: 41), CGPoint(x: 32, y: 44.5))
        case .preocupado:
            eye(24, 34, 4.6, 5.8); eye(40, 34, 4.6, 5.8)
            line(CGPoint(x: 20, y: 28.5), CGPoint(x: 27, y: 26.5))
            line(CGPoint(x: 37, y: 26.5), CGPoint(x: 44, y: 28.5))
            var w = Path()
            w.move(to: CGPoint(x: 26, y: 43))
            w.addQuadCurve(to: CGPoint(x: 32, y: 43), control: CGPoint(x: 29, y: 40))
            w.addQuadCurve(to: CGPoint(x: 38, y: 43), control: CGPoint(x: 35, y: 46))
            ctx.stroke(w, with: .color(ink), style: lw)
            sweat(49, phase: 0)
        case .panico:
            for cx in [24.0, 40.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 4.5, y: 29, width: 9, height: 9)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.6 + sin(t * 23) * 1.2, y: 31.9, width: 3.2, height: 3.2)), with: .color(ink))
            }
            line(CGPoint(x: 19, y: 25), CGPoint(x: 27, y: 23.5))
            line(CGPoint(x: 37, y: 23.5), CGPoint(x: 45, y: 25))
            let open = 5 + abs(sin(t * 9)) * 2
            ctx.fill(Path(ellipseIn: CGRect(x: 29, y: 40, width: 6, height: open)), with: .color(ink))
            sweat(49, phase: 0); sweat(15, phase: 0.5)
        case .agotado:
            mouth(CGPoint(x: 21, y: 33), CGPoint(x: 27, y: 33), CGPoint(x: 24, y: 36))
            mouth(CGPoint(x: 37, y: 33), CGPoint(x: 43, y: 33), CGPoint(x: 40, y: 36))
            let o = 2.2 + sin(t * 0.9) * 0.6
            ctx.stroke(Path(ellipseIn: CGRect(x: 32 - o, y: 41, width: o * 2, height: o * 2)), with: .color(ink), lineWidth: 1.6)
            floating("z", x: 48, y: 16, size: 8, phase: 0, color: .white)
            floating("z", x: 48, y: 16, size: 10, phase: 0.33, color: .white)
            floating("Z", x: 48, y: 16, size: 12, phase: 0.66, color: .white)
        case .confuso:
            eye(24, 33, 5, 6.5); eye(40, 33, 3.4, 4.2)
            var sq = Path()
            sq.move(to: CGPoint(x: 27, y: 42))
            sq.addQuadCurve(to: CGPoint(x: 32, y: 42), control: CGPoint(x: 29.5, y: 40))
            sq.addQuadCurve(to: CGPoint(x: 37, y: 42), control: CGPoint(x: 34.5, y: 44))
            ctx.stroke(sq, with: .color(ink), style: lw)
            ctx.draw(Text("?").font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.85 + sin(t * 3) * 0.15)),
                     at: CGPoint(x: 52, y: 12 + sin(t * 2) * 1.5))
        }

        // Fiesta cuando se reinicia el uso
        if celebrating {
            let colors: [Color] = [.yellow, .pink, .mint, .orange]
            for i in 0..<6 {
                let a = t * 2 + Double(i) * .pi / 3
                let r = 27 + sin(t * 5 + Double(i)) * 3
                ctx.draw(Text("✦").font(.system(size: 8 + Double(i % 3) * 2)).foregroundColor(colors[i % 4]),
                         at: CGPoint(x: 32 + cos(a) * r, y: 34 + sin(a) * r * 0.8))
            }
        }
    }
}

// MARK: Barras

struct UsageBar: View {
    let percent: Double
    let pace: Double?

    var body: some View {
        GeometryReader { g in
            let c = usageColor(percent)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [c.opacity(0.65), c], startPoint: .leading, endPoint: .trailing))
                    .frame(width: percent > 0 ? max(6, g.size.width * CGFloat(min(percent, 100) / 100)) : 0)
                    .shadow(color: c.opacity(0.55), radius: percent >= 85 ? 4 : 0)
                if let pace = pace {
                    // Marca de ritmo: dónde irías si repartieras el consumo de forma uniforme
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: g.size.height + 4)
                        .offset(x: g.size.width * CGFloat(pace) - 1)
                }
            }
            .animation(.spring(response: 0.9, dampingFraction: 0.75), value: percent)
        }
        .frame(height: 7)
    }
}

struct RowView: View {
    let row: UsageRow
    let now: Date

    var pace: Double? {
        guard let r = row.resetsAt else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0, left <= row.window else { return nil }
        return 1 - left / row.window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text("\(Int(row.percent.rounded())) %")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usageColor(row.percent))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.6), value: row.percent)
            }
            UsageBar(percent: row.percent, pace: pace)
            if let r = row.resetsAt {
                Text(resetText(r, now: now))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

struct WidgetActions {
    let setKey: () -> Void
    let clearKey: () -> Void
    let quit: () -> Void
}

struct WidgetView: View {
    @ObservedObject var model: UsageModel
    let actions: WidgetActions

    var worst: UsageRow? { model.rows.max { $0.percent < $1.percent } }
    var session: UsageRow? { model.rows.first { $0.id == "five_hour" } ?? model.rows.first }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 20)) { ctx in
            let mood = Mood.from(worst?.percent)
            let celebrating = model.celebrateUntil > ctx.date
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Mascot(mood: celebrating ? .feliz : mood,
                           accent: usageColor(worst?.percent ?? 0),
                           celebrating: celebrating)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("USO DE CLAUDE")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundColor(.white.opacity(0.45))
                            Spacer()
                            Text(model.updating ? "instalando versión nueva…" : model.loading ? "actualizando…" : (model.lastUpdate.map { agoText($0, now: ctx.date) } ?? ""))
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Text(celebrating ? "¡Energía recargada!" : phrase(mood, ctx.date))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let s = session {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int(s.percent.rounded()))")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(usageColor(s.percent))
                                    .contentTransition(.numericText())
                                    .animation(.easeOut(duration: 0.6), value: s.percent)
                                Text("% de la sesión")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                        }
                        if mood == .agotado, let r = worst?.resetsAt, !celebrating {
                            Text("Vuelvo a las \(hourText(r, now: ctx.date))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }

                if model.rows.isEmpty {
                    Text(model.error ?? "Cargando…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.rows) { RowView(row: $0, now: ctx.date) }
                    if let e = model.error {
                        Text("⚠︎ \(e)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 1, green: 0.7, blue: 0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(width: 290)
            .background(
                ZStack {
                    VisualEffect()
                    LinearGradient(colors: [(celebrating ? Mood.feliz : mood).tint.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .center)
                        .animation(.easeInOut(duration: 1.2), value: mood)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1))
            .contextMenu {
                Button("Actualizar ahora") { model.refresh() }
                Button(model.alwaysOnTop ? "✓ Siempre por encima" : "Siempre por encima") { model.alwaysOnTop.toggle() }
                Button("Abrir uso en claude.ai") {
                    NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                }
                Divider()
                Button("Configurar sessionKey de claude.ai…") { actions.setKey() }
                Button("Borrar sessionKey") { actions.clearKey() }
                if !model.source.isEmpty {
                    Button("Origen: \(model.source)") {}.disabled(true)
                }
                Divider()
                Button("Buscar actualizaciones") { model.checkForUpdate() }
                Button("Versión \(model.version)") {}.disabled(true)
                Divider()
                Button("Salir") { actions.quit() }
            }
        }
    }

    func phrase(_ mood: Mood, _ now: Date) -> String {
        let list = mood.phrases
        let i = Int(now.timeIntervalSinceReferenceDate / 90) % list.count
        return list[i]
    }
}

// MARK: - Ventana flotante

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 290, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var panel: FloatingPanel!
    var hosting: DraggableHostingView<WidgetView>!
    var followTimer: Timer?
    var currentScreenID: CGDirectDisplayID?
    var movingProgrammatically = false

    // Distancia del widget a la esquina superior derecha del área útil de la pantalla
    var offset: CGPoint {
        get {
            let d = UserDefaults.standard
            return CGPoint(x: d.object(forKey: "offsetX") as? Double ?? 20,
                           y: d.object(forKey: "offsetY") as? Double ?? 20)
        }
        set {
            UserDefaults.standard.set(Double(newValue.x), forKey: "offsetX")
            UserDefaults.standard.set(Double(newValue.y), forKey: "offsetY")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = WidgetActions(
            setKey: { [weak self] in self?.askSessionKey() },
            clearKey: { [weak self] in
                KeychainStore.delete()
                UserDefaults.standard.removeObject(forKey: "orgId")
                self?.model.refresh()
            },
            quit: { NSApp.terminate(nil) }
        )
        hosting = DraggableHostingView(rootView: WidgetView(model: model, actions: actions))

        panel = FloatingPanel()
        panel.contentView = hosting
        panel.setContentSize(widgetSize())
        applyLevel()

        if let screen = activeScreen() { place(on: screen) }
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(follow),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(follow),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // También cubre mover una ventana de un monitor a otro sin cambiar de app
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.follow() }

        model.onChange = { [weak self] in DispatchQueue.main.async { self?.resizeKeepingTop() } }
        model.onLevelChange = { [weak self] in self?.applyLevel() }
        model.start()
    }

    // MARK: Seguir al monitor activo

    func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Pantalla donde está la ventana con la que trabajas; si no se puede saber, la del ratón.
    func activeScreen() -> NSScreen? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let rect = frontWindowRect(pid: app.processIdentifier) {
            var best: NSScreen?
            var bestArea: CGFloat = 0
            for s in NSScreen.screens {
                let i = s.frame.intersection(rect)
                let area = i.isNull ? 0 : i.width * i.height
                if area > bestArea { bestArea = area; best = s }
            }
            if let best = best { return best }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Marco (en coordenadas de Cocoa) de la ventana delantera de una app.
    func frontWindowRect(pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.width > 80, r.height > 80 else { continue }
            return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        return nil
    }

    @objc func follow() {
        guard let screen = activeScreen(), let id = displayID(screen) else { return }
        if id != currentScreenID { place(on: screen) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc func screensChanged() {
        currentScreenID = nil
        follow()
    }

    func place(on screen: NSScreen) {
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let o = offset
        var x = vf.maxX - size.width - o.x
        var y = vf.maxY - size.height - o.y
        x = min(max(x, vf.minX), vf.maxX - size.width)
        y = min(max(y, vf.minY), vf.maxY - size.height)
        movingProgrammatically = true
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        movingProgrammatically = false
        currentScreenID = displayID(screen)
        panel.orderFrontRegardless()
    }

    /// Al arrastrarlo, guarda la nueva posición relativa para todas las pantallas.
    @objc func panelMoved() {
        guard !movingProgrammatically,
              let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { return }
        let vf = screen.visibleFrame
        offset = CGPoint(x: max(0, vf.maxX - panel.frame.maxX), y: max(0, vf.maxY - panel.frame.maxY))
        currentScreenID = displayID(screen)
    }

    // MARK: Ventana

    func applyLevel() {
        if model.alwaysOnTop {
            panel.level = .statusBar
        } else {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        panel.orderFrontRegardless()
    }

    /// Tamaño real del contenido (con mínimo de seguridad para que nunca quede en 0×0)
    func widgetSize() -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let s = hosting.fittingSize
        return NSSize(width: max(s.width, 290), height: max(s.height, 90))
    }

    func resizeKeepingTop() {
        let size = widgetSize()
        var f = panel.frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        movingProgrammatically = true
        panel.setFrame(f, display: true)
        movingProgrammatically = false
    }

    func askSessionKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "sessionKey de claude.ai"
        alert.informativeText = "Opcional: úsala si no tienes Claude Code o su token caduca a menudo. En claude.ai abre el inspector web (⌥⌘I) › Almacenamiento/Application › Cookies › claude.ai y copia el valor de «sessionKey». Se guarda solo en el Llavero de este Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-sid01-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("sessionKey=") { value = String(value.dropFirst("sessionKey=".count)) }
        guard !value.isEmpty else { return }
        KeychainStore.save(value)
        UserDefaults.standard.removeObject(forKey: "orgId")
        model.refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
