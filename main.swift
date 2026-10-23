// Uso de Claude — widget flotante para macOS
// Muestra el consumo de la sesión (5 h) y semanal de tu plan de Claude.
// Origen de datos: credenciales de Claude Code (Llavero) o, opcionalmente, la cookie sessionKey de claude.ai.

import AppKit
import SwiftUI
import Security
import WebKit
import Carbon

// MARK: - Modelo de datos

struct UsageRow: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    let window: TimeInterval
}

enum UsageError: LocalizedError, Equatable {
    case noCredentials, unauthorized, http(Int), badData, noOrg, needLogin

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No encuentro credenciales. Inicia sesión en Claude Code o añade tu sessionKey (clic derecho)."
        case .unauthorized: return "Sesión caducada. Abre Claude Code para renovarla o actualiza la sessionKey."
        case .http(let code): return "El servidor respondió con un error \(code)."
        case .badData: return "Respuesta inesperada del servidor."
        case .noOrg: return "No encuentro tu organización en claude.ai."
        case .needLogin: return "Inicia sesión en Claude: clic derecho › Iniciar sesión en claude.ai…"
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
        // Solo cuentan los cambios del widget de Mac (no los de la app de Android)
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/commits?path=main.swift&per_page=1")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeUsageWidget", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                  let sha = list.first?["sha"] as? String, sha.count == 40 else { return completion(nil) }
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
        let parts: [String] = ["/bin/bash", "-c", cmd]
        var args: [UnsafeMutablePointer<CChar>?] = parts.map { strdup($0) }
        args.append(nil)
        defer { args.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, "/bin/bash", nil, &attr, args, environ) == 0
    }
}

// MARK: - Sesión de claude.ai dentro de la app

/// Navegador interno e invisible con su propia sesión de claude.ai. El usuario inicia sesión
/// una vez en una ventanita y las consultas de uso se hacen desde esa misma sesión,
/// como lo haría la web, sin copiar cookies ni tener Claude Code.
final class WebSession: NSObject, WKNavigationDelegate {
    static let shared = WebSession()
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var web: WKWebView?
    private var ready = false
    private var waiters: [() -> Void] = []
    private var loginWindow: NSWindow?
    private var loginWeb: WKWebView?
    private var pollTimer: Timer?
    var onLogin: (() -> Void)?

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680), configuration: cfg)
        w.customUserAgent = WebSession.safariUA
        return w
    }

    private func whenReady(_ f: @escaping () -> Void) {
        if ready { return f() }
        waiters.append(f)
        guard web == nil else { return }
        let w = makeWeb()
        w.navigationDelegate = self
        web = w
        w.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    private func flush() {
        let w = waiters
        waiters = []
        w.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        ready = true
        flush()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView) }

    private func failed(_ webView: WKWebView) {
        guard webView === web else { return }
        web = nil
        ready = false
        flush()
    }

    func fetchUsage(_ completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        DispatchQueue.main.async {
            self.whenReady {
                guard let w = self.web else { return completion(.failure(UsageError.http(0))) }
                let js = """
                const o = await fetch('/api/organizations', {credentials: 'include'});
                if (o.status !== 200) return {status: o.status, body: ''};
                const orgs = await o.json();
                const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
                if (!org) return {status: 404, body: ''};
                const r = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
                return {status: r.status, body: await r.text()};
                """
                w.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .failure(let e):
                        completion(.failure(e))
                    case .success(let v):
                        guard let d = v as? [String: Any], let status = (d["status"] as? NSNumber)?.intValue else {
                            return completion(.failure(UsageError.badData))
                        }
                        if status == 401 || status == 403 { return completion(.failure(UsageError.needLogin)) }
                        guard status == 200, let body = (d["body"] as? String)?.data(using: .utf8) else {
                            return completion(.failure(UsageError.http(status)))
                        }
                        completion(Result { try UsageAPI.parse(body) })
                    }
                }
            }
        }
    }

    private func hasSession(_ done: @escaping (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            done(cookies.contains { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") })
        }
    }

    /// Ventana para iniciar sesión en claude.ai. Se cierra sola en cuanto hay sesión.
    func showLogin() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let w = self.loginWindow, w.isVisible { return w.makeKeyAndOrderFront(nil) }
            let web = self.makeWeb()
            web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            win.title = "Inicia sesión en Claude · Uso de Claude"
            win.contentView = web
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.center()
            self.loginWindow = win
            self.loginWeb = web
            win.makeKeyAndOrderFront(nil)
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self = self else { return t.invalidate() }
                guard self.loginWindow?.isVisible == true else {
                    t.invalidate(); self.loginWeb = nil; return
                }
                self.hasSession { ok in
                    DispatchQueue.main.async {
                        guard ok, let path = self.loginWeb?.url?.path,
                              !path.hasPrefix("/login"), !path.contains("magic-link") else { return }
                        t.invalidate()
                        self.loginWindow?.close()
                        self.loginWindow = nil
                        self.loginWeb = nil
                        self.web = nil
                        self.ready = false
                        self.onLogin?()
                    }
                }
            }
        }
    }
}

