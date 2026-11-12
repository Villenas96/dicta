import Foundation

// MARK: - Normalización y distancias

public enum TextTools {
    /// Minúsculas y sin tildes, para comparar "suena parecido".
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
    }

    /// Distancia de Levenshtein sobre caracteres.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 1.0 = idénticas, 0.0 = nada que ver (sobre texto plegado).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let fa = fold(a), fb = fold(b)
        let m = max(fa.count, fb.count)
        if m == 0 { return 1 }
        return 1 - Double(levenshtein(fa, fb)) / Double(m)
    }

    /// Palabras (letras, números y signos internos como «-», «.», «'» de «Node.js», «e-mail»).
    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber {
                cur.append(c)
            } else if (c == "-" || c == "." || c == "'" || c == "_"), !cur.isEmpty,
                      i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1].isNumber {
                cur.append(c)
            } else if !cur.isEmpty {
                out.append(cur); cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Espaciado al insertar

    private static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%", "»"]
    private static let openers: Set<Character> = ["(", "[", "{", "¿", "¡", "\"", "'", "«", "/", "@", "#"]

    /// Ajusta el texto a insertar según lo que hay justo antes del cursor:
    /// añade un espacio si hace falta y, si la frase anterior no ha terminado,
    /// no empieza en mayúscula (salvo siglas / nombres del diccionario).
    public static func fitInsertion(_ text: String, before: String, keepCapitalized: Set<String> = []) -> String {
        guard var result = Optional(text), let first = result.first else { return text }
        guard let last = before.last else { return result }

        if !last.isWhitespace, !openers.contains(last), !noSpaceBefore.contains(first), !first.isWhitespace {
            result = " " + result
        }

        // ¿La frase anterior está a medias? (termina en letra, número o coma)
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if let end = trimmed.last, end.isLetter || end.isNumber || end == "," || end == ";" {
            let ws = words(text)
            if let w = ws.first, w.first!.isUppercase,
               !w.dropFirst().contains(where: { $0.isUppercase }), // no es sigla
               !keepCapitalized.contains(w) {
                if let idx = result.firstIndex(where: { $0.isLetter }) {
                    result.replaceSubrange(idx...idx, with: String(result[idx]).lowercased())
                }
            }
        }
        return result
    }
}

// MARK: - Aprendizaje de palabras (como el auto-learn de Wispr Flow)

public enum WordLearner {
    /// Palabras muy comunes que nunca se aprenden.
    static let stopWords: Set<String> = [
        "de", "la", "que", "el", "en", "y", "a", "los", "se", "del", "las", "un", "por", "con", "no",
        "una", "su", "para", "es", "al", "lo", "como", "más", "mas", "pero", "sus", "le", "ya", "o",
        "este", "esta", "si", "sí", "porque", "muy", "sin", "sobre", "también", "me", "hasta", "hay",
        "donde", "quien", "desde", "todo", "nos", "durante", "todos", "uno", "les", "ni", "contra",
        "otros", "ese", "eso", "ante", "ellos", "e", "esto", "mí", "antes", "algunos", "qué", "unos",
        "yo", "otro", "otras", "otra", "él", "tanto", "esa", "estos", "mucho", "quienes", "nada",
        "muchos", "cual", "poco", "ella", "estar", "estas", "algunas", "algo", "nosotros", "mi",
        "mis", "tú", "te", "ti", "tu", "tus", "ellas", "bien", "vale", "pues", "the", "and",
    ]

    /// Extrae el fragmento que el usuario ha editado: el texto actual del campo
    /// menos lo que había antes y después de la inserción.
    public static func editedRegion(before: String, after: String, current: String) -> String? {
        let cur = Array(current)
        let b = Array(before), a = Array(after)
        var p = 0
        while p < b.count, p < cur.count, b[p] == cur[p] { p += 1 }
        // El texto anterior al cursor debe seguir casi intacto.
        guard p >= b.count - 2 else { return nil }
        var s = 0
        while s < a.count, s < cur.count - p, a[a.count - 1 - s] == cur[cur.count - 1 - s] { s += 1 }
        guard s >= a.count - 2 else { return nil }
        let start = min(p, cur.count), end = max(start, cur.count - s)
        return String(cur[start..<end])
    }

