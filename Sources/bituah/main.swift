import Foundation
import BituahCore

// MARK: - Tiny argument parser (no dependencies on purpose)

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") || (a.hasPrefix("-") && a.count == 2) {
                let key = a.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") , !["force-ocr", "no-ocr", "quiet", "help", "h", "verbose", "no-cross-check"].contains(key) {
                    options[key] = argv[i + 1]; i += 2; continue
                }
                flags.insert(key); i += 1
            } else {
                positional.append(a); i += 1
            }
        }
    }
    func opt(_ k: String, _ short: String? = nil) -> String? { options[k] ?? short.flatMap { options[$0] } }
    func flag(_ k: String) -> Bool { flags.contains(k) }
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
bituah — offline extraction of key fields from Hebrew insurance policy PDFs

USAGE
  bituah parse <pdf|dir>... [-o result.json] [--details result.details.json] [--force-ocr] [--no-ocr]
  bituah text  <pdf> [--force-ocr] [--engine vision]        dump normalized lines (debug)
      OCR options for both: --dpi 300  --psm 4  --no-cross-check (disable Vision digit fusion)
  bituah make-testset <dir> --out <dir>                     build scan_* and visual_* variants of every PDF in <dir>
  bituah eval  [--ground-truth ground_truth.json] [--samples Samples] [--variants Samples/variants] [-o metrics.json]
  bituah info                                               engines available on this machine
