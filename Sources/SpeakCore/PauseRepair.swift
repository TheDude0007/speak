import Foundation

/// Speech recognizers end a "sentence" at every thinking pause:
///   "I want to. Go to the store and. Buy milk."
/// This rule-based pass rejoins fragments that can't really have ended there.
/// It is deliberately conservative (it only merges when the word before the period
/// can't end an English sentence, or the next word can't start one); the on-device
/// language model (SmartGrammar) handles everything subtler.
public enum PauseRepair {
    /// Words that essentially never end a sentence.
    static let dangling: Set<String> = [
        "a", "an", "the", "to", "of", "for", "with", "from", "by", "into", "onto", "and", "or", "nor",
        "but", "because", "than", "my", "your", "our", "their", "its", "very", "really", "every", "each", "whose",
    ]
    /// Words that essentially never start a sentence.
    static let strongContinuation: Set<String> = [
        "of", "to", "than", "into", "onto", "upon", "from", "by", "whom", "whose", "and", "or", "nor",
    ]
    /// Words that often continue a sentence; merged only after a very short fragment.
    static let weakContinuation: Set<String> = [
        "but", "so", "because", "the", "a", "an", "in", "on", "at", "for", "with", "that", "which", "who",
        "where", "when", "while", "if", "as", "like", "about", "then", "until", "unless", "since", "although",
        "though", "whether", "without", "between", "through", "during", "before", "after", "is", "are", "was", "were",
    ]

    /// Everyday words that are safe to lowercase after a merge (names like "Sam" or "Friday" keep their capital).
    static let common: Set<String> = [
        "a", "about", "above", "actually", "add", "after", "again", "against", "all", "already", "also", "always", "am", "an",
        "and", "any", "apply", "applying", "are", "around", "as", "ask", "at", "away", "back", "bad", "basically", "be",
        "because", "been", "before", "being", "below", "best", "better", "between", "big", "both", "bring", "but", "buy", "by",
        "call", "came", "can", "change", "check", "close", "come", "could", "day", "did", "do", "does", "doing", "done",
        "down", "each", "even", "ever", "every", "few", "find", "first", "fix", "for", "from", "get", "getting", "give",
        "go", "goes", "going", "good", "got", "great", "had", "has", "have", "having", "he", "help", "her", "here",
        "him", "his", "how", "i", "if", "in", "insert", "instead", "into", "is", "it", "its", "just", "keep",
        "know", "last", "least", "left", "less", "let", "like", "little", "long", "look", "looking", "lot", "made", "make",
        "making", "many", "may", "maybe", "me", "might", "more", "most", "move", "much", "must", "my", "need", "never",
        "new", "next", "no", "not", "now", "of", "off", "oh", "ok", "okay", "old", "on", "once", "one",
        "only", "open", "or", "other", "our", "out", "over", "own", "part", "people", "place", "please", "probably", "put",
        "quite", "rather", "read", "really", "remove", "right", "run", "said", "same", "say", "saying", "see", "seem", "send",
        "set", "she", "should", "show", "so", "some", "something", "soon", "start", "still", "such", "sure", "take", "taking",
        "tell", "than", "thank", "thanks", "that", "the", "their", "them", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "though", "through", "time", "to", "today", "together", "tomorrow", "too", "try", "trying", "turn",
        "two", "under", "until", "up", "us", "use", "used", "using", "very", "want", "was", "way", "we", "well",
        "went", "were", "what", "when", "where", "which", "while", "who", "why", "will", "with", "without", "work", "working",
        "would", "write", "yeah", "year", "yes", "yet", "you", "your",
    ]

    public static func repair(_ text: String) -> String {
        text.components(separatedBy: "\n").map(repairLine).joined(separator: "\n")
    }

    static func bare(_ w: Substring) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    static func repairLine(_ line: String) -> String {
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return line }
        var fragmentStart = 0
        var i = 0
        while i < words.count - 1 {
            let w = words[i]
            if w.hasSuffix(".") && !w.hasSuffix("..") {
                let prev = bare(Substring(w))
                let next = bare(Substring(words[i + 1]))
                let fragmentLen = i - fragmentStart + 1
                let merge = dangling.contains(prev)
                    || strongContinuation.contains(next)
                    || (weakContinuation.contains(next) && fragmentLen <= 3)
                if merge {
                    words[i].removeLast()
                    if strongContinuation.contains(next) || weakContinuation.contains(next) || dangling.contains(next) || common.contains(next),
                       let f = words[i + 1].first, f.isUppercase {
                        words[i + 1] = f.lowercased() + words[i + 1].dropFirst()
                    }
                } else {
                    fragmentStart = i + 1
                }
            } else if w.hasSuffix("!") || w.hasSuffix("?") {
                fragmentStart = i + 1
            } else if w.hasSuffix(","), dangling.contains(bare(Substring(w))) {
                words[i].removeLast()   // "the, studio" -> "the studio"
            }
            i += 1
        }
        return words.joined(separator: " ")
    }
}

/// Accept a language model's rewrite only if it is still the user's own words.
/// Blocks hallucinations, answers, and prompt-injected content ("write a poem…").
public enum GrammarGuard {
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Strip wrappers a model may echo back.
    public static func unwrap(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<dictation>", "</dictation>"] { t = t.replacingOccurrences(of: tag, with: "") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    public static func accept(original: String, corrected: String) -> Bool {
        let o = tokens(original), c = tokens(corrected)
        guard !o.isEmpty, !c.isEmpty else { return false }
        let ratio = Double(c.count) / Double(o.count)
        guard ratio >= 0.6, ratio <= 1.3 || c.count <= o.count + 3 else { return false }
        var bag: [String: Int] = [:]
        for t in o { bag[t, default: 0] += 1 }
        var hit = 0
        for t in c where (bag[t] ?? 0) > 0 { bag[t]! -= 1; hit += 1 }
        guard Double(hit) / Double(c.count) >= 0.8 else { return false }   // no invented content
        // No dropped words: every removed word must be replaced (e.g. "goes" -> "go"),
        // with slack of one per 15 words for merges like "GW one" -> "GW1".
        let missing = o.count - hit, added = c.count - hit
        return missing - added <= o.count / 15
    }
}
