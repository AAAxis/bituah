import Foundation

/// Minimal ordered JSON model. Foundation's JSONEncoder does not preserve key
/// order and prints `1500.0` as `1500`; the take-home's ground truth uses the
/// Python style (`1500.0`), so we serialize by hand to make diffs readable.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func from(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    public static func from(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }
    public static func from(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.0 != y.0 || x.1 != y.1 { return false }
            return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var doubleValue: Double? { if case let .number(d) = self { return d }; return nil }

    // MARK: Serialization

    public func serialized(pretty: Bool = true) -> String {
        var out = ""
        write(to: &out, indent: 0, pretty: pretty)
        return out
    }

    private func write(to out: inout String, indent: Int, pretty: Bool) {
        let pad = pretty ? String(repeating: "  ", count: indent) : ""
        let padIn = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let nl = pretty ? "\n" : ""
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(d): out += JSONValue.formatNumber(d)
        case let .string(s): out += JSONValue.quote(s)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, item) in items.enumerated() {
                out += padIn
                item.write(to: &out, indent: indent + 1, pretty: pretty)
                out += (i < items.count - 1 ? "," : "") + nl
            }
            out += pad + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, (k, v)) in pairs.enumerated() {
                out += padIn + JSONValue.quote(k) + (pretty ? ": " : ":")
                v.write(to: &out, indent: indent + 1, pretty: pretty)
                out += (i < pairs.count - 1 ? "," : "") + nl
            }
            out += pad + "}"
        }
    }

    /// `245.5` stays `245.5`, `1500` becomes `1500.0` (Python float style), integers used as counts stay integers
    /// only when explicitly serialized via `.number(Double(Int))` — for the schema all money fields are floats.
    public static func formatNumber(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
        var s = String(format: "%.4f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if u.value < 0x20 { r += String(format: "\\u%04x", u.value) } else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\""
    }

    // MARK: Parsing (via Foundation; order is not needed when reading)

    public static func parse(data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            self = .object(d.keys.sorted().map { ($0, JSONValue(any: d[$0]!)) })
        default: self = .null
        }
    }
}
