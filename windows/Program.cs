// Uso de Claude para Windows — widgets flotantes con el uso de Claude y ChatGPT (suscripciones)
// y el saldo de las APIs de OpenAI y Soniox, con personajes animados que cambian de humor.
// Datos: sesión de Claude Code (%USERPROFILE%\.claude) o inicio de sesión en claude.ai dentro de la app;
// ChatGPT: sesión de Codex (%USERPROFILE%\.codex) o inicio de sesión en chatgpt.com dentro de la app.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using WPath = System.Windows.Shapes.Path;
using IOPath = System.IO.Path;

namespace UsoDeClaude
{
    public record Row(string Label, double Percent, DateTimeOffset? ResetAt, double WindowSec)
    {
        public bool IsWeek => WindowSec >= 6 * 86400;
    }

    // ───────────────────────── Ajustes ─────────────────────────

    public class PanelConfig
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N")[..8];
        public List<string> Services { get; set; } = new() { "claude", "gpt", "openai", "soniox" };
        public string Layout { get; set; } = "normal";
        public double Zoom { get; set; } = 1;
        public double X { get; set; } = double.NaN;
        public double Y { get; set; } = double.NaN;
        public bool OnTop { get; set; } = true;
        public bool Hidden { get; set; }
    }

    public class Settings
    {
        static Settings current;
        public static Settings Current => current ??= Load();

        // De la versión anterior (una sola ventana): se usan para crear el primer widget
        public double X { get; set; } = double.NaN;
        public double Y { get; set; } = double.NaN;
        public double Zoom { get; set; } = 1;
        public bool ShowGpt { get; set; } = true;
        public bool Minimized { get; set; }
        public bool AutoStart { get; set; } = true;

        public List<PanelConfig> Panels { get; set; }
        public List<string> Tray { get; set; } = new() { "claude", "gpt" };
        public bool OpenAISession { get; set; }

        public static string Dir => IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "UsoDeClaude");
        static string FilePath => IOPath.Combine(Dir, "ajustes.json");

        public static Settings Load()
        {
            try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
            catch { return new Settings(); }
        }

        public void Save()
        {
            try { Directory.CreateDirectory(Dir); File.WriteAllText(FilePath, JsonSerializer.Serialize(this)); } catch { }
        }
    }

    // ───────────────────────── Utilidades ─────────────────────────

    public static class Util
    {
        public static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };

        public static Color UsageColor(double p) =>
            p < 60 ? Color.FromRgb(0x5C, 0xCC, 0x80) : p < 85 ? Color.FromRgb(0xFF, 0xAD, 0x42) : Color.FromRgb(0xFF, 0x61, 0x59);

        public static string HourText(DateTimeOffset t)
        {
            var local = t.ToLocalTime();
            var es = new System.Globalization.CultureInfo("es-ES");
            return local.Date == DateTime.Now.Date ? local.ToString("H.mm", es) : local.ToString("ddd H.mm", es);
        }

        public static string ResetText(DateTimeOffset t)
        {
            var s = (t - DateTimeOffset.Now).TotalSeconds;
            if (s <= 0) return "Reiniciándose…";
            int d = (int)(s / 86400), h = (int)(s % 86400 / 3600), m = (int)(s % 3600 / 60);
            var rel = d > 0 ? $"{d} d {h} h" : h > 0 ? $"{h} h {m} min" : $"{Math.Max(m, 1)} min";
            return $"Se reinicia en {rel} · {HourText(t)}";
        }

        public static double? Num(JsonElement e, string name)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return null;
            if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
            if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d)) return d;
            return null;
        }

        public static string Str(JsonElement e, string name)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return null;
            return v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }

        public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    // ───────────────────────── Navegador interno (sesiones web) ─────────────────────────

    /// <summary>Un único entorno WebView2 con sesión persistente; las consultas se hacen desde la propia web.</summary>
    public static class Web
    {
        static CoreWebView2Environment env;
        static Window host;
        static WebView2 view;

        public static async Task<CoreWebView2Environment> Env()
        {
            if (env == null)
                env = await CoreWebView2Environment.CreateAsync(null, IOPath.Combine(Settings.Dir, "WebView2"));
            return env;
        }

        static async Task<WebView2> Hidden()
        {
            if (view != null) return view;
            host = new Window
            {
                Width = 400, Height = 300, Left = -20000, Top = -20000, ShowInTaskbar = false,
                WindowStyle = WindowStyle.None, ShowActivated = false
            };
            view = new WebView2();
            host.Content = view;
            host.Show();
            await view.EnsureCoreWebView2Async(await Env());
            return view;
        }

        public static async Task<bool> HasCookie(string url, string name)
        {
            var w = await Hidden();
            var list = await w.CoreWebView2.CookieManager.GetCookiesAsync(url);
            return list.Any(c => c.Name.Contains(name));
        }

        /// <summary>Abre la web y ejecuta el JS (async) devolviendo {status, body}.</summary>
        public static async Task<(int status, string body)?> Run(string url, string js)
        {
            try
            {
                var w = await Hidden();
                var done = new TaskCompletionSource<bool>();
                void handler(object s, CoreWebView2NavigationCompletedEventArgs e) => done.TrySetResult(true);
                w.CoreWebView2.NavigationCompleted += handler;
                w.CoreWebView2.Navigate(url);
                await Task.WhenAny(done.Task, Task.Delay(25000));
                w.CoreWebView2.NavigationCompleted -= handler;
                await w.CoreWebView2.ExecuteScriptAsync(
                    "window.__uso='';(async()=>{try{const r=await(async()=>{" + js + "})();window.__uso=JSON.stringify(r);}catch(e){window.__uso=JSON.stringify({status:-1,body:String(e)});}})();");
                for (int i = 0; i < 60; i++)
                {
                    await Task.Delay(400);
                    var raw = await w.CoreWebView2.ExecuteScriptAsync("window.__uso||''");
                    var s = JsonSerializer.Deserialize<string>(raw);
                    if (!string.IsNullOrEmpty(s))
                    {
                        using var doc = JsonDocument.Parse(s);
                        var st = (int)(Util.Num(doc.RootElement, "status") ?? -1);
                        return (st, Util.Str(doc.RootElement, "body") ?? "");
                    }
                }
            }
            catch { }
            return null;
        }
    }

    // ───────────────────────── Claude ─────────────────────────

    public static class Claude
    {
        const string JS = @"
            const o = await fetch('/api/organizations', {credentials: 'include'});
            if (o.status !== 200) return {status: o.status, body: ''};
            const orgs = await o.json();
            const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
            if (!org) return {status: 404, body: ''};
            const r = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
            return {status: r.status, body: await r.text()};";

        public static List<Row> Parse(string body)
        {
            using var doc = JsonDocument.Parse(body);
            var rows = new List<Row>();
            foreach (var (key, label, span) in new[] { ("five_hour", "Sesión (5 h)", 18000.0), ("seven_day", "Semana", 604800.0),
                ("seven_day_opus", "Semana · Opus", 604800.0), ("seven_day_sonnet", "Semana · Sonnet", 604800.0) })
            {
                if (!doc.RootElement.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) continue;
                var u = Util.Num(w, "utilization");
                if (u == null) continue;
                DateTimeOffset? reset = DateTimeOffset.TryParse(Util.Str(w, "resets_at") ?? "", out var r) ? r : null;
                rows.Add(new Row(label, u.Value, reset, span));
            }
            if (rows.Count == 0) throw new Exception("Respuesta inesperada de Claude");
            return rows;
        }

        static async Task<List<Row>> ViaClaudeCode()
        {
            var file = IOPath.Combine(Util.Home, ".claude", ".credentials.json");
            if (!File.Exists(file)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(file));
            if (!doc.RootElement.TryGetProperty("claudeAiOauth", out var o)) return null;
            var token = Util.Str(o, "accessToken");
            if (string.IsNullOrEmpty(token)) return null;
            var req = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
            req.Headers.Add("Authorization", "Bearer " + token);
            req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            var res = await Util.Http.SendAsync(req);
            if (!res.IsSuccessStatusCode) return null;
            return Parse(await res.Content.ReadAsStringAsync());
        }

        public static async Task<(List<Row> rows, string error, bool needLogin)> Fetch()
        {
            try { var r = await ViaClaudeCode(); if (r != null) return (r, null, false); } catch { }
            var web = await Web.Run("https://claude.ai/", JS);
            if (web == null) return (null, "Sin respuesta de claude.ai", false);
            var (st, body) = web.Value;
            if (st == 401 || st == 403) return (null, "Inicia sesión en claude.ai (clic derecho › Iniciar sesión)", true);
            if (st != 200) return (null, $"Error {st} de claude.ai", false);
            try { return (Parse(body), null, false); } catch (Exception e) { return (null, e.Message, false); }
        }
    }

    // ───────────────────────── ChatGPT ─────────────────────────

    public static class Gpt
    {
        const string JS = @"
            const sr = await fetch('/api/auth/session', {credentials: 'include'});
            const s = sr.status === 200 ? await sr.json() : null;
            if (!s || !s.accessToken) return {status: 401, body: ''};
            const h = {'Authorization': 'Bearer ' + s.accessToken};
            if (s.account && s.account.id) h['chatgpt-account-id'] = s.account.id;
            const r = await fetch('/backend-api/wham/usage', {headers: h, credentials: 'include'});
            return {status: r.status, body: await r.text()};";

        static string Label(double span) => span >= 6 * 86400 ? "Semana" : Math.Abs(span - 18000) < 120 ? "Sesión (5 h)" : $"Ventana de {Math.Round(span / 3600)} h";

        public static List<Row> ParseApi(string body)
        {
            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty("rate_limit", out var rl)) throw new Exception("Respuesta inesperada de ChatGPT");
            var rows = new List<Row>();
            foreach (var key in new[] { "primary_window", "secondary_window" })
            {
                if (!rl.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) continue;
                var u = Util.Num(w, "used_percent");
                if (u == null) continue;
                var span = Util.Num(w, "limit_window_seconds") ?? (key == "primary_window" ? 18000 : 604800);
                DateTimeOffset? reset = null;
                var at = Util.Num(w, "reset_at");
                var after = Util.Num(w, "reset_after_seconds");
                if (at != null) reset = DateTimeOffset.FromUnixTimeSeconds((long)at.Value);
                else if (after != null) reset = DateTimeOffset.Now.AddSeconds(after.Value);
                rows.Add(new Row(Label(span), u.Value, reset, span));
            }
            if (rows.Count == 0) throw new Exception("Respuesta inesperada de ChatGPT");
            return rows;
        }

        static async Task<List<Row>> ViaCodex()
        {
            var file = IOPath.Combine(Environment.GetEnvironmentVariable("CODEX_HOME") ?? IOPath.Combine(Util.Home, ".codex"), "auth.json");
            if (!File.Exists(file)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(file));
            if (!doc.RootElement.TryGetProperty("tokens", out var t)) return null;
            var token = Util.Str(t, "access_token");
            if (string.IsNullOrEmpty(token)) return null;
            var req = new HttpRequestMessage(HttpMethod.Get, "https://chatgpt.com/backend-api/wham/usage");
            req.Headers.Add("Authorization", "Bearer " + token);
            var acc = Util.Str(t, "account_id");
            if (!string.IsNullOrEmpty(acc)) req.Headers.Add("chatgpt-account-id", acc);
            req.Headers.Add("originator", "codex_cli_rs");
            req.Headers.TryAddWithoutValidation("User-Agent", "codex_cli_rs");
            var res = await Util.Http.SendAsync(req);
            if (!res.IsSuccessStatusCode) return null;
            return ParseApi(await res.Content.ReadAsStringAsync());
        }

        /// <summary>Último registro de límites que Codex guarda en sus sesiones (solo esa línea).</summary>
        static List<Row> ViaCodexLogs()
        {
            var dir = IOPath.Combine(Environment.GetEnvironmentVariable("CODEX_HOME") ?? IOPath.Combine(Util.Home, ".codex"), "sessions");
            if (!Directory.Exists(dir)) return null;
            var file = new DirectoryInfo(dir).EnumerateFiles("rollout-*.jsonl", SearchOption.AllDirectories)
                .OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault();
            if (file == null) return null;
            using var fs = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var len = Math.Min(fs.Length, 512 * 1024);
            fs.Seek(-len, SeekOrigin.End);
            var buf = new byte[len];
            fs.Read(buf, 0, (int)len);
            var lines = System.Text.Encoding.UTF8.GetString(buf).Split('\n');
            foreach (var line in lines.Reverse())
            {
                if (!line.Contains("\"rate_limits\"")) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (!doc.RootElement.TryGetProperty("payload", out var p) || !p.TryGetProperty("rate_limits", out var rl)) continue;
                    var stamp = DateTimeOffset.TryParse(Util.Str(doc.RootElement, "timestamp") ?? "", out var ts) ? ts : DateTimeOffset.Now;
                    var rows = new List<Row>();
                    foreach (var key in new[] { "primary", "secondary" })
                    {
                        if (!rl.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) continue;
                        var u = Util.Num(w, "used_percent");
                        if (u == null) continue;
                        var span = (Util.Num(w, "window_minutes") ?? (key == "primary" ? 300 : 10080)) * 60;
                        DateTimeOffset? reset = null;
                        var at = Util.Num(w, "resets_at");
                        var inS = Util.Num(w, "resets_in_seconds");
                        if (at != null) reset = DateTimeOffset.FromUnixTimeSeconds((long)at.Value);
                        else if (inS != null) reset = stamp.AddSeconds(inS.Value);
                        var used = u.Value;
                        if (reset != null && reset < DateTimeOffset.Now) { used = 0; reset = null; }
                        rows.Add(new Row(Label(span), used, reset, span));
                    }
                    if (rows.Count > 0) return rows;
                }
                catch { }
            }
            return null;
        }

        public static async Task<(List<Row> rows, string error)> Fetch()
        {
            try { var r = await ViaCodex(); if (r != null) return (r, null); } catch { }
            try { var r = ViaCodexLogs(); if (r != null) return (r, null); } catch { }
            var web = await Web.Run("https://chatgpt.com/", JS);
            if (web == null) return (null, "Sin respuesta de chatgpt.com");
            var (st, body) = web.Value;
            if (st == 401 || st == 403) return (null, "Inicia sesión en ChatGPT (clic derecho › Iniciar sesión)");
            if (st != 200) return (null, $"Error {st} de chatgpt.com");
            try { return (ParseApi(body), null); } catch (Exception e) { return (null, e.Message); }
        }
    }

    // ───────────────────────── Actualización desde GitHub ─────────────────────────

    public static class Updater
    {
        const string Api = "https://api.github.com/repos/jorgemoraz/claude-usage-widget/releases/tags/windows-latest";
        public static string InstallDir => IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "UsoDeClaude");
        public static string InstalledExe => IOPath.Combine(InstallDir, "UsoDeClaude.exe");
        public static int Current => typeof(Updater).Assembly.GetName().Version?.Build ?? 0;

        /// <summary>La primera vez se copia a su carpeta definitiva y se apunta para arrancar con Windows.</summary>
        public static bool EnsureInstalled()
        {
            var me = Environment.ProcessPath;
            if (string.Equals(me, InstalledExe, StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                Directory.CreateDirectory(InstallDir);
                foreach (var p in Process.GetProcessesByName("UsoDeClaude"))
                    if (p.Id != Environment.ProcessId) { try { p.Kill(); p.WaitForExit(3000); } catch { } }
                File.Copy(me, InstalledExe, true);
                Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = true });
                return true;
            }
            catch { return false; }
        }

        public static void SetAutoStart(bool on)
        {
            try
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
                if (on) key?.SetValue("UsoDeClaude", "\"" + InstalledExe + "\"");
                else key?.DeleteValue("UsoDeClaude", false);
            }
            catch { }
        }

        public static async Task<bool> CheckAndUpdate()
        {
            try
            {
                var req = new HttpRequestMessage(HttpMethod.Get, Api);
                req.Headers.TryAddWithoutValidation("User-Agent", "UsoDeClaude-Windows");
                req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
                var res = await Util.Http.SendAsync(req);
                if (!res.IsSuccessStatusCode) return false;
                using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync());
                var name = Util.Str(doc.RootElement, "name") ?? "";
                var m = Regex.Match(name, @"(\d+)\)?\s*$");
                if (!m.Success || int.Parse(m.Groups[1].Value) <= Current) return false;
                var asset = doc.RootElement.GetProperty("assets")[0];
                var url = Util.Str(asset, "browser_download_url");
                var tmp = IOPath.Combine(Settings.Dir, "nueva.exe");
                Directory.CreateDirectory(Settings.Dir);
                using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
                {
                    http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "UsoDeClaude-Windows");
                    var bytes = await http.GetByteArrayAsync(url);
                    if (bytes.Length < 1_000_000) return false;
                    await File.WriteAllBytesAsync(tmp, bytes);
                }
                // Un pequeño script espera a que se cierre la app, sustituye el .exe y la vuelve a abrir
                var cmd = IOPath.Combine(Settings.Dir, "actualizar.cmd");
                File.WriteAllText(cmd,
                    "@echo off\r\n" +
                    "timeout /t 2 /nobreak >nul\r\n" +
                    $"move /y \"{tmp}\" \"{InstalledExe}\" >nul\r\n" +
                    $"start \"\" \"{InstalledExe}\"\r\n");
                Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + cmd + "\"") { CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden });
                return true;
            }
            catch { return false; }
        }
    }

    // ───────────────────────── APIs de pago ─────────────────────────

    public record Wallet(double? Available, double? Used, double? Granted, double? Month, double? Budget, string Source)
    {
        /// <summary>0–100: cuánto se ha consumido. Decide el humor del personaje.</summary>
        public double? Level
        {
            get
            {
                if (Granted > 0 && Used != null) return Math.Clamp(100 * Used.Value / Granted.Value, 0, 100);
                if (Available != null && Used != null && Available + Used > 0) return Math.Clamp(100 * Used.Value / (Available.Value + Used.Value), 0, 100);
                if (Budget > 0 && Month != null) return Math.Clamp(100 * Month.Value / Budget.Value, 0, 100);
                return null;
            }
        }
    }

    /// <summary>Claves guardadas cifradas para este usuario de Windows (DPAPI)</summary>
    public static class Secret
    {
        static string F(string k) => IOPath.Combine(Settings.Dir, k + ".clave");
        public static string Read(string k)
        {
            try { var s = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(F(k)), null, DataProtectionScope.CurrentUser)).Trim(); return s.Length > 0 ? s : null; }
            catch { return null; }
        }
        public static void Save(string k, string v)
        {
            Directory.CreateDirectory(Settings.Dir);
            File.WriteAllBytes(F(k), ProtectedData.Protect(Encoding.UTF8.GetBytes(v.Trim()), null, DataProtectionScope.CurrentUser));
        }
        public static void Delete(string k) { try { File.Delete(F(k)); } catch { } }
    }

    /// <summary>Soniox: saldo prepago y gasto del mes con su API oficial</summary>
    public static class Soniox
    {
        public static async Task<(Wallet w, string err)> Fetch()
        {
            var k = Secret.Read("soniox");
            if (k == null) return (null, "Falta la clave de Soniox: clic derecho › Clave de la API de Soniox…");
            async Task<(int, string)> get(string p)
            {
                var req = new HttpRequestMessage(HttpMethod.Get, "https://api.soniox.com/v1/" + p);
                req.Headers.Add("Authorization", "Bearer " + k);
                var r = await Util.Http.SendAsync(req);
                return ((int)r.StatusCode, await r.Content.ReadAsStringAsync());
            }
            try
            {
                var (bs, bb) = await get("organization/balance");
                var (ms, mb) = await get("organization/usage/monthly");
                double? a = null, u = null, m = null, b = null;
                if (bs == 200) { using var d = JsonDocument.Parse(bb); a = Util.Num(d.RootElement, "available_balance_usd"); u = Util.Num(d.RootElement, "used_balance_usd"); }
                if (ms == 200) { using var d = JsonDocument.Parse(mb); m = Util.Num(d.RootElement, "usage_usd"); b = Util.Num(d.RootElement, "monthly_budget_usd"); }
                if (a == null && m == null) return (null, bs == 401 || bs == 403 ? "Soniox no acepta la clave" : $"Soniox respondió {bs}");
                return (new Wallet(a, u, a != null && u != null ? a + u : null, m, b, "Soniox"), null);
            }
            catch { return (null, "Sin respuesta de Soniox"); }
        }
    }

    /// <summary>OpenAI no da el saldo con una clave de API: se lee con la sesión de platform.openai.com (vía no oficial)</summary>
    public static class OpenAI
    {
        public const string TokenJS = @"(function(){var t=null;[window.localStorage,window.sessionStorage].forEach(function(st){for(var i=0;i<st.length;i++){var v=st.getItem(st.key(i))||'';if(v.indexOf('access_token')<0)continue;try{var o=JSON.parse(v);var c=(o&&o.body&&o.body.access_token)||(o&&o.access_token);if(c)t=c;}catch(e){}}});return t||'';})()";

        const string JS = @"
            let tok = " + TokenJS + @";
            if (!tok) {
              try { const s = await fetch('/api/auth/session', {credentials: 'include'}); if (s.status === 200) { const j = await s.json(); tok = j.accessToken || null; } } catch (e) {}
            }
            if (!tok) return {status: 401, body: ''};
            const h = {'Authorization': 'Bearer ' + tok};
            let gs = 0, gb = '';
            try { const g = await fetch('https://api.openai.com/dashboard/billing/credit_grants', {headers: h}); gs = g.status; gb = await g.text(); } catch (e) { gs = -1; }
            const d = new Date();
            const start = d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0') + '-01';
            const end = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
            let ub = '';
            try { const u = await fetch('https://api.openai.com/dashboard/billing/usage?start_date=' + start + '&end_date=' + end, {headers: h}); if (u.status === 200) ub = await u.text(); } catch (e) {}
            return {status: gs, body: JSON.stringify({grants: gb, usage: ub})};";

        public static async Task<(Wallet w, string err)> Fetch()
        {
            if (!Settings.Current.OpenAISession) return (null, "Inicia sesión en OpenAI: clic derecho › Iniciar sesión en OpenAI…");
            var r = await Web.Run("https://platform.openai.com/", JS);
            if (r == null) return (null, "Sin respuesta de OpenAI");
            var (st, body) = r.Value;
            double? a = null, u = null, g = null, m = null;
            try
            {
                using var d = JsonDocument.Parse(string.IsNullOrEmpty(body) ? "{}" : body);
                var gb = Util.Str(d.RootElement, "grants");
                if (st == 200 && !string.IsNullOrEmpty(gb))
                {
                    using var gd = JsonDocument.Parse(gb);
                    g = Util.Num(gd.RootElement, "total_granted"); u = Util.Num(gd.RootElement, "total_used");
                    a = Util.Num(gd.RootElement, "total_available") ?? Util.Num(gd.RootElement, "total_paid_available");
                }
                var ub = Util.Str(d.RootElement, "usage");
                if (!string.IsNullOrEmpty(ub)) { using var ud = JsonDocument.Parse(ub); var c = Util.Num(ud.RootElement, "total_usage"); if (c != null) m = c / 100; }
            }
            catch { }
            if (a == null && m == null)
                return (null, st == 401 || st == 403 ? "Sesión de OpenAI caducada: vuelve a iniciar sesión" : $"OpenAI respondió {st}");
            return (new Wallet(a, u, g, m, null, "OpenAI"), null);
        }
    }

    // ───────────────────────── Servicios, datos y tarjetas ─────────────────────────

    public enum Svc { Claude, ChatGPT, OpenAI, Soniox }

    public static class SvcInfo
    {
        public static readonly Svc[] All = { Svc.Claude, Svc.ChatGPT, Svc.OpenAI, Svc.Soniox };
        public static string Key(Svc s) => s switch { Svc.Claude => "claude", Svc.ChatGPT => "gpt", Svc.OpenAI => "openai", _ => "soniox" };
        public static Svc? From(string k) => All.Cast<Svc?>().FirstOrDefault(s => Key(s.Value) == k);
        public static string Title(Svc s) => s switch { Svc.Claude => "Claude", Svc.ChatGPT => "ChatGPT", Svc.OpenAI => "API OpenAI", _ => "API Soniox" };
        public static string Short(Svc s) => s switch { Svc.Claude => "Claude", Svc.ChatGPT => "GPT", Svc.OpenAI => "OpenAI", _ => "Soniox" };
        public static string Sprite(Svc s) => s switch { Svc.Claude => "claude", Svc.Soniox => "soniox", _ => "chatgpt" };
        public static bool IsAPI(Svc s) => s == Svc.OpenAI || s == Svc.Soniox;
        public static Color Color(Svc s) => s switch
        {
            Svc.Claude => System.Windows.Media.Color.FromRgb(0xE3, 0x87, 0x6A),
            Svc.ChatGPT => System.Windows.Media.Color.FromRgb(0x4D, 0xC7, 0x9E),
            Svc.OpenAI => System.Windows.Media.Color.FromRgb(0x7F, 0xD6, 0xB8),
            _ => System.Windows.Media.Color.FromRgb(0x6F, 0xA8, 0xFF)
        };
    }

    public record Line(string Label, string Value, double? Percent, string Note, Color Color);

    public class Card
    {
        public Svc S;
        public bool HasData;
        public double? Level;
        public string Big = "–", Small = "sin datos", Error;
        public List<Line> Lines = new();
        public int Row => Sprites.Row(Level);

        public string Phrase()
        {
            if (!HasData) return SvcInfo.IsAPI(S) ? "Sin datos de la API" : "Sin datos todavía";
            var l = SvcInfo.IsAPI(S)
                ? new[] { new[] { "Cartera sana", "Hay saldo de sobra", "Gasta tranquilo" }, new[] { "Ojo con el gasto", "Gasta con cabeza" }, new[] { "Recarga pronto", "El saldo baja rápido" }, new[] { "¡Recarga ya!", "¡Me quedo sin saldo!" } }[Row]
                : new[] { new[] { "A tope de energía", "Ritmo de crucero", "Pídeme lo que quieras" }, new[] { "Ojo, que baja", "Dosifícame un poco" }, new[] { "Esto se acaba", "Solo lo importante" }, new[] { "¡Últimas gotas!", "¡Que me apago!" } }[Row];
            return l[(int)(DateTimeOffset.Now.ToUnixTimeSeconds() / 90 % l.Length)];
        }
    }

    public static class Data
    {
        public static List<Row> Claude = new(), Gpt = new();
        public static string ClaudeErr, GptErr, OpenAIErr, SonioxErr;
        public static Wallet OpenAIW, SonioxW;
        public static DateTimeOffset? Updated;
        public static bool Loading, NeedClaudeLogin, Sample;
        static DateTimeOffset lastApis = DateTimeOffset.MinValue;
        public static event Action Changed;
        public static void Notify() => Changed?.Invoke();

        static readonly System.Globalization.CultureInfo Es = new("es-ES");
        public static string Pct(double p) => $"{Math.Round(p)} %";
        public static string Dollars(double v) => v.ToString(v >= 100 ? "N0" : "N2", Es) + " $";

        public static async Task Refresh(bool force = false)
        {
            if (Loading || Sample) return;
            Loading = true; Notify();
            try
            {
                var c = await global::UsoDeClaude.Claude.Fetch();
                if (c.rows != null) { Claude = c.rows; ClaudeErr = null; } else ClaudeErr = c.error;
                NeedClaudeLogin = c.rows == null && c.needLogin;
                var g = await global::UsoDeClaude.Gpt.Fetch();
                if (g.rows != null) { Gpt = g.rows; GptErr = null; } else GptErr = g.error;
                // Las APIs cambian despacio: cada 10 minutos, o al pedirlo a mano
                if (force || DateTimeOffset.Now - lastApis > TimeSpan.FromMinutes(10))
                {
                    lastApis = DateTimeOffset.Now;
                    var s = await Soniox.Fetch();
                    if (s.w != null) { SonioxW = s.w; SonioxErr = null; } else SonioxErr = s.err;
                    var o = await global::UsoDeClaude.OpenAI.Fetch();
                    if (o.w != null) { OpenAIW = o.w; OpenAIErr = null; } else OpenAIErr = o.err;
                }
                Updated = DateTimeOffset.Now;
            }
            finally { Loading = false; Notify(); }
        }

        public static Card Card(Svc s) => SvcInfo.IsAPI(s)
            ? Api(s, s == Svc.OpenAI ? OpenAIW : SonioxW, s == Svc.OpenAI ? OpenAIErr : SonioxErr)
            : Sub(s, s == Svc.Claude ? Claude : Gpt, s == Svc.Claude ? ClaudeErr : GptErr);

        static Card Sub(Svc s, List<Row> rows, string err)
        {
            var c = new Card { S = s, Error = err };
            if (rows.Count == 0) return c;
            c.HasData = true;
            var session = rows.FirstOrDefault(r => !r.IsWeek);
            var week = rows.FirstOrDefault(r => r.IsWeek);
            c.Level = rows.Max(r => r.Percent);
            c.Big = week != null ? Pct(week.Percent) : session != null ? Pct(session.Percent) : "–";
            c.Small = session != null ? "5h " + Pct(session.Percent) : "";
            foreach (var r in rows)
            {
                var note = r.ResetAt == null ? "" : r.ResetAt > DateTimeOffset.Now ? "vuelve " + Util.HourText(r.ResetAt.Value) : "reiniciado";
                var label = !r.IsWeek ? "5 horas" : r.Label.Contains("· ") ? r.Label[(r.Label.IndexOf("· ") + 2)..] : r.Label;
                c.Lines.Add(new Line(label, Pct(r.Percent), r.Percent, note, Util.UsageColor(r.Percent)));
            }
            return c;
        }

        static Card Api(Svc s, Wallet w, string err)
        {
            var c = new Card { S = s, Error = err };
            if (w == null) return c;
            c.HasData = true;
            c.Level = w.Level;
            var dim = System.Windows.Media.Color.FromArgb(140, 255, 255, 255);
            if (w.Available != null)
                c.Lines.Add(new Line("Saldo", Dollars(w.Available.Value), c.Level != null ? 100 - c.Level : null,
                    "queda" + (w.Granted != null ? " de " + Dollars(w.Granted.Value) : ""), c.Level != null ? Util.UsageColor(c.Level.Value) : System.Windows.Media.Color.FromRgb(0x5C, 0xCC, 0x80)));
            if (w.Used != null && w.Available != null) c.Lines.Add(new Line("Gastado", Dollars(w.Used.Value), null, "del saldo cargado", dim));
            if (w.Month != null)
                c.Lines.Add(new Line("Este mes", Dollars(w.Month.Value), w.Budget > 0 ? 100 * w.Month / w.Budget : null,
                    "gastado" + (w.Budget != null ? " de " + Dollars(w.Budget.Value) : ""), dim));
            c.Big = w.Available != null ? Dollars(w.Available.Value) : w.Month != null ? Dollars(w.Month.Value) : "–";
            c.Small = w.Available != null ? (w.Month != null ? "mes " + Dollars(w.Month.Value) : "saldo") : "este mes";
            return c;
        }

        public static void LoadSample()
        {
            Sample = true;
            var now = DateTimeOffset.Now;
            Claude = new() { new Row("Sesión (5 h)", 34, now.AddHours(2), 18000), new Row("Semana", 61, now.AddDays(3), 604800), new Row("Semana · Sonnet", 12, now.AddDays(3), 604800) };
            Gpt = new() { new Row("Sesión (5 h)", 8, now.AddHours(4), 18000), new Row("Semana", 92, now.AddDays(1), 604800) };
            OpenAIW = new Wallet(7.4, 12.6, 20, 3.2, null, "OpenAI");
            SonioxErr = "Falta la clave de Soniox: clic derecho › Clave de la API de Soniox…";
            Updated = now;
        }
    }

    // ───────────────────────── Personajes ─────────────────────────

    /// <summary>36 fotogramas incrustados en el .exe: 3 personajes × 4 humores × 3 fotogramas</summary>
    public static class Sprites
    {
        static readonly Dictionary<string, BitmapImage> cache = new();

        public static int Row(double? l) => l == null ? 0 : l >= 90 ? 3 : l >= 75 ? 2 : l >= 50 ? 1 : 0;
        public static int Interval(int row) => new[] { 650, 480, 320, 200 }[Math.Clamp(row, 0, 3)];

        public static Stream Open(string who, int row, int f) =>
            typeof(Sprites).Assembly.GetManifestResourceStream($"sprites.{who}-{row}-{f}.png");

        public static BitmapImage Get(string who, int row, int f)
        {
            var k = $"{who}-{row}-{f}";
            if (cache.TryGetValue(k, out var b)) return b;
            using var s = Open(who, row, f);
            if (s == null) return null;
            b = new BitmapImage();
            b.BeginInit(); b.StreamSource = s; b.CacheOption = BitmapCacheOption.OnLoad; b.EndInit(); b.Freeze();
            cache[k] = b;
            return b;
        }

        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        /// <summary>Icono de la barra de tareas: el personaje con el dato encima</summary>
        public static System.Drawing.Icon TrayIcon(Card c)
        {
            using var bmp = new System.Drawing.Bitmap(32, 32);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                g.Clear(System.Drawing.Color.Transparent);
                using (var s = Open(SvcInfo.Sprite(c.S), c.Row, 0))
                    if (s != null) using (var img = System.Drawing.Image.FromStream(s)) g.DrawImage(img, 0, -2, 32, 32);
                var text = !c.HasData ? "?" : SvcInfo.IsAPI(c.S)
                    ? Math.Round(c.S == Svc.OpenAI ? Data.OpenAIW?.Available ?? Data.OpenAIW?.Month ?? 0 : Data.SonioxW?.Available ?? Data.SonioxW?.Month ?? 0).ToString()
                    : Math.Min(99, (int)Math.Round(c.Level ?? 0)).ToString();
                var col = c.Level != null ? Util.UsageColor(SvcInfo.IsAPI(c.S) ? c.Level.Value : c.Level.Value) : System.Windows.Media.Colors.White;
                using var f = new System.Drawing.Font("Segoe UI", text.Length > 2 ? 10 : 13, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel);
                var sz = g.MeasureString(text, f);
                var w = Math.Max(16, sz.Width + 2);
                using (var bg = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(225, 20, 18, 18)))
                    g.FillRectangle(bg, 32 - w, 17, w, 15);
                using var fg = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(col.R, col.G, col.B));
                g.DrawString(text, f, fg, 32 - w + (w - sz.Width) / 2, 17 + (15 - sz.Height) / 2 + 0.5f);
            }
            var h = bmp.GetHicon();
            var icon = (System.Drawing.Icon)System.Drawing.Icon.FromHandle(h).Clone();
            DestroyIcon(h);
            return icon;
        }
    }

    // ───────────────────────── Ventanas auxiliares ─────────────────────────

    public class LoginWindow : Window
    {
        readonly WebView2 web = new WebView2();
        DispatcherTimer poll;

        /// <summary>done: comprueba si ya hay sesión (cookie o token en la web)</summary>
        public LoginWindow(string url, Func<WebView2, Task<bool>> done, Action onDone)
        {
            Title = "Inicia sesión · Uso de Claude";
            Width = 480; Height = 720; Topmost = true;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Content = web;
            Loaded += async (_, __) =>
            {
                await web.EnsureCoreWebView2Async(await Web.Env());
                web.CoreWebView2.Navigate(url);
                poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                poll.Tick += async (s2, e2) =>
                {
                    try
                    {
                        var path = web.Source?.AbsolutePath ?? "";
                        if (path.StartsWith("/login") || path.StartsWith("/auth") || path.Contains("magic-link")) return;
                        if (await done(web)) { poll.Stop(); Close(); onDone(); }
                    }
                    catch { }
                };
                poll.Start();
            };
            Closed += (_, __) => poll?.Stop();
        }

        public static Func<WebView2, Task<bool>> Cookie(string url, string name) => async w =>
            (await w.CoreWebView2.CookieManager.GetCookiesAsync(url)).Any(c => c.Name.Contains(name));

        public static async Task<bool> OpenAIToken(WebView2 w)
        {
            if (!(w.Source?.Host ?? "").Contains("platform.openai.com")) return false;
            var raw = await w.CoreWebView2.ExecuteScriptAsync(OpenAI.TokenJS);
            return (JsonSerializer.Deserialize<string>(raw) ?? "").Length > 20;
        }
    }

    public class KeyWindow : Window
    {
        public KeyWindow(string title, string text, Action<string> save, Action clear)
        {
            Title = title; Width = 440; SizeToContent = SizeToContent.Height; Topmost = true;
            WindowStartupLocation = WindowStartupLocation.CenterScreen; ResizeMode = ResizeMode.NoResize;
            var sp = new StackPanel { Margin = new Thickness(18) };
            sp.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
            var box = new PasswordBox { Height = 28 };
            sp.Children.Add(box);
            var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
            Button b(string t, Action a) { var x = new Button { Content = t, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) }; x.Click += (_, __) => a(); bar.Children.Add(x); return x; }
            if (clear != null) b("Borrar la clave", () => { clear(); Close(); });
            b("Cancelar", Close);
            var ok = b("Guardar", () => { if (box.Password.Trim().Length >= 10) { save(box.Password); Close(); } else MessageBox.Show("Esa clave no parece válida."); });
            ok.IsDefault = true;
            sp.Children.Add(bar);
            Content = sp;
            Loaded += (_, __) => box.Focus();
        }
    }

    // ───────────────────────── Widget flotante ─────────────────────────

    public class Widget : Window
    {
        public readonly PanelConfig Cfg;
        readonly ScaleTransform scale = new(1, 1);
        readonly List<(Image img, string who, int row)> sprites = new();
        readonly DateTime start = DateTime.Now;
        Border card;
        StackPanel controls;
        bool hover;

        public static readonly string[] Layouts = { "mini", "compacto", "vertical", "normal", "grande" };
        public static string LayoutName(string l) => l switch
        {
            "mini" => "Mínimo (una línea)", "compacto" => "Compacto (horizontal)", "vertical" => "Vertical",
            "grande" => "Grande", _ => "Normal (tarjetas)"
        };
        static readonly double[] Steps = { 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2 };

        public List<Svc> Services => Cfg.Services.Select(SvcInfo.From).Where(s => s != null).Select(s => s.Value).DefaultIfEmpty(Svc.Claude).ToList();

        public Widget(PanelConfig cfg)
        {
            Cfg = cfg;
            Title = "Uso de Claude";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
            Topmost = cfg.OnTop;
            scale.ScaleX = scale.ScaleY = cfg.Zoom;

            if (!double.IsNaN(cfg.X) && !double.IsNaN(cfg.Y) &&
                cfg.X > SystemParameters.VirtualScreenLeft - 50 && cfg.X < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 50 &&
                cfg.Y > SystemParameters.VirtualScreenTop - 20 && cfg.Y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 50)
            { Left = cfg.X; Top = cfg.Y; }
            else
            { WindowStartupLocation = WindowStartupLocation.Manual; Left = SystemParameters.WorkArea.Right - 400; Top = SystemParameters.WorkArea.Top + 20 + 40 * AppCtl.Panels.Count; }

            // Arrastrar para mover; un clic sin mover actualiza
            MouseLeftButtonDown += (_, e) =>
            {
                if (e.ButtonState != MouseButtonState.Pressed) return;
                double x = Left, y = Top;
                try { DragMove(); } catch { }
                if (Math.Abs(Left - x) < 2 && Math.Abs(Top - y) < 2) _ = Data.Refresh(force: true);
                else SavePos();
            };
            MouseEnter += (_, __) => { hover = true; if (controls != null) controls.Visibility = Visibility.Visible; };
            MouseLeave += (_, __) => { hover = false; if (controls != null) controls.Visibility = Visibility.Collapsed; };
            Data.Changed += OnData;
            Closed += (_, __) => Data.Changed -= OnData;

            var anim = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
            anim.Tick += (_, __) => Animate();
            anim.Start();
            Render();
        }

        void OnData() => Dispatcher.Invoke(Render);

        void SavePos() { Cfg.X = Left; Cfg.Y = Top; Settings.Current.Save(); }

        void Animate()
        {
            var ms = (DateTime.Now - start).TotalMilliseconds;
            foreach (var (img, who, row) in sprites)
            {
                var f = (int)(ms / Sprites.Interval(row)) % 3;
                var src = Sprites.Get(who, row, f);
                if (!ReferenceEquals(img.Source, src)) img.Source = src;
            }
        }

        // ── Piezas ──

        static TextBlock Txt(string s, double size, Color c, FontWeight? w = null) =>
            new TextBlock { Text = s, FontSize = size, Foreground = new SolidColorBrush(c), FontWeight = w ?? FontWeights.Normal, FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI"), TextTrimming = TextTrimming.CharacterEllipsis };
        static Color Wa(byte a) => Color.FromArgb(a, 255, 255, 255);
        static readonly Color Warn = Color.FromRgb(255, 180, 100);

        Image Sprite(Card c, double size)
        {
            var who = SvcInfo.Sprite(c.S);
            var img = new Image { Width = size, Height = size, Source = Sprites.Get(who, c.Row, 0), Cursor = Cursors.Hand, ToolTip = SvcInfo.Title(c.S) + " · " + c.Phrase() };
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
            sprites.Add((img, who, c.Row));
            return img;
        }

        static Color BigColor(Card c) => !c.HasData ? Wa(140) : c.Level != null ? Util.UsageColor(c.Level.Value) : Colors.White;

        static UIElement Bar(double p, Color c)
        {
            var g = new Grid { Height = 7, VerticalAlignment = VerticalAlignment.Center };
            g.Children.Add(new Border { CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Wa(26)) });
            var fill = new Border { CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Left, Background = new LinearGradientBrush(Color.FromArgb(170, c.R, c.G, c.B), c, 0) };
            g.SizeChanged += (_, e) => fill.Width = Math.Max(p > 0 ? 7 : 0, e.NewSize.Width * Math.Clamp(p, 0, 100) / 100);
            g.Children.Add(fill);
            return g;
        }

        /// <summary>Celda compacta: personaje, nombre, dato grande y otro pequeño</summary>
        UIElement Cell(Card c, double sprite, double big)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 2, 10, 2) };
            sp.Children.Add(Sprite(c, sprite));
            var col = new StackPanel { Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, MaxWidth = 150 };
            col.Children.Add(Txt(SvcInfo.IsAPI(c.S) || !c.HasData ? SvcInfo.Short(c.S) : SvcInfo.Short(c.S) + " · semana", 11, SvcInfo.Color(c.S), FontWeights.Bold));
            col.Children.Add(Txt(c.Big, big, BigColor(c), FontWeights.Bold));
            col.Children.Add(Txt(!c.HasData ? (c.Error ?? "sin datos") : c.Small, 11, !c.HasData && c.Error != null ? Warn : Wa(150)));
            sp.Children.Add(col);
            return sp;
        }

        /// <summary>Tarjeta completa con frase y líneas con barra</summary>
        UIElement Full(Card c, bool large)
        {
            var g = new DockPanel { Margin = new Thickness(0, 6, 0, 6) };
            var spr = Sprite(c, large ? 72 : 58);
            spr.VerticalAlignment = VerticalAlignment.Top;
            DockPanel.SetDock(spr, Dock.Left);
            g.Children.Add(spr);
            var col = new StackPanel { Margin = new Thickness(12, 0, 0, 0) };
            var head = new DockPanel();
            var phrase = Txt(c.HasData ? c.Phrase() : "", 11, Wa(150));
            phrase.VerticalAlignment = VerticalAlignment.Bottom; phrase.Margin = new Thickness(8, 0, 0, 1);
            DockPanel.SetDock(phrase, Dock.Right);
            head.Children.Add(phrase);
            head.Children.Add(Txt(SvcInfo.Title(c.S), 15, SvcInfo.Color(c.S), FontWeights.Bold));
            col.Children.Add(head);
            foreach (var l in c.Lines)
            {
                var row = new Grid { Margin = new Thickness(0, 3, 0, 0) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(large ? 86 : 74) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 50 });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(large ? 130 : 108) });
                var lab = Txt(l.Label, 12, Wa(185), FontWeights.Medium); lab.VerticalAlignment = VerticalAlignment.Center;
                var val = Txt(l.Value, large ? 21 : 18, l.Percent != null ? l.Color : Colors.White, FontWeights.Bold);
                var note = Txt(l.Note, 10.5, Wa(130)); note.VerticalAlignment = VerticalAlignment.Center; note.HorizontalAlignment = HorizontalAlignment.Right;
                Grid.SetColumn(val, 1); Grid.SetColumn(note, 3);
                row.Children.Add(lab); row.Children.Add(val); row.Children.Add(note);
                if (l.Percent != null) { var b = Bar(l.Percent.Value, l.Color); Grid.SetColumn(b, 2); ((FrameworkElement)b).Margin = new Thickness(4, 0, 10, 0); row.Children.Add(b); }
                col.Children.Add(row);
            }
            if (!c.HasData || c.Error != null)
            {
                var e = Txt(c.HasData ? "⚠ " + c.Error : c.Error ?? "Sin datos todavía", 11, Warn);
                e.TextWrapping = TextWrapping.Wrap; e.TextTrimming = TextTrimming.None; e.Margin = new Thickness(0, 3, 0, 0);
                col.Children.Add(e);
            }
            g.Children.Add(col);
            return g;
        }

        Button Ctl(string glyph, string tip, Action a)
        {
            var b = new Button { Content = Txt(glyph, 11, Colors.White, FontWeights.Bold), Width = 22, Height = 22, Margin = new Thickness(3, 0, 0, 0), ToolTip = tip, Cursor = Cursors.Hand, Focusable = false };
            b.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
                "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>" +
                "<Border CornerRadius='11' Background='#3A000000' BorderBrush='#50FFFFFF' BorderThickness='0.5'>" +
                "<ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border></ControlTemplate>");
            b.Click += (_, __) => a();
            return b;
        }

        public void Render()
        {
            sprites.Clear();
            var cards = Services.Select(Data.Card).ToList();
            var lay = Cfg.Layout;
            FrameworkElement body;
            switch (lay)
            {
                case "mini":
                    {
                        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 4, 8, 4) };
                        foreach (var c in cards)
                        {
                            var it = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 10, 0), ToolTip = SvcInfo.Title(c.S) + ": " + c.Big + (c.HasData ? " · " + c.Small : "") };
                            it.Children.Add(Sprite(c, 30));
                            var t = Txt(c.Big, 17, BigColor(c), FontWeights.Bold); t.VerticalAlignment = VerticalAlignment.Center; t.Margin = new Thickness(4, 0, 0, 0);
                            it.Children.Add(t);
                            sp.Children.Add(it);
                        }
                        body = sp; break;
                    }
                case "compacto":
                    {
                        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 8, 6, 8) };
                        foreach (var c in cards) sp.Children.Add(Cell(c, 46, 24));
                        body = sp; break;
                    }
                case "vertical":
                    {
                        var sp = new StackPanel { Margin = new Thickness(10, 10, 10, 6), Width = 200 };
                        foreach (var c in cards) { var e = (FrameworkElement)Cell(c, 50, 24); e.Margin = new Thickness(0, 3, 0, 3); sp.Children.Add(e); }
                        sp.Children.Add(Footer());
                        body = sp; break;
                    }
                default:
                    {
                        var large = lay == "grande";
                        var sp = new StackPanel { Margin = new Thickness(16, 12, 16, 10), Width = large ? 440 : 380 };
                        foreach (var c in cards) sp.Children.Add(Full(c, large));
                        sp.Children.Add(Footer());
                        body = sp; break;
                    }
            }

            controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 8, 0), Visibility = hover ? Visibility.Visible : Visibility.Collapsed };
            controls.Children.Add(Ctl("⟳", "Actualizar", () => _ = Data.Refresh(force: true)));
            controls.Children.Add(Ctl("−", "Más pequeño", () => SetZoom(-1)));
            controls.Children.Add(Ctl("+", "Más grande", () => SetZoom(1)));
            controls.Children.Add(Ctl("⌄", "Ocultar (Ctrl+Alt+U o el icono de la barra de tareas para volver)", HidePanel));
            var grid = new Grid();
            grid.Children.Add(body);
            grid.Children.Add(controls);

            var worst = cards.Where(c => c.Level != null).Select(c => c.Level.Value).DefaultIfEmpty(0).Max();
            var tint = Util.UsageColor(worst);
            var bg = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
            bg.GradientStops.Add(new GradientStop(Color.FromArgb(242, (byte)(0x1C + tint.R / 14), (byte)(0x18 + tint.G / 14), (byte)(0x17 + tint.B / 14)), 0));
            bg.GradientStops.Add(new GradientStop(Color.FromArgb(242, 0x1C, 0x18, 0x17), 0.6));
            card = new Border
            {
                CornerRadius = new CornerRadius(lay == "mini" ? 18 : 22), Background = bg, Child = grid, Margin = new Thickness(10),
                BorderThickness = new Thickness(1), BorderBrush = new LinearGradientBrush(Wa(110), Wa(30), 90),
                LayoutTransform = scale,
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.45 }
            };
            Content = card;
            ContextMenu = BuildMenu();
            Animate();
        }

        static UIElement Footer()
        {
            var t = Txt(Data.Loading ? "actualizando…" : Data.Updated != null ? $"Actualizado {Util.HourText(Data.Updated.Value)} · clic para actualizar" : "", 10, Wa(100));
            t.HorizontalAlignment = HorizontalAlignment.Right; t.Margin = new Thickness(0, 6, 0, 0);
            return t;
        }

        public FrameworkElement CardElement => card;

        void SetZoom(int dir)
        {
            var z = Cfg.Zoom;
            var next = dir > 0 ? Steps.FirstOrDefault(s => s > z + 0.001) : Steps.LastOrDefault(s => s < z - 0.001);
            if (next == 0) return;
            Cfg.Zoom = next; Settings.Current.Save();
            scale.ScaleX = scale.ScaleY = next;
        }

        public void HidePanel() { Hide(); Cfg.Hidden = true; Settings.Current.Save(); AppCtl.HiddenHint(); }

        public void ShowPanel()
        {
            Cfg.Hidden = false; Settings.Current.Save();
            Show(); Activate(); Topmost = Cfg.OnTop;
            var wa = SystemParameters.WorkArea;
            if (Left > SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 40 || Top > SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 40)
            { Left = wa.Right - ActualWidth - 20; Top = wa.Top + 20; SavePos(); }
        }

        ContextMenu BuildMenu()
        {
            var m = new ContextMenu();
            MenuItem item(ItemsControl parent, string h, Action a, bool? check = null)
            {
                var i = new MenuItem { Header = h };
                if (check != null) { i.IsCheckable = true; i.IsChecked = check.Value; }
                i.Click += (_, __) => a();
                parent.Items.Add(i);
                return i;
            }
            item(m, "Actualizar ahora", () => _ = Data.Refresh(force: true));
            var what = new MenuItem { Header = "Qué muestra este widget" };
            foreach (var s in SvcInfo.All)
            {
                var k = SvcInfo.Key(s);
                item(what, SvcInfo.Title(s), () =>
                {
                    if (Cfg.Services.Contains(k)) { if (Cfg.Services.Count > 1) Cfg.Services.Remove(k); }
                    else Cfg.Services = SvcInfo.All.Select(SvcInfo.Key).Where(x => x == k || Cfg.Services.Contains(x)).ToList();
                    Settings.Current.Save(); Render();
                }, Cfg.Services.Contains(k));
            }
            m.Items.Add(what);
            var fmt = new MenuItem { Header = "Formato" };
            foreach (var l in Layouts) item(fmt, LayoutName(l), () => { Cfg.Layout = l; Settings.Current.Save(); Render(); }, Cfg.Layout == l);
            m.Items.Add(fmt);
            item(m, "Más grande", () => SetZoom(1));
            item(m, "Más pequeño", () => SetZoom(-1));
            item(m, "Siempre por encima (si no, se queda en el escritorio)", () => { Cfg.OnTop = !Cfg.OnTop; Topmost = Cfg.OnTop; Settings.Current.Save(); }, Cfg.OnTop);
            m.Items.Add(new Separator());
            item(m, "Nuevo widget", () => AppCtl.NewPanel());
            if (AppCtl.Panels.Count > 1) item(m, "Cerrar este widget", () => AppCtl.ClosePanel(this));
            item(m, "Ocultar", HidePanel);
            m.Items.Add(new Separator());
            AppCtl.AccountItems(m);
            m.Items.Add(new Separator());
            item(m, "Salir", AppCtl.Quit);
            return m;
        }
    }

    // ───────────────────────── Aplicación: widgets, barra de tareas y atajo ─────────────────────────

    public static class AppCtl
    {
        public static readonly List<Widget> Panels = new();
        static readonly Dictionary<Svc, System.Windows.Forms.NotifyIcon> trays = new();
        static System.Windows.Forms.NotifyIcon baseTray;
        static HwndSource hotkeyWin;
        static bool hinted;

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        const int HOTKEY_ID = 0x5544;

        public static void Start()
        {
            var st = Settings.Current;
            if (st.Panels == null || st.Panels.Count == 0)
            {
                // Primera vez con esta versión: el widget de antes pasa a ser el primero
                st.Panels = new() { new PanelConfig
                {
                    X = st.X, Y = st.Y, Zoom = st.Zoom, Hidden = st.Minimized,
                    Services = st.ShowGpt ? new() { "claude", "gpt", "openai", "soniox" } : new() { "claude", "openai", "soniox" }
                } };
                st.Save();
            }
            foreach (var c in st.Panels) Open(c);

            // Atajo Ctrl+Alt+U con una ventana invisible de mensajes
            hotkeyWin = new HwndSource(new HwndSourceParameters("UsoDeClaudeAtajo") { ParentWindow = new IntPtr(-3) });
            RegisterHotKey(hotkeyWin.Handle, HOTKEY_ID, 0x0001 | 0x0002 | 0x4000, 0x55);
            hotkeyWin.AddHook((IntPtr hw, int msg, IntPtr wp, IntPtr lp, ref bool handled) =>
            {
                if (msg == 0x0312 && wp.ToInt32() == HOTKEY_ID) { ShowAll(); handled = true; }
                return IntPtr.Zero;
            });

            Data.Changed += () => Application.Current.Dispatcher.Invoke(UpdateTray);
            UpdateTray();

            var refresh = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
            refresh.Tick += (_, __) => _ = Data.Refresh();
            refresh.Start();
            var upd = new DispatcherTimer { Interval = TimeSpan.FromMinutes(30) };
            upd.Tick += async (_, __) => { if (await Updater.CheckAndUpdate()) Quit(); };
            upd.Start();

            Application.Current.Dispatcher.InvokeAsync(async () =>
            {
                await Data.Refresh(force: true);
                if (Data.NeedClaudeLogin && Data.Claude.Count == 0) LoginClaude();
                if (await Updater.CheckAndUpdate()) Quit();
            });
        }

        public static Widget Open(PanelConfig c)
        {
            var p = new Widget(c);
            Panels.Add(p);
            if (!c.Hidden) p.Show();
            return p;
        }

        public static void NewPanel()
        {
            var c = new PanelConfig { Layout = "compacto", Services = new() { "claude", "gpt" } };
            Settings.Current.Panels.Add(c); Settings.Current.Save();
            Open(c);
        }

        public static void ClosePanel(Widget p)
        {
            if (Panels.Count <= 1) return;
            Panels.Remove(p); Settings.Current.Panels.Remove(p.Cfg); Settings.Current.Save();
            p.Close();
        }

        public static void ShowAll() { foreach (var p in Panels) p.ShowPanel(); }

        public static void HiddenHint()
        {
            if (hinted) return;
            hinted = true;
            (trays.Values.FirstOrDefault() ?? baseTray)?.ShowBalloonTip(2500, "Uso de Claude", "Sigue aquí. Ctrl+Alt+U o clic en el icono para volver.", System.Windows.Forms.ToolTipIcon.None);
        }

        public static void Quit()
        {
            foreach (var t in trays.Values) { t.Visible = false; t.Dispose(); }
            if (baseTray != null) { baseTray.Visible = false; baseTray.Dispose(); }
            Application.Current.Shutdown();
        }

        // ── Sesiones y claves ──

        public static void LoginClaude() => new LoginWindow("https://claude.ai/login", LoginWindow.Cookie("https://claude.ai", "sessionKey"), () => _ = Data.Refresh(true)).Show();
        public static void LoginGpt() => new LoginWindow("https://chatgpt.com/auth/login", LoginWindow.Cookie("https://chatgpt.com", "session-token"), () => _ = Data.Refresh(true)).Show();
        public static void LoginOpenAI() => new LoginWindow("https://platform.openai.com/login", LoginWindow.OpenAIToken, () =>
        {
            Settings.Current.OpenAISession = true; Settings.Current.Save();
            _ = Data.Refresh(true);
        }).Show();

        public static void SonioxKey() => new KeyWindow("API de Soniox",
            "Pega una clave de organización de Soniox (empieza por snx_org_): console.soniox.com › Settings › Organization API keys. Las de proyecto (snx_proj_) no dan acceso al saldo. Solo se usa para leer el saldo y el gasto, y se guarda cifrada en este ordenador.",
            k => { Secret.Save("soniox", k); _ = Data.Refresh(true); },
            Secret.Read("soniox") != null ? () => { Secret.Delete("soniox"); Data.SonioxW = null; _ = Data.Refresh(true); } : null).Show();

        public static void AccountItems(ItemsControl m)
        {
            void item(string h, Action a) { var i = new MenuItem { Header = h }; i.Click += (_, __) => a(); m.Items.Add(i); }
            item("Iniciar sesión en claude.ai…", LoginClaude);
            item("Iniciar sesión en ChatGPT…", LoginGpt);
            item("Iniciar sesión en OpenAI (saldo de la API)…", LoginOpenAI);
            item("Clave de la API de Soniox…", SonioxKey);
            var bar = new MenuItem { Header = "En la barra de tareas" };
            foreach (var s in SvcInfo.All)
            {
                var k = SvcInfo.Key(s);
                var i = new MenuItem { Header = SvcInfo.Title(s), IsCheckable = true, IsChecked = Settings.Current.Tray.Contains(k) };
                i.Click += (_, __) => { if (Settings.Current.Tray.Contains(k)) Settings.Current.Tray.Remove(k); else Settings.Current.Tray.Add(k); Settings.Current.Save(); UpdateTray(); };
                bar.Items.Add(i);
            }
            m.Items.Add(bar);
            var auto = new MenuItem { Header = "Abrir al iniciar Windows", IsCheckable = true, IsChecked = Settings.Current.AutoStart };
            auto.Click += (_, __) => { Settings.Current.AutoStart = auto.IsChecked; Settings.Current.Save(); Updater.SetAutoStart(Settings.Current.AutoStart); };
            m.Items.Add(auto);
            item($"Versión {Updater.Current} · buscar actualización", async () => { if (await Updater.CheckAndUpdate()) Quit(); });
        }

        // ── Barra de tareas: un icono por servicio con su personaje y su dato ──

        static System.Windows.Forms.ContextMenuStrip TrayMenu()
        {
            var m = new System.Windows.Forms.ContextMenuStrip();
            m.Items.Add("Mostrar los widgets  (Ctrl+Alt+U)", null, (_, __) => ShowAll());
            m.Items.Add("Nuevo widget", null, (_, __) => NewPanel());
            m.Items.Add("Actualizar ahora", null, (_, __) => _ = Data.Refresh(true));
            m.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            m.Items.Add("Iniciar sesión en claude.ai…", null, (_, __) => LoginClaude());
            m.Items.Add("Iniciar sesión en ChatGPT…", null, (_, __) => LoginGpt());
            m.Items.Add("Iniciar sesión en OpenAI…", null, (_, __) => LoginOpenAI());
            m.Items.Add("Clave de la API de Soniox…", null, (_, __) => SonioxKey());
            m.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            m.Items.Add("Salir", null, (_, __) => Quit());
            return m;
        }

        static System.Windows.Forms.NotifyIcon MakeTray()
        {
            var t = new System.Windows.Forms.NotifyIcon { Visible = true, Text = "Uso de Claude", ContextMenuStrip = TrayMenu() };
            t.MouseClick += (_, e) => { if (e.Button == System.Windows.Forms.MouseButtons.Left) ShowAll(); };
            return t;
        }

        static void SetIcon(System.Windows.Forms.NotifyIcon t, System.Drawing.Icon i) { var old = t.Icon; t.Icon = i; old?.Dispose(); }

        public static void UpdateTray()
        {
            var want = SvcInfo.All.Where(s => Settings.Current.Tray.Contains(SvcInfo.Key(s))).ToList();
            foreach (var s in trays.Keys.Where(k => !want.Contains(k)).ToList()) { trays[s].Visible = false; trays[s].Dispose(); trays.Remove(s); }
            // Windows coloca el icono más nuevo a la izquierda: se crean en orden inverso
            foreach (var s in Enumerable.Reverse(want)) if (!trays.ContainsKey(s)) trays[s] = MakeTray();
            foreach (var s in want)
            {
                var c = Data.Card(s);
                SetIcon(trays[s], Sprites.TrayIcon(c));
                var tip = SvcInfo.Title(s) + ": " + (c.HasData ? string.Join(" · ", c.Lines.Take(3).Select(l => $"{l.Label} {l.Value}")) : c.Error ?? "sin datos");
                trays[s].Text = tip.Length > 127 ? tip[..127] : tip;
            }
            // Si no se ha elegido ninguno, queda uno genérico para poder volver a los widgets
            if (want.Count == 0) { baseTray ??= MakeTray(); SetIcon(baseTray, Sprites.TrayIcon(Data.Card(Svc.Claude))); }
            else if (baseTray != null) { baseTray.Visible = false; baseTray.Dispose(); baseTray = null; }
        }
    }

    // ───────────────────────── Arranque ─────────────────────────

    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            // Prueba automática en GitHub: pinta cada formato con datos de ejemplo, guarda capturas y sale
            if (Environment.GetEnvironmentVariable("WIDGET_SELFTEST") != null)
            {
                var tapp = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                Data.LoadSample();
                Settings.Current.Panels = new();
                var panels = Widget.Layouts.Select(l => { var c = new PanelConfig { Layout = l, X = 20, Y = 20 }; var p = new Widget(c); p.Show(); return p; }).ToList();
                var tt = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
                tt.Tick += (_, __) =>
                {
                    tt.Stop();
                    var log = new StringBuilder($"version={Updater.Current}\n");
                    Directory.CreateDirectory("shots");
                    foreach (var p in panels)
                    {
                        var e = p.CardElement;
                        log.AppendLine($"{p.Cfg.Layout}: ventana={p.ActualWidth:0}x{p.ActualHeight:0}");
                        var bmp = new RenderTargetBitmap((int)Math.Ceiling(e.ActualWidth * 1.5), (int)Math.Ceiling(e.ActualHeight * 1.5), 144, 144, PixelFormats.Pbgra32);
                        var dv = new DrawingVisual();
                        using (var dc = dv.RenderOpen()) dc.DrawRectangle(new VisualBrush(e), null, new Rect(0, 0, e.ActualWidth, e.ActualHeight));
                        bmp.Render(dv);
                        var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmp));
                        using var f = File.Create(IOPath.Combine("shots", p.Cfg.Layout + ".png")); enc.Save(f);
                    }
                    foreach (var s in SvcInfo.All)
                        using (var f = File.Create(IOPath.Combine("shots", "icono-" + SvcInfo.Key(s) + ".png")))
                            Sprites.TrayIcon(Data.Card(s)).ToBitmap().Save(f, System.Drawing.Imaging.ImageFormat.Png);
                    File.WriteAllText("selftest.txt", log.ToString());
                    tapp.Shutdown();
                };
                tt.Start();
                tapp.Run();
                return;
            }

            // Primera ejecución desde Descargas: se copia a su sitio y se abre desde allí
            if (Updater.EnsureInstalled()) return;
            using var single = new System.Threading.Mutex(true, "UsoDeClaude-unico", out bool first);
            if (!first) return;

            Updater.SetAutoStart(Settings.Current.AutoStart);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.Startup += (_, __) => AppCtl.Start();
            app.Run();
        }
    }
}
