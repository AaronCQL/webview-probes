// WebView2 probe host (WinForms window + CoreWebView2Controller) and module DLL loader.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

static class Util
{
    public static double NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public static void Emit(string s)
    {
        Console.Out.WriteLine(s);
        Console.Out.Flush();
    }

    public static string Json(object o) => JsonSerializer.Serialize(o);

    public static uint Fnv1a(byte[] d)
    {
        uint h = 0x811c9dc5;
        foreach (var b in d) { h ^= b; h *= 0x01000193; }
        return h;
    }

    public static Dictionary<string, string> ParseArgs(string[] argv)
    {
        var o = new Dictionary<string, string>();
        for (int i = 0; i < argv.Length; i++)
        {
            if (!argv[i].StartsWith("--")) continue;
            var k = argv[i].Substring(2);
            if (i + 1 < argv.Length && !argv[i + 1].StartsWith("--")) { o[k] = argv[i + 1]; i++; }
            else o[k] = "1";
        }
        return o;
    }

    public static string Get(this Dictionary<string, string> d, string k, string def) => d.TryGetValue(k, out var v) ? v : def;

    public static Dictionary<string, string> Query(Uri u)
    {
        var o = new Dictionary<string, string>();
        var q = u.Query.TrimStart('?');
        if (q.Length == 0) return o;
        foreach (var p in q.Split('&'))
        {
            var i = p.IndexOf('=');
            if (i < 0) o[Uri.UnescapeDataString(p)] = "";
            else o[Uri.UnescapeDataString(p.Substring(0, i))] = Uri.UnescapeDataString(p.Substring(i + 1));
        }
        return o;
    }

    public static bool Contains(byte[] hay, byte[] needle)
    {
        if (needle.Length == 0) return true;
        for (int i = 0; i + needle.Length <= hay.Length; i++)
        {
            int j = 0;
            while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return true;
        }
        return false;
    }
}

static class Program
{
    [STAThread]
    static int Main(string[] argv)
    {
        var args = Util.ParseArgs(argv);
        var mode = args.Get("mode", "main");
        if (mode == "modules") return Modules.Run(args.Get("dir", "."), true);
        if (mode == "unload") return Modules.UnloadChild(args.Get("dir", "."), args.Get("lang", "go"));
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (s, e) => Util.Emit("RESULT host-exception " + Util.Json(new { error = e.Exception.ToString() }));
        AppDomain.CurrentDomain.UnhandledException += (s, e) => Util.Emit("RESULT host-exception " + Util.Json(new { error = e.ExceptionObject.ToString() }));
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        var form = new ProbeForm(args);
        Application.Run(form);
        return form.ExitCode;
    }
}

sealed class ProbeForm : Form
{
    readonly Dictionary<string, string> args;
    readonly string mode, config, origin, webRoot;
    readonly Dictionary<string, object> results = new Dictionary<string, object>();
    readonly List<double> arrivals = new List<double>();
    CoreWebView2Environment env;
    CoreWebView2Controller controller;
    CoreWebView2 core;
    bool finished;
    public int ExitCode = 0;
    string killMethod = "";
    double killAt;
    readonly Dictionary<string, object> configNotes = new Dictionary<string, object>();

    public ProbeForm(Dictionary<string, string> a)
    {
        args = a;
        mode = a.Get("mode", "main");
        config = a.Get("config", "default");
        origin = a.Get("origin", "https://probe.localhost");
        webRoot = Path.GetFullPath(a.Get("web", "web"));
        Text = "probe";
        ClientSize = new Size(900, 700);
        StartPosition = FormStartPosition.Manual;
        Location = new Point(40, 40);
        Shown += async (s, e) => await Init();
        Resize += (s, e) => { if (controller != null) controller.Bounds = ClientRectangle; };
    }

