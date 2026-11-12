using System.Media;
using System.Windows.Threading;
using Dicta.Core;

namespace Dicta;

/// Atajo → micro → Whisper → diccionario → corrección (Claude Code/Codex) → pegado → historial.
public sealed class Controller
{
    public enum State { Idle, Recording, Processing }

    readonly Dispatcher _ui;
    public KeyboardHook Hook { get; }
    public Overlay Overlay { get; } = new();
    public WhisperEngine Whisper { get; } = new();
    readonly AudioRecorder _rec = new();
    FocusSnapshot _snap = new();
    bool _editRequested, _handsFree;
    DateTime _startedAt;
    InsertionRecord? _last;
    int _lastLength;
    public State Current { get; private set; } = State.Idle;
    public event Action? StateChanged;

    public Controller(Dispatcher ui)
    {
        _ui = ui;
        Hook = new KeyboardHook(ui);
        Hook.Action += OnHotkey;
        Hook.Escape += () => Cancel(false);
        _rec.Level += l => _ui.BeginInvoke(() => Overlay.PushLevel(l));
        Overlay.OnStop = () => { Hook.Machine.Reset(); StopAndProcess(); };
        Overlay.OnCancel = () => { Hook.Machine.Reset(); Cancel(false); };
        Overlay.OnUndo = () => { Overlay.HideOverlay(); Paster.Undo(); };
        Overlay.OnCopy = () => { if (History.Entries.FirstOrDefault() is { } e) { Paster.Copy(e.Text); Overlay.Show(Overlay.Phase.Message, "Copiado al portapapeles", autoHideSeconds: 1.5); } };
        Overlay.OnRedictate = Redictate;
        ApplySettings();
    }

    public void ApplySettings()
    {
        var s = Settings.Current;
        Hook.TriggerVk = s.TriggerVk;
        Hook.Machine.HoldThreshold = s.HoldMs / 1000;
        Hook.Machine.DoubleTapWindow = s.DoubleTapMs / 1000;
    }

    public async Task WarmUpAsync()
    {
        try { await Whisper.EnsureAsync(Settings.Current.WhisperModel); }
        catch (Exception e) { _ui.Invoke(() => Overlay.Show(Overlay.Phase.Message, "No se pudo descargar el modelo de voz: " + e.Message, autoHideSeconds: 6)); }
    }

    void SetState(State s) { Current = s; StateChanged?.Invoke(); }

    void OnHotkey(HotkeyAction a, bool shift)
    {
        switch (a)
        {
            case HotkeyAction.StartRecording: Start(false, shift); break;
            case HotkeyAction.LockHandsFree:
                _handsFree = true;
                Overlay.Show(Overlay.Phase.Listening, handsFree: true, edit: _editRequested);
                break;
            case HotkeyAction.StopAndProcess: StopAndProcess(); break;
            case HotkeyAction.Cancel: Cancel(true); break;
        }
    }

    public void StartFromMenu()
    {
        if (Current == State.Recording) { Hook.Machine.Reset(); StopAndProcess(); return; }
        Hook.Machine.ForceHandsFree();
        Start(true, false);
    }

    void Start(bool handsFree, bool edit)
    {
        if (Current != State.Idle) return;
        if (!Whisper.Ready)
        {
            Overlay.Show(Overlay.Phase.Message, Whisper.Status, autoHideSeconds: 3);
            Hook.Machine.Reset();
            return;
        }
        try { _rec.Start(); }
        catch (Exception e)
        {
            Overlay.Show(Overlay.Phase.Message, "No se pudo abrir el micrófono: " + e.Message, autoHideSeconds: 4);
            Hook.Machine.Reset();
            return;
        }
        _startedAt = DateTime.Now;
        _handsFree = handsFree;
        _editRequested = edit;
        SetState(State.Recording);
        _snap = FocusSnapshot.Capture();
        CleanerFactory.Prewarm(); // arranca Claude Code / Codex mientras hablas
        if (Settings.Current.Sounds) SystemSounds.Asterisk.Play();
        Overlay.SetAvoid(_snap.Avoid);
        Overlay.Show(Overlay.Phase.Listening, handsFree: handsFree, edit: edit);
    }

    public void Cancel(bool silent)
    {
        if (Current != State.Recording) return;
        _rec.Stop();
        SetState(State.Idle);
        Hook.Machine.Reset();
        if (silent) Overlay.HideOverlay();
        else Overlay.Show(Overlay.Phase.Message, "Dictado cancelado", autoHideSeconds: 1.2);
    }

