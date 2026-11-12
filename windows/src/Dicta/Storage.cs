using System.Text.Json;
using Dicta.Core;
using Microsoft.Win32;

namespace Dicta;

static class Paths
{
    public static string Data => Dir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Dicta"));
    public static string Models => Dir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Dicta", "models"));
    public static string Work => Dir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Dicta", "cwd"));
    static string Dir(string p) { Directory.CreateDirectory(p); return p; }
}

static class Json
{
    static readonly JsonSerializerOptions Opt = new() { WriteIndented = true };
    public static T? Load<T>(string name)
    {
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(Paths.Data, name)), Opt); }
        catch { return default; }
    }
    public static void Save<T>(string name, T value)
    {
        var path = Path.Combine(Paths.Data, name);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, Opt));
        File.Move(path + ".tmp", path, true);
    }
}

public enum TriggerKey { RightCtrl, RightAlt, F8, F9 }
public enum Provider { ClaudeCode, Codex, ClaudeApi, None }

public sealed class Settings
{
    public TriggerKey Trigger { get; set; } = TriggerKey.RightCtrl;
    public Provider Provider { get; set; } = Provider.ClaudeCode;
    public string ClaudeCodeModel { get; set; } = "sonnet";
    public string CodexModel { get; set; } = "";
    public string ClaudeApiModel { get; set; } = "claude-opus-5-5";
    public string WhisperModel { get; set; } = "small";
    public double HoldMs { get; set; } = 300;
    public double DoubleTapMs { get; set; } = 400;
    public bool Sounds { get; set; } = true;
    public bool UseContext { get; set; } = true;
    public bool KeepInClipboard { get; set; } = false;
    public bool StartWithWindows { get; set; } = true;
    public bool FirstRunDone { get; set; } = false;

    public static Settings Current { get; private set; } = Json.Load<Settings>("settings.json") ?? new Settings();
    public void Save()
    {
        Json.Save("settings.json", this);
        ApplyAutostart();
    }

    public int TriggerVk => Trigger switch
    {
        TriggerKey.RightCtrl => Native.VK_RCONTROL,
        TriggerKey.RightAlt => Native.VK_RMENU,
        TriggerKey.F8 => 0x77,
        _ => 0x78,
    };

    public string TriggerLabel => Trigger switch
    {
        TriggerKey.RightCtrl => "Ctrl derecho",
        TriggerKey.RightAlt => "Alt Gr / Alt derecho",
        TriggerKey.F8 => "F8",
        _ => "F9",
    };

    void ApplyAutostart()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
            if (key is null) return;
            if (StartWithWindows) key.SetValue("Dicta", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("Dicta", false);
        }
        catch { /* sin permisos: se ignora */ }
    }

    /// La clave de API (opcional) va cifrada con DPAPI del usuario.
    public static string? ApiKey
    {
        get
        {
            try
            {
                var p = Path.Combine(Paths.Data, "apikey.bin");
                if (!File.Exists(p)) return Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY");
                var bytes = System.Security.Cryptography.ProtectedData.Unprotect(File.ReadAllBytes(p), null,
                    System.Security.Cryptography.DataProtectionScope.CurrentUser);
                return System.Text.Encoding.UTF8.GetString(bytes);
            }
            catch { return null; }
        }
        set
        {
            var p = Path.Combine(Paths.Data, "apikey.bin");
            if (string.IsNullOrWhiteSpace(value)) { File.Delete(p); return; }
            File.WriteAllBytes(p, System.Security.Cryptography.ProtectedData.Protect(System.Text.Encoding.UTF8.GetBytes(value), null,
                System.Security.Cryptography.DataProtectionScope.CurrentUser));
        }
    }
}

public sealed class HistoryEntry
{
    public DateTime Date { get; set; }
    public string App { get; set; } = "";
    public string Raw { get; set; } = "";
    public string Text { get; set; } = "";
    public string Outcome { get; set; } = "";
    public string Engine { get; set; } = "";
}

public static class History
{
    public static List<HistoryEntry> Entries { get; } = Json.Load<List<HistoryEntry>>("history.json") ?? [];
    public static event Action? Changed;
    public static void Add(HistoryEntry e)
    {
        Entries.Insert(0, e);
        if (Entries.Count > 5000) Entries.RemoveRange(5000, Entries.Count - 5000);
        Json.Save("history.json", Entries);
        Changed?.Invoke();
    }
    public static void Clear() { Entries.Clear(); Json.Save("history.json", Entries); Changed?.Invoke(); }
}

public sealed class DictWord
{
    public string Word { get; set; } = "";
    public List<string> Aliases { get; set; } = [];
}

public static class Dictionary
{
    public static List<DictWord> Words { get; } = Json.Load<List<DictWord>>("dictionary.json") ?? [];
    public static event Action? Changed;

    public static IEnumerable<DictionaryEntry> Entries => Words.Select(w => new DictionaryEntry(w.Word, w.Aliases));
    public static List<string> PromptLines =>
        Words.Select(w => w.Aliases.Count == 0 ? w.Word : $"{w.Word} (se oye como: {string.Join(", ", w.Aliases)})").ToList();
    public static HashSet<string> Set => Words.Select(w => w.Word).ToHashSet();

    public static void Add(string word, string? alias = null)
    {
        word = word.Trim();
        if (word.Length == 0) return;
        alias = alias?.Trim().ToLowerInvariant();
        var existing = Words.FirstOrDefault(w => w.Word == word);
        if (existing is null) { existing = new DictWord { Word = word }; Words.Insert(0, existing); }
        if (!string.IsNullOrEmpty(alias) && alias != word.ToLowerInvariant() && !existing.Aliases.Contains(alias))
            existing.Aliases.Add(alias);
        Save();
    }

    public static void Remove(DictWord w) { Words.Remove(w); Save(); }
    public static void Save() { Json.Save("dictionary.json", Words); Changed?.Invoke(); }
}
