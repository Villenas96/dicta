import Testing
@testable import DictaCore

@Suite struct HotkeyTests {
    @Test func holdToTalk() {
        var m = HotkeyStateMachine(holdThreshold: 0.3, doubleTapWindow: 0.4)
        #expect(m.keyDown(at: 0) == [.startRecording])
        #expect(m.keyUp(at: 1.2) == [.stopAndProcess])
        #expect(m.state == .idle)
    }

    @Test func doubleTapLocksAndTapStops() {
        var m = HotkeyStateMachine(holdThreshold: 0.3, doubleTapWindow: 0.4)
        #expect(m.keyDown(at: 0) == [.startRecording])
        #expect(m.keyUp(at: 0.1) == [])
        #expect(m.keyDown(at: 0.3) == [.lockHandsFree])
        #expect(m.keyUp(at: 0.35) == [])
        #expect(m.tick(at: 5) == [])          // sigue escuchando
        #expect(m.isRecording)
        #expect(m.keyDown(at: 9) == [.stopAndProcess])
        #expect(m.keyUp(at: 9.1) == [])
        #expect(m.state == .idle)
    }

    @Test func singleShortTapIsDiscarded() {
        var m = HotkeyStateMachine(holdThreshold: 0.3, doubleTapWindow: 0.4)
        _ = m.keyDown(at: 0)
        _ = m.keyUp(at: 0.1)
        #expect(m.tick(at: 0.3) == [])
        #expect(m.tick(at: 0.6) == [.cancel])
    }

    @Test func comboWithOtherKeyCancels() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        #expect(m.otherKeyPressed() == [.cancel])
        #expect(m.state == .idle)
    }
}

@Suite struct LearnerTests {
    @Test func learnsCorrectedProperNoun() {
        let w = WordLearner.learnedWords(dictated: "Mañana hablo con guisper sobre el proyecto.",
                                         edited: "Mañana hablo con Wispr sobre el proyecto.")
        #expect(w == ["Wispr"])
    }

    @Test func learnsCaseOnlyFix() {
        let w = WordLearner.learnedWords(dictated: "Sube el código a github hoy.",
                                         edited: "Sube el código a GitHub hoy.")
        #expect(w == ["GitHub"])
    }

    @Test func ignoresRewrites() {
        let w = WordLearner.learnedWords(dictated: "Te escribo luego.",
                                         edited: "Al final no hace falta que hablemos, ya lo he resuelto todo yo solo.")
        #expect(w.isEmpty)
    }

    @Test func ignoresStopWords() {
        let w = WordLearner.learnedWords(dictated: "Lo hago para el lunes.", edited: "Lo hago por el lunes.")
        #expect(w.isEmpty)
    }

    @Test func editedRegionExtraction() {
        let r = WordLearner.editedRegion(before: "Hola ", after: " adiós", current: "Hola Mundo bonito adiós")
        #expect(r == "Mundo bonito")
    }
}

@Suite struct TextToolsTests {
    @Test func addsSpaceAndLowercasesMidSentence() {
        #expect(TextTools.fitInsertion("Y luego vamos.", before: "Primero comemos,") == " y luego vamos.")
    }

    @Test func keepsCapitalAfterPeriod() {
        #expect(TextTools.fitInsertion("Luego vamos.", before: "Comemos. ") == "Luego vamos.")
    }

    @Test func keepsAcronyms() {
        #expect(TextTools.fitInsertion("API nueva", before: "la") == " API nueva")
    }

    @Test func noSpaceBeforePunctuation() {
        #expect(TextTools.fitInsertion(", vale.", before: "hola") == ", vale.")
    }
}

@Suite struct ContinuityTests {
    @Test func detectsContinuation() {
        let last = InsertionRecord(text: "Hoy he ido al médico", bundleID: "com.apple.Notes", elementID: "1", date: .now)
        #expect(ContinuityDetector.isContinuation(last: last, bundleID: "com.apple.Notes", elementID: "1",
                                                  beforeCursor: "Notas. Hoy he ido al médico", now: .now))
        #expect(!ContinuityDetector.isContinuation(last: last, bundleID: "com.apple.Mail", elementID: "1",
                                                   beforeCursor: "Hoy he ido al médico", now: .now))
    }
}

@Suite struct PromptTests {
    @Test func promptContainsContextAndDictionary() {
        let r = CleanupRequest(raw: "hola", beforeCursor: "Querido Juan,", isContinuation: true, dictionary: ["Wispr"])
        let m = CleanupPrompt.userMessage(for: r)
        #expect(m.contains("Querido Juan,"))
        #expect(m.contains("Wispr"))
        #expect(m.contains("<continuacion>sí"))
    }

