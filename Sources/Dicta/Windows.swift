import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Permisos

enum Permissions {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var allGranted: Bool { microphone && accessibility && inputMonitoring }

    static func requestMicrophone() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    static func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    /// macOS a veces solo aplica la Monitorización de entrada al reiniciar la app.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

struct PermissionsView: View {
    private let tick = State(initialValue: 0)
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dicta necesita tres permisos").font(.title2.bold())
            Text("Se piden una sola vez. Si cambias de versión de la app puede que tengas que volver a activarlos.")
                .foregroundStyle(.secondary)
            row("Micrófono", "Para escuchar tu voz.", Permissions.microphone) {
                Permissions.requestMicrophone(); Permissions.open("Privacy_Microphone")
            }
            row("Accesibilidad", "Para leer la casilla activa y pegar el texto (⌘V).", Permissions.accessibility) {
                Permissions.requestAccessibility(); Permissions.open("Privacy_Accessibility")
            }
            row("Monitorización de entrada", "Para detectar el atajo de teclado en cualquier app.", Permissions.inputMonitoring) {
                Permissions.requestInputMonitoring(); Permissions.open("Privacy_ListenEvent")
            }
            if Permissions.allGranted {
                Label("Todo listo. Mantén \(AppSettings.shared.trigger.symbol) derecho y habla.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.headline)
            }
            Divider()
            HStack {
                Text("¿Ya los activaste en Ajustes y aquí siguen sin marcar? Reinicia Dicta para que macOS los aplique.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Reiniciar Dicta") { Permissions.relaunch() }
            }
        }
        .padding(24).frame(width: 520)
        .id(tick.wrappedValue)
        .onReceive(timer) { _ in tick.wrappedValue += 1 }
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary).font(.title3)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Conceder…", action: action) }
        }
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @ObservedObject var s = AppSettings.shared
    private let apiKey = State(initialValue: Keychain.read() ?? "")
    private let saved = State(initialValue: false)
    private let engineStatus = State(initialValue: "")
    private let customModel = State(initialValue: false)
    private let probing = State(initialValue: false)
    private let probeResult = State(initialValue: "")

    static let customTag = "__custom__"
    /// IDs concretos conocidos hoy. Los que salgan en el futuro se escriben en «Otro…».
    static let knownModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-2",
                              "claude-sonnet-5", "claude-opus-5"]
    static let aliases = ["sonnet", "haiku", "opus"]

    /// Selección del desplegable: un alias, un ID conocido o «Otro…» (texto libre).
    private var modelChoice: Binding<String> {
        Binding(
            get: {
                let m = s.claudeCodeModel
                if customModel.wrappedValue || !(Self.aliases + Self.knownModels).contains(m) { return Self.customTag }
                return m
            },
            set: { v in
                probeResult.wrappedValue = ""
                if v == Self.customTag { customModel.wrappedValue = true } else {
                    customModel.wrappedValue = false
                    s.claudeCodeModel = v
                }
            })
    }

    private var lastModelText: String {
        if let m = UserDefaults.standard.string(forKey: "lastClaudeCodeModel") { return "Último dictado: \(m)" }
        return ""
    }

    private func probeModel() {
        let model = s.claudeCodeModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        probing.wrappedValue = true
        probeResult.wrappedValue = ""
        Task {
            do {
                let resolved = try await ClaudeCodeRunner.shared.probe(model: model)
                probeResult.wrappedValue = "✓ Responde \(resolved)"
            } catch {
                probeResult.wrappedValue = "✗ \(error.localizedDescription)"
            }
            probing.wrappedValue = false
        }
    }
    var onChange: () -> Void

    var body: some View {
        Form {
            Section("Atajo") {
                Picker("Tecla", selection: $s.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                Text("Mantén pulsada y habla; suelta para pegar. Doble toque: se queda escuchando hasta que vuelvas a tocarla. Mayús + tecla: modo edición sobre el texto seleccionado. Esc cancela.")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $s.holdThresholdMs, in: 150...600, step: 25) {
                    Text("Mantener a partir de \(Int(s.holdThresholdMs)) ms")
                }
                Slider(value: $s.doubleTapWindowMs, in: 200...700, step: 25) {
                    Text("Doble toque en \(Int(s.doubleTapWindowMs)) ms")
                }
            }
            Section("Corrección inteligente") {
                Picker("Motor", selection: $s.provider) {
                    ForEach(CleanupProvider.allCases) { Text($0.label).tag($0) }
                }
                if s.provider == .claudeCode {
                    Picker("Modelo", selection: modelChoice) {
                        Section("Siempre el último de cada familia") {
                            Text("Sonnet — equilibrado").tag("sonnet")
                            Text("Haiku — el más rápido").tag("haiku")
                            Text("Opus — el más listo").tag("opus")
                        }
                        Section("Modelo concreto") {
                            ForEach(Self.knownModels, id: \.self) { Text($0).tag($0) }
                            Text("Otro (escribir el ID)…").tag(Self.customTag)
                        }
                    }
                    if modelChoice.wrappedValue == Self.customTag {
                        TextField("ID del modelo, p. ej. claude-sonnet-5-5", text: $s.claudeCodeModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button(probing.wrappedValue ? "Comprobando…" : "Comprobar modelo") { probeModel() }
                            .disabled(probing.wrappedValue)
                        Text(probeResult.wrappedValue.isEmpty ? lastModelText : probeResult.wrappedValue)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Usa el comando «claude» de tu terminal con la sesión de tu cuenta (Pro/Max). No necesita clave de API y consume del uso de tu suscripción. Tarda ~1,5 s tras soltar la tecla.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.provider == .codex {
                    TextField("Modelo (vacío = el que use Codex por defecto)", text: $s.codexModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Usa el comando «codex» de tu terminal con tu sesión de ChatGPT (codex login). No necesita clave de API. Tarda ~4 s tras soltar la tecla.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if s.provider == .claude {
                    SecureField("Clave de API de Anthropic", text: apiKey.projectedValue)
                    HStack {
                        Button("Guardar clave en el Llavero") { saved.wrappedValue = Keychain.save(apiKey.wrappedValue) }
                        if saved.wrappedValue { Text("Guardada").foregroundStyle(.green) }
                    }
                    TextField("Modelo", text: $s.claudeModel)
                    Text("Por defecto claude-opus-5-5. Para máxima velocidad puedes usar claude-haiku-5-5.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Label(engineStatus.wrappedValue, systemImage: "info.circle")
                    .font(.callout)
                    .onAppear { engineStatus.wrappedValue = CleanerFactory.describe() }
                    .onChange(of: s.provider) { engineStatus.wrappedValue = CleanerFactory.describe() }
                    .onChange(of: saved.wrappedValue) { engineStatus.wrappedValue = CleanerFactory.describe() }
                Toggle("Usar el texto de la casilla como contexto", isOn: $s.useContext)
            }
            Section("Comportamiento") {
                Toggle("Aprender palabras cuando corrijo el texto pegado", isOn: $s.autoLearn)
                Toggle("Silenciar el audio del Mac mientras dicto", isOn: $s.muteSystemAudio)
                Toggle("Sonidos de inicio y fin", isOn: $s.playSounds)
                Toggle("Mostrar transcripción en directo", isOn: $s.showLivePreview)
                Toggle("Dejar siempre el dictado en el portapapeles", isOn: $s.keepInClipboard)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onChange(of: s.trigger) { onChange() }
        .onChange(of: s.holdThresholdMs) { onChange() }
        .onChange(of: s.doubleTapWindowMs) { onChange() }
        .onChange(of: s.showLivePreview) { onChange() }
    }
}

// MARK: - Historial

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    private let query = State(initialValue: "")
    private let selection = State(initialValue: Set<UUID>())

    private var filtered: [HistoryEntry] {
        query.wrappedValue.isEmpty ? store.entries : store.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query.wrappedValue) || $0.appName.localizedCaseInsensitiveContains(query.wrappedValue)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Buscar en el historial", text: query.projectedValue).textFieldStyle(.roundedBorder)
                Button("Borrar seleccionados") { store.delete(selection.wrappedValue); selection.wrappedValue.removeAll() }
                    .disabled(selection.wrappedValue.isEmpty)
            }.padding(10)
            List(selection: selection.projectedValue) {
                ForEach(filtered) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text(e.appName).font(.caption.bold())
                            badge(e.outcome)
                            Spacer()
                            Button { TextInserter.copyToClipboard(e.text) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copiar")
                        }
                        Text(e.text).textSelection(.enabled)
                        if e.raw != e.text {
                            Text("Oído: \(e.raw)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.vertical, 4).tag(e.id)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
    }

    private func badge(_ o: HistoryEntry.Outcome) -> some View {
        let (t, c): (String, Color) = switch o {
        case .pasted: ("pegado", .green)
        case .clipboard: ("en portapapeles", .orange)
        case .failed: ("fallo", .red)
        case .edited: ("editado", .blue)
        }
        return Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
    }
}

// MARK: - Diccionario

struct DictionaryView: View {
    @ObservedObject var store = DictionaryStore.shared
    private let newWord = State(initialValue: "")
    private let newAlias = State(initialValue: "")
    private let selection = State(initialValue: Set<UUID>())
    private let editingID = State<UUID?>(initialValue: nil)
    private let aliasDraft = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palabras que Dicta debe escribir siempre así: nombres, marcas, términos técnicos… Se aplican aunque el reconocedor oiga una palabra parecida (whisper → Wispr). Se aprenden solas cuando corriges una palabra justo después de dictarla.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Se escribe (p. ej. «Wispr»)", text: newWord.projectedValue)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                TextField("Se oye como (opcional, p. ej. «whisper»)", text: newAlias.projectedValue)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Añadir", action: add).disabled(newWord.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(selection: selection.projectedValue) {
                ForEach(store.words) { w in
                    HStack {
                        Text(w.word).bold()
                        ForEach(w.aliases ?? [], id: \.self) { a in
                            HStack(spacing: 2) {
                                Text("← \(a)").font(.caption)
                                Button { store.removeAlias(a, from: w.id) } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                        }
                        if editingID.wrappedValue == w.id {
                            TextField("se oye como…", text: aliasDraft.projectedValue)
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                                .onSubmit { saveAlias(for: w) }
                            Button("Guardar") { saveAlias(for: w) }
                            Button("Cancelar") { editingID.wrappedValue = nil }
                        } else {
                            Button { aliasDraft.wrappedValue = ""; editingID.wrappedValue = w.id } label: {
                                Label("cómo suena", systemImage: "plus").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Añadir cómo lo oye el reconocedor (p. ej. «whisper» para «Wispr»)")
                        }
                        Spacer()
                        if w.source == .learned {
                            Text("aprendida").font(.caption2).padding(.horizontal, 6)
                                .background(.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
                        }
                        Button { store.remove(ids: [w.id]) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Quitar (deshacer aprendizaje)")
                    }.tag(w.id)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 440)
    }

    private func saveAlias(for w: DictionaryWord) {
        let a = aliasDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { store.add(w.word, alias: a) }
        editingID.wrappedValue = nil
        aliasDraft.wrappedValue = ""
    }

    private func add() {
        let w = newWord.wrappedValue, a = newAlias.wrappedValue
        guard !w.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(w, alias: a)
        newWord.wrappedValue = ""; newAlias.wrappedValue = ""
    }
}

private extension DictionaryStore {
    func remove(ids: Set<UUID>) { remove(ids) }
}

// MARK: - Gestor de ventanas

@MainActor
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, @ViewBuilder content: () -> V) {
        NSApp.setActivationPolicy(.regular)
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
        w.title = title
        w.styleMask.insert([.resizable, .closable, .titled, .miniaturizable])
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.windows.values.filter({ $0.isVisible && $0 !== w }).isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