    async Task Init()
    {
        try
        {
            if (args.ContainsKey("modules-dir"))
            {
                // load all four module DLLs into this (WebView2 host) process first
                Modules.Run(args["modules-dir"], false, "modules-inproc");
            }
            var extra = new List<string>();
            if (config.Contains("flag")) extra.Add("--disable-background-timer-throttling");
            if (args.ContainsKey("browser-args")) extra.Add(args["browser-args"]);
            configNotes["additionalBrowserArguments"] = string.Join(" ", extra);
            var reg = new CoreWebView2CustomSchemeRegistration("probe") { TreatAsSecure = true, HasAuthorityComponent = true };
            var opts = new CoreWebView2EnvironmentOptions(string.Join(" ", extra), "", null, false,
                new List<CoreWebView2CustomSchemeRegistration> { reg });
            var udf = Path.Combine(Path.GetTempPath(), "probe-udf-" + Process.GetCurrentProcess().Id);
            env = await CoreWebView2Environment.CreateAsync(null, udf, opts);
            controller = await env.CreateCoreWebView2ControllerAsync(Handle);
            controller.Bounds = ClientRectangle;
            controller.IsVisible = true;
            core = controller.CoreWebView2;
            core.Settings.AreDevToolsEnabled = true;
            core.AddWebResourceRequestedFilter(origin + "/*", CoreWebView2WebResourceContext.All,
                CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += OnRequest;
            core.WebMessageReceived += OnMessage;
            core.ProcessFailed += OnProcessFailed;
            core.NavigationCompleted += (s, e) => { if (!e.IsSuccess) Util.Emit("PROBE navigation failed: " + e.WebErrorStatus + " http=" + e.HttpStatusCode); };

            var timeout = double.Parse(args.Get("timeout", "300"));
            var wd = new Timer { Interval = (int)(timeout * 1000) };
            wd.Tick += (s, e) => { wd.Stop(); if (mode == "events") RecordEventsHost(); results["timeout"] = new { afterSecs = timeout }; Util.Emit("RESULT timeout {\"afterSecs\":" + timeout + "}"); Finish(2); };
            wd.Start();

            string start;
            if (mode == "throttle") start = "/coi/index.html?mode=throttle&config=" + config;
            else if (mode == "events") start = "/coi/index.html?mode=events&delivery=" + args.Get("delivery", "post") + "&rate=" + args.Get("rate", "10000") + "&secs=" + args.Get("secs", "30");
            else start = "/nocoi/index.html?mode=" + mode;
            Util.Emit($"PROBE start mode={mode} config={config} url={origin}{start} runtime={env.BrowserVersionString}");
            core.Navigate(origin + start);
        }
        catch (Exception ex)
        {
            Util.Emit("RESULT host-error " + Util.Json(new { error = ex.ToString() }));
            Finish(5);
        }
    }

    void Finish(int code)
    {
        if (finished) return;
        finished = true;
        var host = new Dictionary<string, object>
        {
            ["os"] = Environment.OSVersion.VersionString,
            ["webview2Runtime"] = env?.BrowserVersionString ?? "?",
            ["sdk"] = typeof(CoreWebView2Environment).Assembly.GetName().Version?.ToString(),
            ["origin"] = origin,
            ["mode"] = mode,
            ["config"] = config,
            ["configNotes"] = configNotes,
        };
        results["host"] = host;
        Util.Emit("RESULT host " + Util.Json(host));
        if (args.ContainsKey("out")) File.WriteAllText(args["out"], Util.Json(results));
        Util.Emit("PROBE_DONE code=" + code);
        ExitCode = code;
        BeginInvoke(new Action(() => { try { controller?.Close(); } catch { } Close(); }));
    }

    void Record(string phase, byte[] body)
    {
        var text = Encoding.UTF8.GetString(body);
        try { results[phase] = JsonDocument.Parse(text).RootElement.Clone(); } catch { results[phase] = text; }
        Util.Emit("RESULT " + phase + " " + text);
        if (phase == "done")
        {
            if (mode == "events") { SampleMemory("after"); RecordEventsHost(); }
            BeginInvoke(new Action(() => Finish(0)));
        }
    }

    // ---------------- script messages ----------------
    void OnMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string s;
        try { s = e.TryGetWebMessageAsString(); } catch { return; }
        if (s.StartsWith("Q:"))
        {
            int i = s.IndexOf(':', 2);
            var id = s.Substring(2, i - 2);
            var payload = s.Substring(i + 1);
            core.PostWebMessageAsString("R:" + id + ":" + (payload == "ping" ? "pong" : payload));
        }
    }

