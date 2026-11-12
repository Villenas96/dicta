using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dicta.Core;

namespace Dicta;

public interface ICleaner
{
    string DisplayName { get; }
    TimeSpan Timeout { get; }
    Task<string> CleanAsync(CleanupRequest r, CancellationToken ct);
}

/// Localiza un CLI (claude / codex) aunque la app no herede el PATH de la terminal.
static class CliFinder
{
    public static string? Find(string name)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates =
        [
            Path.Combine(home, ".local", "bin", name + ".exe"),
            Path.Combine(local, "Programs", name, name + ".exe"),
            Path.Combine(appData, "npm", name + ".cmd"),
            Path.Combine(local, "pnpm", name + ".cmd"),
            Path.Combine(local, "pnpm", name + ".exe"),
        ];
        foreach (var c in candidates) if (File.Exists(c)) return c;
        try
        {
            var p = Process.Start(new ProcessStartInfo("where.exe", name)
            { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
            var lines = p.StandardOutput.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            p.WaitForExit(3000);
            return lines.FirstOrDefault(l => l.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                ?? lines.FirstOrDefault(l => l.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase));
        }
        catch { return null; }
    }

    static string Quote(string a) => a.Length > 0 && !a.Any(c => c is ' ' or '"' or '\t') ? a : "\"" + a.Replace("\"", "\\\"") + "\"";

    /// Crea el proceso; los .cmd de npm/pnpm se lanzan a través de cmd.exe.
    public static ProcessStartInfo StartInfo(string exe, IEnumerable<string> args)
    {
        var argLine = string.Join(" ", args.Select(Quote));
        var psi = exe.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
            ? new ProcessStartInfo("cmd.exe", $"/d /s /c \"{Quote(exe)} {argLine}\"")
            : new ProcessStartInfo(exe, argLine);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardInputEncoding = new UTF8Encoding(false);
        psi.WorkingDirectory = Paths.Work; // carpeta neutra, sin CLAUDE.md/AGENTS.md de proyectos
        return psi;
    }
}

/// Claude Code con la sesión de la suscripción del alumno (Pro/Max), sin API key.
public sealed class ClaudeCodeCleaner(string model) : ICleaner
{
    public static readonly string? Exe = CliFinder.Find("claude");
    static Process? _warm;
    static string? _warmModel;
    static readonly object Lock = new();

    public string DisplayName => $"Claude Code · {model} (tu suscripción)";
    public TimeSpan Timeout => TimeSpan.FromSeconds(25);

    static string PromptFile()
    {
        var p = Path.Combine(Paths.Work, "system-prompt.txt");
        File.WriteAllText(p, CleanupPrompt.System, new UTF8Encoding(false));
        return p;
    }

