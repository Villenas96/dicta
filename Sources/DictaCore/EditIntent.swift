import Foundation

/// En modo edición, ¿lo dictado es una instrucción sobre la selección o un texto nuevo?
/// Decidirlo con reglas evita que el modelo devuelva la selección sin tocar cuando
/// el usuario solo quería volver a decirla (fallo observado con Apple Intelligence:
/// selección «Esto es un dictado.», dictado «Esto no es un dictado.» → sin cambios).
public enum EditIntent: Equatable, Sendable {
    case instruction
    case replacement

    static let imperatives: [String] = [
        "cambia", "cámbialo", "cámbiala", "cámbiame", "cambiar", "pon", "ponlo", "ponla", "ponle", "ponme",
        "haz", "hazlo", "hazla", "hazme", "quita", "quítale", "quítalo", "elimina", "elimínalo", "borra",
        "bórralo", "añade", "añádele", "agrega", "sustituye", "reemplaza", "reescribe", "reescríbelo",
        "redacta", "redáctalo", "corrige", "corrígelo", "traduce", "tradúcelo", "resume", "resúmelo",
        "acorta", "acórtalo", "alarga", "alárgalo", "amplía", "mejora", "mejóralo", "convierte",
        "conviértelo", "formatea", "ordena", "ordénalo", "usa", "utiliza", "escríbelo", "escribe",
        "sube", "baja", "simplifica", "simplifícalo", "parafrasea", "divide", "separa", "une", "junta",
        "capitaliza", "mayúsculas", "minúsculas", "tradúceme",
    ]
    static let leadIns = ["por favor", "oye", "vale", "venga", "ahora", "y", "mejor", "también"]
    static let startPhrases = ["más ", "menos ", "en vez de ", "en lugar de ", "que sea ", "que quede ",
                               "lo mismo pero", "igual pero", "en inglés", "en una lista", "como lista",
                               "en formato", "con viñetas", "sin "]

    public static func classify(_ dictated: String) -> EditIntent {
        var s = TextTools.fold(dictated).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Quita muletillas de arranque: «vale, por favor, cámbialo…»
        var changed = true
        while changed {
            changed = false
            for l in leadIns.map({ TextTools.fold($0) }) where s.hasPrefix(l + " ") || s.hasPrefix(l + ",") {
                s = String(s.dropFirst(l.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
                changed = true
            }
        }
        let first = s.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
        if imperatives.map({ TextTools.fold($0) }).contains(first) { return .instruction }
        if startPhrases.map({ TextTools.fold($0) }).contains(where: { s.hasPrefix($0) }) { return .instruction }
        return .replacement
    }
}
