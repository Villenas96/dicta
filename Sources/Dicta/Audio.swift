import AVFoundation
import CoreAudio
import Speech

/// Captura el micrófono con AVAudioEngine y entrega el audio, ya convertido al formato
/// que pide el modelo, a medida que llega (como el AudioWorklet de Wispr, pero nativo).
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Nivel RMS normalizado 0…1 para dibujar la onda.
    var onLevel: (@Sendable (Float) -> Void)?
    private(set) var isRunning = false

    func start(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        stop()
        lock.lock(); self.continuation = continuation; lock.unlock()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Dicta", code: 1, userInfo: [NSLocalizedDescriptionKey: "No hay micrófono disponible"])
        }
        converter = inFormat == targetFormat ? nil : AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, target: targetFormat)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func process(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Nivel para la onda
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            onLevel?(max(0, min(1, (db + 55) / 45)))
        }

        let out: AVAudioPCMBuffer
        if let converter {
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error != nil || converted.frameLength == 0 { return }
            out = converted
        } else {
            out = buffer
        }
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(AnalyzerInput(buffer: out))
    }

    func stop() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        lock.lock(); continuation?.finish(); continuation = nil; lock.unlock()
    }
}

/// Transcripción local en streaming con SpeechAnalyzer + SpeechTranscriber (macOS 26+).
/// El modelo se queda cargado en memoria (`modelRetention: .processLifetime`) y transcribe
/// mientras hablas: al soltar la tecla solo falta el último trozo. Es la misma idea que hace
/// rápidos a Wispr/Typeless, pero sin red.
final class SpeechSession: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Error>?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    /// El flujo existe desde el primer instante: el micro puede empezar a volcar audio
    /// antes de que el analizador esté listo (queda en buffer, no se pierde nada).
    let inputStream: AsyncStream<AnalyzerInput>
    let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private(set) var audioFormat: AVAudioFormat?
    var onPartial: (@Sendable (String) -> Void)?

    init() {
        (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Formato que espera el modelo; se calcula una vez al arrancar la app.
    static func preferredFormat(localeID: String) async -> AVAudioFormat? {
        let locale = await resolvedLocale(localeID)
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
    }

    static func resolvedLocale(_ id: String) async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) ?? Locale(identifier: id)
    }

    /// Descarga el modelo de español si falta (una sola vez).
    static func ensureAssets(localeID: String) async throws {
        let locale = await resolvedLocale(localeID)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    static func isLocaleSupported(_ id: String) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) != nil
    }

    /// Prepara el analizador. Se llama al pulsar la tecla; el audio que llegue mientras
    /// tanto se queda en el buffer del AsyncStream, así que no se pierde nada.
    func prepare(localeID: String, vocabulary: [String]) async throws -> AVAudioFormat {
        let locale = await Self.resolvedLocale(localeID)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Dicta", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato de audio no disponible"])
        }
        audioFormat = format

        if !vocabulary.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = Array(vocabulary.prefix(100))
            try? await analyzer.setContext(ctx)
        }

        let stream = inputStream

        resultsTask = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                let text = String(result.text.characters)
                let partial = self.lock.withLock {
                    if result.isFinal {
                        self.finalized = Self.join(self.finalized, text)
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    return Self.join(self.finalized, self.volatile)
                }
                self.onPartial?(partial)
            }
        }
        try await analyzer.start(inputSequence: stream)
        return format
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Cierra la entrada, espera los últimos resultados y devuelve el texto completo.
    func finish() async -> String {
        inputContinuation.finish()
        if let analyzer {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
        }
        _ = try? await resultsTask?.value
        return lock.withLock { Self.join(finalized, volatile) }
    }

    func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }
}

/// Silencia la salida de audio mientras dictas (Typeless lo hace en `libUtilHelper`).
enum SystemAudio {
    private static var previousMute: UInt32?

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    private static var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                             mScope: kAudioDevicePropertyScopeOutput,
                                                             mElement: kAudioObjectPropertyElementMain)

    static func mute() {
        guard let dev = defaultOutput() else { return }
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &size, &current) == noErr else { return }
        previousMute = current
        var one: UInt32 = 1
        AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, size, &one)
    }

    static func restore() {
        guard let prev = previousMute, let dev = defaultOutput() else { return }
        var v = prev
        AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        previousMute = nil
    }
}
