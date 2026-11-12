using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Dicta.Core;
using NAudio.Wave;
using Whisper.net;

namespace Dicta;

/// Atajo global con un gancho de teclado de bajo nivel (equivalente al CGEventTap de Mac).
public sealed class KeyboardHook : IDisposable
{
    readonly Native.LowLevelKeyboardProc _proc; // se guarda para que el GC no lo libere
    IntPtr _hook;
    bool _down, _shiftAtStart;
    readonly Stopwatch _clock = Stopwatch.StartNew();
    readonly Dispatcher _ui;
    public HotkeyStateMachine Machine { get; } = new();
    public int TriggerVk { get; set; } = Native.VK_RCONTROL;
    public event Action<HotkeyAction, bool>? Action; // (acción, mayúsculas pulsada al empezar)
    public event Action? Escape;
    public bool IsTriggerDown => _down;

    public KeyboardHook(Dispatcher ui)
    {
        _ui = ui;
        _proc = Callback;
        _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
    }

    double Now => _clock.Elapsed.TotalSeconds;

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var k = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            bool injected = (k.flags & Native.LLKHF_INJECTED) != 0; // nuestras propias pulsaciones (Ctrl+V…)
            int msg = wParam.ToInt32();
            bool isDown = msg is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
            bool isUp = msg is Native.WM_KEYUP or Native.WM_SYSKEYUP;
            if (!injected)
            {
                if (k.vkCode == TriggerVk)
                {
                    if (isDown && !_down)
                    {
                        _down = true;
                        _shiftAtStart = (Native.GetAsyncKeyState(Native.VK_SHIFT) & 0x8000) != 0;
                        Emit(Machine.KeyDown(Now));
                        ScheduleTick();
                    }
                    else if (isUp && _down)
                    {
                        _down = false;
                        Emit(Machine.KeyUp(Now));
                        ScheduleTick();
                    }
                }
                else if (isDown)
                {
                    if (k.vkCode == Native.VK_ESCAPE && Machine.IsRecording) { Machine.Reset(); _ui.BeginInvoke(() => Escape?.Invoke()); }
                    // Alt Gr genera un Ctrl izquierdo fantasma; las Mayúsculas son para el modo edición.
                    else if (_down && k.vkCode is not (Native.VK_LSHIFT or Native.VK_RSHIFT or Native.VK_SHIFT or Native.VK_LCONTROL))
                        Emit(Machine.OtherKeyPressed());
                }
            }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    void ScheduleTick()
    {
        var t = new DispatcherTimer(TimeSpan.FromSeconds(Machine.DoubleTapWindow + 0.02), DispatcherPriority.Normal,
            (s, _) => { ((DispatcherTimer)s!).Stop(); Emit(Machine.Tick(Now)); }, _ui);
        t.Start();
    }

    void Emit(List<HotkeyAction> actions)
    {
        var shift = _shiftAtStart;
        foreach (var a in actions) _ui.BeginInvoke(() => Action?.Invoke(a, shift));
    }

    public async Task WaitForReleaseAsync(int timeoutMs = 1000)
    {
        var sw = Stopwatch.StartNew();
        while ((_down || (Native.GetAsyncKeyState(Native.VK_SHIFT) & 0x8000) != 0) && sw.ElapsedMilliseconds < timeoutMs)
            await Task.Delay(20);
    }

    public void Dispose() { if (_hook != IntPtr.Zero) Native.UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
}

/// Micrófono a 16 kHz mono (el formato que espera Whisper).
public sealed class AudioRecorder
{
    WaveIn? _wave;
    readonly List<float> _samples = new(16000 * 60);
    readonly object _lock = new();
    public event Action<float>? Level;
    public float Peak { get; private set; }

