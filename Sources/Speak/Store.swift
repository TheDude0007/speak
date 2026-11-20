import Foundation
import SpeakCore

/// Settings in UserDefaults; history + dictionary as small JSON files in
/// ~/Library/Application Support/Speak. Audio is never written to disk.
final class Store {
    static let shared = Store()

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speak", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    var dictionaryURL: URL { dir.appendingPathComponent("dictionary.json") }
    var historyURL: URL { dir.appendingPathComponent("history.json") }

    // MARK: settings
    private let d = UserDefaults.standard
    var hotkey: HotkeyKey {
        get { HotkeyKey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    func bool(_ key: String, default def: Bool) -> Bool { d.object(forKey: key) == nil ? def : d.bool(forKey: key) }
    var removeFillers: Bool { get { bool("removeFillers", default: true) } set { d.set(newValue, forKey: "removeFillers") } }
    var smartSpacing: Bool { get { bool("smartSpacing", default: true) } set { d.set(newValue, forKey: "smartSpacing") } }
    var sounds: Bool { get { bool("sounds", default: true) } set { d.set(newValue, forKey: "sounds") } }
    var liveText: Bool { get { bool("liveText", default: true) } set { d.set(newValue, forKey: "liveText") } }
    var keepHistory: Bool { get { bool("keepHistory", default: true) } set { d.set(newValue, forKey: "keepHistory") } }
    var smartGrammar: Bool { get { bool("smartGrammar", default: true) } set { d.set(newValue, forKey: "smartGrammar") } }
    var aiPolish: Bool { get { bool("aiPolish", default: false) } set { d.set(newValue, forKey: "aiPolish") } }
    var instantStart: Bool { get { bool("instantStart", default: false) } set { d.set(newValue, forKey: "instantStart") } }

    // MARK: dictionary
    struct Dictionary: Codable {
        var vocabulary: [String]
        var replacements: [String: String]
    }
    private var dictCache: (Date, Dictionary)?

    func dictionary() -> Dictionary {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dictionaryURL.path) {
            let template = Dictionary(
                vocabulary: ["Speak"],
                replacements: ["smiley face": "🙂"])
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(template).write(to: dictionaryURL)
        }
        let mtime = (try? fm.attributesOfItem(atPath: dictionaryURL.path)[.modificationDate] as? Date) ?? .distantPast
        if let (t, cached) = dictCache, t == mtime { return cached }
        let parsed = (try? Data(contentsOf: dictionaryURL)).flatMap { try? JSONDecoder().decode(Dictionary.self, from: $0) }
            ?? Dictionary(vocabulary: [], replacements: [:])
        dictCache = (mtime, parsed)
        return parsed
    }

    func cleanerOptions() -> TextCleaner.Options {
        var o = TextCleaner.Options()
        o.removeFillers = removeFillers
        o.replacements = dictionary().replacements
        return o
    }

    // MARK: history
    struct Entry: Codable {
        let date: Date
        let text: String
        let raw: String
        let latencyMs: Int
        let app: String?
    }
    private(set) lazy var history: [Entry] = {
        (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }()

    func add(_ e: Entry) {
        guard keepHistory else { return }
        history.insert(e, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        let snapshot = history
        let url = historyURL
        DispatchQueue.global(qos: .utility).async {
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    func clearHistory() {
        history.removeAll()
        try? FileManager.default.removeItem(at: historyURL)
    }
}
