// Uso de Claude — widgets flotantes para macOS
// Suscripciones (Claude y ChatGPT: % de la sesión de 5 h y de la semana, con su reinicio)
// y APIs de pago (OpenAI y Soniox: saldo y gasto del mes), con un personaje por servicio que se agobia según el uso.

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

// MARK: - Gastos del mes (cerebro de Moni)

/// Gastos y tokens del mes que calcula el cerebro de Moni en este Mac (http://127.0.0.1:8765/gastos).
/// Solo aparece si el cerebro está instalado: lee su token de ~/.config/companero/token. Nada sale del Mac.
struct MonthSpend: Equatable {
    struct Line: Equatable, Identifiable { let id: String; let name: String; let detail: String }
    var month = ""
    var spentEUR = 0.0          // gastado de verdad hasta hoy (APIs + cuotas prorrateadas + luz)
    var forecastEUR = 0.0       // previsto a fin de mes
    var tokens = 0.0, tokensApps = 0.0, tokensAPIs = 0.0
    var apiUSD = 0.0, budgetUSD: Double?
    var savedEUR = 0.0          // lo que costaría a precio de API lo que va con suscripción, menos las cuotas
    var apps: [Line] = []       // Claude Code, Codex, Hermes: tokens del mes
    var apis: [Line] = []       // OpenAI, Soniox…: gasto y tokens del mes
    var apiByName: [String: Double] = [:]   // gasto del mes en $ por API (nombre en minúsculas)

    func apiUSD(_ name: String) -> Double? {
        apiByName.first { $0.key.contains(name) }?.value
    }
}