// MARK: - ChatGPT (límites de Codex)

/// Lee los límites de uso del plan de ChatGPT a través de la sesión de Codex del Mac.
/// Es un endpoint interno de OpenAI (el que usa el /status de Codex): puede cambiar sin aviso.
enum CodexAPI {
    static var authFile: URL {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let base = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return base.appendingPathComponent("auth.json")
    }

    static var available: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    enum CodexError: LocalizedError {
        case noLogin, expired, http(Int), badData
        var errorDescription: String? {
            switch self {
            case .noLogin: return "Inicia sesión en Codex con tu cuenta de ChatGPT para ver este uso."
            case .expired: return "Sesión de Codex caducada: abre Codex un momento para renovarla."
            case .http(let c): return "ChatGPT respondió con un error \(c)."
            case .badData: return "Respuesta inesperada de ChatGPT."
            }
        }
    }

    static func credentials() -> (token: String, account: String?)? {
        guard let data = try? Data(contentsOf: authFile),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    /// Intenta la API y, si falla, lee los límites que Codex apunta en sus registros locales.
    static func fetch(_ completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        fetchAPI { r in
            if case .success = r { return completion(r) }
            if let rows = CodexLog.latest() { return completion(.success(rows)) }
            completion(r)
        }
    }

    static func fetchAPI(_ completion: @escaping (Result<[UsageRow], Error>) -> Void) {
        guard let c = credentials() else { return completion(.failure(CodexError.noLogin)) }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpShouldHandleCookies = false
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        if let a = c.account { req.setValue(a, forHTTPHeaderField: "chatgpt-account-id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return completion(.failure(CodexError.expired)) }
            guard (200..<300).contains(code), let data = data else { return completion(.failure(CodexError.http(code))) }
            completion(Result { try parse(data) })
        }.resume()
    }

    static func parse(_ data: Data) throws -> [UsageRow] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any] else { throw CodexError.badData }
        var rows: [UsageRow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let span = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? (key == "primary_window" ? 18000 : 604800)
            var reset: Date?
            if let at = (w["reset_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: at)
            } else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue {
                reset = Date().addingTimeInterval(after)
            }
            let label: String
            if span >= 6 * 86400 { label = "Semana" }
            else if abs(span - 18000) < 60 { label = "Sesión (5 h)" }
            else { label = "Ventana de \(Int((span / 3600).rounded())) h" }
            rows.append(UsageRow(id: "gpt_" + key, label: label, percent: used, resetsAt: reset, window: span))
        }
        if rows.isEmpty { throw CodexError.badData }
        return rows
    }
}

/// Codex guarda en cada sesión (~/.codex/sessions/…/rollout-*.jsonl) los límites del plan
/// que le devuelve OpenAI. Se lee solo el último registro de límites, nada de las conversaciones.
enum CodexLog {
    static var sessionsDir: URL { CodexAPI.authFile.deletingLastPathComponent().appendingPathComponent("sessions") }

