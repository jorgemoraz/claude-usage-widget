// Uso de Claude para Windows — ventana flotante con el uso de Claude y ChatGPT.
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

    public class Settings
    {
        public double X { get; set; } = double.NaN;
        public double Y { get; set; } = double.NaN;
        public double Zoom { get; set; } = 1;
        public bool ShowGpt { get; set; } = true;
        public bool Minimized { get; set; }
        public bool AutoStart { get; set; } = true;

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
            return v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;
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
            foreach (var (key, label, span) in new[] { ("five_hour", "Sesión (5 h)", 18000.0), ("seven_day", "Semana · todos los modelos", 604800.0) })
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

    // ───────────────────────── Estado de ánimo y mascota ─────────────────────────

    public enum Mood { Feliz, Tranquilo, Preocupado, Panico, Agotado }

    public static class Mascot
    {
        public static Mood From(double? p) => p == null ? Mood.Tranquilo : p >= 100 ? Mood.Agotado : p >= 90 ? Mood.Panico : p >= 70 ? Mood.Preocupado : p >= 40 ? Mood.Tranquilo : Mood.Feliz;

        static readonly Dictionary<Mood, string[]> Phrases = new()
        {
            [Mood.Feliz] = new[] { "A tope de energía", "Pídeme lo que quieras", "Fresco como una lechuga" },
            [Mood.Tranquilo] = new[] { "Vamos bien", "Ritmo de crucero", "Aún queda gasolina" },
            [Mood.Preocupado] = new[] { "Ojo, que se acaba", "Dosifícame un poco", "Esto baja rápido" },
            [Mood.Panico] = new[] { "¡Últimas gotas!", "¡Que me apago!", "Solo para lo importante" },
            [Mood.Agotado] = new[] { "Fuera de combate", "Zzz… vuelvo pronto" },
        };

        public static string Phrase(Mood m) { var l = Phrases[m]; return l[(int)(DateTimeOffset.Now.ToUnixTimeSeconds() / 90 % l.Length)]; }

        static string Ell(double cx, double cy, double rx, double ry) =>
            FormattableString.Invariant($"M{cx - rx},{cy} a{rx},{ry} 0 1 0 {2 * rx},0 a{rx},{ry} 0 1 0 {-2 * rx},0");

        const string Body = "M14,12 h20 a10,10 0 0 1 10,10 v14 a10,10 0 0 1 -10,10 h-20 a10,10 0 0 1 -10,-10 v-14 a10,10 0 0 1 10,-10 z";

        static WPath Fill(string d, Color c) => new WPath { Data = Geometry.Parse(d), Fill = new SolidColorBrush(c) };
        static WPath Stroke(string d, Color c, double w = 1.8) => new WPath
        { Data = Geometry.Parse(d), Stroke = new SolidColorBrush(c), StrokeThickness = w, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };

        static Color C(uint argb) => Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

        /// <summary>Dibuja la mascota (personaje original) en un lienzo de 48×48.</summary>
        public static Canvas Draw(Mood mood, Color accent)
        {
            var cv = new Canvas { Width = 48, Height = 48 };
            var ink = C(0xFF291A17);
            var tired = mood == Mood.Agotado;
            var body = tired ? C(0xFF9C908D) : C(0xFFE0896A);
            void add(UIElement e) => cv.Children.Add(e);
            add(Stroke("M24,12 Q21.5,8 24,4.5", body, 1.6));
            add(Fill(Ell(24, 4.5, 2.6, 2.6), tired ? Colors.Gray : accent));
            add(Fill(Body, body));
            add(Fill(Ell(15, 17, 3.5, 2), C(0x38FFFFFF)));
            void eyes()
            {
                add(Fill(Ell(18, 26, 2.2, 2.8), ink)); add(Fill(Ell(30, 26, 2.2, 2.8), ink));
                add(Fill(Ell(18.8, 25, 0.8, 0.8), Colors.White)); add(Fill(Ell(30.8, 25, 0.8, 0.8), Colors.White));
            }
            void cheeks() { add(Fill(Ell(12.5, 31, 2.2, 1.4), C(0x73FF8FA3))); add(Fill(Ell(35.5, 31, 2.2, 1.4), C(0x73FF8FA3))); }
            void drop(double x) => add(Fill(FormattableString.Invariant($"M{x},15 C{x + 2.2},18 {x + 2.6},20.5 {x},21.5 C{x - 2.6},20.5 {x - 2.2},18 {x},15 Z"), C(0xFF8FCCFF)));
            switch (mood)
            {
                case Mood.Feliz: eyes(); cheeks(); add(Fill("M19,32 Q24,39.5 29,32 Z", ink)); break;
                case Mood.Tranquilo: eyes(); cheeks(); add(Stroke("M21,33 Q24,35.8 27,33", ink)); break;
                case Mood.Preocupado:
                    eyes(); add(Stroke("M14.5,21.5 L21,20 M27,20 L33.5,21.5", ink));
                    add(Stroke("M19,35 Q21.5,32.5 24,35 Q26.5,37.5 29,35", ink)); drop(40); break;
                case Mood.Panico:
                    add(Fill(Ell(18, 26, 3.6, 3.6), Colors.White)); add(Fill(Ell(30, 26, 3.6, 3.6), Colors.White));
                    add(Fill(Ell(18, 26, 1.4, 1.4), ink)); add(Fill(Ell(30, 26, 1.4, 1.4), ink));
                    add(Stroke("M14,19.5 L21,18.5 M27,18.5 L34,19.5", ink)); add(Fill(Ell(24, 36, 2.6, 3.2), ink));
                    drop(40); drop(8); break;
                case Mood.Agotado:
                    add(Stroke("M15.5,26 Q18,28.6 20.5,26 M27.5,26 Q30,28.6 32.5,26", ink));
                    add(Stroke(Ell(24, 35, 1.8, 1.8), ink, 1.4)); add(Stroke("M37,5 h4.5 l-4.5,5 h4.5", Colors.White, 1.4)); break;
            }
            return cv;
        }

        /// <summary>Icono de la bandeja: carita con el porcentaje de la sesión.</summary>
        public static System.Drawing.Icon TrayIcon(double? percent)
        {
            using var bmp = new System.Drawing.Bitmap(32, 32);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                g.Clear(System.Drawing.Color.Transparent);
                var c = percent == null ? System.Drawing.Color.FromArgb(0xE0, 0x89, 0x6A)
                    : System.Drawing.Color.FromArgb(Util.UsageColor(percent.Value).R, Util.UsageColor(percent.Value).G, Util.UsageColor(percent.Value).B);
                using var path = new System.Drawing.Drawing2D.GraphicsPath();
                path.AddArc(1, 1, 12, 12, 180, 90); path.AddArc(19, 1, 12, 12, 270, 90);
                path.AddArc(19, 19, 12, 12, 0, 90); path.AddArc(1, 19, 12, 12, 90, 90); path.CloseFigure();
                using (var b = new System.Drawing.SolidBrush(c)) g.FillPath(b, path);
                var text = percent == null ? "?" : Math.Min(99, (int)Math.Round(percent.Value)).ToString();
                using var f = new System.Drawing.Font("Segoe UI", text.Length > 1 ? 15 : 18, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel);
                var sz = g.MeasureString(text, f);
                g.DrawString(text, f, System.Drawing.Brushes.Black, (32 - sz.Width) / 2, (32 - sz.Height) / 2 + 1);
            }
            return System.Drawing.Icon.FromHandle(bmp.GetHicon());
        }
    }

    // ───────────────────────── Ventana de inicio de sesión ─────────────────────────

    public class LoginWindow : Window
    {
        readonly string url, cookieUrl, cookieName;
        readonly Action onDone;
        readonly WebView2 web = new WebView2();
        DispatcherTimer poll;

        public LoginWindow(string url, string cookieUrl, string cookieName, Action onDone)
        {
            this.url = url; this.cookieUrl = cookieUrl; this.cookieName = cookieName; this.onDone = onDone;
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
                        var cookies = await web.CoreWebView2.CookieManager.GetCookiesAsync(cookieUrl);
                        if (cookies.Any(c => c.Name.Contains(cookieName))) { poll.Stop(); Close(); onDone(); }
                    }
                    catch { }
                };
                poll.Start();
            };
            Closed += (_, __) => poll?.Stop();
        }
    }

    // ───────────────────────── Ventana flotante ─────────────────────────

    public class Widget : Window
    {
        readonly Settings st = Settings.Load();
        List<Row> claude = new(), gpt = new();
        string claudeErr, gptErr;
        bool loading, askedLogin;
        DateTimeOffset? updated;
        readonly ScaleTransform scale = new ScaleTransform(1, 1);
        readonly TranslateTransform bob = new TranslateTransform();
        System.Windows.Forms.NotifyIcon tray;
        Border card;
        double t;

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        const int HOTKEY_ID = 0x5544;

        public Widget()
        {
            Title = "Uso de Claude";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
            scale.ScaleX = scale.ScaleY = st.Zoom;

            if (!double.IsNaN(st.X) && !double.IsNaN(st.Y) &&
                st.X > SystemParameters.VirtualScreenLeft - 50 && st.X < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 50 &&
                st.Y > SystemParameters.VirtualScreenTop - 20 && st.Y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 50)
            { Left = st.X; Top = st.Y; }
            else
            { WindowStartupLocation = WindowStartupLocation.Manual; Left = SystemParameters.WorkArea.Right - 330; Top = SystemParameters.WorkArea.Top + 20; }

            MouseLeftButtonDown += (_, e) => { if (e.ButtonState == MouseButtonState.Pressed) { try { DragMove(); } catch { } SavePos(); } };
            ContextMenu = BuildMenu();
            SetupTray();
            Render();

            SourceInitialized += (_, __) =>
            {
                var h = new WindowInteropHelper(this).Handle;
                RegisterHotKey(h, HOTKEY_ID, 0x0001 | 0x0002 | 0x4000, 0x55); // Ctrl+Alt+U
                HwndSource.FromHwnd(h).AddHook((IntPtr hw, int msg, IntPtr wp, IntPtr lp, ref bool handled) =>
                {
                    if (msg == 0x0312 && wp.ToInt32() == HOTKEY_ID) { ShowWidget(); handled = true; }
                    return IntPtr.Zero;
                });
            };

            var anim = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(40) };
            anim.Tick += (_, __) => Animate();
            anim.Start();

            var refresh = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
            refresh.Tick += (_, __) => _ = Refresh();
            refresh.Start();

            var upd = new DispatcherTimer { Interval = TimeSpan.FromMinutes(30) };
            upd.Tick += async (_, __) => { if (await Updater.CheckAndUpdate()) Quit(); };
            upd.Start();

            Loaded += async (_, __) =>
            {
                if (st.Minimized) Minimize();
                await Refresh();
                if (await Updater.CheckAndUpdate()) Quit();
            };
        }

        void SavePos() { st.X = Left; st.Y = Top; st.Save(); }

        void Animate()
        {
            t += 0.04;
            var mood = Mascot.From(claude.Count > 0 ? claude.Max(r => r.Percent) : null);
            switch (mood)
            {
                case Mood.Feliz: bob.Y = -Math.Abs(Math.Sin(t * 2.6)) * 3; bob.X = 0; break;
                case Mood.Panico: bob.X = Math.Sin(t * 38) * 1.2; bob.Y = Math.Sin(t * 29) * 0.6; break;
                case Mood.Agotado: bob.Y = 1 + Math.Sin(t * 0.9) * 0.6; bob.X = 0; break;
                default: bob.Y = Math.Sin(t * 1.8) * 1.2; bob.X = 0; break;
            }
        }

        // ── Datos ──

        async Task Refresh()
        {
            if (loading) return;
            loading = true; Render();
            var c = await Claude.Fetch();
            if (c.rows != null) { claude = c.rows; claudeErr = null; } else claudeErr = c.error;
            if (st.ShowGpt)
            {
                var g = await Gpt.Fetch();
                if (g.rows != null) { gpt = g.rows; gptErr = null; } else gptErr = g.error;
            }
            updated = DateTimeOffset.Now;
            loading = false;
            Render();
            UpdateTray();
            if (claude.Count == 0 && c.needLogin && !askedLogin) { askedLogin = true; LoginClaude(); }
        }

        void LoginClaude() => new LoginWindow("https://claude.ai/login", "https://claude.ai", "sessionKey", () => _ = Refresh()).Show();
        void LoginGpt() => new LoginWindow("https://chatgpt.com/auth/login", "https://chatgpt.com", "session-token", () => _ = Refresh()).Show();

        // ── Interfaz ──

        static TextBlock Txt(string s, double size, Color c, FontWeight? w = null) =>
            new TextBlock { Text = s, FontSize = size, Foreground = new SolidColorBrush(c), FontWeight = w ?? FontWeights.Normal, FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI") };

        static readonly Color White = Colors.White;
        static Color Wa(byte a) => Color.FromArgb(a, 255, 255, 255);

        UIElement Bar(double p, Color c)
        {
            var g = new Grid { Height = 7, Margin = new Thickness(0, 4, 0, 0) };
            g.Children.Add(new Border { CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Wa(26)) });
            var fill = new Border
            {
                CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Left,
                Background = new LinearGradientBrush(Color.FromArgb(170, c.R, c.G, c.B), c, 0)
            };
            g.SizeChanged += (_, e) => fill.Width = Math.Max(p > 0 ? 7 : 0, e.NewSize.Width * Math.Min(p, 100) / 100);
            g.Children.Add(fill);
            return g;
        }

        UIElement RowView(Row r)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            var head = new DockPanel();
            var pct = Txt($"{Math.Round(r.Percent)} %", 18, Util.UsageColor(r.Percent), FontWeights.SemiBold);
            DockPanel.SetDock(pct, Dock.Right);
            head.Children.Add(pct);
            head.Children.Add(Txt(r.Label, 12, Wa(190), FontWeights.Medium));
            sp.Children.Add(head);
            sp.Children.Add(Bar(r.Percent, Util.UsageColor(r.Percent)));
            if (r.ResetAt != null) sp.Children.Add(Txt(Util.ResetText(r.ResetAt.Value), 10.5, Wa(128)));
            return sp;
        }

        Button Ctl(string glyph, string tip, Action a)
        {
            var b = new Button
            {
                Content = Txt(glyph, 10, White, FontWeights.Bold), Width = 20, Height = 20, Margin = new Thickness(3, 0, 0, 0),
                ToolTip = tip, Cursor = Cursors.Hand, Focusable = false
            };
            b.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
                "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Button'>" +
                "<Border CornerRadius='10' Background='#24FFFFFF' BorderBrush='#40FFFFFF' BorderThickness='0.5'>" +
                "<ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/></Border></ControlTemplate>");
            b.Click += (_, __) => a();
            return b;
        }

        void Render()
        {
            var worst = claude.Count > 0 ? claude.Max(r => r.Percent) : (double?)null;
            var mood = Mascot.From(worst);
            var session = claude.FirstOrDefault(r => !r.IsWeek);

            var root = new StackPanel { Width = 300, Margin = new Thickness(16) };

            // Cabecera: mascota + frase + número grande
            var head = new DockPanel();
            var mascot = new Viewbox { Width = 68, Height = 68, Child = Mascot.Draw(mood, Util.UsageColor(worst ?? 0)), RenderTransform = bob, Cursor = Cursors.Hand, ToolTip = "Actualizar" };
            mascot.MouseLeftButtonDown += (_, e) => { e.Handled = true; _ = Refresh(); };
            DockPanel.SetDock(mascot, Dock.Left);
            head.Children.Add(mascot);
            var info = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            var top = new DockPanel();
            var ctl = new StackPanel { Orientation = Orientation.Horizontal };
            ctl.Children.Add(Ctl("−", "Más pequeño", () => SetZoom(-1)));
            ctl.Children.Add(Ctl("+", "Más grande", () => SetZoom(1)));
            ctl.Children.Add(Ctl("⌄", "Minimizar a la bandeja (Ctrl+Alt+U para volver)", Minimize));
            DockPanel.SetDock(ctl, Dock.Right);
            top.Children.Add(ctl);
            top.Children.Add(Txt("USO DE CLAUDE", 10, Wa(115), FontWeights.Bold));
            info.Children.Add(top);
            info.Children.Add(Txt(claude.Count == 0 ? "Conectando…" : Mascot.Phrase(mood), 14, Wa(242), FontWeights.SemiBold));
            if (session != null)
            {
                var big = new StackPanel { Orientation = Orientation.Horizontal };
                big.Children.Add(Txt($"{Math.Round(session.Percent)}", 36, Util.UsageColor(session.Percent), FontWeights.Bold));
                var lbl = Txt(" % de la sesión", 11, Wa(140), FontWeights.Medium); lbl.VerticalAlignment = VerticalAlignment.Bottom; lbl.Margin = new Thickness(2, 0, 0, 8);
                big.Children.Add(lbl);
                info.Children.Add(big);
            }
            head.Children.Add(info);
            root.Children.Add(head);

            if (claude.Count == 0) root.Children.Add(Txt(claudeErr ?? "Cargando…", 12, Wa(180)));
            foreach (var r in claude) root.Children.Add(RowView(r));
            if (claude.Count > 0 && claudeErr != null) root.Children.Add(Txt("⚠ " + claudeErr, 11, Color.FromRgb(255, 180, 100)));

            if (st.ShowGpt && (gpt.Count > 0 || gptErr != null))
            {
                var sec = Txt("CHATGPT", 10, Wa(115), FontWeights.Bold); sec.Margin = new Thickness(0, 14, 0, 0);
                root.Children.Add(sec);
                if (gpt.Count == 0) root.Children.Add(Txt(gptErr, 12, Wa(160)));
                foreach (var r in gpt) root.Children.Add(RowView(r));
            }

            var foot = Txt(loading ? "actualizando…" : updated != null ? $"Actualizado {Util.HourText(updated.Value)} · toca la mascota para actualizar" : "", 10, Wa(100));
            foot.HorizontalAlignment = HorizontalAlignment.Right; foot.Margin = new Thickness(0, 10, 0, 0);
            root.Children.Add(foot);

            var tint = Mascot.From(worst) switch
            {
                Mood.Feliz => Color.FromRgb(0x5C, 0xCC, 0x80),
                Mood.Preocupado => Color.FromRgb(0xFF, 0xAD, 0x42),
                Mood.Panico => Color.FromRgb(0xFF, 0x61, 0x59),
                Mood.Agotado => Color.FromRgb(0x8C, 0x8C, 0x9E),
                _ => Color.FromRgb(0x73, 0xB3, 0xF2)
            };
            var bg = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
            bg.GradientStops.Add(new GradientStop(Color.FromArgb(240, (byte)(0x1C + tint.R / 12), (byte)(0x18 + tint.G / 12), (byte)(0x17 + tint.B / 12)), 0));
            bg.GradientStops.Add(new GradientStop(Color.FromArgb(240, 0x1C, 0x18, 0x17), 0.55));

            card = new Border
            {
                CornerRadius = new CornerRadius(22), Background = bg, Child = root, Margin = new Thickness(10),
                BorderThickness = new Thickness(1),
                BorderBrush = new LinearGradientBrush(Wa(110), Wa(30), 90),
                LayoutTransform = scale,
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.45 }
            };
            Content = card;
        }

        static readonly double[] Steps = { 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2 };

        void SetZoom(int dir)
        {
            var z = st.Zoom;
            var next = dir > 0 ? Steps.FirstOrDefault(s => s > z + 0.001) : Steps.LastOrDefault(s => s < z - 0.001);
            if (next == 0) return;
            st.Zoom = next; st.Save();
            scale.ScaleX = scale.ScaleY = next;
        }

        // ── Bandeja del sistema ──

        void SetupTray()
        {
            tray = new System.Windows.Forms.NotifyIcon { Visible = true, Text = "Uso de Claude", Icon = Mascot.TrayIcon(null) };
            tray.MouseClick += (_, e) => { if (e.Button == System.Windows.Forms.MouseButtons.Left) ShowWidget(); };
            var m = new System.Windows.Forms.ContextMenuStrip();
            m.Items.Add("Mostrar widget  (Ctrl+Alt+U)", null, (_, __) => ShowWidget());
            m.Items.Add("Actualizar ahora", null, (_, __) => _ = Refresh());
            m.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            m.Items.Add("Iniciar sesión en claude.ai…", null, (_, __) => LoginClaude());
            m.Items.Add("Iniciar sesión en ChatGPT…", null, (_, __) => LoginGpt());
            m.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            m.Items.Add("Salir", null, (_, __) => Quit());
            tray.ContextMenuStrip = m;
        }

        void UpdateTray()
        {
            var s = claude.FirstOrDefault(r => !r.IsWeek);
            var w = claude.FirstOrDefault(r => r.IsWeek);
            var gs = gpt.FirstOrDefault(r => !r.IsWeek);
            var gw = gpt.FirstOrDefault(r => r.IsWeek);
            string p(Row r) => r == null ? "–" : $"{Math.Round(r.Percent)}%";
            var text = $"Claude sem {p(w)} · 5h {p(s)}" + (st.ShowGpt && gpt.Count > 0 ? $"\nGPT sem {p(gw)} · 5h {p(gs)}" : "");
            tray.Text = text.Length > 127 ? text[..127] : text;
            var old = tray.Icon;
            tray.Icon = Mascot.TrayIcon(s?.Percent);
            old?.Dispose();
        }

        void Minimize() { Hide(); st.Minimized = true; st.Save(); tray.ShowBalloonTip(2000, "Uso de Claude", "Sigue aquí. Ctrl+Alt+U o clic en el icono para volver.", System.Windows.Forms.ToolTipIcon.None); }

        void ShowWidget()
        {
            st.Minimized = false; st.Save();
            Show(); Activate(); Topmost = true;
            var wa = SystemParameters.WorkArea;
            if (Left > SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 40 || Top > SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 40)
            { Left = wa.Right - ActualWidth - 20; Top = wa.Top + 20; SavePos(); }
        }

        void Quit() { tray.Visible = false; tray.Dispose(); Application.Current.Shutdown(); }

        ContextMenu BuildMenu()
        {
            var m = new ContextMenu();
            void item(string h, Action a) { var i = new MenuItem { Header = h }; i.Click += (_, __) => a(); m.Items.Add(i); }
            item("Actualizar ahora", () => _ = Refresh());
            item("Más grande", () => SetZoom(1));
            item("Más pequeño", () => SetZoom(-1));
            item("Minimizar a la bandeja", Minimize);
            m.Items.Add(new Separator());
            item("Iniciar sesión en claude.ai…", LoginClaude);
            item("Iniciar sesión en ChatGPT…", LoginGpt);
            var gptItem = new MenuItem { Header = "Mostrar ChatGPT", IsCheckable = true, IsChecked = st.ShowGpt };
            gptItem.Click += (_, __) => { st.ShowGpt = gptItem.IsChecked; st.Save(); _ = Refresh(); };
            m.Items.Add(gptItem);
            var auto = new MenuItem { Header = "Abrir al iniciar Windows", IsCheckable = true, IsChecked = st.AutoStart };
            auto.Click += (_, __) => { st.AutoStart = auto.IsChecked; st.Save(); Updater.SetAutoStart(st.AutoStart); };
            m.Items.Add(auto);
            m.Items.Add(new Separator());
            item($"Versión {Updater.Current} · buscar actualización", async () => { if (await Updater.CheckAndUpdate()) Quit(); });
            item("Salir", Quit);
            return m;
        }
    }

    // ───────────────────────── Arranque ─────────────────────────

    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            // Prueba automática en GitHub: abre la ventana, mide y sale
            if (Environment.GetEnvironmentVariable("WIDGET_SELFTEST") != null)
            {
                var tapp = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                var tw = new Widget();
                tw.Show();
                var tt = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
                tt.Tick += (_, __) =>
                {
                    File.WriteAllText("selftest.txt", $"ventana={tw.ActualWidth:0}x{tw.ActualHeight:0} version={Updater.Current}");
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

            var settings = Settings.Load();
            Updater.SetAutoStart(settings.AutoStart);

            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var w = new Widget();
            w.Show();
            app.Run();
        }
    }
}
