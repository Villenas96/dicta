import AVFoundation
import DictaCore
import Foundation
import Speech

/// `Dicta --selftest audio.aiff [--context "texto previo"]`
/// Transcribe un archivo con el mismo motor local que usa la app y lo pasa por el corrector.
/// Sirve para comprobar el modelo de español y la corrección sin usar el micrófono.
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first else { print("uso: Dicta --selftest <audio> [--context <texto>]"); return 2 }
        var context = ""
        if let i = args.firstIndex(of: "--context"), i + 1 < args.count { context = args[i + 1] }
        let localeID = await MainActor.run { AppSettings.shared.localeID }

        do {
            let t0 = Date()
            try await SpeechSession.ensureAssets(localeID: localeID)
            let locale = await SpeechSession.resolvedLocale(localeID)
            print("Modelo de voz: \(locale.identifier) listo en \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")

            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let t1 = Date()
            let collect = Task { () -> String in
                var out: [String] = []
                for try await r in transcriber.results where r.isFinal { out.append(String(r.text.characters)) }
                return out.joined(separator: " ")
            }
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
            _ = analyzer
            let raw = try await collect.value.trimmingCharacters(in: .whitespaces)
            let audioSecs = Double(file.length) / file.processingFormat.sampleRate
            print("Audio: \(String(format: "%.1f", audioSecs)) s · transcrito en \(String(format: "%.2f", Date().timeIntervalSince(t1))) s")
            print("TRANSCRIPCIÓN: \(raw)")

            let (dict, entries) = await MainActor.run { (DictionaryStore.shared.promptLines, DictionaryStore.shared.entries) }
            let fixedRaw = DictionaryCorrector.apply(raw, entries: entries)
            if fixedRaw != raw { print("DICCIONARIO: \(fixedRaw)") }
            let request = CleanupRequest(raw: fixedRaw, appName: "SelfTest", bundleID: "selftest",
                                         beforeCursor: context, isContinuation: !context.isEmpty, dictionary: dict)
            let cleaner = await MainActor.run { CleanerFactory.make() }
            let t2 = Date()
            let result = await CleanerFactory.cleanWithFallback(cleaner, request, timeout: 30)
            if let e = result.error { print("AVISO corrector \(cleaner.name): \(e.localizedDescription)") }
            let finalText = DictionaryCorrector.apply(result.text, entries: entries)
            print("CORREGIDO (\(result.provider), \(String(format: "%.2f", Date().timeIntervalSince(t2))) s): \(finalText)")
            if !context.isEmpty {
                print("INSERCIÓN: \(context)\(TextTools.fitInsertion(finalText, before: context))")
            }
            return 0
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }
}
