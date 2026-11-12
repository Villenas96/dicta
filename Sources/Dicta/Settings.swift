import AppKit
import Combine
import Foundation
import Security

/// Tecla que dispara el dictado. Igual que Wispr/Typeless: una tecla modificadora sola.
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }
    /// Máscara de dispositivo (NX_DEVICER*KEYMASK) para saber si está pulsada.
    var deviceMask: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .fn: return 0x800000 // maskSecondaryFn
        }
    }
    var label: String {
        switch self {
        case .rightOption: return "⌥ Opción derecha"
        case .rightCommand: return "⌘ Comando derecho"
        case .rightControl: return "⌃ Control derecho"
        case .fn: return "fn / 🌐 (desactiva el emoji de fn en Ajustes › Teclado)"
        }
    }
    var symbol: String {
        switch self {
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
}

enum CleanupProvider: String, CaseIterable, Identifiable {
    case claudeCode, codex, claude, apple, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCode: return "Claude Code — tu suscripción, sin API key"
        case .codex: return "Codex — tu suscripción de ChatGPT, sin API key"
        case .claude: return "Claude API (con clave de API)"
        case .apple: return "Apple Intelligence (en el Mac, sin conexión)"
        case .none: return "Sin IA (solo limpieza básica)"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var trigger: TriggerKey { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var provider: CleanupProvider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    @Published var claudeCodeModel: String { didSet { d.set(claudeCodeModel, forKey: "claudeCodeModel") } }
    @Published var codexModel: String { didSet { d.set(codexModel, forKey: "codexModel") } }
    @Published var holdThresholdMs: Double { didSet { d.set(holdThresholdMs, forKey: "holdMs") } }
    @Published var doubleTapWindowMs: Double { didSet { d.set(doubleTapWindowMs, forKey: "doubleTapMs") } }
    @Published var muteSystemAudio: Bool { didSet { d.set(muteSystemAudio, forKey: "mute") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "sounds") } }
    @Published var showLivePreview: Bool { didSet { d.set(showLivePreview, forKey: "livePreview") } }
    @Published var autoLearn: Bool { didSet { d.set(autoLearn, forKey: "autoLearn") } }
    @Published var keepInClipboard: Bool { didSet { d.set(keepInClipboard, forKey: "keepClipboard") } }
    @Published var useContext: Bool { didSet { d.set(useContext, forKey: "useContext") } }
    @Published var localeID: String { didSet { d.set(localeID, forKey: "locale") } }

    private init() {
        d.register(defaults: [
            "trigger": TriggerKey.rightOption.rawValue,
            "provider": CleanupProvider.apple.rawValue, // gratis; pasa a Claude Code si está instalado
            "claudeModel": "claude-opus-5-5",
            "claudeCodeModel": "sonnet",
            "holdMs": 300.0, "doubleTapMs": 400.0,
            "mute": false, "sounds": true, "livePreview": true,
            "autoLearn": true, "keepClipboard": false, "useContext": true,
            "locale": "es_ES",
        ])
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .rightOption
        provider = CleanupProvider(rawValue: d.string(forKey: "provider") ?? "") ?? .claude
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-opus-5-5"
        claudeCodeModel = d.string(forKey: "claudeCodeModel") ?? "sonnet"
        codexModel = d.string(forKey: "codexModel") ?? ""
        // Una sola vez: si tienes Claude Code instalado, pasa a usarlo por defecto.
        if !d.bool(forKey: "migratedToClaudeCode") {
            d.set(true, forKey: "migratedToClaudeCode")
            // Primero Claude Code; si no, Codex. didSet no corre en init: se guarda a mano.
            if ClaudeCodeRunner.executablePath != nil {
                provider = .claudeCode
                d.set(CleanupProvider.claudeCode.rawValue, forKey: "provider")
            } else if CodexRunner.executablePath != nil {
                provider = .codex
                d.set(CleanupProvider.codex.rawValue, forKey: "provider")
            }
        }
        holdThresholdMs = d.double(forKey: "holdMs")
        doubleTapWindowMs = d.double(forKey: "doubleTapMs")
        muteSystemAudio = d.bool(forKey: "mute")
        playSounds = d.bool(forKey: "sounds")
        showLivePreview = d.bool(forKey: "livePreview")
        autoLearn = d.bool(forKey: "autoLearn")
        keepInClipboard = d.bool(forKey: "keepClipboard")
        useContext = d.bool(forKey: "useContext")
        localeID = d.string(forKey: "locale") ?? "es_ES"
    }

    /// Clave de API: Keychain, o variable de entorno ANTHROPIC_API_KEY.
    var apiKey: String? {
        if let k = Keychain.read(), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return nil
    }
}

enum Keychain {
    static let service = "local.dicta.app"
    static let account = "anthropic-api-key"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
