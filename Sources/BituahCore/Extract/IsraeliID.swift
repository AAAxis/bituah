import Foundation

/// Israeli identity number (ת.ז). 9 digits, last digit is a Luhn-style check digit.
/// The checksum is the single most useful signal we have: it rejects policy numbers, phone
/// numbers and OCR-corrupted digits, and it lets us detect a digit string stored in reversed order.
public enum IsraeliID {

    public static func isValid(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 5, digits.count <= 9, digits.allSatisfy({ $0.isASCII }) else { return false }
        let padded = String(repeating: "0", count: 9 - digits.count) + digits
        var sum = 0
        for (i, ch) in padded.enumerated() {
            var d = Int(String(ch))! * ((i % 2) + 1)
            if d > 9 { d -= 9 }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Canonical 9-digit form (zero-padded).
    public static func canonical(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return String(repeating: "0", count: max(0, 9 - digits.count)) + digits
    }

    public struct Candidate: Equatable {
        public var value: String
        public var checksumOK: Bool
        public var wasReversed: Bool
    }

    /// Given a digit string from the page, decide whether it (or its mirror image) is a plausible ID.
    public static func candidate(from raw: String, allowMirror: Bool = false) -> Candidate? {
        let digits = raw.filter(\.isNumber)
        guard (8...9).contains(digits.count) else { return nil }
        if isValid(digits) { return Candidate(value: canonical(digits), checksumOK: true, wasReversed: false) }
        let mirrored = String(digits.reversed())
        if allowMirror, isValid(mirrored) { return Candidate(value: canonical(mirrored), checksumOK: true, wasReversed: true) }
        return Candidate(value: canonical(digits), checksumOK: false, wasReversed: false)
    }
}