enum MoniAPI {
    static let base = "http://127.0.0.1:8765"
    static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/companero/token")
    }
    static var token: String? {
        (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var available: Bool { token?.isEmpty == false }
    static var panelURL: URL? { token.flatMap { URL(string: base + "/panel?token=" + $0) } }

    enum MoniError: LocalizedError {
        case noToken, down, http(Int), badData
        var errorDescription: String? {
            switch self {
            case .noToken: return "No encuentro el cerebro de Moni en este Mac."
            case .down: return "El cerebro de Moni no responde."
            case .http(let c): return "El cerebro de Moni respondió con un error \(c)."
            case .badData: return "Respuesta inesperada del cerebro de Moni."
            }
        }
    }

    static func fetch(_ completion: @escaping (Result<MonthSpend, Error>) -> Void) {
        guard let t = token, !t.isEmpty else { return completion(.failure(MoniError.noToken)) }
        var req = URLRequest(url: URL(string: base + "/gastos")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if err != nil { return completion(.failure(MoniError.down)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let data = data else { return completion(.failure(MoniError.http(code))) }
            completion(Result { try parse(data) })
        }.resume()
    }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    static func parse(_ data: Data) throws -> MonthSpend {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = o["totales"] as? [String: Any] else { throw MoniError.badData }
        var s = MonthSpend()
        s.month = o["mes"] as? String ?? ""
        s.spentEUR = num(t["real_eur_hasta_hoy"]); s.forecastEUR = num(t["real_eur_mes_previsto"])
        s.tokens = num(t["tokens"]); s.tokensApps = num(t["tokens_suscripciones"]); s.tokensAPIs = num(t["tokens_apis"])
        s.savedEUR = num(t["ahorro_suscripciones_eur"])
        let moni = o["moni"] as? [String: Any] ?? [:]
        s.apiUSD = num(moni["usd"]); s.budgetUSD = (moni["presupuesto_usd"] as? NSNumber)?.doubleValue
        for (key, name) in [("claude", "Claude Code"), ("codex", "Codex"), ("hermes", "Hermes")] {
            let a = o[key] as? [String: Any] ?? [:]
            s.apps.append(.init(id: key, name: name, detail: tokensText(num(a["tokens"]))))
        }
        for a in o["apis"] as? [[String: Any]] ?? [] {
            let usd = num(a["usd"]), tok = num(a["tokens"]), min = num(a["minutos"])
            if let n = a["nombre"] as? String { s.apiByName[n.lowercased()] = usd }
            guard usd > 0 || tok > 0 else { continue }
            var d = String(format: "%.2f $", usd)
            if tok > 0 { d += " · " + tokensText(tok) }
            if min >= 1 { d += " · \(Int(min.rounded())) min" }
            s.apis.append(.init(id: a["nombre"] as? String ?? UUID().uuidString, name: a["nombre"] as? String ?? "API", detail: d))
        }
        return s
    }
}

func tokensText(_ n: Double) -> String {
    if n >= 1e9 { return String(format: "%.1f mil M", n / 1e9) }
    if n >= 1e6 { return String(format: "%.0f M", n / 1e6) }
    if n >= 1e3 { return String(format: "%.0f mil", n / 1e3) }
    return "\(Int(n))"
}

func euros(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "es_ES"); f.numberStyle = .currency; f.currencyCode = "EUR"
    f.maximumFractionDigits = v >= 100 ? 0 : 2
    return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f €", v)
}

// MARK: - APIs de pago: saldo y gasto

/// Claves guardadas en el Llavero de este Mac (cuenta = nombre del servicio)
enum Secret {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainStore.service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    static func save(_ value: String, _ account: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// Número que puede venir como número o como texto ("12.40")
func dnum(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func dollars(_ v: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "es_ES")
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.currencySymbol = "$"
    f.minimumFractionDigits = v >= 100 ? 0 : 2
    f.maximumFractionDigits = v >= 100 ? 0 : 2
    return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f $", v)
}

/// Saldo y gasto de una API de pago
struct Wallet: Equatable {
    var available: Double?      // saldo que queda
    var used: Double?           // gastado del saldo cargado (acumulado)
    var granted: Double?        // total cargado
    var month: Double?          // gastado este mes
    var budget: Double?         // tope del mes, si lo hay
    var source = ""

    /// 0–100: cuánto se ha consumido. Decide el humor del personaje.
    var level: Double? {
        if let g = granted, g > 0, let u = used { return min(100, max(0, 100 * u / g)) }
        if let a = available, let u = used, a + u > 0 { return min(100, max(0, 100 * u / (a + u))) }
        if let b = budget, b > 0, let m = month { return min(100, max(0, 100 * m / b)) }
        return nil
    }
}

enum APIError: LocalizedError {
    case noKey(String), needLogin(String), http(String, Int), badData(String), badKey
    var errorDescription: String? {
        switch self {
        case .noKey(let s): return "Falta la clave de \(s): clic derecho › Clave de la API de \(s)…"
        case .needLogin(let s): return "Inicia sesión en \(s) para ver el saldo: clic derecho › Iniciar sesión en \(s)…"
        case .http(let s, let c): return "\(s) respondió con un error \(c)."
        case .badData(let s): return "Respuesta inesperada de \(s)."
        case .badKey: return "Esa es una clave de proyecto. Soniox pide una de organización (snx_org_…): Settings › Organization API keys."
        }
    }
}

/// Soniox: saldo prepago y gasto del mes con la API oficial (clave guardada en el Llavero)
enum SonioxAPI {
    static let account = "soniox"
    static var key: String? { Secret.read(account) }

    static func get(_ path: String, _ key: String, _ done: @escaping (Result<[String: Any], Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.soniox.com/v1/" + path)!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { return done(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return done(.failure(APIError.http("Soniox", code)))
            }
            done(.success(o))
        }.resume()
    }

    static func fetch(_ done: @escaping (Result<Wallet, Error>) -> Void) {
        guard let k = key else { return done(.failure(APIError.noKey("Soniox"))) }
        if k.hasPrefix("snx_proj_") { return done(.failure(APIError.badKey)) }
        get("organization/balance", k) { r1 in
            get("organization/usage/monthly", k) { r2 in
                var w = Wallet(source: "Soniox")
                if case .success(let b) = r1 {
                    w.available = dnum(b["available_balance_usd"])
                    w.used = dnum(b["used_balance_usd"])
                    if let a = w.available, let u = w.used { w.granted = a + u }
                }
                if case .success(let m) = r2 {
                    w.month = dnum(m["usage_usd"])
                    w.budget = dnum(m["monthly_budget_usd"])
                }
                if w.available == nil && w.month == nil {
                    if case .failure(let e) = r1 { return done(.failure(e)) }
                    return done(.failure(APIError.badData("Soniox")))
                }
                done(.success(w))
            }
        }
    }
}

/// OpenAI no da el saldo con una clave de API: se lee desde una sesión de platform.openai.com
/// iniciada dentro de la app (lo mismo que ve la página de facturación). Es una vía no oficial.
final class PlatformSession: NSObject, WKNavigationDelegate {
    static let shared = PlatformSession()

    private var web: WKWebView?
    private var ready = false
    private var waiters: [() -> Void] = []
    private var loginWindow: NSWindow?
    private var loginWeb: WKWebView?
    private var pollTimer: Timer?
    var onLogin: (() -> Void)?

    static let findToken = """
    const findTok = () => {
      let t = null;
      for (const st of [window.localStorage, window.sessionStorage]) {
        for (let i = 0; i < st.length; i++) {
          const v = st.getItem(st.key(i)) || '';
          if (v.indexOf('access_token') < 0) continue;
          try { const o = JSON.parse(v); const c = (o && o.body && o.body.access_token) || (o && o.access_token); if (c) t = c; } catch (e) {}
        }
      }
      return t;
    };
    let tok = findTok();
    if (!tok) {
      try { const s = await fetch('/api/auth/session', {credentials: 'include'}); if (s.status === 200) { const j = await s.json(); tok = j.accessToken || null; } } catch (e) {}
    }
    """

    static let walletJS = findToken + """
    if (!tok) return {status: 401, grants: '', usage: ''};
    const h = {'Authorization': 'Bearer ' + tok};
    let gs = 0, gb = '';
    try { const g = await fetch('https://api.openai.com/dashboard/billing/credit_grants', {headers: h}); gs = g.status; gb = await g.text(); } catch (e) { gs = -1; gb = String(e); }
    const d = new Date();
    const start = d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0') + '-01';
    const end = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
    let ub = '';
    try { const u = await fetch('https://api.openai.com/dashboard/billing/usage?start_date=' + start + '&end_date=' + end, {headers: h}); if (u.status === 200) ub = await u.text(); } catch (e) {}
    return {status: gs, grants: gb, usage: ub};
    """

    private func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: cfg)
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
        w.load(URLRequest(url: URL(string: "https://platform.openai.com/")!))
    }

    private func flush() { let w = waiters; waiters = []; w.forEach { $0() } }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        // La web monta la sesión con JavaScript: se le da un momento antes de consultar
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.ready = true; self.flush() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView) }
    private func failed(_ webView: WKWebView) {
        guard webView === web else { return }
        web = nil; ready = false; flush()
    }

    func fetchWallet(_ done: @escaping (Result<Wallet, Error>) -> Void) {
        DispatchQueue.main.async {
            self.whenReady {
                guard let w = self.web else { return done(.failure(APIError.http("OpenAI", 0))) }
                w.callAsyncJavaScript(PlatformSession.walletJS, arguments: [:], in: nil, in: .page) { result in
                    guard case .success(let v) = result, let d = v as? [String: Any] else {
                        return done(.failure(APIError.badData("OpenAI")))
                    }
                    let status = (d["status"] as? NSNumber)?.intValue ?? 0
                    var wallet = Wallet(source: "OpenAI")
                    if status == 200, let g = (d["grants"] as? String)?.data(using: .utf8),
                       let o = (try? JSONSerialization.jsonObject(with: g)) as? [String: Any] {
                        wallet.granted = dnum(o["total_granted"])
                        wallet.used = dnum(o["total_used"])
                        wallet.available = dnum(o["total_available"]) ?? dnum(o["total_paid_available"])
                    }
                    if let u = (d["usage"] as? String)?.data(using: .utf8),
                       let o = (try? JSONSerialization.jsonObject(with: u)) as? [String: Any],
                       let cents = dnum(o["total_usage"]) {
                        wallet.month = cents / 100
                    }
                    if wallet.available == nil && wallet.month == nil {
                        if status == 401 || status == 403 { return done(.failure(APIError.needLogin("OpenAI"))) }
                        return done(.failure(APIError.http("OpenAI", status)))
                    }
                    done(.success(wallet))
                }
            }
        }
    }

    /// Ventana para iniciar sesión en platform.openai.com. Se cierra sola al detectar la sesión.
    func showLogin() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let w = self.loginWindow, w.isVisible { return w.makeKeyAndOrderFront(nil) }
            let web = self.makeWeb()
            web.load(URLRequest(url: URL(string: "https://platform.openai.com/login")!))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            win.title = "Inicia sesión en OpenAI · Uso de Claude"
            win.contentView = web
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.center()
            self.loginWindow = win
            self.loginWeb = web
            win.makeKeyAndOrderFront(nil)
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] t in
                guard let self = self, let lw = self.loginWeb, self.loginWindow?.isVisible == true else {
                    t.invalidate(); self?.loginWeb = nil; return
                }
                guard let path = lw.url?.path, !path.hasPrefix("/login"), !path.hasPrefix("/auth") else { return }
                lw.callAsyncJavaScript(PlatformSession.findToken + "\nreturn tok ? 1 : 0;", arguments: [:], in: nil, in: .page) { r in
                    guard case .success(let v) = r, (v as? NSNumber)?.intValue == 1 else { return }
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
    @Published var spend: MonthSpend?
    @Published var spendError: String?
    @Published var showSpend: Bool = UserDefaults.standard.object(forKey: "showSpend") as? Bool ?? MoniAPI.available {
        didSet {
            UserDefaults.standard.set(showSpend, forKey: "showSpend")
            if showSpend { refreshSpend() }
            DispatchQueue.main.async { self.onChange?() }
        }
    }
    @Published var updating = false
    let version = Updater.installed.map { String($0.prefix(7)) } ?? "local"
    @Published var openai: Wallet?
    @Published var openaiError: String?
    @Published var soniox: Wallet?
    @Published var sonioxError: String?

    var onChange: (() -> Void)?
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

    private var lastAPIFetch = Date.distantPast

    /// Saldo y gasto de las APIs de pago: cambian despacio, como mucho cada 10 minutos (o al tocar el widget)
    func refreshAPIs(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastAPIFetch) > 590 else { return }
        lastAPIFetch = Date()
        SonioxAPI.fetch { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let w): self.soniox = w; self.sonioxError = nil
                case .failure(let e): self.sonioxError = e.localizedDescription
                }
                self.onChange?()
            }
        }
        PlatformSession.shared.fetchWallet { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let w): self.openai = w; self.openaiError = nil
                case .failure(let e): self.openaiError = e.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    func refreshGPT() {
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

    private var lastSpendFetch = Date.distantPast

    /// Los gastos cambian despacio y calcularlos cuesta un poco al cerebro: como mucho cada 10 minutos.
    func refreshSpend(force: Bool = false) {
        guard showSpend, force || Date().timeIntervalSince(lastSpendFetch) > 590 else { return }
        lastSpendFetch = Date()
        MoniAPI.fetch { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let s): self.spend = s; self.spendError = nil
                case .failure(let e): self.spendError = e.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    func refresh() {
        refreshGPT()
        refreshSpend()
        refreshAPIs()
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

// MARK: - Servicios

enum Service: String, CaseIterable, Codable, Identifiable {
    case claude, chatgpt, openai, soniox
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .openai: return "API OpenAI"
        case .soniox: return "API Soniox"
        }
    }
    var short: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "GPT"
        case .openai: return "OpenAI"
        case .soniox: return "Soniox"
        }
    }
    var sprite: String {
        switch self {
        case .claude: return "claude"
        case .chatgpt, .openai: return "chatgpt"
        case .soniox: return "soniox"
        }
    }
    var isAPI: Bool { self == .openai || self == .soniox }
    var nsColor: NSColor {
        switch self {
        case .claude: return NSColor(red: 0.96, green: 0.52, blue: 0.30, alpha: 1)
        case .chatgpt, .openai: return NSColor(red: 0.42, green: 0.86, blue: 0.72, alpha: 1)
        case .soniox: return NSColor(red: 0.33, green: 0.68, blue: 1.0, alpha: 1)
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

struct CardLine: Identifiable {
    let id: String
    let label: String
    let percent: Double?       // con barra si no es nil
    let value: String
    let reset: Date?
    let window: TimeInterval?
    var shortLabel: String? = nil
    var shortValue: String? = nil
}

/// Lo que se pinta de cada servicio, sea suscripción o API
struct Card {
    let service: Service
    var level: Double?         // 0–100, para el humor
    var headline = "–"         // número grande
    var short = "–"            // número para formatos pequeños
    var caption = ""
    var compact = ""           // una línea con lo esencial
    var lines: [CardLine] = []
    var error: String?
    var hasData = false
    var exhaustedUntil: Date?
}

func pctText(_ p: Double) -> String { "\(Int(p.rounded())) %" }

extension UsageModel {
    func card(_ s: Service) -> Card {
        switch s {
        case .claude: return subscriptionCard(s, rows, error)
        case .chatgpt: return subscriptionCard(s, gptRows, gptError)
        case .openai: return apiCard(s, openai ?? moniWallet("openai"), openaiError)
        case .soniox: return apiCard(s, soniox ?? moniWallet("soniox"), sonioxError)
        }
    }

    /// Si no hay saldo, al menos el gasto del mes que calcula el cerebro de Moni
    func moniWallet(_ name: String) -> Wallet? {
        guard let usd = spend?.apiUSD(name) else { return nil }
        return Wallet(month: usd, source: "Moni")
    }

    func subscriptionCard(_ s: Service, _ rows: [UsageRow], _ error: String?) -> Card {
        var c = Card(service: s)
        c.error = error
        guard !rows.isEmpty else { c.short = "–"; c.caption = "sin datos"; return c }
        c.hasData = true
        let session = rows.first { $0.window < 6 * 86400 }
        let week = rows.first { $0.window >= 6 * 86400 }
        c.level = rows.map(\.percent).max()
        let main = session ?? week!
        c.headline = pctText(main.percent)
        c.short = "\(Int(main.percent.rounded()))%"
        c.caption = session != nil ? "de la sesión (5 h)" : "de la semana"
        c.compact = "sem \(week.map { "\(Int($0.percent.rounded()))%" } ?? "–")  ·  5h \(session.map { "\(Int($0.percent.rounded()))%" } ?? "–")"
        c.lines = rows.map { CardLine(id: $0.id, label: $0.label, percent: $0.percent, value: pctText($0.percent),
                                      reset: $0.resetsAt, window: $0.window,
                                      shortLabel: $0.label.replacingOccurrences(of: " · todos los modelos", with: "")) }
        if let full = rows.first(where: { $0.percent >= 100 }) { c.exhaustedUntil = full.resetsAt }
        return c
    }

    func apiCard(_ s: Service, _ w: Wallet?, _ error: String?) -> Card {
        var c = Card(service: s)
        c.error = error
        guard let w = w else { c.caption = "sin datos"; return c }
        c.hasData = true
        c.level = w.level
        if let a = w.available {
            c.headline = dollars(a); c.short = dollars(a); c.caption = "de saldo"
        } else if let m = w.month {
            c.headline = dollars(m); c.short = dollars(m); c.caption = "gastado este mes"
        }
        var parts: [String] = []
        if let a = w.available { parts.append(dollars(a)) }
        if let m = w.month { parts.append("mes \(dollars(m))") }
        c.compact = parts.joined(separator: " · ")
        if let g = w.granted, g > 0, let u = w.used {
            c.lines.append(CardLine(id: "saldo", label: "Consumido del saldo", percent: min(100, 100 * u / g),
                                    value: "\(dollars(u)) de \(dollars(g))", reset: nil, window: nil,
                                    shortLabel: "Consumido", shortValue: pctText(min(100, 100 * u / g))))
        }
        if let m = w.month {
            if let b = w.budget, b > 0 {
                c.lines.append(CardLine(id: "mes", label: "Gastado este mes", percent: min(100, 100 * m / b),
                                        value: "\(dollars(m)) de \(dollars(b))", reset: nil, window: nil,
                                        shortLabel: "Mes", shortValue: dollars(m)))
            } else {
                c.lines.append(CardLine(id: "mes", label: "Gastado este mes", percent: nil, value: dollars(m), reset: nil, window: nil,
                                        shortLabel: "Mes"))
            }
        }
        if w.available == nil, w.source == "Moni" {
            c.lines.append(CardLine(id: "nota", label: "Saldo", percent: nil, value: "sin conectar", reset: nil, window: nil))
        }
        return c
    }
}

// MARK: Personajes (dibujos de Jorge, 4 estados × 3 fotogramas)

/// En las capturas de prueba no hay cristal real: se pinta un fondo oscuro
var renderingShots = false

enum Sprites {
    static var cache: [String: NSImage] = [:]

    static func image(_ who: String, row: Int, frame: Int) -> NSImage? {
        let name = "\(who)-\(row)-\(frame)"
        if let i = cache[name] { return i }
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("sprites"),
                    Updater.support.appendingPathComponent("sprites"),
                    ProcessInfo.processInfo.environment["WIDGET_SPRITES"].map { URL(fileURLWithPath: $0) }].compactMap { $0 }
        for d in dirs {
            if let i = NSImage(contentsOf: d.appendingPathComponent(name + ".png")) { cache[name] = i; return i }
        }
        return nil
    }

    /// 0 tranquilo · 1 preocupado · 2 sudando · 3 pánico
    static func row(_ level: Double?) -> Int {
        guard let l = level else { return 0 }
        if l >= 90 { return 3 }
        if l >= 75 { return 2 }
        if l >= 50 { return 1 }
        return 0
    }
}

func phrase(_ c: Card, _ now: Date) -> String {
    if !c.hasData { return c.service.isAPI ? "Sin datos de la API" : "Sin datos todavía" }
    if let r = c.exhaustedUntil { return "Fuera de combate · vuelve a las \(hourText(r, now: now))" }
    let row = Sprites.row(c.level)
    let list: [String]
    if c.service.isAPI {
        list = [["Cartera sana", "Hay saldo de sobra", "Gasta tranquilo"],
                ["Ojo con el gasto", "Gasta con cabeza"],
                ["Recarga pronto", "El saldo baja rápido"],
                ["¡Recarga ya!", "¡Me quedo sin saldo!"]][row]
    } else {
        list = [["A tope de energía", "Ritmo de crucero", "Pídeme lo que quieras"],
                ["Ojo, que baja", "Dosifícame un poco"],
                ["Esto se acaba", "Solo lo importante"],
                ["¡Últimas gotas!", "¡Que me apago!"]][row]
    }
    return list[Int(now.timeIntervalSinceReferenceDate / 90) % list.count]
}

struct SpriteView: View {
    let service: Service
    let level: Double?
    let size: CGFloat

    var body: some View {
        let row = Sprites.row(level)
        let interval = [0.55, 0.4, 0.26, 0.17][row]
        TimelineView(.periodic(from: Date(), by: interval)) { ctx in
            let f = Int(ctx.date.timeIntervalSinceReferenceDate / interval) % 3
            Group {
                if let img = Sprites.image(service.sprite, row: row, frame: f) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Circle().fill(service.color)
                        .overlay(Text(String(service.short.prefix(1)))
                            .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                            .foregroundColor(.black.opacity(0.7)))
                        .padding(size * 0.08)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: Formatos

enum WidgetLayout: String, CaseIterable, Identifiable, Codable {
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

/// Ajustes de cada widget: qué servicios muestra, formato, tamaño y si va siempre encima
struct PanelConfig: Codable, Equatable {
    var id = UUID().uuidString
    var services: [Service] = Service.allCases
    var layout: WidgetLayout = .normal
    var zoom: Double = 1
    var onTop = true
}

final class PanelSettings: ObservableObject {
    @Published var cfg: PanelConfig {
        didSet { onSave?(); DispatchQueue.main.async { self.onChange?() } }
    }
    var onSave: (() -> Void)?
    var onChange: (() -> Void)?
    init(_ c: PanelConfig) { cfg = c }

    static let zoomSteps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    var canZoomIn: Bool { cfg.zoom < (PanelSettings.zoomSteps.last ?? 2) - 0.001 }
    var canZoomOut: Bool { cfg.zoom > (PanelSettings.zoomSteps.first ?? 1) + 0.001 }
    func zoomIn() { if let n = PanelSettings.zoomSteps.first(where: { $0 > cfg.zoom + 0.001 }) { cfg.zoom = n } }
    func zoomOut() { if let n = PanelSettings.zoomSteps.last(where: { $0 < cfg.zoom - 0.001 }) { cfg.zoom = n } }

    func toggle(_ s: Service) {
        if cfg.services.contains(s) {
            if cfg.services.count > 1 { cfg.services.removeAll { $0 == s } }
        } else {
            cfg.services = Service.allCases.filter { cfg.services.contains($0) || $0 == s }
        }
    }
}

// MARK: Barras y líneas

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

struct LineView: View {
    let line: CardLine
    let now: Date
    var k: CGFloat = 1
    var showReset = true
    var short = false

    var pace: Double? {
        guard let r = line.reset, let w = line.window else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0, left <= w else { return nil }
        return 1 - left / w
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * k) {
            HStack(alignment: .firstTextBaseline) {
                Text(short ? (line.shortLabel ?? line.label) : line.label)
                    .font(.system(size: 11 * k, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(short ? (line.shortValue ?? line.value) : line.value)
                    .font(.system(size: (line.percent != nil && line.window != nil ? 17 : 13) * k, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(line.percent.map { usageColor($0) } ?? .white.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if let p = line.percent { UsageBar(percent: p, pace: pace, height: 6 * k) }
            if showReset, let r = line.reset {
                Text(resetText(r, now: now))
                    .font(.system(size: 10 * k))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

// MARK: Botones del widget

struct WidgetActions {
    let refresh: () -> Void
    let minimize: () -> Void
    let newWidget: () -> Void
    let closeWidget: () -> Void
    let canClose: () -> Bool
    let toggleMenuBar: () -> Void
    let menuBarOn: () -> Bool
    let loginClaude: () -> Void
    let loginOpenAI: () -> Void
    let sonioxKey: () -> Void
    let setKey: () -> Void
    let clearKey: () -> Void
    let quit: () -> Void
}

struct ControlsRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct Controls: View {
    @ObservedObject var settings: PanelSettings
    let actions: WidgetActions
    let vertical: Bool
    let onRect: (CGRect) -> Void

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
        button("arrow.clockwise", "Actualizar ahora") { actions.refresh() }
        button("minus", "Más pequeño", enabled: settings.canZoomOut) { settings.zoomOut() }
        button("plus", "Más grande", enabled: settings.canZoomIn) { settings.zoomIn() }
        button("menubar.arrow.up.rectangle", "Minimizar en la barra de menús") { actions.minimize() }
    }

    var body: some View {
        Group {
            if vertical { VStack(spacing: 4) { buttons } } else { HStack(spacing: 4) { buttons } }
        }
        .background(GeometryReader { g in Color.clear.preference(key: ControlsRectKey.self, value: g.frame(in: .global)) })
        .onPreferenceChange(ControlsRectKey.self) { onRect($0) }
    }
}

// MARK: El widget

struct WidgetView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: PanelSettings
    let actions: WidgetActions
    let onControlsRect: (CGRect) -> Void

    var services: [Service] { settings.cfg.services }
    var z: CGFloat { CGFloat(settings.cfg.zoom) }
    var controlsVertical: Bool { [.compacto, .horizontal].contains(settings.cfg.layout) }
    var controlsAlignment: Alignment {
        settings.cfg.layout == .mini ? .trailing : (controlsVertical ? .trailing : .topTrailing)
    }

    func tint(_ level: Double?) -> Color {
        guard let l = level else { return Color(red: 0.45, green: 0.70, blue: 0.95) }
        return usageColor(l)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 20)) { ctx in
            let radius: CGFloat = (settings.cfg.layout == .mini ? 23 : 22) * z
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let worst = services.compactMap { model.card($0).level }.max()
            content(ctx.date)
                .fixedSize()
                .background(
                    ZStack {
                        if renderingShots { Color(red: 0.13, green: 0.12, blue: 0.13) } else { GlassBackground(radius: radius) }
                        LinearGradient(colors: [tint(worst).opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                    }
                    .clipShape(shape)
                )
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .white.opacity(0.22)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                .overlay(shape.stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                .overlay(alignment: controlsAlignment) {
                    Controls(settings: settings, actions: actions, vertical: controlsVertical, onRect: onControlsRect)
                        .padding(controlsVertical ? 8 : 9)
                }
                .padding(1)
                .contextMenu { menu }
        }
    }

    func statusText(_ now: Date) -> String {
        if model.updating { return "instalando versión nueva…" }
        if model.loading { return "actualizando…" }
        guard let d = model.lastUpdate else { return "" }
        return "Actualizado \(hourText(d, now: now)) · toca para actualizar"
    }

    func headColor(_ c: Card) -> Color { c.hasData ? usageColor(c.level ?? 0) : .white.opacity(0.5) }

    // Tarjeta completa de un servicio
    func cardView(_ c: Card, _ now: Date, k: CGFloat, sprite: CGFloat = 64) -> some View {
        VStack(alignment: .leading, spacing: 7 * k) {
            HStack(alignment: .center, spacing: 10 * k) {
                SpriteView(service: c.service, level: c.level, size: sprite * k)
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text(c.service.title.uppercased())
                        .font(.system(size: 9.5 * k, weight: .heavy)).tracking(0.8)
                        .foregroundColor(c.service.color)
                    Text(phrase(c, now))
                        .font(.system(size: 12 * k, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(alignment: .firstTextBaseline, spacing: 4 * k) {
                        Text(c.headline)
                            .font(.system(size: 30 * k, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(headColor(c))
                            .lineLimit(1).fixedSize()
                        Text(c.caption)
                            .font(.system(size: 10 * k, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2).minimumScaleFactor(0.8)
                    }
                }
            }
            if !c.hasData, let e = c.error {
                Text(e).font(.system(size: 10.5 * k)).foregroundColor(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(c.lines) { LineView(line: $0, now: now, k: k) }
            if c.hasData, let e = c.error {
                Text("⚠︎ " + e).font(.system(size: 9.5 * k)).foregroundColor(Color(red: 1, green: 0.7, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func separator() -> some View { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }

    @ViewBuilder
    func content(_ now: Date) -> some View {
        let cards = services.map { model.card($0) }
        switch settings.cfg.layout {
        case .mini:
            HStack(spacing: 10 * z) {
                ForEach(cards, id: \.service) { c in
                    HStack(spacing: 3 * z) {
                        SpriteView(service: c.service, level: c.level, size: 34 * z)
                        Text(c.short)
                            .font(.system(size: 17 * z, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(headColor(c))
                    }
                }
            }
            .padding(.vertical, 5 * z)
            .padding(.leading, 8 * z)
            .padding(.trailing, 8 * z + 86)

        case .compacto:
            VStack(alignment: .leading, spacing: 7 * z) {
                ForEach(cards, id: \.service) { c in
                    HStack(spacing: 8 * z) {
                        SpriteView(service: c.service, level: c.level, size: 40 * z)
                        VStack(alignment: .leading, spacing: 1 * z) {
                            Text(c.service.title)
                                .font(.system(size: 10 * z, weight: .heavy))
                                .foregroundColor(c.service.color)
                            Text(c.hasData ? c.compact : (c.error ?? "sin datos"))
                                .font(.system(size: (c.hasData ? 14 : 10) * z, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(c.hasData ? headColor(c) : .white.opacity(0.6))
                                .lineLimit(2).minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10 * z)
            .padding(.trailing, 28)
            .frame(width: 250 * z + 28)

        case .normal, .grande:
            let k: CGFloat = (settings.cfg.layout == .grande ? 1.3 : 1) * z
            VStack(alignment: .leading, spacing: 12 * k) {
                ForEach(Array(cards.enumerated()), id: \.element.service) { item in
                    if item.offset > 0 { separator() }
                    cardView(item.element, now, k: k)
                }
                if model.showSpend { spendSection(k: k) }
                Text(statusText(now))
                    .font(.system(size: 9 * k))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14 * k)
            .padding(.top, 12)
            .frame(width: 300 * k)

        case .horizontal:
            HStack(alignment: .top, spacing: 14 * z) {
                ForEach(Array(cards.enumerated()), id: \.element.service) { item in
                    if item.offset > 0 { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.5) }
                    cardView(item.element, now, k: 0.85 * z, sprite: 58).frame(width: 215 * z)
                }
            }
            .padding(14 * z)
            .padding(.trailing, 26)

        case .vertical:
            VStack(spacing: 12 * z) {
                ForEach(Array(cards.enumerated()), id: \.element.service) { item in
                    let c = item.element
                    if item.offset > 0 { separator() }
                    VStack(spacing: 3 * z) {
                        SpriteView(service: c.service, level: c.level, size: 62 * z)
                        Text(c.service.title.uppercased())
                            .font(.system(size: 9 * z, weight: .heavy)).tracking(0.8)
                            .foregroundColor(c.service.color)
                        Text(c.headline)
                            .font(.system(size: 26 * z, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundColor(headColor(c))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(c.hasData ? c.caption : (c.error ?? ""))
                            .font(.system(size: 9.5 * z)).foregroundColor(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6 * z) {
                            ForEach(c.lines) { LineView(line: $0, now: now, k: 0.85 * z, showReset: false, short: true) }
                        }
                    }
                }
                Text(statusText(now)).font(.system(size: 8.5 * z)).foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(14 * z)
            .padding(.top, 14)
            .frame(width: 180 * z)
        }
    }

    // Gastos del mes (cerebro de Moni)
    @ViewBuilder
    func spendSection(k: CGFloat) -> some View {
        if model.spend != nil || model.spendError != nil {
            VStack(alignment: .leading, spacing: 6 * k) {
                separator()
                Text("GASTOS DEL MES")
                    .font(.system(size: 9 * k, weight: .bold)).tracking(0.8)
                    .foregroundColor(.white.opacity(0.45))
                if let s = model.spend {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(euros(s.spentEUR))
                            .font(.system(size: 22 * k, weight: .bold, design: .rounded))
                            .monospacedDigit().foregroundColor(.white)
                        Text("previsto \(euros(s.forecastEUR))")
                            .font(.system(size: 10 * k)).foregroundColor(.white.opacity(0.55))
                    }
                    HStack {
                        Text("Tokens del mes").font(.system(size: 11 * k)).foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Text(tokensText(s.tokens)).font(.system(size: 11 * k, weight: .medium)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                if let e = model.spendError, model.spend == nil {
                    Text(e).font(.system(size: 10 * k)).foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    @ViewBuilder
    var menu: some View {
        Button("Actualizar ahora") { actions.refresh() }
        Menu("Qué muestra este widget") {
            ForEach(Service.allCases) { s in
                Button((settings.cfg.services.contains(s) ? "✓ " : "") + s.title) { settings.toggle(s) }
            }
        }
        Menu("Formato") {
            ForEach(WidgetLayout.allCases) { l in
                Button((settings.cfg.layout == l ? "✓ " : "") + l.title) { settings.cfg.layout = l }
            }
            Divider()
            Button("Tamaño original") { settings.cfg.zoom = 1 }
        }
        Button("Nuevo widget") { actions.newWidget() }
        if actions.canClose() { Button("Cerrar este widget") { actions.closeWidget() } }
        Button(settings.cfg.onTop ? "✓ Siempre por encima" : "Siempre por encima") { settings.cfg.onTop.toggle() }
        Button(actions.menuBarOn() ? "✓ Mostrar en la barra de menús" : "Mostrar en la barra de menús") { actions.toggleMenuBar() }
        Button("Minimizar todo en la barra de menús") { actions.minimize() }
        Divider()
        Button("Iniciar sesión en claude.ai…") { actions.loginClaude() }
        Button("Iniciar sesión en OpenAI (saldo de la API)…") { actions.loginOpenAI() }
        Button("Clave de la API de Soniox…") { actions.sonioxKey() }
        Menu("Más opciones de Claude") {
            Button("Configurar sessionKey de claude.ai…") { actions.setKey() }
            Button("Borrar sessionKey") { actions.clearKey() }
            if !model.source.isEmpty { Button("Origen: \(model.source)") {}.disabled(true) }
        }
        if MoniAPI.available {
            Button(model.showSpend ? "✓ Gastos del mes (Moni)" : "Gastos del mes (Moni)") { model.showSpend.toggle() }
            if let url = MoniAPI.panelURL { Button("Abrir panel de gastos") { NSWorkspace.shared.open(url) } }
        }
        Divider()
        Button("Buscar actualizaciones") { model.checkForUpdate() }
        Button("Versión \(model.version) · mostrar todo: ⌃⌥⌘U") {}.disabled(true)
        Divider()
        Button("Salir") { actions.quit() }
    }
}

// MARK: - Ventana flotante

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
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

/// Arrastrar mueve el widget; un toque sin mover lo actualiza; los botones funcionan como botones
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var controlsRect: CGRect = .zero
    var onTap: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        if controlsRect.insetBy(dx: -3, dy: -3).contains(point) {
            super.mouseDown(with: event)
            return
        }
        let before = window?.frame.origin
        window?.performDrag(with: event)
        if let b = before, let a = window?.frame.origin, abs(a.x - b.x) < 2, abs(a.y - b.y) < 2 {
            onTap?()
        }
    }
}

final class PanelController: NSObject {
    let settings: PanelSettings
    let panel = FloatingPanel()
    var hosting: DraggableHostingView<WidgetView>!
    var moving = false
    weak var app: AppDelegate?

    var posKey: String { "pos." + settings.cfg.id }

    init(cfg: PanelConfig, model: UsageModel, app: AppDelegate, actions: (PanelController) -> WidgetActions, index: Int) {
        settings = PanelSettings(cfg)
        self.app = app
        super.init()
        let acts = actions(self)
        hosting = DraggableHostingView(rootView: WidgetView(model: model, settings: settings, actions: acts,
                                                           onControlsRect: { [weak self] r in self?.hosting?.controlsRect = r }))
        hosting.onTap = { acts.refresh() }
        panel.contentView = hosting
        panel.setContentSize(fitting())
        settings.onSave = { [weak app] in app?.saveConfigs() }
        settings.onChange = { [weak self] in self?.applyLevel(); self?.contentChanged() }
        applyLevel()
        restorePosition(index: index)
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: panel)
    }

    func fitting() -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let s = hosting.fittingSize
        return NSSize(width: max(s.width, 60), height: max(s.height, 40))
    }

    func applyLevel() {
        panel.level = settings.cfg.onTop ? .statusBar : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func contentChanged() {
        for delay in [0.0, 0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.setSizeKeepingTopLeft(self.fitting())
            }
        }
    }

    func setSizeKeepingTopLeft(_ size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        var f = panel.frame
        if abs(f.width - size.width) < 0.5 && abs(f.height - size.height) < 0.5 { return }
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        moving = true
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
        moving = false
    }

    static func isOnScreen(_ f: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(f.insetBy(dx: 20, dy: 20)) }
    }

    func restorePosition(index: Int) {
        let d = UserDefaults.standard
        if let p = d.array(forKey: posKey) as? [Double], p.count == 2 {
            let size = panel.frame.size
            let f = NSRect(x: p[0], y: p[1] - size.height, width: size.width, height: size.height)
            if PanelController.isOnScreen(f) { return setOrigin(f.origin) }
        }
        placeDefault(index: index)
    }

    func placeDefault(index: Int = 0) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let off = CGFloat(index) * 30
        setOrigin(NSPoint(x: vf.maxX - size.width - 20 - off, y: vf.maxY - size.height - 20 - off))
        savePosition()
    }

    func setOrigin(_ p: NSPoint) { moving = true; panel.setFrameOrigin(p); moving = false }

    func savePosition() { UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.maxY)], forKey: posKey) }

    @objc func moved() { if !moving { savePosition() } }

    func show() {
        if !PanelController.isOnScreen(panel.frame) { placeDefault() }
        panel.orderFrontRegardless()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        panel.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: posKey)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel()
    var panels: [PanelController] = []

    var menuBarOn: Bool {
        get { UserDefaults.standard.bool(forKey: "menuBar") }
        set { UserDefaults.standard.set(newValue, forKey: "menuBar") }
    }
    var minimized: Bool {
        get { UserDefaults.standard.bool(forKey: "minimized") }
        set { UserDefaults.standard.set(newValue, forKey: "minimized") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for cfg in loadConfigs() { addPanel(cfg) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.onChange = { [weak self] in
            self?.panels.forEach { $0.contentChanged() }
            self?.updateStatusItem()
        }
        WebSession.shared.onLogin = { [weak self] in self?.model.refresh() }
        PlatformSession.shared.onLogin = { [weak self] in self?.model.refreshAPIs(force: true) }
        registerHotKey()
        if minimized { minimize() } else { panels.forEach { $0.show() } }
        updateStatusItem()
        if ProcessInfo.processInfo.environment["WIDGET_SELFTEST"] != nil { return selfTest() }
        model.start()
    }

    // MARK: Widgets

    /// Lee los widgets guardados; la primera vez convierte los ajustes de la versión anterior
    func loadConfigs() -> [PanelConfig] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "panels.v2"),
           let list = try? JSONDecoder().decode([PanelConfig].self, from: data), !list.isEmpty {
            return list
        }
        var c = PanelConfig()
        if let l = d.string(forKey: "layout"), let layout = WidgetLayout(rawValue: l) { c.layout = layout }
        if let z = d.object(forKey: "zoom") as? Double { c.zoom = z }
        if let t = d.object(forKey: "alwaysOnTop") as? Bool { c.onTop = t }
        if let x = d.object(forKey: "posX") as? Double, let top = d.object(forKey: "posTop") as? Double {
            d.set([x, top], forKey: "pos." + c.id)
        }
        return [c]
    }

    func saveConfigs() {
        if let data = try? JSONEncoder().encode(panels.map { $0.settings.cfg }) {
            UserDefaults.standard.set(data, forKey: "panels.v2")
        }
    }

    func actions(for pc: PanelController) -> WidgetActions {
        WidgetActions(
            refresh: { [weak self] in self?.refreshAll() },
            minimize: { [weak self] in DispatchQueue.main.async { self?.minimize() } },
            newWidget: { [weak self] in DispatchQueue.main.async { self?.newWidget(from: pc) } },
            closeWidget: { [weak self, weak pc] in DispatchQueue.main.async { if let pc = pc { self?.closeWidget(pc) } } },
            canClose: { [weak self] in (self?.panels.count ?? 0) > 1 },
            toggleMenuBar: { [weak self] in DispatchQueue.main.async { self?.toggleMenuBar() } },
            menuBarOn: { [weak self] in self?.menuBarOn ?? false },
            loginClaude: { WebSession.shared.showLogin() },
            loginOpenAI: { PlatformSession.shared.showLogin() },
            sonioxKey: { [weak self] in DispatchQueue.main.async { self?.askSonioxKey() } },
            setKey: { [weak self] in DispatchQueue.main.async { self?.askSessionKey() } },
            clearKey: { [weak self] in
                KeychainStore.delete()
                UserDefaults.standard.removeObject(forKey: "orgId")
                self?.model.refresh()
            },
            quit: { NSApp.terminate(nil) }
        )
    }

    @discardableResult
    func addPanel(_ cfg: PanelConfig) -> PanelController {
        let pc = PanelController(cfg: cfg, model: model, app: self, actions: { [unowned self] in self.actions(for: $0) },
                                 index: panels.count)
        panels.append(pc)
        return pc
    }

    func newWidget(from pc: PanelController) {
        var c = PanelConfig()
        c.layout = .compacto
        c.services = pc.settings.cfg.services
        let n = addPanel(c)
        saveConfigs()
        n.placeDefault(index: panels.count - 1)
        n.show()
        n.contentChanged()
    }

    func closeWidget(_ pc: PanelController) {
        guard panels.count > 1 else { return }
        pc.close()
        panels.removeAll { $0 === pc }
        saveConfigs()
    }

    func refreshAll() {
        model.refresh()
        model.refreshAPIs(force: true)
        model.refreshSpend(force: true)
    }

    @objc func screensChanged() {
        for pc in panels where !PanelController.isOnScreen(pc.panel.frame) { pc.placeDefault() }
    }

    /// Prueba automática (solo en GitHub Actions): mide la ventana antes y después de agrandar
    func selfTest() {
        if let dir = ProcessInfo.processInfo.environment["WIDGET_SHOTS"] { return shots(dir) }
        guard let pc = panels.first else { exit(1) }
        func report(_ tag: String) {
            print("[\(tag)] zoom=\(pc.settings.cfg.zoom) ventana=\(pc.panel.frame.size) fitting=\(pc.fitting())")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { report("inicio"); pc.settings.zoomIn(); pc.settings.zoomIn() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { report("tras +2"); pc.settings.zoomOut() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            report("tras -1")
            pc.settings.cfg.layout = .horizontal
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { report("horizontal"); exit(0) }
    }

    /// Capturas de cada formato con datos de ejemplo (solo en GitHub Actions, para revisar el diseño)
    func shots(_ dir: String) {
        let now = Date()
        model.rows = [
            UsageRow(id: "five_hour", label: "Sesión (5 h)", percent: 42, resetsAt: now.addingTimeInterval(7200), window: 18000),
            UsageRow(id: "seven_day", label: "Semana · todos los modelos", percent: 63, resetsAt: now.addingTimeInterval(3 * 86400), window: 604800),
            UsageRow(id: "seven_day_sonnet", label: "Semana · Sonnet", percent: 12, resetsAt: now.addingTimeInterval(3 * 86400), window: 604800),
        ]
        model.gptRows = [
            UsageRow(id: "gpt_p", label: "Sesión (5 h)", percent: 81, resetsAt: now.addingTimeInterval(3000), window: 18000),
            UsageRow(id: "gpt_s", label: "Semana", percent: 30, resetsAt: now.addingTimeInterval(5 * 86400), window: 604800),
        ]
        model.openai = Wallet(available: 7.30, used: 42.70, granted: 50, month: 3.10, source: "OpenAI")
        model.soniox = Wallet(available: 1.20, used: 18.80, granted: 20, month: 4.60, budget: 10, source: "Soniox")
        model.lastUpdate = now
        renderingShots = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for layout in WidgetLayout.allCases {
                let st = PanelSettings(PanelConfig(layout: layout))
                let view = WidgetView(model: self.model, settings: st, actions: self.actions(for: self.panels[0]), onControlsRect: { _ in })
                    .padding(20)
                    .background(Color(red: 0.55, green: 0.6, blue: 0.68))
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(layout.rawValue).png"))
                    print("[captura] \(layout.rawValue) \(img.size)")
                }
            }
            fflush(stdout)
            exit(0)
        }
    }

    // MARK: Atajo de teclado global ⌃⌥⌘U

    var hotKeyRef: EventHotKeyRef?

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.showAll() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x434C5544), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func showAll() {
        minimized = false
        for pc in panels {
            pc.show()
            pc.panel.alphaValue = 0.3
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                pc.panel.animator().alphaValue = 1
            }
        }
        updateStatusItem()
    }

    // MARK: Barra de menús

    var statusItem: NSStatusItem?

    func minimize() {
        panels.forEach { $0.panel.orderOut(nil) }
        minimized = true
        updateStatusItem()
    }

    func toggleMenuBar() {
        menuBarOn.toggle()
        updateStatusItem()
    }

    @objc func refreshAction() { refreshAll() }
    @objc func quitAction() { NSApp.terminate(nil) }
    @objc func newWidgetAction() { if let pc = panels.first { newWidget(from: pc) } }
    @objc func toggleMenuBarAction() { toggleMenuBar() }

    /// Servicios que aparecen en algún widget
    var shownServices: [Service] {
        Service.allCases.filter { s in panels.contains { $0.settings.cfg.services.contains(s) } }
    }

    func updateStatusItem() {
        let wanted = menuBarOn || minimized
        if !wanted {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        add("Mostrar widgets  ⌃⌥⌘U", #selector(showAll))
        add("Actualizar ahora", #selector(refreshAction))
        add("Nuevo widget", #selector(newWidgetAction))
        add(menuBarOn ? "✓ Mostrar siempre en la barra de menús" : "Mostrar siempre en la barra de menús", #selector(toggleMenuBarAction))
        menu.addItem(.separator())
        add("Salir", #selector(quitAction))
        statusItem?.menu = menu

        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let title = NSMutableAttributedString()
        func icon(_ img: NSImage?) {
            guard let img = img else { return }
            let a = NSTextAttachment()
            a.image = img
            a.bounds = CGRect(x: 0, y: -5, width: 19, height: 19)
            title.append(NSAttributedString(attachment: a))
        }
        func text(_ t: String, _ c: NSColor = .labelColor) {
            title.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: c]))
        }
        func small(_ t: String) {
            title.append(NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        func pct(_ r: UsageRow?) -> String { r.map { "\(Int($0.percent.rounded()))%" } ?? "–" }
        for (i, s) in shownServices.enumerated() {
            let c = model.card(s)
            if i > 0 { text("  ") }
            icon(Sprites.image(s.sprite, row: Sprites.row(c.level), frame: 0))
            if s.isAPI {
                text(" " + (c.hasData ? c.short : "–"))
            } else {
                let rows = s == .claude ? model.rows : model.gptRows
                small(" sem ")
                text(pct(rows.first { $0.window >= 6 * 86400 }))
                small(" 5h ")
                text(pct(rows.first { $0.window < 6 * 86400 }))
            }
        }
        if title.length == 0 { text("Uso") }
        button.image = nil
        button.attributedTitle = title
    }

    // MARK: Claves

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

    func askSonioxKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clave de la API de Soniox"
        alert.informativeText = "Pega una clave de organización de Soniox (empieza por snx_org_; console.soniox.com › Settings › Organization API keys). Las claves de proyecto (snx_proj_) no dan acceso al saldo. Con ella el widget lee el saldo prepago y el gasto del mes. Se guarda solo en el Llavero de este Mac. Déjala vacía para borrarla."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { Secret.delete(SonioxAPI.account); model.soniox = nil } else { Secret.save(value, SonioxAPI.account) }
        model.refreshAPIs(force: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// Menú Edición invisible: sin él, ⌘V, ⌘C, ⌘X y ⌘A no funcionan en los campos de texto
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edición")
editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
app.run()