    static func newestFile() -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Date)?
        for case let u as URL in en where u.lastPathComponent.hasPrefix("rollout-") && u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || d > best!.1 { best = (u, d) }
        }
        return best?.0
    }

    static func latest() -> [UsageRow]? {
        guard let file = newestFile(), let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let stamp = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            var rows: [UsageRow] = []
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any],
                      var used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let span = ((w["window_minutes"] as? NSNumber)?.doubleValue ?? (key == "primary" ? 300 : 10080)) * 60
                var reset: Date?
                if let at = (w["resets_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: at) }
                else if let s = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { reset = stamp.addingTimeInterval(s) }
                if let r = reset, r < Date() { used = 0; reset = nil }   // la ventana ya se reinició
                let label = span >= 6 * 86400 ? "Semana" : (abs(span - 18000) < 120 ? "Sesión (5 h)" : "Ventana de \(Int((span / 3600).rounded())) h")
                rows.append(UsageRow(id: "gpt_" + key, label: label, percent: used, resetsAt: reset, window: span))
            }
            if !rows.isEmpty { return rows }
        }
        return nil
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
    @Published var gptRows: [UsageRow] = []
    @Published var gptError: String?
    @Published var showGPT: Bool = UserDefaults.standard.object(forKey: "showGPT") as? Bool ?? CodexAPI.available {
        didSet {
            UserDefaults.standard.set(showGPT, forKey: "showGPT")
            if showGPT { refreshGPT() }
            DispatchQueue.main.async { self.onChange?() }
        }
    }
    @Published var updating = false
    let version = Updater.installed.map { String($0.prefix(7)) } ?? "local"
    @Published var layout: WidgetLayout = WidgetLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: "layout")
            DispatchQueue.main.async { self.onChange?() }
        }
    }
    /// Escala libre que se ajusta arrastrando la esquina inferior derecha
    @Published var zoom: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1) {
        didSet {
            UserDefaults.standard.set(Double(zoom), forKey: "zoom")
            DispatchQueue.main.async { self.onChange?() }
        }
    }
    static let zoomSteps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    var canZoomIn: Bool { zoom < (UsageModel.zoomSteps.last ?? 2) - 0.001 }
    var canZoomOut: Bool { zoom > (UsageModel.zoomSteps.first ?? 1) + 0.001 }
    func zoomIn() { if let n = UsageModel.zoomSteps.first(where: { $0 > zoom + 0.001 }) { zoom = n } }
    func zoomOut() { if let n = UsageModel.zoomSteps.last(where: { $0 < zoom - 0.001 }) { zoom = n } }
    var onSize: ((CGSize) -> Void)?
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

    func refreshGPT() {
        guard showGPT else { return }
        DispatchQueue.global(qos: .utility).async {
            CodexAPI.fetch { r in
                DispatchQueue.main.async {
                    switch r {
                    case .success(let rows): self.gptRows = rows; self.gptError = nil
                    case .failure(let e): self.gptError = e.localizedDescription
                    }
                    self.onChange?()
                }
            }
        }
    }

    func refresh() {
        refreshGPT()
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            // 1) Sesión de Claude Code, si la hay en este Mac
            UsageAPI.viaClaudeCode { r in
                if case .success = r { return self.finish(r, "Claude Code") }
                // 2) Sesión de claude.ai iniciada dentro de la propia app
                WebSession.shared.fetchUsage { r2 in
                    if case .success = r2 { return self.finish(r2, "claude.ai") }
                    // 3) sessionKey pegada a mano (opción avanzada)
                    if let key = KeychainStore.read() {
                        UsageAPI.viaWeb(key: key) { r3 in
                            if case .success = r3 { self.finish(r3, "claude.ai") } else { self.finish(r2, "claude.ai") }
                        }
                    } else {
                        self.finish(r2, "claude.ai")
                    }
                }
            }
        }
    }

    private var askedLogin = false

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
                // Sin datos y sin sesión: abre la ventana de inicio de sesión (una vez por arranque)
                if self.rows.isEmpty, (e as? UsageError) == .needLogin, !self.askedLogin {
                    self.askedLogin = true
                    WebSession.shared.showLogin()
                }
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

