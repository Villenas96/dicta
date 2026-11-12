import DictaCore
import Foundation
import FoundationModels

enum CleanerError: LocalizedError {
    case missingKey, http(Int, String), refusal, unavailable(String), timeout, claudeCode(String)
    var errorDescription: String? {
        switch self {
        case .claudeCode(let msg): return "Claude Code: \(msg)"
        case .missingKey: return "Falta la clave de API de Anthropic (Ajustes)."
        case .http(let code, let msg): return "Claude respondió \(code): \(msg)"
        case .refusal: return "El modelo rechazó la petición."
        case .unavailable(let why): return "Apple Intelligence no disponible: \(why)"
        case .timeout: return "La corrección tardó demasiado."
        }
    }
}

protocol TextCleaner: Sendable {
    var name: String { get }
    /// Nombre para mostrar al usuario («Claude Code · sonnet»).
    var displayName: String { get }
    /// Tiempo máximo antes de caer a la limpieza básica.
    var timeout: TimeInterval { get }
    func clean(_ request: CleanupRequest) async throws -> String
}

extension TextCleaner {
    var displayName: String { name }
    var timeout: TimeInterval { 12 }
}

/// Claude por la API de Mensajes (HTTP directo: Swift no tiene SDK oficial).
struct ClaudeCleaner: TextCleaner {
    let apiKey: String
    let model: String
    var name: String { model }
    var displayName: String { "Claude API · \(model)" }

    func clean(_ request: CleanupRequest) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": CleanupPrompt.systemPrompt(for: request),
            "messages": [["role": "user", "content": CleanupPrompt.userMessage(for: request)]],
            // Tarea corta y sensible a la latencia: esfuerzo bajo.
            "output_config": ["effort": "low"],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Respaldo automático en el servidor si el modelo rechaza la petición.
        if ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2"].contains(model) {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw CleanerError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw CleanerError.refusal }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return CleanupPrompt.sanitize(text)
    }
}

/// Modelo de Apple en el propio Mac (Foundation Models): gratis, privado y sin conexión.
struct AppleCleaner: TextCleaner {
    var name: String { "apple-on-device" }
    var displayName: String { "Apple Intelligence (en el Mac)" }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func clean(_ request: CleanupRequest) async throws -> String {
        guard Self.isAvailable else { throw CleanerError.unavailable("\(SystemLanguageModel.default.availability)") }
        let session = LanguageModelSession(instructions: CleanupPrompt.systemPrompt(for: request))
        let response = try await session.respond(to: CleanupPrompt.userMessage(for: request))
        return CleanupPrompt.sanitize(response.content)
    }
}

struct LocalRulesCleaner: TextCleaner {
    var name: String { "local" }
    var displayName: String { "Limpieza básica (sin IA)" }
    func clean(_ request: CleanupRequest) async throws -> String {
        if case .edit = request.mode { return LocalCleaner.clean(request.raw, request: request) }
        return LocalCleaner.clean(request.raw, request: request)
    }
}

enum CleanerFactory {
    @MainActor
    static func make() -> TextCleaner {
        let s = AppSettings.shared
        switch s.provider {
        case .claudeCode:
            if ClaudeCodeRunner.executablePath != nil { return ClaudeCodeCleaner(model: s.claudeCodeModel) }
            return AppleCleaner.isAvailable ? AppleCleaner() : LocalRulesCleaner()
        case .codex:
            if CodexRunner.executablePath != nil { return CodexCleaner(model: s.codexModel) }
            return AppleCleaner.isAvailable ? AppleCleaner() : LocalRulesCleaner()
        case .claude:
            if let key = s.apiKey { return ClaudeCleaner(apiKey: key, model: s.claudeModel) }
            return AppleCleaner.isAvailable ? AppleCleaner() : LocalRulesCleaner()
        case .apple:
            return AppleCleaner.isAvailable ? AppleCleaner() : LocalRulesCleaner()
        case .none:
            return LocalRulesCleaner()
        }
    }

    /// Explica qué motor se está usando de verdad (y por qué, si no es el elegido).
    @MainActor
    static func describe() -> String {
        let s = AppSettings.shared
        let actual = make().displayName
        switch s.provider {
        case .claudeCode where ClaudeCodeRunner.executablePath == nil:
            return "No encuentro el comando «claude» → se usa \(actual)."
        case .codex where CodexRunner.executablePath == nil:
            return "No encuentro el comando «codex» → se usa \(actual)."
        case .claude where s.apiKey == nil:
            return "No hay clave de API → se usa \(actual)."
        case .apple where !AppleCleaner.isAvailable:
            return "Apple Intelligence no está disponible → se usa \(actual)."
        default:
            return "Se usa: \(actual)."
        }
    }

