using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dicta.Core;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using Orientation = System.Windows.Controls.Orientation;
using Rectangle = System.Windows.Shapes.Rectangle;
using FontFamily = System.Windows.Media.FontFamily;

namespace Dicta;

/// Píldora flotante: micro / candado (manos libres) / onda / estado / botones.
/// No roba el foco (WS_EX_NOACTIVATE) y se coloca donde no tape la casilla.
public sealed class Overlay : Window
{
    public enum Phase { Hidden, Listening, Processing, Done, Message }

    readonly TextBlock _icon = new() { FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 16, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel _bars = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _text = new() { Foreground = Brushes.White, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 380, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly Rectangle[] _barRects = new Rectangle[16];
    readonly DispatcherTimer _hideTimer = new();
    IntPtr _hwnd;
    RectD? _avoid;

    public Action? OnStop, OnCancel, OnUndo, OnCopy, OnRedictate;

    public Overlay()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        for (int i = 0; i < _barRects.Length; i++)
        {
            _barRects[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White, Margin = new Thickness(1, 0, 1, 0), VerticalAlignment = VerticalAlignment.Center };
            _bars.Children.Add(_barRects[i]);
        }
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_icon);
        row.Children.Add(new Border { Width = 10 });
        row.Children.Add(_bars);
        row.Children.Add(_text);
        row.Children.Add(_buttons);
        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x12, 0x12, 0x12)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(20),
            Padding = new Thickness(14, 8, 14, 8),
            Child = row,
        };
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); HideOverlay(); };
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            var ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
            Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
        };
    }

    public void SetAvoid(RectD? avoid) { _avoid = avoid; if (IsVisible) Position(); }

    void SetClickThrough(bool on)
    {
        if (_hwnd == IntPtr.Zero) return;
        var ex = Native.GetWindowLong(_hwnd, Native.GWL_EXSTYLE);
        ex = on ? ex | Native.WS_EX_TRANSPARENT : ex & ~Native.WS_EX_TRANSPARENT;
        Native.SetWindowLong(_hwnd, Native.GWL_EXSTYLE, ex);
    }

    public void PushLevel(float level)
    {
        for (int i = 0; i < _barRects.Length - 1; i++) _barRects[i].Height = _barRects[i + 1].Height;
        _barRects[^1].Height = 4 + level * 20;
    }

    Button Btn(string glyph, string tip, Action? a)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), Foreground = Brushes.White, FontSize = 13 },
            ToolTip = tip, Width = 26, Height = 26, Margin = new Thickness(6, 0, 0, 0),
            Background = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)), BorderThickness = new Thickness(0),
            Focusable = false,
        };
        b.Click += (_, _) => a?.Invoke();
        return b;
    }

    public void Show(Phase phase, string text = "", bool handsFree = false, bool edit = false, double autoHideSeconds = 0)
    {
        _hideTimer.Stop();
        _buttons.Children.Clear();
        _bars.Visibility = Visibility.Collapsed;
        _text.Text = text;
        _text.Margin = new Thickness(text.Length > 0 ? 6 : 0, 0, 0, 0);
        switch (phase)
        {
            case Phase.Listening:
                _icon.Text = handsFree ? "" : ""; // candado / micro
                _icon.Foreground = edit ? Brushes.Orange : Brushes.OrangeRed;
                _bars.Visibility = Visibility.Visible;
                if (edit) { _text.Text = "Editar"; _text.Foreground = Brushes.Orange; } else _text.Foreground = Brushes.White;
                if (handsFree)
                {
                    _buttons.Children.Add(Btn("", "Parar", OnStop));
                    _buttons.Children.Add(Btn("", "Cancelar (Esc)", OnCancel));
                }
                break;
            case Phase.Processing:
                _icon.Text = ""; _icon.Foreground = Brushes.White; _text.Foreground = Brushes.White;
                break;
            case Phase.Done:
                // Sin el texto en medio: confirmación y botones.
                _icon.Text = ""; _icon.Foreground = Brushes.LimeGreen; _text.Text = "";
                _buttons.Children.Add(Btn("", "Re-dictar", OnRedictate));
                _buttons.Children.Add(Btn("", "Deshacer", OnUndo));
                _buttons.Children.Add(Btn("", "Copiar", OnCopy));
                break;
            case Phase.Message:
                _icon.Text = ""; _icon.Foreground = Brushes.Gold; _text.Foreground = Brushes.White;
                break;
            case Phase.Hidden:
                HideOverlay(); return;
        }
        if (!IsVisible) { base.Show(); }
        SetClickThrough(_buttons.Children.Count == 0);
        UpdateLayout();
        Position();
        if (autoHideSeconds > 0) { _hideTimer.Interval = TimeSpan.FromSeconds(autoHideSeconds); _hideTimer.Start(); }
    }

    void Position()
    {
        if (_hwnd == IntPtr.Zero) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        double w = ActualWidth * dpi.DpiScaleX, h = ActualHeight * dpi.DpiScaleY;
        var fg = Native.GetForegroundWindow();
        var screen = System.Windows.Forms.Screen.FromHandle(fg == IntPtr.Zero ? _hwnd : fg);
        var wa = screen.WorkingArea;
        var (x, y) = OverlayPlacement.Choose(new RectD(wa.X, wa.Y, wa.Width, wa.Height), w, h, _avoid);
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, (int)x, (int)y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
    }

    public void HideOverlay() { _hideTimer.Stop(); base.Hide(); }
}
