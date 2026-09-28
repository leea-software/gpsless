import Foundation

/// One searchable place or street cluster from a region's `-search.json`.
public struct SearchEntry: Codable, Sendable, Equatable {
    public let n: String
    public let l: [String]
    public let k: String
    public let c: String
    public let y: Double
    public let x: Double
    public let r: Int
    /// Latin form of the context, in indexes built since fuel stations were added.
    public let cl: String?

    public var name: String { n }
    public var kind: String { k }
    /// Settlement (and district within a city) the entry belongs to.
    public var context: String { c }
    public var coordinate: Coordinate { Coordinate(latitude: y, longitude: x) }
}

public struct SearchResult: Identifiable, Sendable {
    public let id: Int
    public let entry: SearchEntry
    public let distanceMetres: Double?
}

/// Offline search over a region's places and streets. Every query word must
/// begin a word of the name, a Latin form or the settlement, and at least one
/// must match the name itself. Words of five letters or more tolerate one typo
/// ("Slavske" finds Славсько, transliterated "Slavsko"). Settlements rank above
/// districts and streets; nearer entries rank first within a kind.
///
/// Distinct words are kept sorted with the entries that use them, so a prefix
/// is a binary search and typo matching visits each distinct word once rather
/// than every entry; typing stays responsive on the 17,000-entry Lviv index.
public struct PlaceSearch: Sendable {
    public let entries: [SearchEntry]
    private let nameIndex: WordIndex
    private let contextIndex: WordIndex
    private let firstNameWords: [[Character]]

    private struct WordIndex: Sendable {
        let words: [[Character]]
        let postings: [[Int32]]

        init(_ entryWords: [[String]]) {
            var map: [String: [Int32]] = [:]
            for (index, words) in entryWords.enumerated() {
                for word in Set(words) {
                    map[word, default: []].append(Int32(index))
                }
            }
            let sorted = map.keys.sorted()
            words = sorted.map { word in
                return Array(word)
            }
            postings = sorted.map { word in
                return map[word] ?? []
            }
        }

        /// Entries with a word starting with `term`: quality 0 for an exact
        /// prefix, 1 for a prefix within one edit.
        func matches(_ term: [Character], fuzzy: Bool) -> [Int32: Int] {
            var result: [Int32: Int] = [:]
            var low = 0
            var high = words.count
            while low < high {
                let middle = (low + high) / 2
                if words[middle].lexicographicallyPrecedes(term) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            var index = low
            while index < words.count, words[index].starts(with: term) {
                for entry in postings[index] {
                    result[entry] = 0
                }
                index += 1
            }
            guard fuzzy, term.count >= 5 else {
                return result
            }
            for (wordIndex, word) in words.enumerated() {
                for length in [term.count - 1, term.count, term.count + 1] where length > 0 && length <= word.count {
                    if PlaceSearch.withinOneEdit(term, word[0..<length]) {
                        for entry in postings[wordIndex] where result[entry] == nil {
                            result[entry] = 1
                        }
                        break
                    }
                }
            }
            return result
        }
    }

    public init(data: Data) throws {
        struct File: Decodable {
            let entries: [SearchEntry]
        }
        entries = try JSONDecoder().decode(File.self, from: data).entries
        nameIndex = WordIndex(entries.map { entry in
            return Self.words(([entry.n] + entry.l).joined(separator: " "))
        })
        contextIndex = WordIndex(entries.map { entry in
            return Self.words(entry.c + " " + (entry.cl ?? ""))
        })
        firstNameWords = entries.map { entry in
            return Array(Self.words(entry.n).first ?? "")
        }
    }

    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "ʼ", with: "")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "`", with: "")
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { word in
            return !word.isEmpty
        }
    }

    public func search(_ query: String, near: Coordinate? = nil, limit: Int = 40) -> [SearchResult] {
        let terms = Self.words(query).map { term in
            return Array(term)
        }
        guard !terms.isEmpty else {
            return []
        }
        // Typo tolerance is costlier; use it only when exact prefixes find little.
        var scored = rank(terms, near: near, fuzzy: false)
        if scored.count < limit / 2 {
            scored = rank(terms, near: near, fuzzy: true)
        }
        scored.sort { first, second in
            if first.score == second.score {
                return entries[first.index].n < entries[second.index].n
            }
            return first.score < second.score
        }
        return scored.prefix(limit).map { item in
            return SearchResult(id: item.index, entry: entries[item.index], distanceMetres: item.distance)
        }
    }

    private func rank(_ terms: [[Character]], near: Coordinate?, fuzzy: Bool) -> [(score: Double, index: Int, distance: Double?)] {
        var candidates: [Int32: (score: Double, nameMatches: Int)]?
        for term in terms {
            let name = nameIndex.matches(term, fuzzy: fuzzy)
            let context = contextIndex.matches(term, fuzzy: fuzzy)
            var next: [Int32: (score: Double, nameMatches: Int)] = [:]
            func consider(_ entry: Int32) {
                let previous = candidates == nil ? (0.0, 0) : candidates?[entry]
                guard let previous else {
                    return
                }
                if let quality = name[entry] {
                    next[entry] = (previous.0 + Double(quality) * 15, previous.1 + 1)
                } else if let quality = context[entry] {
                    next[entry] = (previous.0 + Double(quality) * 15, previous.1)
                }
            }
            for entry in name.keys {
                consider(entry)
            }
            for entry in context.keys where name[entry] == nil {
                consider(entry)
            }
            candidates = next
            if next.isEmpty {
                return []
            }
        }
        var scored: [(score: Double, index: Int, distance: Double?)] = []
        let nearMetres = near?.metres
        for (entry, match) in candidates ?? [:] where match.nameMatches > 0 {
            let index = Int(entry)
            var score = Double(entries[index].r) * 10 + match.score
            if firstNameWords[index].starts(with: terms[0]) {
                score -= 5
            }
            var distance: Double?
            if let nearMetres {
                let metres = (entries[index].coordinate.metres - nearMetres).length
                distance = metres
                score += min(metres / 1000, 300) * 0.05
            }
            scored.append((score, index, distance))
        }
        return scored
    }

    fileprivate static func withinOneEdit(_ first: [Character], _ second: ArraySlice<Character>) -> Bool {
        if abs(first.count - second.count) > 1 {
            return false
        }
        var index = 0
        var other = second.startIndex
        var edits = 0
        while index < first.count && other < second.endIndex {
            if first[index] == second[other] {
                index += 1
                other += 1
                continue
            }
            edits += 1
            if edits > 1 {
                return false
            }
            if first.count > second.count {
                index += 1
            } else if first.count < second.count {
                other += 1
            } else {
                index += 1
                other += 1
            }
        }
        return edits + (first.count - index) + (second.endIndex - other) <= 1
    }
}