    /// Arranca el motor por adelantado (al empezar a hablar).
    @MainActor
    static func prewarm() {
        let s = AppSettings.shared
        if s.provider == .claudeCode, ClaudeCodeRunner.executablePath != nil {
            let model = s.claudeCodeModel
            Task { await ClaudeCodeRunner.shared.prewarm(model: model) }
        } else if s.provider == .codex, CodexRunner.executablePath != nil {
            let model = s.codexModel
            Task { await CodexRunner.shared.prewarm(model: model) }
        }
    }

    /// Ejecuta el corrector con límite de tiempo; si falla, cae a la limpieza básica
    /// para no perder nunca el dictado.
    static func cleanWithFallback(_ cleaner: TextCleaner, _ request: CleanupRequest,
                                  timeout: TimeInterval = 12) async -> (text: String, provider: String, error: Error?) {
        do {
            let text = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await cleaner.clean(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CleanerError.timeout
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            // Si el modelo devuelve vacío pero sí había voz, no tiramos el dictado.
            if text.isEmpty, request.raw.split(separator: " ").count > 2 {
                return (LocalCleaner.clean(request.raw, request: request), "local", nil)
            }
            return (text, cleaner.name, nil)
        } catch {
            return (LocalCleaner.clean(request.raw, request: request), "local", error)
        }
    }
}


// MARK: - Claude Code (tu suscripción, sin API key)

/// Usa el CLI `claude` ya autenticado con tu cuenta (Pro/Max): no hace falta API key
/// y consume del uso de tu suscripción.
struct ClaudeCodeCleaner: TextCleaner {
    let model: String
    var name: String { "claude-code-\(model)" }
    var displayName: String { "Claude Code · \(model) (tu suscripción)" }
    var timeout: TimeInterval { 25 }

    func clean(_ request: CleanupRequest) async throws -> String {
        let out = try await ClaudeCodeRunner.shared.run(prompt: CleanupPrompt.userMessage(for: request), model: model)
        return CleanupPrompt.sanitize(out)
    }
}

/// Mantiene un proceso `claude -p` precalentado (el arranque cuesta ~3 s; la respuesta
/// con el proceso ya listo, ~1,5 s). Cada dictado usa un proceso nuevo para no mezclar
/// conversaciones.
actor ClaudeCodeRunner {
    static let shared = ClaudeCodeRunner()

    private struct Warm {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let model: String
        let born: Date
    }
    private var warm: Warm?
    /// Modelo concreto que respondió la última vez.
    private(set) var lastResolvedModel: String?

    /// Comprueba un modelo (alias o ID exacto) con una petición mínima y devuelve el ID real.
    func probe(model: String) async throws -> String {
        lastResolvedModel = nil
        _ = try await run(prompt: "<transcripcion>\nok\n</transcripcion>", model: model)
        return lastResolvedModel ?? model
    }

    /// Ruta del CLI `claude`. Las apps del Dock no heredan el PATH de la terminal,
    /// así que se prueba en los sitios habituales y, si no, con un shell de login.
    nonisolated static let executablePath: String? = CLITool.find("claude", extra: ["~/.claude/local/claude"])

    func prewarm(model: String) {
        if let w = warm, w.model == model, w.process.isRunning, Date().timeIntervalSince(w.born) < 600 { return }
        discardWarm()
        warm = try? spawn(model: model)
        // Si no se usa en 5 minutos, se libera.
        let born = warm?.born
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            self.expire(born: born)
        }
    }

    private func expire(born: Date?) {
        if let w = warm, w.born == born { discardWarm() }
    }

    private func discardWarm() {
        if let w = warm {
            try? w.stdin.close()
            if w.process.isRunning { w.process.terminate() }
        }
        warm = nil
    }

    private func spawn(model: String) throws -> Warm {
        guard let path = Self.executablePath else { throw CleanerError.claudeCode("no encuentro el comando «claude»") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-p", "--model", model, "--effort", "low",
                       "--system-prompt", CleanupPrompt.combinedSystem,
                       "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                       "--no-session-persistence",
                       "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY") // que use la sesión de tu suscripción
        env["PATH"] = CLITool.searchPath(env["PATH"])
        p.environment = env
        // Carpeta neutra: sin CLAUDE.md de ningún proyecto.
        let cwd = AppPaths.supportDir.appendingPathComponent("claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        p.currentDirectoryURL = cwd
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        return Warm(process: p, stdin: inPipe.fileHandleForWriting, stdout: outPipe.fileHandleForReading,
                    model: model, born: Date())
    }

    func run(prompt: String, model: String) async throws -> String {
        let w: Warm
        if let cur = warm, cur.model == model, cur.process.isRunning {
            w = cur
        } else {
            discardWarm()
            w = try spawn(model: model)
        }
        warm = nil
        defer {
            try? w.stdin.close()
            if w.process.isRunning { w.process.terminate() }
            // Deja preparado el siguiente.
            Task { self.prewarm(model: model) }
        }

        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        var line = try JSONSerialization.data(withJSONObject: msg)
        line.append(0x0A)
        try w.stdin.write(contentsOf: line)

        for try await raw in w.stdout.bytes.lines {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // El evento init dice qué modelo concreto hay detrás del alias («sonnet» → «claude-sonnet-5-5»).
            if obj["type"] as? String == "system", obj["subtype"] as? String == "init",
               let resolved = obj["model"] as? String {
                lastResolvedModel = resolved
                UserDefaults.standard.set(resolved, forKey: "lastClaudeCodeModel")
            }
            guard obj["type"] as? String == "result" else { continue }
            let text = obj["result"] as? String ?? ""
            if obj["subtype"] as? String == "success", (obj["is_error"] as? Bool) != true { return text }
            let lower = text.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("auth") {
                throw CleanerError.claudeCode("no has iniciado sesión. Ejecuta «claude» en la terminal y entra con tu cuenta.")
            }
            throw CleanerError.claudeCode(text.isEmpty ? "error desconocido" : text)
        }
        throw CleanerError.claudeCode("el proceso terminó sin respuesta (¿sesión iniciada en «claude»?)")
    }
}


// MARK: - Utilidades para CLIs

enum CLITool {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Las apps del Dock no heredan el PATH de la terminal: añadimos las rutas habituales.
    static func searchPath(_ current: String?) -> String {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/Library/pnpm",
         "\(home)/.npm-global/bin", "/usr/bin", "/bin", current ?? ""].joined(separator: ":")
    }