/// Fondo de cristal: Liquid Glass nativo en macOS 26 y, en versiones anteriores,
/// desenfoque con máscara redondeada real (para que las esquinas no se vean cuadradas).
struct GlassBackground: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = radius
            g.tintColor = NSColor.black.withAlphaComponent(0.28)
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = GlassBackground.mask(radius)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let g = nsView as? NSGlassEffectView {
            g.cornerRadius = radius
        } else if let v = nsView as? NSVisualEffectView {
            v.maskImage = GlassBackground.mask(radius)
        }
    }

    static func mask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
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
    var size: CGFloat = 64

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .frame(width: size, height: size)
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

// MARK: Formatos

enum WidgetLayout: String, CaseIterable, Identifiable {
    case mini, compacto, normal, grande, horizontal, vertical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mini: return "Mínima expresión"
        case .compacto: return "Pequeño"
        case .normal: return "Normal"
        case .grande: return "Grande"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

// MARK: Barras

struct UsageBar: View {
    let percent: Double
    let pace: Double?
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { g in
            let c = usageColor(percent)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [c.opacity(0.65), c], startPoint: .leading, endPoint: .trailing))
                    .frame(width: percent > 0 ? max(height, g.size.width * CGFloat(min(percent, 100) / 100)) : 0)
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
        .frame(height: height)
    }
}

struct RowView: View {
    let row: UsageRow
    let now: Date
    var k: CGFloat = 1
    var showReset = true

