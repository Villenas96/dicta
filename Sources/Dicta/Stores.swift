import Combine
import DictaCore
import Foundation

enum AppPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dicta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Persistencia JSON sencilla y atómica.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let url = AppPaths.supportDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        let url = AppPaths.supportDir.appendingPathComponent(name)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Historial

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Outcome: String, Codable { case pasted, clipboard, failed, edited }
    var id = UUID()
    var date: Date
    var appName: String
    var bundleID: String
    var raw: String
    var text: String
    var outcome: Outcome
    var durationSeconds: Double
    var provider: String
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    private let file = "history.json"

    private init() { entries = JSONFile.load([HistoryEntry].self, name: file) ?? [] }

    func add(_ e: HistoryEntry) {
        entries.insert(e, at: 0)
        if entries.count > 5000 { entries.removeLast(entries.count - 5000) }
        persist()
    }

    func delete(_ ids: Set<UUID>) { entries.removeAll { ids.contains($0.id) }; persist() }
    func clear() { entries.removeAll(); persist() }
    var last: HistoryEntry? { entries.first }
    private func persist() { JSONFile.save(entries, name: file) }
}

// MARK: - Diccionario personal

struct DictionaryWord: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case manual, learned }
    var id = UUID()
    var word: String
    var source: Source
    var added: Date
    /// Cómo lo oye el reconocedor (p. ej. «whisper» para «Wispr»). Opcional para leer
    /// diccionarios antiguos.
    var aliases: [String]? = nil
}

@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()
    @Published private(set) var words: [DictionaryWord] = []
    private let file = "dictionary.json"

    private init() { words = JSONFile.load([DictionaryWord].self, name: file) ?? [] }

    var list: [String] { words.map(\.word) }
    var set: Set<String> { Set(words.map(\.word)) }
    var entries: [DictionaryEntry] { words.map { DictionaryEntry(word: $0.word, aliases: $0.aliases ?? []) } }

    /// Líneas para el prompt: «Wispr (se oye como: whisper)».
    var promptLines: [String] {
        words.map { w in
            let a = (w.aliases ?? []).filter { !$0.isEmpty }
            return a.isEmpty ? w.word : "\(w.word) (se oye como: \(a.joined(separator: ", ")))"
        }
    }

    /// Añade una palabra (o, si ya existe, le suma el alias). Devuelve true si es nueva.
    @discardableResult
    func add(_ raw: String, source: DictionaryWord.Source = .manual, alias rawAlias: String? = nil) -> Bool {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        let alias = rawAlias?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let validAlias = (alias?.isEmpty == false && alias != w.lowercased()) ? alias : nil
        if let i = words.firstIndex(where: { $0.word == w }) {
            if let a = validAlias, !(words[i].aliases ?? []).contains(a) {
                words[i].aliases = (words[i].aliases ?? []) + [a]
                persist()
            }
            return false
        }
        words.insert(DictionaryWord(word: w, source: source, added: .now, aliases: validAlias.map { [$0] }), at: 0)
        persist()
        return true
    }

    func removeAlias(_ alias: String, from id: UUID) {
        guard let i = words.firstIndex(where: { $0.id == id }) else { return }
        words[i].aliases?.removeAll { $0 == alias }
        persist()
    }

    func remove(_ ids: Set<UUID>) { words.removeAll { ids.contains($0.id) }; persist() }
    func remove(word: String) { words.removeAll { $0.word == word }; persist() }
    private func persist() { JSONFile.save(words, name: file) }
}