    static Process Spawn(string model)
    {
        var psi = CliFinder.StartInfo(Exe!, ["-p", "--model", model, "--effort", "low", "--system-prompt-file", PromptFile(),
            "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]);
        psi.Environment.Remove("ANTHROPIC_API_KEY"); // que use la suscripción
        return Process.Start(psi)!;
    }

    /// Arranca el proceso mientras el usuario habla (el arranque cuesta ~3 s).
    public static void Prewarm(string model)
    {
        if (Exe is null) return;
        lock (Lock)
        {
            if (_warm is { HasExited: false } && _warmModel == model) return;
            try { _warm?.Kill(true); } catch { }
            try { _warm = Spawn(model); _warmModel = model; } catch { _warm = null; }
        }
    }

    public async Task<string> CleanAsync(CleanupRequest r, CancellationToken ct)
    {
        if (Exe is null) throw new Exception("no encuentro el comando «claude»");
        Process p;
        lock (Lock)
        {
            p = _warm is { HasExited: false } && _warmModel == model ? _warm : Spawn(model);
            _warm = null;
        }
        try
        {
            var msg = new JsonObject
            {
                ["type"] = "user",
                ["message"] = new JsonObject { ["role"] = "user", ["content"] = CleanupPrompt.UserMessage(r) },
            };
            await p.StandardInput.WriteLineAsync(msg.ToJsonString());
            await p.StandardInput.FlushAsync();
            while (await p.StandardOutput.ReadLineAsync(ct) is { } line)
            {
                JsonNode? o;
                try { o = JsonNode.Parse(line); } catch { continue; }
                if (o?["type"]?.GetValue<string>() != "result") continue;
                var text = o["result"]?.GetValue<string>() ?? "";
                var ok = o["subtype"]?.GetValue<string>() == "success" && o["is_error"]?.GetValue<bool>() != true;
                if (ok) return CleanupPrompt.Sanitize(text);
                if (text.Contains("login", StringComparison.OrdinalIgnoreCase))
                    throw new Exception("no has iniciado sesión: abre una terminal, escribe «claude» y entra con tu cuenta");
                throw new Exception(text.Length > 0 ? text : "error desconocido");
            }
            throw new Exception("Claude Code terminó sin responder (¿sesión iniciada?)");
        }
        finally
        {
            try { p.StandardInput.Close(); if (!p.HasExited) p.Kill(true); } catch { }
            _ = Task.Run(() => Prewarm(model)); // deja el siguiente listo
        }
    }
}

/// Codex con la sesión de ChatGPT del alumno (codex login), sin API key.
public sealed class CodexCleaner(string model) : ICleaner
{
    public static readonly string? Exe = CliFinder.Find("codex");
    static (Process P, string Out, string Model)? _warm;
    static readonly object Lock = new();

    public string DisplayName => "Codex" + (model.Length > 0 ? $" · {model}" : "") + " (tu suscripción)";
    public TimeSpan Timeout => TimeSpan.FromSeconds(35);

    static (Process, string, string) Spawn(string model)
    {
        var outFile = Path.Combine(Path.GetTempPath(), $"dicta-codex-{Guid.NewGuid():N}.txt");
        var args = new List<string> { "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "-s", "read-only",
            "-c", "model_reasoning_effort=low", "--color", "never", "-C", Paths.Work, "-o", outFile };
        if (model.Length > 0) { args.Add("-m"); args.Add(model); }
        // Solo corrige texto: sin terminal, navegador, apps ni control del ordenador.
        foreach (var f in new[] { "shell_tool", "unified_exec", "apps", "browser_use", "browser_use_external",
                                  "computer_use", "in_app_browser", "tool_suggest", "sleep_tool" })
        { args.Add("--disable"); args.Add(f); }
        args.Add("-");
        var psi = CliFinder.StartInfo(Exe!, args);
        psi.Environment.Remove("OPENAI_API_KEY"); // que use la sesión de ChatGPT
        return (Process.Start(psi)!, outFile, model);
    }

    public static void Prewarm(string model)
    {
        if (Exe is null) return;
        lock (Lock)
        {
            if (_warm is { } w && !w.P.HasExited && w.Model == model) return;
            try { _warm?.P.Kill(true); } catch { }
            try { _warm = Spawn(model); } catch { _warm = null; }
        }
    }

    public async Task<string> CleanAsync(CleanupRequest r, CancellationToken ct)
    {
        if (Exe is null) throw new Exception("no encuentro el comando «codex»");
        (Process P, string Out, string Model) w;
        lock (Lock)
        {
            w = _warm is { } cur && !cur.P.HasExited && cur.Model == model ? cur : Spawn(model);
            _warm = null;
        }
        try
        {
            // Codex lee la instrucción de stdin («-»): se la damos y cerramos.
            await w.P.StandardInput.WriteAsync(CleanupPrompt.System + "\n\n" + CleanupPrompt.UserMessage(r));
            w.P.StandardInput.Close();
            _ = w.P.StandardOutput.ReadToEndAsync(ct); // vaciar para que no se bloquee
            _ = w.P.StandardError.ReadToEndAsync(ct);
            await w.P.WaitForExitAsync(ct);
            var text = File.Exists(w.Out) ? (await File.ReadAllTextAsync(w.Out, ct)).Trim() : "";
            if (w.P.ExitCode != 0 || text.Length == 0)
                throw new Exception("Codex no respondió (¿sesión iniciada? abre una terminal y ejecuta «codex login»)");
            return CleanupPrompt.Sanitize(text);
        }
        finally
        {
            try { File.Delete(w.Out); if (!w.P.HasExited) w.P.Kill(true); } catch { }
            _ = Task.Run(() => Prewarm(model));
        }
    }
}

/// Claude por la API de Mensajes (opcional, para quien tenga clave).
public sealed class ClaudeApiCleaner(string apiKey, string model) : ICleaner
{
    static readonly HttpClient Http = new();
    public string DisplayName => $"Claude API · {model}";
    public TimeSpan Timeout => TimeSpan.FromSeconds(20);

    public async Task<string> CleanAsync(CleanupRequest r, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = 4096,
            ["system"] = CleanupPrompt.System,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = CleanupPrompt.UserMessage(r) }),
            ["output_config"] = new JsonObject { ["effort"] = "low" },
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages")
        { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2026-10-21");
        if (model is "claude-opus-5-5" or "claude-sonnet-5-5" or "claude-fable-5-2")
        {
            body["fallbacks"] = "default";
            req.Headers.Add("anthropic-beta", "server-side-fallback-2026-07-01");
            req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        }
        using var resp = await Http.SendAsync(req, ct);
        var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct));
        if (!resp.IsSuccessStatusCode) throw new Exception($"Claude API {(int)resp.StatusCode}: {json?["error"]?["message"]}");
        if (json?["stop_reason"]?.GetValue<string>() == "refusal") throw new Exception("el modelo rechazó la petición");
        var sb = new StringBuilder();
        foreach (var b in json?["content"]?.AsArray() ?? [])
            if (b?["type"]?.GetValue<string>() == "text") sb.Append(b["text"]?.GetValue<string>());
        return CleanupPrompt.Sanitize(sb.ToString());
    }
}

