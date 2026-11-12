using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Dicta.Core;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using Label = System.Windows.Controls.Label;
using ListBox = System.Windows.Controls.ListBox;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;
using Brushes = System.Windows.Media.Brushes;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using FontFamily = System.Windows.Media.FontFamily;

namespace Dicta;

/// Ventanas de la app, construidas en código (sin XAML).
public static class UI
{
    public const string GuideUrl = "https://github.com/Villenas96/dicta/blob/main/docs/INSTALACION.md";
    static readonly Dictionary<string, Window> Open = new();

    static Window Win(string id, string title, UIElement content, double w = 560, double h = 600)
    {
        if (Open.TryGetValue(id, out var existing)) { existing.Activate(); return existing; }
        var win = new Window
        {
            Title = title, Width = w, Height = h, Content = new ScrollViewer { Content = content, Padding = new Thickness(18) },
            WindowStartupLocation = WindowStartupLocation.CenterScreen, FontSize = 13,
        };
        win.Closed += (_, _) => Open.Remove(id);
        Open[id] = win;
        win.Show();
        win.Activate();
        return win;
    }

    static TextBlock H(string t) => new() { Text = t, FontSize = 16, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 6) };
    static TextBlock P(string t, bool muted = false) => new()
    {
        Text = t, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6),
        Foreground = muted ? Brushes.DimGray : Brushes.Black,
    };
    static Button B(string t, Action a)
    {
        var b = new Button { Content = t, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 4, 8, 4), HorizontalAlignment = HorizontalAlignment.Left };
        b.Click += (_, _) => a();
        return b;
    }
    static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    // ───────────── Bienvenida / guía ─────────────
    public static void ShowWelcome(Controller c)
    {
        var s = Settings.Current;
        var p = new StackPanel();
        p.Children.Add(new TextBlock { Text = "Bienvenido a Dicta", FontSize = 22, FontWeight = FontWeights.Bold });
        p.Children.Add(P("Dictado por voz en español: pulsa un atajo, habla y el texto corregido aparece donde estés escribiendo (también en la terminal)."));

        p.Children.Add(H("1. Cómo se usa"));
        p.Children.Add(P($"• Mantén {s.TriggerLabel} mientras hablas y suelta: se corrige y se pega.\n• Doble toque: se queda escuchando; otro toque lo para.\n• Mayús + {s.TriggerLabel} con texto seleccionado: modo edición («hazlo más formal»).\n• Esc: cancelar."));

        p.Children.Add(H("2. Tu IA (usa tu suscripción, sin claves)"));
        p.Children.Add(P(ClaudeCodeCleaner.Exe is not null ? "✅ Claude Code encontrado: " + ClaudeCodeCleaner.Exe : "❌ Claude Code no está instalado."));
        p.Children.Add(P(CodexCleaner.Exe is not null ? "✅ Codex encontrado: " + CodexCleaner.Exe : "❌ Codex no está instalado."));
        p.Children.Add(P("Para conectarlo, abre PowerShell y ejecuta UNO de estos (luego inicia sesión y reinicia Dicta):", true));
        p.Children.Add(new TextBox
        {
            Text = "# Claude Code (suscripción Claude Pro/Max)\nirm https://claude.ai/install.ps1 | iex\nclaude      # inicia sesión la primera vez\n\n# Codex (suscripción ChatGPT Plus/Pro)\npnpm add -g @openai/codex\ncodex login",
            IsReadOnly = true, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6),
        });
        p.Children.Add(P(CleanerFactory.Describe(), true));

        p.Children.Add(H("3. Modelo de voz"));
        var status = P(c.Whisper.Ready ? "✅ Listo" : "⏳ " + c.Whisper.Status);
        c.Whisper.StatusChanged += () => status.Dispatcher.BeginInvoke(() => status.Text = c.Whisper.Ready ? "✅ Listo" : "⏳ " + c.Whisper.Status);
        p.Children.Add(status);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        row.Children.Add(B("Guía completa", () => OpenUrl(GuideUrl)));
        row.Children.Add(B("Ajustes", () => ShowSettings(c)));
        row.Children.Add(B("Reiniciar Dicta", Restart));
        p.Children.Add(row);
        Win("welcome", "Dicta · Guía de inicio", p, 620, 680);
    }

    public static void Restart()
    {
        Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true });
        System.Windows.Application.Current.Shutdown();
    }

    // ───────────── Ajustes ─────────────
    public static void ShowSettings(Controller c)
    {
        var s = Settings.Current;
        var p = new StackPanel();

        p.Children.Add(H("Atajo"));
        var trig = new ComboBox { ItemsSource = new[] { "Ctrl derecho", "Alt Gr / Alt derecho", "F8", "F9" }, SelectedIndex = (int)s.Trigger };
        p.Children.Add(trig);
        p.Children.Add(P("Mantener para hablar · doble toque = manos libres · Mayús + atajo = editar selección · Esc = cancelar.", true));

        p.Children.Add(H("Corrección con IA"));
        var prov = new ComboBox
        {
            ItemsSource = new[] { "Claude Code — tu suscripción, sin API key", "Codex — tu suscripción de ChatGPT", "Claude API (con clave)", "Sin IA (limpieza básica)" },
            SelectedIndex = (int)s.Provider,
        };
        p.Children.Add(prov);
        p.Children.Add(new Label { Content = "Modelo de Claude Code (alias o ID exacto):" });
        var ccModel = new ComboBox
        {
            IsEditable = true, Text = s.ClaudeCodeModel,
            ItemsSource = new[] { "sonnet", "haiku", "opus", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-2" },
        };
        p.Children.Add(ccModel);
        p.Children.Add(new Label { Content = "Modelo de Codex (vacío = el de Codex por defecto):" });
        var cxModel = new TextBox { Text = s.CodexModel };
        p.Children.Add(cxModel);
        p.Children.Add(new Label { Content = "Clave de API de Anthropic (solo para «Claude API»):" });
        var key = new PasswordBox { Password = Settings.ApiKey ?? "" };
        p.Children.Add(key);
        var describe = P(CleanerFactory.Describe(), true);
        p.Children.Add(describe);

        p.Children.Add(H("Voz"));
        var models = WhisperEngine.Models.ToList();
        var wm = new ComboBox { ItemsSource = models.Select(m => m.Value.Label).ToList(), SelectedIndex = Math.Max(0, models.FindIndex(m => m.Key == s.WhisperModel)) };
        p.Children.Add(wm);

        p.Children.Add(H("Comportamiento"));
        CheckBox Chk(string t, bool v) { var cb = new CheckBox { Content = t, IsChecked = v, Margin = new Thickness(0, 3, 0, 3) }; p.Children.Add(cb); return cb; }
        var ctx = Chk("Usar el texto de la casilla como contexto", s.UseContext);
        var snd = Chk("Sonido al empezar", s.Sounds);
        var keep = Chk("Dejar siempre el dictado en el portapapeles", s.KeepInClipboard);
        var auto = Chk("Abrir Dicta al iniciar Windows", s.StartWithWindows);

        p.Children.Add(B("Guardar", async () =>
        {
            s.Trigger = (TriggerKey)trig.SelectedIndex;
            s.Provider = (Provider)prov.SelectedIndex;
            s.ClaudeCodeModel = string.IsNullOrWhiteSpace(ccModel.Text) ? "sonnet" : ccModel.Text.Trim();
            s.CodexModel = cxModel.Text.Trim();
            Settings.ApiKey = key.Password;
            var newModel = models[Math.Max(0, wm.SelectedIndex)].Key;
            var modelChanged = newModel != s.WhisperModel;
            s.WhisperModel = newModel;
            s.UseContext = ctx.IsChecked == true; s.Sounds = snd.IsChecked == true;
            s.KeepInClipboard = keep.IsChecked == true; s.StartWithWindows = auto.IsChecked == true;
            s.Save();
            c.ApplySettings();
            describe.Text = "Guardado. " + CleanerFactory.Describe();
            if (modelChanged) await c.WarmUpAsync();
        }));
        Win("settings", "Dicta · Ajustes", p, 560, 760);
    }

    // ───────────── Historial ─────────────
    public static void ShowHistory()
    {
        var p = new StackPanel();
        var search = new TextBox { Margin = new Thickness(0, 0, 0, 8) };
        var list = new ListBox { Height = 520 };
        void Fill()
        {
            var q = search.Text.Trim();
            list.Items.Clear();
            foreach (var e in History.Entries.Where(e => q.Length == 0 || e.Text.Contains(q, StringComparison.OrdinalIgnoreCase)).Take(500))
            {
                var item = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };
                item.Children.Add(new TextBlock { Text = $"{e.Date:g} · {e.App} · {e.Outcome} · {e.Engine}", Foreground = Brushes.DimGray, FontSize = 11 });
                item.Children.Add(new TextBlock { Text = e.Text, TextWrapping = TextWrapping.Wrap, MaxWidth = 600 });
                if (e.Raw != e.Text) item.Children.Add(new TextBlock { Text = "Oído: " + e.Raw, Foreground = Brushes.Gray, FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxWidth = 600 });
                var copy = B("Copiar", () => Paster.Copy(e.Text));
                item.Children.Add(copy);
                list.Items.Add(item);
            }
        }
        search.TextChanged += (_, _) => Fill();
        History.Changed += () => list.Dispatcher.BeginInvoke(Fill);
        p.Children.Add(new Label { Content = "Buscar:" });
        p.Children.Add(search);
        p.Children.Add(list);
        p.Children.Add(B("Borrar todo el historial", () => { if (System.Windows.MessageBox.Show("¿Borrar todo el historial?", "Dicta", MessageBoxButton.YesNo) == MessageBoxResult.Yes) History.Clear(); }));
        Fill();
        Win("history", "Dicta · Historial", p, 680, 720);
    }

    // ───────────── Diccionario ─────────────
    public static void ShowDictionary()
    {
        var p = new StackPanel();
        p.Children.Add(P("Palabras que Dicta debe escribir siempre así (nombres, marcas, términos técnicos). «Se oye como» indica cómo lo transcribe el reconocedor: whisper → Wispr."));
        var word = new TextBox { Margin = new Thickness(0, 0, 0, 4) };
        var alias = new TextBox { Margin = new Thickness(0, 0, 0, 4) };
        p.Children.Add(new Label { Content = "Se escribe:" }); p.Children.Add(word);
        p.Children.Add(new Label { Content = "Se oye como (opcional):" }); p.Children.Add(alias);
        var list = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        void Fill()
        {
            list.Children.Clear();
            foreach (var w in Dictionary.Words.ToList())
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 3) };
                row.Children.Add(new TextBlock { Text = w.Word, FontWeight = FontWeights.SemiBold, Width = 160, VerticalAlignment = VerticalAlignment.Center });
                row.Children.Add(new TextBlock { Text = w.Aliases.Count > 0 ? "← " + string.Join(", ", w.Aliases) : "", Foreground = Brushes.DimGray, Width = 170, VerticalAlignment = VerticalAlignment.Center });
                var add = new TextBox { Width = 110, ToolTip = "Añadir cómo suena y pulsa Intro" };
                add.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter && add.Text.Trim().Length > 0) Dictionary.Add(w.Word, add.Text); };
                row.Children.Add(add);
                row.Children.Add(B("Quitar", () => Dictionary.Remove(w)));
                list.Children.Add(row);
            }
        }
        p.Children.Add(B("Añadir", () => { Dictionary.Add(word.Text, alias.Text); word.Clear(); alias.Clear(); }));
        p.Children.Add(list);
        Dictionary.Changed += () => list.Dispatcher.BeginInvoke(Fill);
        Fill();
        Win("dictionary", "Dicta · Diccionario personal", p, 620, 640);
    }
}
