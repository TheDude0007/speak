import Foundation

/// Deterministic, local post-processing. Runs in microseconds; no network, no model.
public struct TextCleaner: Sendable {
    public struct Options: Sendable, Equatable {
        public var removeFillers = true
        public var spokenCommands = true   // "new line", "new paragraph", "scratch that"
        public var replacements: [String: String] = [:] // case-insensitive phrase -> output
        public init() {}
    }

    public var options: Options
    public init(options: Options = .init()) { self.options = options }

    static let fillers = ["um", "umm", "uh", "uhh", "uh-huh-uh", "er", "erm", "ah", "hmm", "mm", "mhm"]

    public func clean(_ raw: String) -> String {
        var s = raw
        if options.spokenCommands { s = applyScratchThat(s) }
        if options.removeFillers { s = removeFillers(s) }
        if !options.replacements.isEmpty { s = applyReplacements(s) }
        if options.spokenCommands { s = applyLineCommands(s) }
        return tidy(s)
    }

    // MARK: - Steps

    func removeFillers(_ s: String) -> String {
        let alternation = Self.fillers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // filler word with optional trailing comma/period-less pause punctuation
        let pattern = "(?i)(^|[\\s,])(?:\(alternation))(?:[,.…]+)?(?=\\s|$|[,.!?;:])"
        return s.replacingRegex(pattern, with: "$1")
    }

    func applyReplacements(_ s: String) -> String {
        var out = s
        // Longest phrases first so "gemini sound pro" wins over "gemini sound".
        for (from, to) in options.replacements.sorted(by: { $0.key.count > $1.key.count }) {
            let trimmed = from.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let words = trimmed.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])"
            out = out.replacingRegex(pattern, with: NSRegularExpression.escapedTemplate(for: to))
        }
        return out
    }

    /// "scratch that" / "delete that" removes the preceding sentence (or clause when no sentence break).
    func applyScratchThat(_ s: String) -> String {
        let pattern = "(?i)[,.!?]?\\s*\\b(scratch that|delete that)\\b[,.!?]?"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        while let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range, in: out) {
            let before = String(out[..<r.lowerBound])
            let after = String(out[r.upperBound...])
            // Drop back to the previous sentence terminator (keep it).
            let kept: String
            if let idx = before.lastIndex(where: { ".!?\n".contains($0) }) {
                kept = String(before[...idx])
            } else {
                kept = ""
            }
            out = kept + after
        }
        return out
    }

    func applyLineCommands(_ s: String) -> String {
        var out = s
        out = out.replacingRegex("(?i)\\s*\\bnew paragraph\\b[,.!?]?\\s*", with: "\n\n")
        out = out.replacingRegex("(?i)\\s*\\bnew line\\b[,.!?]?\\s*", with: "\n")
        return out
    }

    func tidy(_ s: String) -> String {
        var out = s
        out = out.replacingRegex("[ \\t]+", with: " ")
        out = out.replacingRegex(" +([,.!?;:])", with: "$1")
        out = out.replacingRegex(",(?=[,.!?])", with: "")          // ",." -> "."
        out = out.replacingRegex("([,;:])(?=[\\p{L}])", with: "$1 ")
        out = out.replacingRegex(" *\\n *", with: "\n")
        out = out.replacingRegex("^[\\s,;:]+", with: "")              // leading junk
        out = out.trimmingCharacters(in: .whitespaces)
        return capitalizeSentences(out)
    }

    func capitalizeSentences(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var capNext = true
        for ch in s {
            if capNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capNext = false
                continue
            }
            if ".!?\n".contains(ch) { capNext = true }
            else if !ch.isWhitespace && !"\"'”’)".contains(ch) { capNext = false }
            result.append(ch)
        }
        return result
    }
}

// MARK: - Caret-aware joining

public enum SmartJoin {
    /// Adjust `text` so it reads naturally after `preceding` (the characters just before the caret).
    /// - Adds a leading space when continuing mid-line.
    /// - Lowercases the first word when continuing mid-sentence (not "I", not acronyms).
    public static func adapt(_ text: String, after preceding: String?) -> String {
        guard !text.isEmpty, let preceding, let last = preceding.last else { return text }
        var t = text
        let midSentence = !".!?\n:".contains(last) && !(last.isWhitespace && preceding.dropLast().last.map { ".!?\n".contains($0) } ?? true)
        if midSentence, last.isLetter || last.isNumber || ",;".contains(last) || last == " " {
            let firstWord = t.prefix { $0.isLetter || $0 == "'" }
            let isPronounI = firstWord == "I" || firstWord.hasPrefix("I'")
            let isAcronym = firstWord.count > 1 && firstWord.allSatisfy { $0.isUppercase }
            if !isPronounI && !isAcronym, let f = t.first, f.isUppercase {
                t = f.lowercased() + t.dropFirst()
            }
        }
        if !last.isWhitespace && !"([{\"'“‘/-".contains(last), let f = t.first, !",.!?;:)".contains(f), !f.isNewline {
            t = " " + t
        }
        return t
    }
}

extension String {
    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