    public void Start()
    {
        lock (_lock) { _samples.Clear(); Peak = 0; }
        _wave = new WaveIn { WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 40 };
        _wave.DataAvailable += (_, e) =>
        {
            double sum = 0; float peak = 0;
            lock (_lock)
            {
                for (int i = 0; i + 1 < e.BytesRecorded; i += 2)
                {
                    float v = BitConverter.ToInt16(e.Buffer, i) / 32768f;
                    _samples.Add(v);
                    sum += v * v;
                    peak = Math.Max(peak, Math.Abs(v));
                }
                Peak = Math.Max(Peak, peak);
            }
            var rms = Math.Sqrt(sum / Math.Max(1, e.BytesRecorded / 2));
            var db = 20 * Math.Log10(Math.Max(rms, 1e-6));
            Level?.Invoke((float)Math.Clamp((db + 55) / 45, 0, 1));
        };
        _wave.StartRecording();
    }

    public float[] Stop()
    {
        try { _wave?.StopRecording(); } catch { }
        _wave?.Dispose();
        _wave = null;
        lock (_lock) return _samples.ToArray();
    }
}

/// Whisper local (whisper.cpp). Descarga el modelo la primera vez y lo mantiene cargado.
public sealed class WhisperEngine
{
    public static readonly Dictionary<string, (string File, string Label)> Models = new()
    {
        ["base"] = ("ggml-base-q5_1.bin", "Base · 60 MB · el más rápido, menos preciso"),
        ["small"] = ("ggml-small-q5_1.bin", "Small · 190 MB · equilibrado (recomendado)"),
        ["turbo"] = ("ggml-large-v3-turbo-q5_0.bin", "Large v3 Turbo · 550 MB · el más preciso, necesita PC potente"),
    };

    WhisperFactory? _factory;
    string? _loaded;
    public string Status { get; private set; } = "Preparando el modelo de voz…";
    public bool Ready => _factory is not null;
    public event Action? StatusChanged;

    void SetStatus(string s) { Status = s; StatusChanged?.Invoke(); }

    public async Task EnsureAsync(string model)
    {
        if (_loaded == model && _factory is not null) return;
        var (file, _) = Models.TryGetValue(model, out var m) ? m : Models["small"];
        var path = Path.Combine(Paths.Models, file);
        if (!File.Exists(path))
        {
            var url = $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{file}";
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? 0;
            await using (var src = await resp.Content.ReadAsStreamAsync())
            await using (var dst = File.Create(path + ".part"))
            {
                var buf = new byte[1 << 16];
                long done = 0; int n; var last = 0;
                while ((n = await src.ReadAsync(buf)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n));
                    done += n;
                    var pct = total > 0 ? (int)(done * 100 / total) : 0;
                    if (pct != last) { last = pct; SetStatus($"Descargando el modelo de voz… {pct}% (solo la primera vez)"); }
                }
            }
            File.Move(path + ".part", path, true);
        }
        SetStatus("Cargando el modelo de voz…");
        _factory?.Dispose();
        _factory = WhisperFactory.FromPath(path);
        _loaded = model;
        SetStatus("Listo");
    }

    public async Task<string> TranscribeAsync(float[] samples, IEnumerable<string> vocabulary)
    {
        if (_factory is null) throw new InvalidOperationException("Modelo de voz no cargado");
        // El prompt inicial ayuda a Whisper a escribir bien nombres del diccionario.
        var prompt = string.Join(", ", vocabulary.Take(60));
        var builder = _factory.CreateBuilder()
            .WithLanguage("es")
            .WithThreads(Math.Clamp(Environment.ProcessorCount - 1, 2, 8))
            .WithNoContext();
        if (prompt.Length > 0) builder = builder.WithPrompt(prompt + ".");
        await using var processor = builder.Build();
        var parts = new List<string>();
        await foreach (var seg in processor.ProcessAsync(samples, CancellationToken.None)) parts.Add(seg.Text.Trim());
        var text = string.Join(" ", parts).Trim();
        return LocalCleaner.IsHallucination(text) ? "" : text;
    }
}
