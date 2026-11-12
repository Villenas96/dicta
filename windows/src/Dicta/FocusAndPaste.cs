using System.Windows;
using System.Windows.Automation;
using Dicta.Core;
using Clipboard = System.Windows.Clipboard;
using DataObject = System.Windows.DataObject;

namespace Dicta;

/// Foto de la casilla activa (como `AX.snapshot()` en Mac), con UI Automation.
public sealed class FocusSnapshot
{
    public string App = "";
    public IntPtr Hwnd;
    public bool IsTerminal;
    public bool IsEditable;
    public bool HasElement;
    public string Before = "", After = "", Selected = "";
    public RectD? Avoid;

    public bool CanPaste => IsTerminal || (HasElement && IsEditable);

    public static FocusSnapshot Capture()
    {
        var s = new FocusSnapshot { App = Native.ForegroundProcessName(out var hwnd), Hwnd = hwnd };
        s.IsTerminal = Native.Terminals.Contains(s.App);
        if (Native.CaretRect(hwnd) is { } c) s.Avoid = new RectD(c.X - 40, c.Y - 24, c.W + 80, c.H + 48);

        // UI Automation puede colgarse con algunas apps: máximo 400 ms.
        var t = Task.Run(() =>
        {
            try
            {
                var el = AutomationElement.FocusedElement;
                if (el is null) return;
                s.HasElement = true;
                var ct = el.Current.ControlType;
                bool readOnly = el.TryGetCurrentPattern(ValuePattern.Pattern, out var vp) && ((ValuePattern)vp).Current.IsReadOnly;
                s.IsEditable = !readOnly && (ct == ControlType.Edit || ct == ControlType.Document || vp is not null
                                             || el.TryGetCurrentPattern(TextPattern.Pattern, out _));
                if (s.Avoid is null)
                {
                    var r = el.Current.BoundingRectangle;
                    if (!r.IsEmpty && r.Height < 400) s.Avoid = new RectD(r.X - 12, r.Y - 12, r.Width + 24, r.Height + 24);
                }
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out var tpo))
                {
                    var tp = (TextPattern)tpo;
                    var sel = tp.GetSelection();
                    if (sel.Length > 0)
                    {
                        s.Selected = sel[0].GetText(4000);
                        var before = tp.DocumentRange.Clone();
                        before.MoveEndpointByRange(TextPatternRangeEndpoint.End, sel[0], TextPatternRangeEndpoint.Start);
                        var b = before.GetText(-1);
                        s.Before = b.Length > 1500 ? b[^1500..] : b;
                        var after = tp.DocumentRange.Clone();
                        after.MoveEndpointByRange(TextPatternRangeEndpoint.Start, sel[0], TextPatternRangeEndpoint.End);
                        s.After = after.GetText(400);
                    }
                }
            }
            catch { /* la app no expone accesibilidad: seguimos sin contexto */ }
        });
        t.Wait(400);
        if (s.IsTerminal) s.IsEditable = true;
        return s;
    }
}

/// Pegado: guardar portapapeles → poner texto → Ctrl+V (o Mayús+Insert en terminales) → restaurar.
public static class Paster
{
    static DataObject? Save()
    {
        try
        {
            var src = Clipboard.GetDataObject();
            if (src is null) return null;
            var copy = new DataObject();
            foreach (var f in src.GetFormats(false))
                try { var d = src.GetData(f, false); if (d is not null) copy.SetData(f, d); } catch { }
            return copy;
        }
        catch { return null; }
    }

    static void Retry(Action a)
    {
        for (int i = 0; i < 10; i++)
        {
            try { a(); return; }
            catch (System.Runtime.InteropServices.COMException) { Thread.Sleep(30); } // portapapeles ocupado
        }
    }

    public static void Copy(string text) => Retry(() => Clipboard.SetText(text));

    public static async Task PasteAsync(string text, bool terminal, bool keepInClipboard)
    {
        var saved = keepInClipboard ? null : Save();
        Copy(text);
        await Task.Delay(40);
        // Mayús+Insert pega en Windows Terminal, cmd, PowerShell, Git Bash (mintty) y PuTTY;
        // Ctrl+V en el resto de apps.
        if (terminal) Native.Chord(Native.VK_INSERT, Native.VK_SHIFT);
        else Native.Chord(Native.VK_V, Native.VK_CONTROL);
        if (keepInClipboard) return;
        await Task.Delay(500);
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() == text)
            {
                if (saved is not null) Retry(() => Clipboard.SetDataObject(saved, true));
                else Retry(Clipboard.Clear);
            }
        }
        catch { }
    }

    /// Lee la selección con Ctrl+C cuando UI Automation no la expone (restaura el portapapeles).
    public static async Task<string> CopySelectionAsync()
    {
        var saved = Save();
        Retry(Clipboard.Clear);
        Native.Chord(Native.VK_C, Native.VK_CONTROL);
        string text = "";
        for (int i = 0; i < 15 && text.Length == 0; i++)
        {
            await Task.Delay(25);
            try { if (Clipboard.ContainsText()) text = Clipboard.GetText(); } catch { }
        }
        if (saved is not null) Retry(() => Clipboard.SetDataObject(saved, true));
        return text;
    }

    public static void Undo() => Native.Chord(Native.VK_Z, Native.VK_CONTROL);

    public static void SelectBackwards(int chars)
    {
        for (int i = 0; i < Math.Min(chars, 3000); i++) Native.Chord(Native.VK_LEFT, Native.VK_SHIFT);
    }
}
