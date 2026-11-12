using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Dicta;

/// Llamadas a la API de Windows (user32/kernel32).
internal static class Native
{
    // ── Gancho de teclado de bajo nivel ──
    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    public const uint LLKHF_INJECTED = 0x10;

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string? lpModuleName);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);

    // ── SendInput ──
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_EXTENDEDKEY = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_INSERT = 0x2D, VK_LEFT = 0x25,
        VK_V = 0x56, VK_C = 0x43, VK_Z = 0x5A, VK_ESCAPE = 0x1B, VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1,
        VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5;

    static INPUT Key(ushort vk, bool up)
    {
        uint flags = up ? KEYEVENTF_KEYUP : 0;
        if (vk is VK_INSERT or VK_LEFT or VK_RCONTROL or VK_RMENU) flags |= KEYEVENTF_EXTENDEDKEY;
        return new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } } };
    }

    /// Pulsa una combinación (modificadores + tecla) y suelta en orden inverso.
    public static void Chord(ushort key, params ushort[] modifiers)
    {
        var list = new List<INPUT>();
        foreach (var m in modifiers) list.Add(Key(m, false));
        list.Add(Key(key, false));
        list.Add(Key(key, true));
        foreach (var m in modifiers.Reverse()) list.Add(Key(m, true));
        SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf<INPUT>());
    }

    // ── Ventana en primer plano / cursor de texto ──
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    public static string ForegroundProcessName(out IntPtr hwnd)
    {
        hwnd = GetForegroundWindow();
        try
        {
            GetWindowThreadProcessId(hwnd, out var pid);
            return Process.GetProcessById((int)pid).ProcessName;
        }
        catch { return ""; }
    }

    /// Rectángulo del cursor de texto (píxeles de pantalla), si la app lo expone.
    public static (int X, int Y, int W, int H)? CaretRect(IntPtr hwnd)
    {
        var tid = GetWindowThreadProcessId(hwnd, out _);
        var gti = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (!GetGUIThreadInfo(tid, ref gti) || gti.hwndCaret == IntPtr.Zero) return null;
        var p = new POINT { X = gti.rcCaret.Left, Y = gti.rcCaret.Top };
        if (!ClientToScreen(gti.hwndCaret, ref p)) return null;
        return (p.X, p.Y, Math.Max(2, gti.rcCaret.Right - gti.rcCaret.Left), Math.Max(16, gti.rcCaret.Bottom - gti.rcCaret.Top));
    }

    // ── Estilos de ventana para la píldora (no roba el foco) ──
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TRANSPARENT = 0x20, WS_EX_TOPMOST = 0x8;
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x1, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;

    public static readonly HashSet<string> Terminals = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "OpenConsole", "conhost", "cmd", "powershell", "pwsh", "mintty", "putty", "kitty",
        "wezterm-gui", "alacritty", "Hyper", "Tabby", "ConEmu64", "ConEmu", "Cmder", "warp", "ghostty",
    };
}