    public async void StopAndProcess()
    {
        if (Current != State.Recording) return;
        var samples = _rec.Stop();
        var duration = (DateTime.Now - _startedAt).TotalSeconds;
        if (duration < 0.35 && !_handsFree) { Cancel(true); return; }
        SetState(State.Processing);
        Overlay.Show(Overlay.Phase.Processing, "Transcribiendo…");
        try { await ProcessAsync(samples); }
        catch (Exception e) { Overlay.Show(Overlay.Phase.Message, "Error: " + e.Message, autoHideSeconds: 4); }
        finally { SetState(State.Idle); }
    }

    async Task ProcessAsync(float[] samples)
    {
        var snap = _snap;
        var raw = await Task.Run(() => Whisper.TranscribeAsync(samples, Dictionary.Words.Select(w => w.Word)));
        if (raw.Length == 0)
        {
            Overlay.Show(Overlay.Phase.Message, "No te he oído. Revisa el micrófono.", autoHideSeconds: 2);
            return;
        }
        raw = DictionaryCorrector.Apply(raw, Dictionary.Entries);

        // Modo edición: la selección se lee al soltar (con las teclas ya libres).
        await Hook.WaitForReleaseAsync();
        bool edit = false;
        if (_editRequested && !snap.IsTerminal)
        {
            if (snap.Selected.Length == 0) snap.Selected = (await Paster.CopySelectionAsync()).Trim();
            edit = snap.Selected.Length > 0;
        }
        bool instruction = edit && EditIntentClassifier.Classify(raw) == EditIntent.Instruction;

        var cont = !edit && ContinuityDetector.IsContinuation(_last, snap.App, snap.Before, DateTime.Now);
        var ctx = Settings.Current.UseContext;
        var req = new CleanupRequest(raw, instruction ? CleanupMode.Edit : CleanupMode.Dictation, snap.Selected, snap.App,
            snap.IsTerminal, ctx ? snap.Before : "", ctx ? snap.After : "", cont, Dictionary.PromptLines);

        var cleaner = CleanerFactory.Make();
        Overlay.Show(Overlay.Phase.Processing, $"Corrigiendo con {cleaner.DisplayName}…");
        var (text, engine, error) = await CleanerFactory.CleanWithFallbackAsync(cleaner, req);
        text = DictionaryCorrector.Apply(text, Dictionary.Entries);
        if (text.Length == 0) { Overlay.HideOverlay(); return; }
        if (instruction && text.Trim() == snap.Selected.Trim())
        {
            Overlay.Show(Overlay.Phase.Message, $"No he sabido aplicar «{raw}». Prueba a decirlo de otra forma.", autoHideSeconds: 3.5);
            return;
        }
        if (!instruction) text = TextTools.FitInsertion(text, snap.Before, Dictionary.Set);

        var target = FocusSnapshot.Capture();
        string outcome;
        if (target.CanPaste)
        {
            await Paster.PasteAsync(text, target.IsTerminal, Settings.Current.KeepInClipboard);
            outcome = "pegado";
            Overlay.SetAvoid(target.Avoid);
            if (error is not null) Overlay.Show(Overlay.Phase.Message, "Pegado sin IA: " + error, autoHideSeconds: 5);
            else Overlay.Show(Overlay.Phase.Done, autoHideSeconds: 4);
            _last = new InsertionRecord(text.Trim(), target.App, DateTime.Now);
            _lastLength = text.TrimStart().Length;
        }
        else
        {
            Paster.Copy(text.Trim());
            outcome = "portapapeles";
            Overlay.Show(Overlay.Phase.Message, "No hay casilla de texto activa: copiado al portapapeles (Ctrl+V)", autoHideSeconds: 3.5);
        }
        History.Add(new HistoryEntry { Date = DateTime.Now, App = snap.App, Raw = raw, Text = text.Trim(), Outcome = outcome, Engine = engine });
    }

    /// Selecciona lo último pegado y abre el modo edición (vuelve a decirlo o da una instrucción).
    public void Redictate()
    {
        if (Current != State.Idle || _last is null) return;
        Overlay.HideOverlay();
        Paster.SelectBackwards(_lastLength);
        Hook.Machine.ForceHandsFree();
        Start(true, true);
    }

    public void PasteLast()
    {
        if (History.Entries.FirstOrDefault() is { } e)
        {
            var t = FocusSnapshot.Capture();
            _ = Paster.PasteAsync(e.Text, t.IsTerminal, false);
        }
    }
}