"""

// MARK: - Helpers

func collectPDFs(_ inputs: [String]) -> [URL] {
    var urls: [URL] = []
    let fm = FileManager.default
    for p in inputs {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { log("skip: \(p) not found"); continue }
        if isDir.boolValue {
            let items = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            urls += items.filter { $0.lowercased().hasSuffix(".pdf") }.sorted().map { URL(fileURLWithPath: p).appendingPathComponent($0) }
        } else if p.lowercased().hasSuffix(".pdf") {
            urls.append(URL(fileURLWithPath: p))
        }
    }
    return urls
}

func makeOptions(_ args: Args) -> ParserOptions {
    var o = ParserOptions()
    o.forceOCR = args.flag("force-ocr")
    if let d = args.opt("dpi").flatMap(Double.init) { o.dpi = CGFloat(d) }
    if args.opt("engine") == "vision" {
        o.ocrEngine = VisionOCREngine()
        return o
    }
    if !args.flag("no-ocr") {
        var t = TesseractCLIEngine()
        if let psm = args.opt("psm").flatMap(Int.init) { t.psm = psm }
        if let dpi = args.opt("dpi").flatMap(Double.init) { o.dpi = CGFloat(dpi) }
        if t.isAvailable {
            o.ocrEngine = t
            if !args.flag("no-cross-check") { o.digitCrossCheckEngine = VisionOCREngine() }
        } else {
            log("warning: tesseract not found — OCR tier disabled (brew install tesseract tesseract-lang)")
        }
    }
    return o
}

func detailsJSON(_ r: ExtractionResult) -> JSONValue {
    let ev: [(String, JSONValue)] = PolicyFields.keys.compactMap { k in
        guard let e = r.evidence[k] else { return nil }
        var pairs: [(String, JSONValue)] = [("confidence", .number((e.confidence * 100).rounded() / 100)), ("evidence", .string(e.evidence))]
        if let n = e.note { pairs.append(("note", .string(n))) }
        return (k, .object(pairs))
    }
    return .object([
        ("fields", .object(PolicyFields.keys.map { ($0, r.fields.jsonObject[$0] ?? .null) })),
        ("evidence", .object(ev)),
        ("source", .string(r.source.rawValue)),
        ("pages", .number(Double(r.pageCount))),
        ("timings_sec", .object(r.timings.sorted { $0.key < $1.key }.map { ($0.key, .number(($0.value * 1000).rounded() / 1000)) })),
        ("warnings", .array(r.warnings.map { .string($0) })),
    ])
}

func write(_ json: JSONValue, to path: String) throws {
    try (json.serialized() + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Commands

func cmdParse(_ args: Args) throws {
    let urls = collectPDFs(Array(args.positional.dropFirst()))
    guard !urls.isEmpty else { die("no PDF inputs\n\n" + usage) }
    let parser = PolicyParser(options: makeOptions(args))
    var results: [(String, JSONValue)] = []
    var details: [(String, JSONValue)] = []
    for u in urls {
        do {
            let r = try parser.parse(url: u)
            results.append((r.fileName, .object(PolicyFields.keys.map { ($0, r.fields.jsonObject[$0] ?? .null) })))
            details.append((r.fileName, detailsJSON(r)))
            if !args.flag("quiet") {
                log(String(format: "%@  [%@, %.0f ms]", r.fileName, r.source.rawValue, (r.timings["total"] ?? 0) * 1000))
                for w in r.warnings { log("  ! " + w) }
            }
        } catch {
            log("error: \(u.lastPathComponent): \(error)")
            results.append((u.lastPathComponent, .null))
        }
    }
    let out = JSONValue.object(results)
    if let path = args.opt("o", "output") {
        try write(out, to: path)
        let detailsPath = args.opt("details") ?? (path.hasSuffix(".json") ? String(path.dropLast(5)) + ".details.json" : path + ".details.json")
        try write(.object(details), to: detailsPath)
        log("wrote \(path) and \(detailsPath)")
    } else {
        print(out.serialized())
    }
}

func cmdText(_ args: Args) throws {
    guard args.positional.count >= 2 else { die(usage) }
    let parser = PolicyParser(options: makeOptions(args))
    let r = try parser.parse(url: URL(fileURLWithPath: args.positional[1]))
    print("# source: \(r.source.rawValue), pages: \(r.pageCount)")
    for (i, l) in r.normalizedLines.enumerated() { print(String(format: "%3d  %@", i, l)) }
    for w in r.warnings { print("! " + w) }
}

func cmdMakeTestset(_ args: Args) throws {
    guard args.positional.count >= 2, let out = args.opt("out") else { die(usage) }
    let urls = collectPDFs([args.positional[1]])
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for u in urls {
        let name = u.lastPathComponent
        let scan = URL(fileURLWithPath: out).appendingPathComponent("scan_" + name)
        let visual = URL(fileURLWithPath: out).appendingPathComponent("visual_" + name)
        try TestSetGenerator.makeScan(from: u, to: scan)
        try TestSetGenerator.makeVisualOrderVariant(from: u, to: visual)
        log("made \(scan.lastPathComponent), \(visual.lastPathComponent)")
    }
}

func cmdEval(_ args: Args) throws {
    let gtPath = args.opt("ground-truth") ?? "ground_truth.json"
    let samples = args.opt("samples") ?? "Samples"
    let variants = args.opt("variants") ?? "Samples/variants"
    let gt = try JSONValue.parse(data: Data(contentsOf: URL(fileURLWithPath: gtPath)))
    guard case let .object(gtPairs) = gt else { die("ground truth must be an object keyed by file name") }

    let parser = PolicyParser(options: makeOptions(args))
    var sections: [(String, [Metrics.DocScore])] = []
    var ocrRates: [(String, Double, Double, Double)] = []   // file, CER, WER, seconds
    var metricsJSON: [(String, JSONValue)] = []

    func evaluate(prefix: String, dir: String, title: String) throws {
        var scores: [Metrics.DocScore] = []
        for (file, truth) in gtPairs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(prefix + file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let r = try parser.parse(url: url)
            scores.append(Metrics.score(file: prefix + file, predicted: r.fields, truth: truth))
            if r.source == .tesseractOCR {
                // Reference text = native layer of the original digital PDF.
                let orig = URL(fileURLWithPath: samples).appendingPathComponent(file)
                let ref = try PolicyParser(options: ParserOptions()).parse(url: orig).normalizedLines.joined(separator: "\n")
                let hyp = r.normalizedLines.joined(separator: "\n")
                ocrRates.append((prefix + file, Metrics.cer(reference: ref, hypothesis: hyp), Metrics.wer(reference: ref, hypothesis: hyp), (r.timings["ocr_primary"] ?? 0) + (r.timings["ocr_digits"] ?? 0)))
            }
            metricsJSON.append((prefix + file, .object([
                ("source", .string(r.source.rawValue)),
                ("correct", .number(Double(scores.last!.correct))),
                ("total", .number(Double(scores.last!.total))),
                ("mismatches", .object(scores.last!.perField.filter { !$0.1 }.map { ($0.0, .object([("predicted", $0.2), ("truth", $0.3)])) })),
                ("total_sec", .number(((r.timings["total"] ?? 0) * 1000).rounded() / 1000)),
            ])))
        }
        if !scores.isEmpty { sections.append((title, scores)) }
    }

    try evaluate(prefix: "", dir: samples, title: "Digital PDFs (text layer)")
    try evaluate(prefix: "visual_", dir: variants, title: "Visual-order text layer → inverted digits after PDFKit bidi")
    try evaluate(prefix: "scan_", dir: variants, title: "Scanned (image-only, Tesseract heb)")

    var report = ""
    for (title, scores) in sections {
        report += "### \(title)\n\n" + Metrics.markdownTable(scores: scores) + "\n"
        for s in scores { for (k, ok, p, t) in s.perField where !ok { report += "- \(s.file) · \(k): got `\(p.serialized(pretty: false))`, expected `\(t.serialized(pretty: false))`\n" } }
        report += "\n"
    }
    if !ocrRates.isEmpty {
        report += "### OCR text quality vs. native text layer\n\n| file | CER | WER | OCR time |\n|---|---|---|---|\n"
        for (f, c, w, s) in ocrRates { report += String(format: "| %@ | %.1f%% | %.1f%% | %.1f s |\n", f, c * 100, w * 100, s) }
        let mc = ocrRates.map(\.1).reduce(0, +) / Double(ocrRates.count), mw = ocrRates.map(\.2).reduce(0, +) / Double(ocrRates.count)
        report += String(format: "| **mean** | **%.1f%%** | **%.1f%%** | |\n", mc * 100, mw * 100)
        metricsJSON.append(("ocr_text_quality", .object(ocrRates.map { ($0.0, .object([("cer", .number(($0.1 * 1000).rounded() / 1000)), ("wer", .number(($0.2 * 1000).rounded() / 1000))])) })))
    }
    print(report)
    if let o = args.opt("o", "output") { try write(.object(metricsJSON), to: o); log("wrote \(o)") }
}

func cmdInfo() {
    let t = TesseractCLIEngine()
    print("tesseract: \(t.isAvailable ? t.binary.path : "not found")")
    print("vision: available, hebrew supported = \(VisionOCREngine.supportsHebrew)")
}

// MARK: - Main

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = args.positional.first, !args.flag("help"), !args.flag("h") else { print(usage); exit(0) }
do {
    switch command {
    case "parse": try cmdParse(args)
    case "text": try cmdText(args)
    case "make-testset": try cmdMakeTestset(args)
    case "eval": try cmdEval(args)
    case "info": cmdInfo()
    default: die("unknown command: \(command)\n\n" + usage)
    }
} catch {
    die("error: \(error)")
}
