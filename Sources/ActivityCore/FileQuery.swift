import Foundation

/// A search like `ext:dmg size:>300mb age:>90d invoice`. Tokens are separated by spaces and all must match.
///
/// Syntax (case-insensitive):
/// - `word`: substring of the file name, case- and diacritic-insensitive. `"two words"` is one phrase.
/// - `ext:dmg,pkg` or `.dmg`: extension in the set.
/// - `kind:video`: file kind. Aliases: videos, image(s), photos, audio, music, archive(s), code,
///   doc(s), document(s), app(s), cache(s), data, other. Comma lists match any of them.
/// - `size:>300mb`, `size:<1gb`, `size:>=2g`, `size:500mb..2gb`; bare `size:300mb` means at least.
///   Units b, k/kb, m/mb, g/gb, t/tb, decimal (1 KB = 1000 bytes), decimals allowed.
/// - `age:>90d`, `age:<7d`, `age:5..30d`; bare `age:90d` means at least. Modified date.
///   Units d, w (7 days), m (30 days), y (365 days).
/// - `opened:>180d`: the same on the last access date. A file without one matches `opened:>N` only.
/// - `-` before a token negates it, e.g. `-ext:log`, `-kind:video`, `-draft`.
///
/// Unknown `key:value` tokens are plain words, malformed values are ignored.
public struct FileQuery: Sendable, Equatable {
    private enum Criterion: Equatable, Sendable {
        case text(String)
        case ext(Set<String>)
        case kind(Set<FileKind>)
        case size(ClosedRange<Double>)
        case age(ClosedRange<Double>)
        case opened(ClosedRange<Double>)
    }

    private struct Term: Equatable, Sendable {
        var criterion: Criterion
        var negated: Bool
    }

    private var terms: [Term] = []

    public init() {}

    /// True when no active filter remains (empty text or only malformed tokens).
    public var isEmpty: Bool { terms.isEmpty }

    public static func parse(_ text: String) -> FileQuery {
        var query = FileQuery()
        for raw in tokens(text) {
            let negated = raw.hasPrefix("-")
            let body = (negated ? String(raw.dropFirst()) : raw).replacingOccurrences(of: "\"", with: "")
            if let criterion = criterion(for: body) {
                query.terms.append(Term(criterion: criterion, negated: negated))
            }
        }
        return query
    }

    public func matches(name: String, bytes: UInt64, modified: Date, accessed: Date?, kind: FileKind, now: Date = Date()) -> Bool {
        let ageDays = now.timeIntervalSince(modified) / 86_400
        let openedDays = accessed.map { now.timeIntervalSince($0) / 86_400 }
        return terms.allSatisfy { term in
            let hit: Bool
            switch term.criterion {
            case .text(let needle): hit = FileQuery.fold(name).contains(needle)
            case .ext(let exts): hit = exts.contains(FileQuery.extensionOf(name))
            case .kind(let kinds): hit = kinds.contains(kind)
            case .size(let range): hit = range.contains(Double(bytes))
            case .age(let range): hit = range.contains(ageDays)
            case .opened(let range): hit = openedDays.map { range.contains($0) } ?? (range.upperBound == .infinity)
            }
            return hit != term.negated
        }
    }

    // MARK: - Parsing

    /// Splits on spaces outside double quotes. Quote characters stay in the token; `parse` removes them.
    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func criterion(for token: String) -> Criterion? {
        guard !token.isEmpty else { return nil }
        guard let colon = token.firstIndex(of: ":") else {
            if token.hasPrefix("."), token.count > 1 {
                return .ext([String(token.dropFirst()).lowercased()])
            }
            return .text(fold(token))
        }
        let key = token[..<colon].lowercased()
        let value = String(token[token.index(after: colon)...])
        switch key {
        case "ext":
            let exts = Set(value.split(separator: ",").map { piece in
                String(piece.drop { $0 == "." }).lowercased()
            }.filter { !$0.isEmpty })
            return exts.isEmpty ? nil : .ext(exts)
        case "kind":
            let parts = value.split(separator: ",")
            let kinds = parts.compactMap { kindAliases[$0.lowercased()] }
            return kinds.isEmpty || kinds.count != parts.count ? nil : .kind(Set(kinds))
        case "size":
            return range(value, units: sizeUnits).map { Criterion.size($0) }
        case "age":
            return range(value, units: ageUnits).map { Criterion.age($0) }
        case "opened":
            return range(value, units: ageUnits).map { Criterion.opened($0) }
        default:
            return .text(fold(token))
        }
    }

    /// Parses `>300`, `>=2g`, `<1gb`, `<=7d`, `300mb` (at least) or `500mb..2gb` (inclusive) into a range
    /// in the base unit (bytes or days). A missing unit on one side of a range takes the other side's unit.
    private static func range(_ value: String, units: [String: Double]) -> ClosedRange<Double>? {
        if let dots = value.range(of: "..") {
            guard let low = amount(String(value[..<dots.lowerBound])),
                  let high = amount(String(value[dots.upperBound...])) else { return nil }
            let lowUnit = low.unit.isEmpty ? high.unit : low.unit
            let highUnit = high.unit.isEmpty ? lowUnit : high.unit
            guard let lowScale = units[lowUnit], let highScale = units[highUnit] else { return nil }
            let lower = low.value * lowScale
            let upper = high.value * highScale
            guard lower <= upper else { return nil }
            return lower...upper
        }
        let (op, rest) = comparison(value)
        guard let quantity = amount(rest), let scale = units[quantity.unit] else { return nil }
        let base = quantity.value * scale
        switch op {
        case ">": return base.nextUp...Double.infinity
        case "<": return (-Double.infinity)...base.nextDown
        case "<=": return (-Double.infinity)...base
        default: return base...Double.infinity // ">=" or bare value
        }
    }

    /// "1.5gb" → (1.5, "gb"); "300" → (300, ""); anything else → nil.
    private static func amount(_ text: String) -> (value: Double, unit: String)? {
        let digits = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard digits.first?.isNumber == true, let value = Double(digits) else { return nil }
        return (value, String(text.dropFirst(digits.count)).lowercased())
    }

    private static func comparison(_ value: String) -> (String, String) {
        for op in [">=", "<=", ">", "<"] where value.hasPrefix(op) {
            return (op, String(value.dropFirst(op.count)))
        }
        return ("", value)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    private static let sizeUnits: [String: Double] = [
        "": 1, "b": 1, "k": 1e3, "kb": 1e3, "m": 1e6, "mb": 1e6, "g": 1e9, "gb": 1e9, "t": 1e12, "tb": 1e12,
    ]

    private static let ageUnits: [String: Double] = ["": 1, "d": 1, "w": 7, "m": 30, "y": 365]

    private static let kindAliases: [String: FileKind] = [
        "video": .video, "videos": .video,
        "image": .image, "images": .image, "photo": .image, "photos": .image,
        "audio": .audio, "music": .audio,
        "archive": .archive, "archives": .archive,
        "code": .code,
        "document": .document, "documents": .document, "doc": .document, "docs": .document,
        "app": .app, "apps": .app,
        "cache": .dataCache, "caches": .dataCache, "data": .dataCache, "datacache": .dataCache,
        "other": .other,
    ]
}