public sealed class LocalCleanerEngine : ICleaner
{
    public string DisplayName => "Limpieza básica (sin IA)";
    public TimeSpan Timeout => TimeSpan.FromSeconds(1);
    public Task<string> CleanAsync(CleanupRequest r, CancellationToken ct) => Task.FromResult(LocalCleaner.Clean(r.Raw, r.IsTerminal));
}

public static class CleanerFactory
{
    public static ICleaner Make()
    {
        var s = Settings.Current;
        return s.Provider switch
        {
            Provider.ClaudeCode when ClaudeCodeCleaner.Exe is not null => new ClaudeCodeCleaner(s.ClaudeCodeModel),
            Provider.Codex when CodexCleaner.Exe is not null => new CodexCleaner(s.CodexModel),
            Provider.ClaudeApi when Settings.ApiKey is { Length: > 0 } k => new ClaudeApiCleaner(k, s.ClaudeApiModel),
            _ => new LocalCleanerEngine(),
        };
    }

    public static string Describe()
    {
        var s = Settings.Current;
        var actual = Make().DisplayName;
        return s.Provider switch
        {
            Provider.ClaudeCode when ClaudeCodeCleaner.Exe is null => $"No encuentro «claude» → se usa {actual}",
            Provider.Codex when CodexCleaner.Exe is null => $"No encuentro «codex» → se usa {actual}",
            Provider.ClaudeApi when string.IsNullOrEmpty(Settings.ApiKey) => $"No hay clave de API → se usa {actual}",
            _ => $"Corrección: {actual}",
        };
    }

    public static void Prewarm()
    {
        var s = Settings.Current;
        if (s.Provider == Provider.ClaudeCode) _ = Task.Run(() => ClaudeCodeCleaner.Prewarm(s.ClaudeCodeModel));
        else if (s.Provider == Provider.Codex) _ = Task.Run(() => CodexCleaner.Prewarm(s.CodexModel));
    }

    /// Con límite de tiempo; si falla, limpieza básica para no perder nunca el dictado.
    public static async Task<(string Text, string Engine, string? Error)> CleanWithFallbackAsync(ICleaner c, CleanupRequest r)
    {
        using var cts = new CancellationTokenSource(c.Timeout);
        try
        {
            var text = await c.CleanAsync(r, cts.Token);
            if (text.Length == 0 && r.Raw.Split(' ').Length > 2) return (LocalCleaner.Clean(r.Raw, r.IsTerminal), "local", null);
            return (text, c.DisplayName, null);
        }
        catch (Exception e)
        {
            return (LocalCleaner.Clean(r.Raw, r.IsTerminal), "local", e is OperationCanceledException ? "tardó demasiado" : e.Message);
        }
    }
}