    // ---------------- crash ----------------
    void OnProcessFailed(object sender, CoreWebView2ProcessFailedEventArgs e)
    {
        var t = Util.NowMs();
        var info = new Dictionary<string, object>
        {
            ["processFailedEvent"] = true,
            ["kind"] = e.ProcessFailedKind.ToString(),
            ["reason"] = e.Reason.ToString(),
            ["exitCode"] = e.ExitCode,
            ["method"] = killMethod,
            ["msFromKillToEvent"] = killAt > 0 ? (int)(t - killAt) : -1,
        };
        results["crash-host"] = info;
        Util.Emit("RESULT crash-host " + Util.Json(info));
        if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessExited ||
            e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive ||
            e.ProcessFailedKind == CoreWebView2ProcessFailedKind.FrameRenderProcessExited)
        {
            if (killMethod.Length > 0) core.Navigate(origin + "/coi/index.html?recovered=1&mode=" + mode);
        }
        else
        {
            Finish(3);
        }
    }

    void KillRenderer()
    {
        killAt = Util.NowMs();
        var pids = env.GetProcessInfos().Where(p => p.Kind == CoreWebView2ProcessKind.Renderer).Select(p => p.ProcessId).ToList();
        killMethod = "Process.Kill(renderer) x" + pids.Count;
        foreach (var pid in pids)
        {
            try { Process.GetProcessById(pid).Kill(); } catch (Exception ex) { Util.Emit("PROBE kill failed " + ex.Message); }
        }
        if (pids.Count == 0) { killMethod = ""; Util.Emit("RESULT crash-host {\"error\":\"no renderer pid\"}"); Finish(4); }
    }

    // ---------------- resource handler ----------------
    void OnRequest(object sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var req = e.Request;
        var uri = new Uri(req.Uri);
        var path = uri.AbsolutePath;
        var q = Util.Query(uri);
        int status = 200;
        string ctype = "text/plain; charset=utf-8";
        byte[] body = Array.Empty<byte>();
        bool isolate = false;

        if (path.StartsWith("/coi/") || path.StartsWith("/nocoi/"))
        {
            isolate = path.StartsWith("/coi/");
            var rel = path.Substring(isolate ? 5 : 7);
            var file = Path.Combine(webRoot, rel.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(file))
            {
                body = File.ReadAllBytes(file);
                ctype = rel.EndsWith(".html") ? "text/html; charset=utf-8" : rel.EndsWith(".js") ? "text/javascript" : "application/octet-stream";
            }
            else status = 404;
        }
        else if (path == "/ping") body = Encoding.UTF8.GetBytes("pong");
        else if (path == "/wping") { arrivals.Add(Util.NowMs()); body = Encoding.UTF8.GetBytes("ok"); }
        else if (path == "/echo")
        {
            var (b, src) = ReadBody(req);
            var marker = q.TryGetValue("marker", out var m) && Util.Contains(b, Encoding.UTF8.GetBytes(m));
            string ct = "";
            try { ct = req.Headers.Contains("Content-Type") ? req.Headers.GetHeader("Content-Type") : ""; } catch { }
            body = Encoding.UTF8.GetBytes(Util.Json(new { len = b.Length, fnv = Util.Fnv1a(b), ct, marker, src }));
            ctype = "application/json";
        }
        else if (path.StartsWith("/result/"))
        {
            var (b, _) = ReadBody(req);
            Record(Uri.UnescapeDataString(path.Substring(8)), b);
            body = Encoding.UTF8.GetBytes("ok");
        }
        else if (path.StartsWith("/cmd/")) body = Encoding.UTF8.GetBytes(Command(path.Substring(5), q));
        else if (path == "/pull") { body = Encoding.UTF8.GetBytes(Pull()); ctype = "application/json"; }
        else status = 404;

        var headers = new StringBuilder();
        headers.Append("Content-Type: ").Append(ctype).Append("\r\n");
        headers.Append("Cache-Control: no-store\r\n");
        headers.Append("Cross-Origin-Resource-Policy: same-origin\r\n");
        if (isolate)
        {
            headers.Append("Cross-Origin-Opener-Policy: same-origin\r\n");
            headers.Append("Cross-Origin-Embedder-Policy: require-corp\r\n");
        }
        e.Response = env.CreateWebResourceResponse(new MemoryStream(body), status, status == 200 ? "OK" : "Not Found", headers.ToString());
    }

    static (byte[], string) ReadBody(CoreWebView2WebResourceRequest req)
    {
        Stream s;
        try { s = req.Content; } catch (Exception ex) { return (Array.Empty<byte>(), "error:" + ex.GetType().Name); }
        if (s == null) return (Array.Empty<byte>(), "null");
        var ms = new MemoryStream();
        s.CopyTo(ms);
        return (ms.ToArray(), "stream");
    }

    string Command(string name, Dictionary<string, string> q)
    {
        switch (name)
        {
            case "crash":
                Later(300, KillRenderer);
                return "ok";
            case "arrivals":
                {
                    var from = double.Parse(q.Get("from", "0"));
                    var to = double.Parse(q.Get("to", "0"));
                    return Util.Json(new { count = arrivals.Count(t => t > from && t < to), total = arrivals.Count });
                }
            case "throttle-start":
                Later(0, RunThrottle);
                return "ok";
            case "events-start":
                Later(0, () => StartEvents(q.Get("delivery", "post"), int.Parse(q.Get("rate", "10000")), double.Parse(q.Get("secs", "30"))));
                return "ok";
            default:
                return "unknown";
        }
    }

    void Later(int ms, Action a)
    {
        if (ms <= 0) { BeginInvoke(a); return; }
        var t = new Timer { Interval = ms };
        t.Tick += (s, e) => { t.Stop(); t.Dispose(); a(); };
        t.Start();
    }

    // ---------------- W2-lite throttling ----------------
    void RunThrottle()
    {
        var visibleSecs = double.Parse(args.Get("visible-secs", "10"));
        var hiddenSecs = double.Parse(args.Get("hidden-secs", "90"));
        bool keepVisible = config.Contains("keepvisible");
        bool minimize = config.Contains("minimize");
        configNotes["hide"] = minimize ? "WindowState=Minimized" : "Form.Hide()";
        configNotes["controllerIsVisibleWhileHidden"] = keepVisible;
        var segs = new Dictionary<string, object> { ["visibleStart"] = Util.NowMs() };
        int beats = 0;
        var beat = new Timer { Interval = 1000 };
        beat.Tick += (s, e) => { if (!finished) { beats++; core.PostWebMessageAsString("B"); } };
        beat.Start();
        Later((int)(visibleSecs * 1000), () =>
        {
            segs["hideAt"] = Util.NowMs();
            if (minimize) WindowState = FormWindowState.Minimized; else Hide();
            if (!keepVisible) controller.IsVisible = false;
            Later(2000, () => segs["controllerIsVisible"] = controller.IsVisible);
            Later((int)(hiddenSecs * 1000), () =>
            {
                segs["showAt"] = Util.NowMs();
                if (minimize) WindowState = FormWindowState.Normal; else Show();
                controller.IsVisible = true;
                Later(10000, () =>
                {
                    segs["end"] = Util.NowMs();
                    segs["hostBeatsSent"] = beats;
                    beat.Stop();
                    _ = core.ExecuteScriptAsync("probeThrottleDone(" + Util.Json(segs) + ")");
                });
            });
        });
    }

    // ---------------- C7 event soak ----------------
    readonly List<string> queue = new List<string>();
    bool wakePending;
    long sent;
    double postMsTotal;
    readonly List<object> memSamples = new List<object>();
    string eventsDelivery = "";

    string Pull()
    {
        wakePending = false;
        var sb = new StringBuilder("[");
        sb.Append(string.Join(",", queue));
        sb.Append(']');
        queue.Clear();
        return sb.ToString();
    }

    void SampleMemory(string label)
    {
        try
        {
            long rPriv = 0, rWs = 0, allPriv = 0;
            int nr = 0;
            foreach (var p in env.GetProcessInfos())
            {
                try
                {
                    var pr = Process.GetProcessById(p.ProcessId);
                    allPriv += pr.PrivateMemorySize64;
                    if (p.Kind == CoreWebView2ProcessKind.Renderer) { rPriv += pr.PrivateMemorySize64; rWs += pr.WorkingSet64; nr++; }
                }
                catch { }
            }
            memSamples.Add(new { label, t = Util.NowMs(), sent, renderers = nr, rendererPrivateMB = Math.Round(rPriv / 1048576.0, 1), rendererWorkingSetMB = Math.Round(rWs / 1048576.0, 1), allWebView2PrivateMB = Math.Round(allPriv / 1048576.0, 1) });
        }
        catch (Exception ex) { memSamples.Add(new { label, error = ex.Message }); }
    }

    void RecordEventsHost()
    {
        var o = new { delivery = eventsDelivery, sent, postCallMsTotal = Math.Round(postMsTotal, 1), memory = memSamples };
        results["events-host"] = o;
        Util.Emit("RESULT events-host " + Util.Json(o));
    }

    void StartEvents(string delivery, int rate, double secs)
    {
        eventsDelivery = delivery;
        Util.Emit($"PROBE events start delivery={delivery} rate={rate} secs={secs}");
        SampleMemory("start");
        var sw = Stopwatch.StartNew();
        double nextSample = 2000;
        var tick = new Timer { Interval = 1 };
        tick.Tick += (s, e) =>
        {
            var el = sw.Elapsed.TotalMilliseconds;
            var target = (long)Math.Min(rate * secs, rate * el / 1000.0);
            var ms = Util.NowMs();
            var t0 = Stopwatch.GetTimestamp();
            while (sent < target)
            {
                if (delivery == "post") core.PostWebMessageAsString("E:" + sent + ":" + ms);
                else
                {
                    queue.Add("{\"seq\":" + sent + ",\"ms\":" + ms + "}");
                    if (!wakePending) { wakePending = true; core.PostWebMessageAsString("W"); }
                }
                sent++;
            }
            postMsTotal += (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
            if (el >= nextSample) { SampleMemory("t+" + (int)(el / 1000) + "s"); nextSample += 5000; Util.Emit($"PROBE events t={(int)(el / 1000)}s sent={sent} queue={queue.Count}"); }
            if (el >= secs * 1000 && sent >= (long)(rate * secs))
            {
                tick.Stop();
                SampleMemory("end");
                Util.Emit($"PROBE events END sent={sent}");
                core.PostWebMessageAsString("END:" + sent);
            }
        };
        tick.Start();
    }
}
