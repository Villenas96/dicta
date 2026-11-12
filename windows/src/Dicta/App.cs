using System.Drawing;
using System.Windows;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

namespace Dicta;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        using var mutex = new Mutex(true, "Dicta.SingleInstance", out var first);
        if (!first) { System.Windows.MessageBox.Show("Dicta ya está abierta (mira el icono junto al reloj).", "Dicta"); return; }

        var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var controller = new Controller(app.Dispatcher);
        var tray = new Tray(controller, app);
        app.Startup += async (_, _) =>
        {
            if (!Settings.Current.FirstRunDone)
            {
                // Primera vez: elige la IA de la suscripción que tenga instalada.
                var s = Settings.Current;
                s.Provider = ClaudeCodeCleaner.Exe is not null ? Provider.ClaudeCode
                           : CodexCleaner.Exe is not null ? Provider.Codex : Provider.None;
                s.FirstRunDone = true;
                s.Save();
                UI.ShowWelcome(controller);
            }
            await controller.WarmUpAsync();
            tray.Refresh();
        };
        app.Exit += (_, _) => { tray.Dispose(); controller.Hook.Dispose(); };
        app.Run();
    }
}

/// Icono junto al reloj con el menú de la app.
sealed class Tray : IDisposable
{
    readonly WinForms.NotifyIcon _icon = new();
    readonly Controller _c;
    readonly System.Windows.Application _app;
    readonly Icon _idle = MakeIcon(Color.FromArgb(40, 120, 255)), _rec = MakeIcon(Color.FromArgb(235, 60, 50));

    public Tray(Controller c, System.Windows.Application app)
    {
        _c = c; _app = app;
        _icon.Icon = _idle;
        _icon.Visible = true;
        _icon.Text = "Dicta";
        _icon.ContextMenuStrip = new WinForms.ContextMenuStrip();
        _icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        _icon.MouseClick += (_, e) => { if (e.Button == WinForms.MouseButtons.Left) UI.ShowHistory(); };
        c.StateChanged += () => app.Dispatcher.BeginInvoke(() => _icon.Icon = c.Current == Controller.State.Recording ? _rec : _idle);
        c.Whisper.StatusChanged += () => app.Dispatcher.BeginInvoke(Refresh);
        BuildMenu();
    }

    public void Refresh()
    {
        var status = _c.Whisper.Ready ? $"Dicta · mantén {Settings.Current.TriggerLabel}" : _c.Whisper.Status;
        _icon.Text = status.Length > 63 ? status[..63] : status;
    }

    void BuildMenu()
    {
        var m = _icon.ContextMenuStrip!;
        m.Items.Clear();
        var s = Settings.Current;
        m.Items.Add(new WinForms.ToolStripMenuItem($"Mantén {s.TriggerLabel} para dictar · doble toque: manos libres") { Enabled = false });
        if (!_c.Whisper.Ready) m.Items.Add(new WinForms.ToolStripMenuItem("⏳ " + _c.Whisper.Status) { Enabled = false });
        m.Items.Add(new WinForms.ToolStripMenuItem(CleanerFactory.Describe()) { Enabled = false });
        m.Items.Add(new WinForms.ToolStripSeparator());
        m.Items.Add(_c.Current == Controller.State.Recording ? "Parar dictado" : "Empezar dictado (manos libres)", null, (_, _) => _c.StartFromMenu());
        m.Items.Add("Re-dictar / editar lo último", null, (_, _) => _c.Redictate());
        m.Items.Add("Pegar último dictado", null, (_, _) => _c.PasteLast());
        m.Items.Add(new WinForms.ToolStripSeparator());
        m.Items.Add("Historial…", null, (_, _) => UI.ShowHistory());
        m.Items.Add("Diccionario…", null, (_, _) => UI.ShowDictionary());
        m.Items.Add("Ajustes…", null, (_, _) => UI.ShowSettings(_c));
        m.Items.Add("Guía de inicio…", null, (_, _) => UI.ShowWelcome(_c));
        m.Items.Add(new WinForms.ToolStripSeparator());
        m.Items.Add("Salir de Dicta", null, (_, _) => _app.Shutdown());
    }

    static Icon MakeIcon(Color c)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var b = new SolidBrush(c);
            g.FillEllipse(b, 1, 1, 30, 30);
            using var w = new SolidBrush(Color.White);
            g.FillRectangle(w, 12, 6, 8, 13);       // cápsula del micro
            g.FillEllipse(w, 12, 3, 8, 8);
            g.FillEllipse(w, 12, 15, 8, 8);
            using var pen = new Pen(Color.White, 2);
            g.DrawArc(pen, 8, 10, 16, 14, 0, 180);
            g.DrawLine(pen, 16, 24, 16, 28);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose() { _icon.Visible = false; _icon.Dispose(); }
}
