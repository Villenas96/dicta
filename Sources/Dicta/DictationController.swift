import AppKit
import AVFoundation
import DictaCore

/// Orquesta el ciclo completo: atajo → micro → transcripción en streaming → corrección
/// → pegado (o portapapeles) → historial → aprendizaje.
@MainActor
final class DictationController {
    enum State { case idle, recording, processing }

    let hotkeys = HotkeyMonitor()
    let overlay = OverlayController()
    private let recorder = AudioRecorder()
    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let dictionary = DictionaryStore.shared

    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?

    private var session: SpeechSession?
    private var snapshot = FocusSnapshot()
    private var editMode = false
    private var handsFree = false
    private var startedAt = Date()
    private var cachedFormat: AVAudioFormat?

    /// Último texto insertado: para continuar en la misma casilla y para re-dictar.
    private var lastRecord: InsertionRecord?
    private var lastInsert: (element: AXUIElement, location: Int, length: Int, text: String)?
    private var learnTasks: [Task<Void, Never>] = []

    init() {
        hotkeys.onAction = { [weak self] e in self?.handle(e) }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        overlay.model.onStop = { [weak self] in
            self?.hotkeys.reset()
            self?.stopAndProcess()
        }
        overlay.model.onCancel = { [weak self] in self?.hotkeys.reset(); self?.cancel() }
        overlay.model.onRedictate = { [weak self] in self?.redictateLast() }
        overlay.model.onUndo = { [weak self] in
            self?.overlay.hide()
            TextInserter.undoShortcut()
        }
        overlay.model.onCopy = { [weak self] in
            guard let self, let t = self.history.last?.text else { return }
            TextInserter.copyToClipboard(t)
            self.overlay.show(.message("Copiado al portapapeles", icon: "doc.on.clipboard"), autoHide: 1.5)
        }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.overlay.model.push(level: level) }
        }
    }

    func applySettings() {
        hotkeys.configure(trigger: settings.trigger, holdMs: settings.holdThresholdMs, doubleTapMs: settings.doubleTapWindowMs)
        overlay.model.triggerSymbol = settings.trigger.symbol
        overlay.model.showPreview = settings.showLivePreview
    }

    func start() {
        applySettings()
        hotkeys.start()
        Task { await warmUp() }
    }

    /// Descarga/carga el modelo de español y calcula el formato de audio por adelantado,
    /// para que el primer dictado sea tan rápido como los siguientes.
    /// Estado del modelo de voz (la primera vez se descarga de Apple).
    enum VoiceModel: Equatable { case preparing, ready, failed(String) }
    private(set) var voiceModel: VoiceModel = .preparing

    func warmUp() async {
        voiceModel = .preparing
        guard await SpeechSession.isLocaleSupported(settings.localeID) else {
            voiceModel = .failed("Este Mac no admite el reconocimiento de voz en español (requiere macOS 26).")
            return
        }
        do { try await SpeechSession.ensureAssets(localeID: settings.localeID) } catch {
            NSLog("Dicta: no se pudo instalar el modelo de voz: \(error)")
            voiceModel = .failed("No se pudo descargar el modelo de voz: \(error.localizedDescription). ¿Hay conexión?")
            return
        }
        voiceModel = .ready
        cachedFormat = await SpeechSession.preferredFormat(localeID: settings.localeID)
        // Carga el modelo en memoria con una sesión vacía.
        let s = SpeechSession()
        if (try? await s.prepare(localeID: settings.localeID, vocabulary: [])) != nil { _ = await s.finish() }
    }

    // MARK: - Atajo

    private func handle(_ e: HotkeyMonitor.Event) {
        switch e.action {
        case .startRecording:
            startRecording(handsFree: false, edit: e.shiftHeld)
        case .lockHandsFree:
            handsFree = true
            overlay.show(.listening(handsFree: true, edit: editMode))
            playSound("Morse")
        case .stopAndProcess:
            stopAndProcess()
        case .cancel:
            cancel(silent: true)
        }
    }

    // MARK: - Grabación

    func startFromMenu() {
        guard state == .idle else { stopAndProcess(); return }
        hotkeys.forceHandsFree()
        startRecording(handsFree: true, edit: false)
    }

    private func startRecording(handsFree: Bool, edit: Bool, presetSnapshot: FocusSnapshot? = nil) {
        guard state == .idle else { return }
        switch voiceModel {
        case .preparing:
            overlay.show(.message("Descargando el modelo de voz en español… (solo la primera vez)", icon: "arrow.down.circle"), autoHide: 3)
            hotkeys.reset()
            return
        case .failed(let why):
            overlay.show(.message(why, icon: "exclamationmark.triangle"), autoHide: 4)
            hotkeys.reset()
            Task { await warmUp() } // reintento
            return
        case .ready:
            break
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            overlay.show(.message("Falta el permiso de micrófono (menú › Permisos)", icon: "mic.slash"), autoHide: 3)
            hotkeys.reset()
            return
        }
        learnTasks.forEach { $0.cancel() }; learnTasks.removeAll()
        state = .recording
        self.handsFree = handsFree
        startedAt = Date()

        // 1) Micro en marcha inmediatamente.
        let session = SpeechSession()
        self.session = session
        session.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.overlay.model.partial = text }
        }
        if let fmt = cachedFormat {
            do { try recorder.start(targetFormat: fmt, continuation: session.inputContinuation) } catch {
                fail("No se pudo abrir el micrófono: \(error.localizedDescription)"); return
            }
        }

        // 2) Contexto de la casilla enfocada.
        snapshot = presetSnapshot ?? AX.snapshot()
        editMode = edit && !snapshot.selectedText.isEmpty
        if edit, snapshot.selectedText.isEmpty, !snapshot.isTerminal, AX.isTrusted {
            // Accesibilidad no expone la selección: la leemos con ⌘C.
            editMode = true
            Task {
                let copied = await TextInserter.copySelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard self.state == .recording else { return }
                if copied.isEmpty {
                    self.editMode = false
                    self.overlay.show(.listening(handsFree: self.handsFree, edit: false))
                } else {
                    self.snapshot.selectedText = copied
                }
            }
        }

        // Pre-arranca el corrector (Claude Code tarda en arrancar) mientras hablas.
        CleanerFactory.prewarm()

        if settings.playSounds { playSound("Tink") }
        if settings.muteSystemAudio { SystemAudio.mute() }
        overlay.setAvoid(AX.avoidRect(for: snapshot))
        overlay.show(.listening(handsFree: handsFree, edit: editMode))

        // 3) Analizador (el audio ya se está acumulando).
        let vocab = dictionary.list
        let localeID = settings.localeID
        Task {
            do {
                let fmt = try await session.prepare(localeID: localeID, vocabulary: vocab)
                if self.cachedFormat == nil, self.session === session, self.state == .recording {
                    self.cachedFormat = fmt
                    try self.recorder.start(targetFormat: fmt, continuation: session.inputContinuation)
                }
            } catch {
                if self.session === session { self.fail("Error de reconocimiento de voz: \(error.localizedDescription)") }
            }
        }
    }

    func stopAndProcess() {
        guard state == .recording, let session else { return }
        let duration = Date().timeIntervalSince(startedAt)
        recorder.stop()
        if settings.muteSystemAudio { SystemAudio.restore() }
        if duration < 0.35 && !handsFree { cancel(silent: true); return }
        state = .processing
        overlay.show(.processing)
        if settings.playSounds { playSound("Pop") }

        let snap = snapshot
        let edit = editMode
        Task {
            let raw = await session.finish()
            self.session = nil
            await self.process(raw: raw, snapshot: snap, edit: edit, duration: duration)
        }
    }

    func cancel(silent: Bool = false) {
        guard state == .recording else { return }
        recorder.stop()
        if settings.muteSystemAudio { SystemAudio.restore() }
        let s = session
        session = nil
        Task { await s?.cancel() }
        state = .idle
        hotkeys.reset()
        if silent { overlay.hide() } else { overlay.show(.message("Dictado cancelado", icon: "xmark.circle"), autoHide: 1.2) }
    }

    private func fail(_ message: String) {
        recorder.stop()
        if settings.muteSystemAudio { SystemAudio.restore() }
        session = nil
        state = .idle
        hotkeys.reset()
        overlay.show(.message(message, icon: "exclamationmark.triangle"), autoHide: 4)
    }

    // MARK: - Procesado

    private func process(raw: String, snapshot snap: FocusSnapshot, edit: Bool, duration: TimeInterval) async {
        defer { state = .idle }
        let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrim.isEmpty else {
            overlay.show(.message("No te he oído. Revisa el micrófono.", icon: "ear.trianglebadge.exclamationmark"), autoHide: 2)
            return
        }

        let continuation = !edit && ContinuityDetector.isContinuation(
            last: lastRecord, bundleID: snap.bundleID, elementID: snap.elementID,
            beforeCursor: snap.beforeCursor, now: .now)

        // Diccionario aplicado antes (para que la IA ya vea la palabra buena)…
        let entries = dictionary.entries
        let rawFixed = DictionaryCorrector.apply(rawTrim, entries: entries)

        // Modo edición: ¿instrucción («cámbialo a jueves») o texto nuevo que sustituye la selección?
        // Si es texto nuevo se corrige como un dictado normal y se pega encima de la selección.
        let isInstruction = edit && EditIntent.classify(rawFixed) == .instruction

        let useCtx = settings.useContext
        let request = CleanupRequest(
            raw: rawFixed,
            mode: isInstruction ? .edit(selected: snap.selectedText) : .dictation,
            appName: snap.appName, bundleID: snap.bundleID, isTerminal: snap.isTerminal,
            beforeCursor: useCtx ? snap.beforeCursor : "", afterCursor: useCtx ? snap.afterCursor : "",
            isContinuation: continuation, dictionary: dictionary.promptLines)

        let cleaner = CleanerFactory.make()
        overlay.model.engineName = cleaner.displayName
        let result = await CleanerFactory.cleanWithFallback(cleaner, request, timeout: cleaner.timeout)
        if let err = result.error {
            NSLog("Dicta: corrector \(cleaner.name) falló: \(err)")
            overlay.model.lastError = err.localizedDescription
        }
        // …y después, como garantía: la IA a veces "corrige" a la palabra común.
        var text = DictionaryCorrector.apply(result.text, entries: entries)
        guard !text.isEmpty else { overlay.hide(); return }
        if isInstruction, text.trimmingCharacters(in: .whitespacesAndNewlines)
            == snap.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) {
            // El modelo no aplicó la instrucción: no tocamos nada.
            overlay.show(.message("No he sabido aplicar «\(rawTrim.prefix(40))». Prueba a decirlo de otra forma.",
                                  icon: "questionmark.circle"), autoHide: 3.5)
            return
        }
        if !isInstruction { text = TextTools.fitInsertion(text, before: snap.beforeCursor, keepCapitalized: dictionary.set) }

        await hotkeys.waitForRelease()

        // La casilla puede haber cambiado mientras procesábamos: usamos el foco actual.
        let target = AX.snapshot()
        var outcome: HistoryEntry.Outcome = .clipboard
        defer { if outcome == .pasted { overlay.setAvoid(AX.avoidRect(for: AX.snapshot())) } }
        // Las terminales a veces no exponen la casilla por Accesibilidad, pero ⌘V funciona.
        let canPaste = AX.isTrusted && (target.hasTarget || target.isTerminal)
        if canPaste {
            let ok = await TextInserter.paste(text, into: target, keepInClipboard: settings.keepInClipboard)
            if ok {
                outcome = .pasted
                if let err = result.error {
                    overlay.show(.message("Pegado sin IA: \(err.localizedDescription)", icon: "exclamationmark.triangle"),
                                 autoHide: 5)
                } else {
                    overlay.show(.done(text.trimmingCharacters(in: .whitespacesAndNewlines)), autoHide: 4)
                }
            }
        }
        if outcome != .pasted {
            TextInserter.copyToClipboard(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let why = AX.isTrusted ? "No hay casilla de texto activa" : "Falta el permiso de Accesibilidad"
            overlay.show(.message("\(why): copiado al portapapeles (⌘V)", icon: "doc.on.clipboard"), autoHide: 3.5)
        }

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        history.add(HistoryEntry(date: .now, appName: snap.appName, bundleID: snap.bundleID, raw: rawTrim,
                                 text: finalText, outcome: outcome, durationSeconds: duration,
                                 provider: result.provider))

        guard outcome == .pasted else { return }
        lastRecord = InsertionRecord(text: finalText, bundleID: target.bundleID,
                                     elementID: target.elementID, date: .now)
        if let el = target.element, let sel = target.selection, sel.location != kCFNotFound {
            let leading = text.utf16.count - text.drop(while: { $0.isWhitespace }).utf16.count
            lastInsert = (el, sel.location + leading, finalText.utf16.count, finalText)
        } else {
            lastInsert = nil
        }
        if settings.autoLearn, !target.isTerminal, !edit { scheduleLearning(target: target, inserted: text) }
    }

    // MARK: - Re-dictar

    /// Selecciona lo último que se pegó y abre un dictado en modo edición sobre ello:
    /// puedes volver a decirlo o dar una instrucción («cambia viernes por jueves»).
    func redictateLast() {
        guard state == .idle else { return }
        overlay.hide()
        if let li = lastInsert {
            let wanted = CFRange(location: li.location, length: li.length)
            AX.setSelection(li.element, wanted)
            // Algunas apps (Electron, navegadores) aceptan la llamada pero no seleccionan:
            // comprobamos y, si no, seleccionamos hacia atrás con Mayús+←.
            if let r = AX.range(li.element), r.location == wanted.location, r.length == wanted.length {
            } else {
                TextInserter.selectBackwards(characters: li.text.count)
            }
            var snap = AX.snapshot()
            if snap.selectedText.isEmpty { snap.selectedText = li.text }
            hotkeys.forceHandsFree()
            startRecording(handsFree: true, edit: true, presetSnapshot: snap)
        } else {
            // No se puede seleccionar (p. ej. terminal): deshacer y dictar de nuevo.
            TextInserter.undoShortcut()
            hotkeys.forceHandsFree()
            startRecording(handsFree: true, edit: false)
        }
    }

    func pasteLast() {
        guard let t = history.last?.text else { return }
        Task {
            let target = AX.snapshot()
            if target.hasTarget { _ = await TextInserter.paste(t, into: target, keepInClipboard: false) }
            else { TextInserter.copyToClipboard(t) }
        }
    }

    // MARK: - Aprendizaje automático (como `dictionary_item_auto_added` de Wispr)

    private func scheduleLearning(target: FocusSnapshot, inserted: String) {
        guard let el = target.element else { return }
        let before = target.beforeCursor
        let after = target.afterCursor
        let dictated = inserted
        let task = Task { [weak self] in
            for delay in [8.0, 20.0, 45.0, 90.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard let current = AX.string(el, kAXValueAttribute),
                      let region = WordLearner.editedRegion(before: before, after: after, current: current) else { continue }
                let edited = region.trimmingCharacters(in: .whitespacesAndNewlines)
                guard edited != dictated.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let fixes = WordLearner.learnedCorrections(dictated: dictated, edited: edited, known: self.dictionary.set)
                guard !fixes.isEmpty else { continue }
                for f in fixes { self.dictionary.add(f.word, source: .learned, alias: f.heard) }
                let words = fixes.map(\.word)
                if self.state == .idle {
                    self.overlay.show(.message("Aprendido: \(words.joined(separator: ", "))", icon: "book.closed"), autoHide: 2.5)
                }
                return
            }
        }
        learnTasks.append(task)
    }

    private func playSound(_ name: String) {
        guard settings.playSounds, let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = 0.25
        s.play()
    }
}
