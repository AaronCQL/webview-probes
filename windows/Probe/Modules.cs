// Loads the four demo module DLLs (C, Rust, Zig, Go) into one process and calls them.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

unsafe struct PmHost
{
    public uint version;
    public void* ctx;
    public delegate* unmanaged<void*, ulong, long, void> callback;
}

unsafe struct PmModule
{
    public uint version;
    public byte* name;
    public delegate* unmanaged<long, long, long> add;
    public delegate* unmanaged<byte*, nuint, byte**, nuint*, int> reverse;
    public delegate* unmanaged<byte*, nuint, void> free_bytes;
    public delegate* unmanaged<long, void*> counter_new;
    public delegate* unmanaged<void*, long, PmHost*, ulong, long> count_to;
    public delegate* unmanaged<void*, void> counter_free;
}

static unsafe class Modules
{
    public static readonly string[] Langs = { "c", "rust", "zig", "go" };

    [UnmanagedCallersOnly]
    static void OnCount(void* ctx, ulong id, long v)
    {
        var acc = (long*)ctx;
        acc[0] += 1;
        acc[1] += v;
    }

    static Dictionary<string, object> Exercise(PmModule* m, int n)
    {
        var r = new Dictionary<string, object>();
        r["name"] = Marshal.PtrToStringUTF8((IntPtr)m->name);
        r["abi"] = m->version;
        long sum = m->add(40, 2);
        r["add_40_2"] = sum;
        var input = Encoding.UTF8.GetBytes("h\u00e9llo \u2192 w\u00f6rld \U0001F600");
        byte* outp = null;
        nuint outLen = 0;
        int rc;
        fixed (byte* ip = input) rc = m->reverse(ip, (nuint)input.Length, &outp, &outLen);
        var rev = Encoding.UTF8.GetString(outp, (int)outLen);
        m->free_bytes(outp, outLen);
        r["reverse"] = rev;
        var expected = new string(Encoding.UTF8.GetString(input).EnumerateRunes().Reverse().SelectMany(x => x.ToString()).ToArray());
        long* acc = stackalloc long[2];
        acc[0] = 0; acc[1] = 0;
        PmHost host;
        host.version = 1;
        host.ctx = acc;
        host.callback = &OnCount;
        void* counter = m->counter_new(0);
        var sw = Stopwatch.StartNew();
        long calls = m->count_to(counter, n, &host, 7);
        sw.Stop();
        m->counter_free(counter);
        r["count_to_calls"] = calls;
        r["ns_per_callback"] = Math.Round(sw.Elapsed.TotalMilliseconds * 1e6 / n, 1);
        r["ok"] = rc == 0 && sum == 42 && rev == expected && calls == n && acc[0] == n && acc[1] == (long)n * (n + 1) / 2;
        return r;
    }

    static (IntPtr, IntPtr, string) Load(string dir, string lang)
    {
        var path = Path.Combine(Path.GetFullPath(dir), "probe_" + lang + ".dll");
        try
        {
            var h = NativeLibrary.Load(path);
            var sym = NativeLibrary.GetExport(h, "probe_" + lang + "_module");
            var entry = (delegate* unmanaged<PmModule*>)sym;
            return (h, (IntPtr)entry(), null);
        }
        catch (Exception ex) { return (IntPtr.Zero, IntPtr.Zero, ex.GetType().Name + ": " + ex.Message); }
    }

    public static int Run(string dir, bool standalone, string phase = "modules")
    {
        var res = new Dictionary<string, object>();
        var mods = new Dictionary<string, IntPtr>();
        var handles = new Dictionary<string, IntPtr>();
        foreach (var lang in Langs)
        {
            var sw = Stopwatch.StartNew();
            var (h, m, err) = Load(dir, lang);
            var loadMs = sw.Elapsed.TotalMilliseconds;
            if (m == IntPtr.Zero) { res[lang] = new Dictionary<string, object> { ["ok"] = false, ["error"] = err }; continue; }
            var r = Exercise((PmModule*)m, 100000);
            r["load_ms"] = Math.Round(loadMs, 2);
            res[lang] = r;
            mods[lang] = m;
            handles[lang] = h;
        }
        // all loaded modules at once from 4 threads
        var conc = new Dictionary<string, bool>();
        Parallel.ForEach(mods.Keys.ToList(), lang =>
        {
            bool ok = true;
            for (int i = 0; i < 5; i++) ok &= (bool)Exercise((PmModule*)mods[lang], 100000)["ok"];
            lock (conc) conc[lang] = ok;
        });
        res["concurrent_threads_ok"] = conc;
        res["loaded_in_one_process"] = mods.Keys.ToList();

        if (standalone)
        {
            // unload/reload test, each in a child process so a crash doesn't take this one down
            var unload = new Dictionary<string, object>();
            foreach (var lang in Langs)
            {
                var psi = new ProcessStartInfo(Environment.ProcessPath, $"--mode unload --dir \"{dir}\" --lang {lang}")
                { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
                var p = Process.Start(psi);
                var stdout = p.StandardOutput.ReadToEndAsync();
                var stderr = p.StandardError.ReadToEndAsync();
                bool exited = p.WaitForExit(30000);
                if (!exited) { try { p.Kill(); } catch { } }
                unload[lang] = new
                {
                    exited,
                    exitCode = exited ? p.ExitCode : (int?)null,
                    stdout = Tail(stdout.Result, 600),
                    stderr = Tail(stderr.Result, 600),
                };
            }
            res["unload_child"] = unload;
        }
        Util.Emit("RESULT " + phase + " " + Util.Json(res));
        return 0;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandleW(string name);

    static string Tail(string s, int n) => s.Length <= n ? s : s.Substring(s.Length - n);

    // child: load, call, FreeLibrary, try to reload + call again, then exit cleanly.
    public static int UnloadChild(string dir, string lang)
    {
        var (h, m, err) = Load(dir, lang);
        if (m == IntPtr.Zero) { Console.WriteLine("load failed " + err); return 10; }
        Console.WriteLine("first call ok=" + Exercise((PmModule*)m, 1000)["ok"]);
        Console.Out.Flush();
        NativeLibrary.Free(h);
        Console.WriteLine("freed; module still mapped=" + (GetModuleHandleW("probe_" + lang + ".dll") != IntPtr.Zero));
        Console.Out.Flush();
        System.Threading.Thread.Sleep(1000);
        Console.WriteLine("survived 1s after free");
        Console.Out.Flush();
        var (h2, m2, err2) = Load(dir, lang);
        if (m2 == IntPtr.Zero) { Console.WriteLine("reload failed " + err2); return 11; }
        Console.WriteLine("reload call ok=" + Exercise((PmModule*)m2, 1000)["ok"]);
        Console.Out.Flush();
        return 0;
    }
}