    var pace: Double? {
        guard let r = row.resetsAt else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0, left <= row.window else { return nil }
        return 1 - left / row.window
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * k) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.system(size: 11 * k, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("\(Int(row.percent.rounded())) %")
                    .font(.system(size: 13 * k, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usageColor(row.percent))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.6), value: row.percent)
            }
            UsageBar(percent: row.percent, pace: pace, height: 7 * k)
            if showReset, let r = row.resetsAt {
                Text(resetText(r, now: now))
                    .font(.system(size: 10 * k))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

struct WidgetActions {
    let setKey: () -> Void
    let clearKey: () -> Void
    let quit: () -> Void
    let minimize: () -> Void
}

/// Zonas clicables (botones) en coordenadas de la ventana; el resto del widget sirve para arrastrar.
enum HitZones { static var controls: CGRect = .zero }

struct ControlsRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct FinalSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Botoncitos: más pequeño, más grande y minimizar a la barra de menús
struct Controls: View {
    @ObservedObject var model: UsageModel
    let actions: WidgetActions
    let vertical: Bool

    func button(_ symbol: String, _ help: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(enabled ? 0.9 : 0.3))
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder var buttons: some View {
        button("minus", "Más pequeño", enabled: model.canZoomOut) { model.zoomOut() }
        button("plus", "Más grande", enabled: model.canZoomIn) { model.zoomIn() }
        button("menubar.arrow.up.rectangle", "Minimizar en la barra de menús") { actions.minimize() }
    }

    var body: some View {
        Group {
            if vertical { VStack(spacing: 4) { buttons } } else { HStack(spacing: 4) { buttons } }
        }
        .background(GeometryReader { g in Color.clear.preference(key: ControlsRectKey.self, value: g.frame(in: .global)) })
        .onPreferenceChange(ControlsRectKey.self) { HitZones.controls = $0 }
    }
}

struct NaturalSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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
            let shown = celebrating ? Mood.feliz : mood
            let z = model.zoom
            let radius: CGFloat = (model.layout == .mini ? 23 : 22) * z
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content(ctx.date, mood: mood, celebrating: celebrating)
                .fixedSize()
                .background(
                    ZStack {
                        GlassBackground(radius: radius)
                        // Un toque del color del ánimo, muy sutil, como luz dentro del cristal
                        LinearGradient(colors: [shown.tint.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                            .animation(.easeInOut(duration: 1.2), value: mood)
                    }
                    .clipShape(shape)
                )
                // Brillo del canto superior, como en el cristal de Apple
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .white.opacity(0.22)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                // Filo exterior oscuro finísimo: define el borde sobre fondos blancos
                .overlay(shape.stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                .overlay(alignment: controlsAlignment) {
                    Controls(model: model, actions: actions, vertical: controlsVertical)
                        .padding(controlsVertical ? 8 : 7)
                }
                .padding(1)
                .contextMenu { menu }
        }
    }

    var controlsVertical: Bool { [.compacto, .horizontal, .vertical].contains(model.layout) }
    var controlsAlignment: Alignment { [.mini, .compacto, .horizontal].contains(model.layout) ? .trailing : .topTrailing }

    // MARK: Piezas

    func mascot(_ size: CGFloat, _ mood: Mood, _ celebrating: Bool) -> some View {
        Mascot(mood: celebrating ? .feliz : mood, accent: usageColor(worst?.percent ?? 0),
               celebrating: celebrating, size: size)
    }

    func statusText(_ now: Date) -> String {
        model.updating ? "instalando versión nueva…" : model.loading ? "actualizando…" : (model.lastUpdate.map { agoText($0, now: now) } ?? "")
    }

    func phraseText(_ mood: Mood, _ celebrating: Bool, _ now: Date, k: CGFloat, center: Bool = false) -> some View {
        Text(celebrating ? "¡Energía recargada!" : phrase(mood, now))
            .font(.system(size: 13 * k, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.95))
            .multilineTextAlignment(center ? .center : .leading)
            .lineLimit(center ? 2 : 1)
            .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    func bigPercent(k: CGFloat, label: String = "% de la sesión") -> some View {
        if let s = session {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(s.percent.rounded()))")
                    .font(.system(size: 26 * k, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usageColor(s.percent))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.6), value: s.percent)
                Text(label)
                    .font(.system(size: 10 * k, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    func comeback(_ mood: Mood, _ celebrating: Bool, _ now: Date, k: CGFloat) -> some View {
        if mood == .agotado, let r = worst?.resetsAt, !celebrating {
            Text("Vuelvo a las \(hourText(r, now: now))")
                .font(.system(size: 10 * k, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    @ViewBuilder
    func rows(_ now: Date, k: CGFloat, showReset: Bool = true) -> some View {
        if model.rows.isEmpty {
            Text(model.error ?? "Cargando…")
                .font(.system(size: 11 * k))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(model.rows) { RowView(row: $0, now: now, k: k, showReset: showReset) }
            if let e = model.error {
                Text("⚠︎ \(e)")
                    .font(.system(size: 10 * k))
                    .foregroundColor(Color(red: 1, green: 0.7, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    func gptSection(_ now: Date, k: CGFloat, showReset: Bool = true) -> some View {
        if model.showGPT && (!model.gptRows.isEmpty || model.gptError != nil) {
            VStack(alignment: .leading, spacing: 8 * k) {
                HStack(spacing: 6) {
                    Text("CHATGPT")
                        .font(.system(size: 9 * k, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.45))
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                }
                ForEach(model.gptRows) { RowView(row: $0, now: now, k: k, showReset: showReset) }
                if let e = model.gptError {
                    Text(model.gptRows.isEmpty ? e : "⚠︎ \(e)")
                        .font(.system(size: 10 * k))
                        .foregroundColor(model.gptRows.isEmpty ? .white.opacity(0.6) : Color(red: 1, green: 0.7, blue: 0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var gptHeadline: UsageRow? { model.gptRows.max { $0.percent < $1.percent } }

    // MARK: Formatos

    @ViewBuilder
    func content(_ now: Date, mood: Mood, celebrating: Bool) -> some View {
        let z = model.zoom
        switch model.layout {
        case .mini:
            HStack(spacing: 6 * z) {
                mascot(34 * z, mood, celebrating)
                if let s = session {
                    Text("\(Int(s.percent.rounded()))%")
                        .font(.system(size: 17 * z, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(usageColor(s.percent))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.6), value: s.percent)
                }
                if model.showGPT, let g = gptHeadline {
                    Text("· GPT \(Int(g.percent.rounded()))%")
                        .font(.system(size: 11 * z, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.vertical, 6 * z)
            .padding(.leading, 6 * z)
            .padding(.trailing, 12 * z + 60)

        case .compacto:
            HStack(spacing: 10 * z) {
                mascot(46 * z, mood, celebrating)
                VStack(alignment: .leading, spacing: 2 * z) {
                    phraseText(mood, celebrating, now, k: 0.9 * z)
                    bigPercent(k: 0.8 * z, label: "% sesión")
                    if let w = model.rows.first(where: { $0.id == "seven_day" }) {
                        miniBar("Semana", w.percent, z)
                    }
                    if model.showGPT, let g = gptHeadline {
                        miniBar("ChatGPT", g.percent, z)
                    }
                }
            }
            .padding(10 * z)
            .padding(.trailing, 28)
            .frame(width: 220 * z + 28)

        case .normal, .grande:
            let k: CGFloat = (model.layout == .grande ? 1.35 : 1) * z
            VStack(alignment: .leading, spacing: 12 * k) {
                HStack(alignment: .center, spacing: 12 * k) {
                    mascot(64 * k, mood, celebrating)
                    VStack(alignment: .leading, spacing: 2 * k) {
                        HStack {
                            Text("USO DE CLAUDE")
                                .font(.system(size: 9 * k, weight: .bold))
                                .tracking(0.8)
                                .foregroundColor(.white.opacity(0.45))
                            Spacer()
                        }
                        phraseText(mood, celebrating, now, k: k)
                        bigPercent(k: k)
                        comeback(mood, celebrating, now, k: k)
                    }
                }
                rows(now, k: k)
                gptSection(now, k: k)
                Text(statusText(now))
                    .font(.system(size: 9 * k))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14 * k)
            .frame(width: 290 * k)

        case .horizontal:
            HStack(alignment: .center, spacing: 16 * z) {
                mascot(54 * z, mood, celebrating)
                VStack(alignment: .leading, spacing: 2 * z) {
                    phraseText(mood, celebrating, now, k: z)
                    bigPercent(k: 0.9 * z)
                    comeback(mood, celebrating, now, k: z)
                }
                .frame(width: 150 * z, alignment: .leading)
                if model.rows.isEmpty {
                    rows(now, k: z).frame(width: 220 * z)
                } else {
                    ForEach(model.rows) { r in
                        Divider().frame(height: 44 * z).overlay(Color.white.opacity(0.1))
                        RowView(row: r, now: now, k: z).frame(width: 190 * z)
                    }
                }
                if model.showGPT {
                    ForEach(model.gptRows) { r in
                        Divider().frame(height: 44 * z).overlay(Color.white.opacity(0.1))
                        RowView(row: UsageRow(id: r.id, label: "ChatGPT · " + r.label, percent: r.percent,
                                              resetsAt: r.resetsAt, window: r.window), now: now, k: z)
                            .frame(width: 190 * z)
                    }
                }
            }
            .padding(.leading, 14 * z)
            .padding(.trailing, 14 * z + 26)
            .padding(.vertical, 10 * z)

        case .vertical:
            VStack(alignment: .center, spacing: 10 * z) {
                mascot(68 * z, mood, celebrating)
                phraseText(mood, celebrating, now, k: 0.95 * z, center: true)
                if let s = session {
                    VStack(spacing: 0) {
                        Text("\(Int(s.percent.rounded()))%")
                            .font(.system(size: 30 * z, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(usageColor(s.percent))
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.6), value: s.percent)
                        Text("de la sesión").font(.system(size: 10 * z)).foregroundColor(.white.opacity(0.55))
                    }
                }
                comeback(mood, celebrating, now, k: z)
                VStack(alignment: .leading, spacing: 10 * z) {
                    rows(now, k: 0.9 * z, showReset: false)
                    gptSection(now, k: 0.9 * z, showReset: false)
                }
                Text(statusText(now)).font(.system(size: 9 * z)).foregroundColor(.white.opacity(0.4))
            }
            .padding(14 * z)
            .frame(width: 160 * z)
        }
    }

    func miniBar(_ label: String, _ percent: Double, _ z: CGFloat) -> some View {
        HStack(spacing: 5 * z) {
            Text(label).font(.system(size: 9 * z)).foregroundColor(.white.opacity(0.5))
            UsageBar(percent: percent, pace: nil, height: 4 * z)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 9 * z, weight: .semibold)).monospacedDigit()
                .foregroundColor(usageColor(percent))
        }
    }

    @ViewBuilder
    var menu: some View {
        Menu("Tamaño") {
            ForEach(WidgetLayout.allCases) { l in
                Button((model.layout == l ? "✓ " : "") + l.title) { model.layout = l }
            }
        }
        Button("Tamaño original") { model.zoom = 1 }
        Button("Minimizar en la barra de menús") { actions.minimize() }
        Button("Mostrar desde cualquier sitio: ⌃⌥⌘U") {}.disabled(true)
        Divider()
        Button("Actualizar ahora") { model.refresh() }
        Button(model.showGPT ? "✓ Mostrar ChatGPT" : "Mostrar ChatGPT") { model.showGPT.toggle() }
        Button(model.alwaysOnTop ? "✓ Siempre por encima" : "Siempre por encima") { model.alwaysOnTop.toggle() }
        Button("Abrir uso en claude.ai") {
            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
        }
        Divider()
        Button("Iniciar sesión en claude.ai…") { WebSession.shared.showLogin() }
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        if HitZones.controls.insetBy(dx: -3, dy: -3).contains(point) {
            super.mouseDown(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var panel: FloatingPanel!
    var hosting: DraggableHostingView<WidgetView>!
    var movingProgrammatically = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = WidgetActions(
            setKey: { [weak self] in self?.askSessionKey() },
            clearKey: { [weak self] in
                KeychainStore.delete()
                UserDefaults.standard.removeObject(forKey: "orgId")
                self?.model.refresh()
            },
            quit: { NSApp.terminate(nil) },
            minimize: { [weak self] in DispatchQueue.main.async { self?.minimize() } }
        )
        hosting = DraggableHostingView(rootView: WidgetView(model: model, actions: actions))

        panel = FloatingPanel()
        panel.contentView = hosting
        panel.setContentSize(widgetSize())
        applyLevel()
        restorePosition()
        if UserDefaults.standard.bool(forKey: "minimized") { minimize() } else { panel.orderFrontRegardless() }

        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        model.onChange = { [weak self] in self?.contentChanged() }
        model.onLevelChange = { [weak self] in self?.applyLevel() }
        WebSession.shared.onLogin = { [weak self] in self?.model.refresh() }
        registerHotKey()
        if ProcessInfo.processInfo.environment["WIDGET_SELFTEST"] != nil { return selfTest() }
        model.start()
    }

    // MARK: Posición libre (se recuerda dónde lo dejas)

    func isOnScreen(_ f: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(f.insetBy(dx: 20, dy: 20)) }
    }

    func restorePosition() {
        let d = UserDefaults.standard
        if let x = d.object(forKey: "posX") as? Double, let top = d.object(forKey: "posTop") as? Double {
            let size = panel.frame.size
            let f = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
            if isOnScreen(f) { return setOrigin(f.origin) }
        }
        placeDefault()
    }

    func placeDefault() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        setOrigin(NSPoint(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 20))
        savePosition()
    }

    func setOrigin(_ p: NSPoint) {
        movingProgrammatically = true
        panel.setFrameOrigin(p)
        movingProgrammatically = false
    }

    func savePosition() {
        UserDefaults.standard.set(Double(panel.frame.minX), forKey: "posX")
        UserDefaults.standard.set(Double(panel.frame.maxY), forKey: "posTop")
    }

    @objc func panelMoved() {
        guard !movingProgrammatically else { return }
        savePosition()
    }

    @objc func screensChanged() {
        if !isOnScreen(panel.frame) { placeDefault() }
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
        return NSSize(width: max(s.width, 60), height: max(s.height, 40))
    }

    /// Tras cualquier cambio, espera a que SwiftUI redibuje y ajusta la ventana a su tamaño real
    func contentChanged() {
        updateStatusItem()
        for delay in [0.0, 0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.hosting.layoutSubtreeIfNeeded()
                self.setSizeKeepingTopLeft(self.hosting.fittingSize)
            }
        }
    }

    /// Ajusta la ventana al tamaño exacto del widget, con la esquina superior izquierda fija
    func setSizeKeepingTopLeft(_ size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        var f = panel.frame
        if abs(f.width - size.width) < 0.5 && abs(f.height - size.height) < 0.5 { return }
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        movingProgrammatically = true
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
        movingProgrammatically = false
    }

    /// Prueba automática (solo en GitHub Actions): mide la ventana antes y después de agrandar
    func selfTest() {
        func report(_ tag: String) {
            print("[\(tag)] zoom=\(model.zoom) ventana=\(panel.frame.size) fitting=\(hosting.fittingSize)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { report("inicio") ; self.model.zoomIn(); self.model.zoomIn() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { report("tras +2") ; self.model.zoomOut() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { report("tras -1") ; exit(0) }
    }

    // MARK: Atajo de teclado global ⌃⌥⌘U

    var hotKeyRef: EventHotKeyRef?

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.showFromHotKey() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x434C5544), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Trae el widget a la vista: lo saca de la barra de menús y lo recoloca si quedó fuera de pantalla
    func showFromHotKey() {
        if statusItem != nil { restoreAction() }
        if !isOnScreen(panel.frame) { placeDefault() }
        panel.orderFrontRegardless()
        // Pequeño destello para encontrarlo
        panel.alphaValue = 0.3
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    // MARK: Barra de menús

    var statusItem: NSStatusItem?

    func minimize() {
        panel.orderOut(nil)
        UserDefaults.standard.set(true, forKey: "minimized")
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            for (title, sel) in [("Mostrar widget  ⌃⌥⌘U", #selector(restoreAction)), ("Actualizar ahora", #selector(refreshAction))] {
                let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                i.target = self
                menu.addItem(i)
            }
            menu.addItem(.separator())
            let q = NSMenuItem(title: "Salir", action: #selector(quitAction), keyEquivalent: "")
            q.target = self
            menu.addItem(q)
            item.menu = menu
            statusItem = item
        }
        updateStatusItem()
    }

    @objc func restoreAction() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        UserDefaults.standard.set(false, forKey: "minimized")
        panel.orderFrontRegardless()
    }

    @objc func refreshAction() { model.refresh() }
    @objc func quitAction() { NSApp.terminate(nil) }

    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func icon(_ img: NSImage) {
            let a = NSTextAttachment()
            a.image = img
            a.bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
            title.append(NSAttributedString(attachment: a))
        }
        func text(_ t: String) {
            title.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        func name(_ t: String, _ c: NSColor) {
            title.append(NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: c]))
        }
        func small(_ t: String) {
            title.append(NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        func pct(_ r: UsageRow?) -> String { r.map { "\(Int($0.percent.rounded()))%" } ?? "–" }
        // Semana / horas (ventana de 5 h)
        func pair(_ rows: [UsageRow]) {
            small("sem ")
            text(pct(rows.first { $0.window >= 6 * 86400 }))
            small("  5h ")
            text(pct(rows.first { $0.window < 6 * 86400 }))
        }
        icon(AppDelegate.mascotIcon)
        name(" Claude ", NSColor(red: 0.89, green: 0.52, blue: 0.38, alpha: 1))
        pair(model.rows)
        if model.showGPT, !model.gptRows.isEmpty {
            text("   ")
            name("GPT ", NSColor(red: 0.30, green: 0.78, blue: 0.62, alpha: 1))
            pair(model.gptRows)
        }
        button.image = nil
        button.attributedTitle = title
    }

    /// Carita de la mascota en miniatura (dibujo propio)
    static let mascotIcon: NSImage = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        NSColor(red: 0.87, green: 0.50, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1.5), xRadius: 4, yRadius: 4).fill()
        NSColor(red: 0.16, green: 0.10, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 6, width: 2, height: 2.6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 6, width: 2, height: 2.6)).fill()
        return true
    }

    /// Bocadillo genérico para ChatGPT
    static let chatIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(red: 0.30, green: 0.78, blue: 0.62, alpha: 1)]))
        return NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "ChatGPT")?
            .withSymbolConfiguration(cfg) ?? NSImage()
    }()

    /// Al cambiar de tamaño mantiene fija la esquina superior izquierda
    func resizeKeepingTopLeft() {
        let size = widgetSize()
        var f = panel.frame
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        movingProgrammatically = true
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
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