    /// Compara lo dictado con lo que quedó tras la corrección del usuario y devuelve
    /// las palabras corregidas que merece la pena recordar.
    public static func learnedWords(dictated: String, edited: String, known: Set<String> = []) -> [String] {
        learnedCorrections(dictated: dictated, edited: edited, known: known).map(\.word)
    }

    /// Corrección aprendida: la palabra buena y cómo se había oído/escrito.
    public struct Correction: Equatable, Sendable {
        public let word: String
        public let heard: String
    }

    public static func learnedCorrections(dictated: String, edited: String, known: Set<String> = []) -> [Correction] {
        let d = TextTools.words(dictated), e = TextTools.words(edited)
        guard !d.isEmpty, !e.isEmpty else { return [] }
        // Si el usuario reescribió casi todo, no es una corrección de palabra.
        guard Double(e.count) <= Double(d.count) * 1.6 + 2, Double(e.count) >= Double(d.count) * 0.5 - 1 else { return [] }

        // Alineación por LCS (sensible a mayúsculas para captar «github» → «GitHub»).
        let n = d.count, m = e.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = d[i] == e[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var i = 0, j = 0
        var gapsD: [String] = [], gapsE: [String] = []
        var learned: [Correction] = []
        func flush() {
            defer { gapsD.removeAll(); gapsE.removeAll() }
            guard !gapsE.isEmpty, !gapsD.isEmpty, gapsD.count <= 3, gapsE.count <= 3 else { return }
            let oldJoined = gapsD.joined(separator: " ")
            for w in gapsE {
                let f = TextTools.fold(w)
                guard w.count >= 3, !stopWords.contains(f), !known.contains(w) else { continue }
                // Debe "sonar" parecido a lo que se dictó (corrección, no reescritura).
                let sim = max(TextTools.similarity(oldJoined, w),
                              gapsD.map { TextTools.similarity($0, w) }.max() ?? 0)
                let caseOnly = gapsD.contains { TextTools.fold($0) == f }
                if caseOnly || sim >= 0.45 {
                    // Lo que se oyó: la palabra dictada más parecida (o todo el hueco).
                    let heard = gapsD.max { TextTools.similarity($0, w) < TextTools.similarity($1, w) } ?? oldJoined
                    learned.append(Correction(word: w, heard: heard))
                }
            }
        }
        while i < n || j < m {
            if i < n, j < m, d[i] == e[j] {
                flush(); i += 1; j += 1
            } else if j < m, (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                gapsE.append(e[j]); j += 1
            } else {
                gapsD.append(d[i]); i += 1
            }
        }
        flush()
        var seen = Set<String>()
        return learned.filter { seen.insert($0.word).inserted }
    }
}

// MARK: - Continuidad entre dictados

public struct InsertionRecord: Codable, Equatable, Sendable {
    public var text: String
    public var bundleID: String
    public var elementID: String
    public var date: Date
    public init(text: String, bundleID: String, elementID: String, date: Date) {
        self.text = text; self.bundleID = bundleID; self.elementID = elementID; self.date = date
    }
}

public enum ContinuityDetector {
    /// ¿El nuevo dictado continúa el anterior en la misma casilla?
    /// Si es así, el corrector debe seguir el texto tal cual, sin redactarlo de nuevo.
    public static func isContinuation(last: InsertionRecord?, bundleID: String, elementID: String,
                                      beforeCursor: String, now: Date, maxGap: TimeInterval = 15 * 60) -> Bool {
        guard let last, last.bundleID == bundleID, now.timeIntervalSince(last.date) <= maxGap else { return false }
        let tail = beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastText.isEmpty else { return false }
        if tail.hasSuffix(lastText) { return true }
        // El usuario pudo retocar el final; basta con que el final se parezca.
        let probe = String(lastText.suffix(40))
        if tail.suffix(400).contains(probe) { return true }
        // Sin texto legible (p. ej. terminal sin AX): misma casilla y poco tiempo.
        return beforeCursor.isEmpty && last.elementID == elementID && now.timeIntervalSince(last.date) <= 120
    }
}
