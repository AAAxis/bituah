import Foundation

/// Israeli insurers: short aliases as they appear in headers, and the full legal name to emit when
/// the document itself does not spell it out.
public struct Insurer: Sendable {
    public let canonical: String
    public let aliases: [String]      // Hebrew and Latin; matched as substrings on normalized lines

    public static let all: [Insurer] = [
        Insurer(canonical: "הראל חברה לביטוח בע\"מ", aliases: ["הראל", "Harel"]),
        Insurer(canonical: "מגדל חברה לביטוח בע\"מ", aliases: ["מגדל", "Migdal"]),
        Insurer(canonical: "כלל חברה לביטוח בע\"מ", aliases: ["כלל ביטוח", "כלל חברה", "Clal"]),
        Insurer(canonical: "הפניקס חברה לביטוח בע\"מ", aliases: ["הפניקס", "פניקס", "Phoenix"]),
        Insurer(canonical: "מנורה מבטחים ביטוח בע\"מ", aliases: ["מנורה", "Menora"]),
        Insurer(canonical: "איילון חברה לביטוח בע\"מ", aliases: ["איילון", "Ayalon"]),
        Insurer(canonical: "הכשרה חברה לביטוח בע\"מ", aliases: ["הכשרה", "Hachshara"]),
        Insurer(canonical: "שלמה חברה לביטוח בע\"מ", aliases: ["שלמה ביטוח", "שלמה חברה", "Shlomo"]),
        Insurer(canonical: "איי.די.איי חברה לביטוח בע\"מ", aliases: ["ביטוח ישיר", "איי.די.איי", "IDI"]),
        Insurer(canonical: "איי.אי.ג'י ישראל חברה לביטוח בע\"מ", aliases: ["AIG", "איי.אי.ג'י"]),
        Insurer(canonical: "ליברה חברה לביטוח בע\"מ", aliases: ["ליברה", "Libra"]),
        Insurer(canonical: "ווישור חברה לביטוח בע\"מ", aliases: ["ווישור", "Wesure"]),
        Insurer(canonical: "שירביט חברה לביטוח בע\"מ", aliases: ["שירביט", "Shirbit"]),
        Insurer(canonical: "אלטשולר שחם ביטוח בע\"מ", aliases: ["אלטשולר", "Altshuler"]),
        Insurer(canonical: "מור ביטוח בע\"מ", aliases: ["מור ביטוח"]),
        Insurer(canonical: "הכשרת הישוב חברה לביטוח בע\"מ", aliases: ["הכשרת הישוב"]),
    ]

    /// First insurer whose alias occurs in the line, plus the alias that matched.
    public static func match(in line: String) -> (Insurer, String)? {
        for ins in all {
            for a in ins.aliases {
                if line.range(of: a, options: [.caseInsensitive]) != nil { return (ins, a) }
            }
        }
        return nil
    }
}

/// Keyword lexicon for the branch classifier. Weighted: a hit on the "סוג ביטוח" line counts 5×,
/// a hit in a title line 3×, anywhere else 1×. Negative words demote branches that appear as
/// side-mentions (e.g. "ללא צבירת חיסכון פנסיוני" in a life policy).
public enum InsuranceTypeLexicon {
    public static let keywords: [InsuranceType: [String]] = [
        .health: ["בריאות", "רפואי", "רפואיות", "ניתוחים", "השתלות", "תרופות", "אשפוז", "רופא"],
        .life: ["ביטוח חיים", "חיים", "ריסק", "מקרה מוות", "מוות", "פטירה", "מוטבים", "מוטב"],
        .auto: ["רכב", "מקיף", "צד ג", "צד שלישי", "נהג", "נהגים", "רישוי", "גרירה", "שמשות", "מוסך"],
        .home: ["דירה", "מבנה", "תכולה", "נכס", "דירת", "בית משותף", "צנרת"],
        .pension: ["פנסיה", "קרן פנסיה", "קצבה", "פנסיוני", "גמל", "השתלמות"],
        .longTermCare: ["סיעוד", "סיעודי"],
        .personalAccident: ["תאונות אישיות"],
        .travel: ["נסיעות לחו\"ל", "נסיעות", "חו\"ל"],
    ]

    /// Strong, unambiguous markers used to break ties between the five core branches.
    public static let strong: [InsuranceType: [String]] = [
        .health: ["ביטוח בריאות", "פוליסת בריאות"],
        .life: ["ביטוח חיים", "פוליסת חיים", "ריסק"],
        .auto: ["ביטוח רכב", "פוליסת רכב", "רכב מקיף", "ביטוח חובה"],
        .home: ["ביטוח דירה", "פוליסת דירה"],
        .pension: ["קרן פנסיה", "ביטוח פנסיה", "פוליסת פנסיה"],
        .longTermCare: ["ביטוח סיעודי", "ביטוח סיעוד"],
        .personalAccident: ["תאונות אישיות"],
        .travel: ["ביטוח נסיעות", "נסיעות לחו\"ל"],
    ]
}