    /// Busca un ejecutable en las rutas habituales y, si no, con un shell de login.
    static func find(_ name: String, extra: [String] = []) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                          "\(home)/Library/pnpm/\(name)", "\(home)/.npm-global/bin/\(name)"]
            + extra.map { $0.replacingOccurrences(of: "~", with: home) }
        if let p = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: out) ? out : nil
    }
}

// MARK: - Codex (tu suscripción de ChatGPT, sin API key)

struct CodexCleaner: TextCleaner {
    let model: String
    var name: String { "codex" + (model.isEmpty ? "" : "-\(model)") }
    var displayName: String { "Codex" + (model.isEmpty ? "" : " · \(model)") + " (tu suscripción)" }
    var timeout: TimeInterval { 30 }

    func clean(_ request: CleanupRequest) async throws -> String {
        let prompt = CleanupPrompt.combinedSystem + "\n\n" + CleanupPrompt.userMessage(for: request)
        return CleanupPrompt.sanitize(try await CodexRunner.shared.run(prompt: prompt, model: model))
    }
}

/// `codex exec` precalentado: se arranca al empezar a hablar con la instrucción por stdin
/// («-») y se le pasa el texto al soltar. Sin la configuración del usuario (MCP, etc.),
/// que lo hace más lento. ~4 s con el proceso ya listo.
actor CodexRunner {
    static let shared = CodexRunner()
    nonisolated static let executablePath: String? = CLITool.find("codex")

    private struct Warm { let process: Process; let stdin: FileHandle; let out: URL; let model: String; let born: Date }
    private var warm: Warm?

    func prewarm(model: String) {
        if let w = warm, w.model == model, w.process.isRunning, Date().timeIntervalSince(w.born) < 600 { return }
        discard()
        warm = try? spawn(model: model)
        let born = warm?.born
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            self.expire(born: born)
        }
    }

    private func expire(born: Date?) { if let w = warm, w.born == born { discard() } }

    private func discard() {
        if let w = warm { try? w.stdin.close(); if w.process.isRunning { w.process.terminate() } }
        warm = nil
    }

    private func spawn(model: String) throws -> Warm {
        guard let path = Self.executablePath else { throw CleanerError.claudeCode("no encuentro el comando «codex»") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dicta-codex-\(UUID().uuidString).txt")
        let cwd = AppPaths.supportDir.appendingPathComponent("claude-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "-s", "read-only",
                    "-c", "model_reasoning_effort=\"low\"", "--color", "never", "-C", cwd.path, "-o", out.path]
        if !model.isEmpty { args += ["-m", model] }
        args.append("-")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OPENAI_API_KEY") // que use la sesión de ChatGPT
        env["PATH"] = CLITool.searchPath(env["PATH"])
        p.environment = env
        p.currentDirectoryURL = cwd
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return Warm(process: p, stdin: inPipe.fileHandleForWriting, out: out, model: model, born: Date())
    }

    func run(prompt: String, model: String) async throws -> String {
        let w: Warm
        if let cur = warm, cur.model == model, cur.process.isRunning { w = cur } else { discard(); w = try spawn(model: model) }
        warm = nil
        defer {
            try? FileManager.default.removeItem(at: w.out)
            Task { self.prewarm(model: model) }
        }
        try w.stdin.write(contentsOf: Data(prompt.utf8))
        try w.stdin.close()
        while w.process.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        let text = (try? String(contentsOf: w.out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard w.process.terminationStatus == 0, !text.isEmpty else {
            throw CleanerError.claudeCode("Codex no respondió (¿sesión iniciada? ejecuta «codex login»)")
        }
        return text
    }
}