    @Test func sanitizeStripsQuotes() {
        #expect(CleanupPrompt.sanitize("«Hola.»") == "Hola.")
    }

    @Test func localCleanerRemovesFillers() {
        #expect(LocalCleaner.clean("eh quiero em un café punto y aparte gracias") == "Quiero un café.\n\ngracias")
    }
}

@Suite struct DictionaryCorrectorTests {
    let entries = [DictionaryEntry(word: "Wispr"), DictionaryEntry(word: "Typeless")]

    @Test func fixesWhisperFromRealHistory() {
        let raw = "me lo sigue escribiendo como whisper y no como whisper del whisper Flow"
        #expect(DictionaryCorrector.apply(raw, entries: entries)
                == "me lo sigue escribiendo como Wispr y no como Wispr del Wispr Flow")
    }

    @Test func fixesCapitalizedAndPunctuated() {
        #expect(DictionaryCorrector.apply("Eres mejor que Whisper, tío.", entries: entries) == "Eres mejor que Wispr, tío.")
    }

    @Test func aliasAndMultiword() {
        let e = [DictionaryEntry(word: "Typeless", aliases: ["diveless", "timeless"]), DictionaryEntry(word: "GitHub")]
        #expect(DictionaryCorrector.apply("funciona como timeless y lo subo a github", entries: e)
                == "funciona como Typeless y lo subo a GitHub")
    }

    @Test func doesNotTouchUnrelatedWords() {
        let e = [DictionaryEntry(word: "Wispr"), DictionaryEntry(word: "Marta"), DictionaryEntry(word: "Kubernetes")]
        let s = "Mañana voy de marcha con mi primo, es una persona muy espabilada."
        #expect(DictionaryCorrector.apply(s, entries: e) == s)
    }

    @Test func skeleton() {
        #expect(DictionaryCorrector.skeleton("Whisper") == DictionaryCorrector.skeleton("Wispr"))
    }

    @Test func learnerRecordsHeardForm() {
        let c = WordLearner.learnedCorrections(dictated: "Hablo de whisper Flow.", edited: "Hablo de Wispr Flow.")
        #expect(c == [WordLearner.Correction(word: "Wispr", heard: "whisper")])
    }
}

@Suite struct EditIntentTests {
    @Test func replacementFromRealHistory() {
        #expect(EditIntent.classify("Esto no es un dictado.") == .replacement)
        #expect(EditIntent.classify("Quiero algo para el jueves") == .replacement)
        #expect(EditIntent.classify("Mañana hablamos con Marta") == .replacement)
    }

    @Test func instructions() {
        #expect(EditIntent.classify("Cámbialo a jueves") == .instruction)
        #expect(EditIntent.classify("vale, por favor, hazlo más formal") == .instruction)
        #expect(EditIntent.classify("Más corto") == .instruction)
        #expect(EditIntent.classify("Pon esto en una lista") == .instruction)
        #expect(EditIntent.classify("Cambia viernes por jueves.") == .instruction)
    }
}

import CoreGraphics

@Suite struct OverlayPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let panel = CGSize(width: 460, height: 120)

    @Test func defaultsToBottomCenter() {
        let r = OverlayPlacement.choose(screen: screen, panel: panel, avoid: nil)
        #expect(r.origin == CGPoint(x: 526, y: 24) && !r.anchorTop)
    }

    @Test func chatBoxAtBottomCenterMovesAside() {
        // Casilla de chat abajo en el centro (como la app de Claude).
        let box = CGRect(x: 400, y: 30, width: 700, height: 90)
        let r = OverlayPlacement.choose(screen: screen, panel: panel, avoid: box)
        #expect(!CGRect(origin: r.origin, size: panel).intersects(box))
    }

    @Test func narrowBoxBottomCenterGoesRight() {
        let box = CGRect(x: 500, y: 30, width: 500, height: 60)
        let r = OverlayPlacement.choose(screen: screen, panel: panel, avoid: box)
        #expect(r.origin.x > 1000 && !r.anchorTop) // abajo a la derecha
    }

    @Test func fullWidthBottomBoxGoesTop() {
        let box = CGRect(x: 0, y: 0, width: 1512, height: 160)
        let r = OverlayPlacement.choose(screen: screen, panel: panel, avoid: box)
        #expect(r.anchorTop)
    }
}
