import Foundation

/// Tiny NSRegularExpression wrapper so the extractors read like Python.
/// Compiled patterns are cached; all matching is done on UTF-16 ranges and mapped back to Swift Strings.
public struct Pattern {
    public let pattern: String
    let re: NSRegularExpression

    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    public init(_ pattern: String, options: NSRegularExpression.Options = []) {
        self.pattern = pattern
        let key = pattern + "\u{0}" + String(options.rawValue)
        Pattern.lock.lock(); defer { Pattern.lock.unlock() }
        if let cached = Pattern.cache[key] {
            re = cached
        } else {
            // Patterns are literals in this code base; a typo is a programmer error.
            re = try! NSRegularExpression(pattern: pattern, options: options)
            Pattern.cache[key] = re
        }
    }

    public struct Match {
        public let text: String
        public let range: Range<String.Index>
        public let groups: [String?]
        /// UTF-16 offset of the match start — handy as a "distance from keyword" metric.
        public let location: Int
    }

    public func matches(in s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let r = Range(m.range, in: s)!
            var groups: [String?] = []
            for g in 1..<max(1, m.numberOfRanges) {
                let gr = m.range(at: g)
                groups.append(gr.location == NSNotFound ? nil : ns.substring(with: gr))
            }
            return Match(text: ns.substring(with: m.range), range: r, groups: groups, location: m.range.location)
        }
    }

    public func first(in s: String) -> Match? { matches(in: s).first }
    public func test(_ s: String) -> Bool { first(in: s) != nil }

    public func replace(in s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}
