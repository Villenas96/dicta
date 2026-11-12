import Foundation

/// Una entrada del diccionario personal: cómo se escribe y cómo la oye el reconocedor.
public struct DictionaryEntry: Sendable, Equatable {
    public var word: String
    /// Formas en que se ha oído (p. ej. «whisper» para «Wispr»). Se aprenden solas.
    public var aliases: [String]
    public init(word: String, aliases: [String] = []) { self.word = word; self.aliases = aliases }
}

/// Aplica el diccionario de forma determinista, sin depender de la IA:
/// 1. alias exactos («whisper» → «Wispr»),
/// 2. mayúsculas («github» → «GitHub»),
/// 3. parecido fonético («Whisper» ≈ «Wispr»: mismo esqueleto de consonantes).
public enum DictionaryCorrector {
    /// Esqueleto fonético aproximado (español + inglés): sin tildes, sin vocales,
    /// sin «h», con equivalencias b/v, c/k/q, s/z, ph/f… «Whisper» y «Wispr» → «wspr».
    public static func skeleton(_ s: String) -> String {
        var t = TextTools.fold(s).lowercased()
        let rules: [(String, String)] = [("ph", "f"), ("qu", "k"), ("ck", "k"), ("ce", "se"), ("ci", "si"),
                                         ("ll", "y"), ("sh", "x"), ("ch", "x")]
        for (a, b) in rules { t = t.replacingOccurrences(of: a, with: b) }
        var out = ""
        for c in t {
            var ch = c
            switch c {
            case "h": continue
            case "v": ch = "b"
            case "c", "q": ch = "k"
            case "z": ch = "s"
            case "a", "e", "i", "o", "u", "y": continue
            default: break
            }
            guard ch.isLetter || ch.isNumber else { continue }
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    private struct Token { let range: Range<String.Index>; let text: String }

    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isLetter || c.isNumber {
                if start == nil { start = i }
            } else if let st = start {
                out.append(Token(range: st..<i, text: String(s[st..<i]))); start = nil
            }
            i = s.index(after: i)
        }
        if let st = start { out.append(Token(range: st..<s.endIndex, text: String(s[st...]))) }
        return out
    }

    /// ¿La ventana de texto `heard` corresponde a `entry`?
    static func matches(_ heard: String, _ entry: DictionaryEntry) -> Bool {
        let fh = TextTools.fold(heard)
        if heard == entry.word { return false } // ya está bien escrita
        if fh == TextTools.fold(entry.word) { return true } // solo cambian mayúsculas/tildes
        if entry.aliases.contains(where: { TextTools.fold($0) == fh }) { return true }
        // Parecido fonético: solo para palabras con cuerpo y que no sean comunes.
        let compact = fh.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 4, !WordLearner.stopWords.contains(fh) else { return false }
        let sk = skeleton(heard), skw = skeleton(entry.word)
        guard sk.count >= 3, skw.count >= 3 else { return false }
        let lenDiff = abs(compact.count - TextTools.fold(entry.word).replacingOccurrences(of: " ", with: "").count)
        guard lenDiff <= 3 else { return false }
        let sim = TextTools.similarity(heard, entry.word)
        return (sk == skw && sim >= 0.45) || (TextTools.similarity(sk, skw) >= 0.8 && sim >= 0.7)
    }

    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var result = text
        // Las entradas de varias palabras primero («Wispr Flow» antes que «Wispr»).
        let sorted = entries.sorted { $0.word.split(separator: " ").count > $1.word.split(separator: " ").count }
        for entry in sorted {
            let n = max(1, entry.word.split(separator: " ").count)
            var toks = tokens(result)
            var idx = 0
            while idx + n <= toks.count {
                let window = toks[idx..<(idx + n)]
                let lo = window.first!.range.lowerBound, hi = window.last!.range.upperBound
                let heard = String(result[lo..<hi])
                if matches(heard, entry) {
                    result.replaceSubrange(lo..<hi, with: entry.word)
                    toks = tokens(result)
                    idx += n
                } else {
                    idx += 1
                }
            }
        }
        return result
    }
}
