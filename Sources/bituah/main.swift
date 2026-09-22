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
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") , !["force-ocr", "no-ocr", "quiet", "help", "h", "verbose", "no-cross-check", "warm"].contains(key) {
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
  bituah make-doc <txt|dir> --out <dir>                     typeset plain-text policies into PDFs (held-out templates)
  bituah eval  [--ground-truth ground_truth.json] [--samples Samples] [--variants Samples/variants] [-o metrics.json]
  bituah bench [--modes rules,model,hybrid] [-o bench.json]  rules vs on-device model vs hybrid: fields, CER/WER, seconds, peak memory
  bituah info                                               engines and models available on this machine
      --mode rules|model|hybrid (parse/text/eval)  --threshold 0.8 (hybrid)
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

func makeModel() -> FieldModel? {
    if #available(macOS 26, *) {
        let m = FoundationModelExtractor()
        return m
    }
    return nil
}

func makeOptions(_ args: Args) -> ParserOptions {
    var o = ParserOptions()
    o.forceOCR = args.flag("force-ocr")
    if let m = args.opt("mode").flatMap(ExtractionMode.init(rawValue:)) { o.mode = m }
    if let t = args.opt("threshold").flatMap(Double.init) { o.hybridThreshold = t }
    if o.mode != .rules {
        o.fieldModel = makeModel()
        if let m = o.fieldModel, !m.isAvailable { log("warning: on-device model not available on this machine") }
        if o.fieldModel == nil { log("warning: Foundation Models framework needs macOS 26+; falling back to rules") ; o.mode = .rules }
    }
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

/// `--ground-truth a.json,b.json` and `--samples DirA,DirB` are lists; documents are looked up in every dir.
func loadGroundTruth(_ args: Args) throws -> [(String, JSONValue)] {
    var pairs: [(String, JSONValue)] = []
    for path in (args.opt("ground-truth") ?? "ground_truth.json").split(separator: ",").map(String.init) {
        let gt = try JSONValue.parse(data: Data(contentsOf: URL(fileURLWithPath: path)))
        guard case let .object(p) = gt else { die("\(path): ground truth must be an object keyed by file name") }
        pairs += p
    }
    return pairs
}

func locate(_ file: String, in dirs: [String]) -> String? {
    for d in dirs {
        let p = URL(fileURLWithPath: d).appendingPathComponent(file).path
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

func cmdMakeDoc(_ args: Args) throws {
    guard args.positional.count >= 2, let out = args.opt("out") else { die(usage) }
    var inputs: [String] = []
    var isDir: ObjCBool = false
    let src = args.positional[1]
    if FileManager.default.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue {
        inputs = ((try? FileManager.default.contentsOfDirectory(atPath: src)) ?? []).filter { $0.hasSuffix(".txt") }.sorted().map { src + "/" + $0 }
    } else { inputs = [src] }
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for path in inputs {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let dest = URL(fileURLWithPath: out).appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".pdf")
        try TestSetGenerator.makeDocument(fromText: text, to: dest)
        log("made \(dest.lastPathComponent)")
    }
}

func cmdEval(_ args: Args) throws {
    let sampleDirs = (args.opt("samples") ?? "Samples").split(separator: ",").map(String.init)
    let samples = sampleDirs[0]
    let variantDirs = (args.opt("variants") ?? "Samples/variants").split(separator: ",").map(String.init)
    let variants = variantDirs[0]
    let gtPairs = try loadGroundTruth(args)

    let parser = PolicyParser(options: makeOptions(args))
    var sections: [(String, [Metrics.DocScore])] = []
    var ocrRates: [(String, Double, Double, Double)] = []   // file, CER, WER, seconds
    var metricsJSON: [(String, JSONValue)] = []

    func evaluate(prefix: String, dir: String, title: String) throws {
        var scores: [Metrics.DocScore] = []
        for (file, truth) in gtPairs {
            guard let path = locate(prefix + file, in: dir == samples ? sampleDirs : variantDirs) else { continue }
            let url = URL(fileURLWithPath: path)
            let r = try parser.parse(url: url)
            scores.append(Metrics.score(file: prefix + file, predicted: r.fields, truth: truth))
            if r.source == .tesseractOCR, let origPath = locate(file, in: sampleDirs) {
                // Reference text = native layer of the original digital PDF.
                let orig = URL(fileURLWithPath: origPath)
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
    if #available(macOS 26, *) {
        let m = FoundationModelExtractor()
        print("apple foundation model: \(m.availabilityDescription)")
    } else {
        print("apple foundation model: requires macOS 26+")
    }
}

// MARK: - Bench (rules vs model vs hybrid)

struct BenchRun {
    var mode: String
    var perDoc: [(file: String, score: Metrics.DocScore, seconds: Double, source: String)] = []
    var peakRSSBytes: Int = 0
    var peakFootprintBytes: Int = 0
    var wallSeconds: Double = 0
}

func runInChild(mode: String, inputs: [String], outPath: String) throws -> (rss: Int, footprint: Int, seconds: Double) {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/time")
    p.arguments = ["-l", exe.path, "parse"] + inputs + ["--mode", mode, "-o", outPath, "--quiet"]
    let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
    let t0 = Date()
    try p.run()
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let wall = Date().timeIntervalSince(t0)
    var rss = 0, fp = 0
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let n = Int(parts[0]) else { continue }
        if parts[1].contains("maximum resident set size") { rss = n }
        if parts[1].contains("peak memory footprint") { fp = n }
    }
    return (rss, fp, wall)
}

func fieldsText(_ obj: JSONValue) -> String {
    PolicyFields.keys.map { k in
        let v = obj[k] ?? .null
        switch v {
        case .string(let s): return s
        case .number(let d): return JSONValue.formatNumber(d)
        default: return "null"
        }
    }.joined(separator: " | ")
}

func cmdBench(_ args: Args) throws {
    // Defaults cover both sets: the 3 employer PDFs and the 6 held-out templates, digital + scanned.
    let sampleDirs = (args.opt("samples") ?? "Samples,Samples/extra").split(separator: ",").map(String.init)
    let variantDirs = (args.opt("variants") ?? "Samples/variants,Samples/extra/variants").split(separator: ",").map(String.init)
    let modes = (args.opt("modes") ?? "rules,model,hybrid").split(separator: ",").map(String.init)
    var a = args
    if a.options["ground-truth"] == nil { a.options["ground-truth"] = "ground_truth.json,ground_truth_extra.json" }
    let gtPairs = try loadGroundTruth(a)

    // Documents: originals + scanned variants (the text-layer inverted-digit variants behave like originals).
    var docs: [(path: String, gtKey: String)] = []
    for (file, _) in gtPairs {
        if let orig = locate(file, in: sampleDirs) { docs.append((orig, file)) }
        if let scan = locate("scan_" + file, in: variantDirs) { docs.append((scan, file)) }
    }
    guard !docs.isEmpty else { die("no documents found") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bituah-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    var runs: [BenchRun] = []
    for mode in modes {
        log("bench: mode=\(mode) on \(docs.count) documents …")
        let out = tmp.appendingPathComponent("\(mode).json").path
        let mem = try runInChild(mode: mode, inputs: docs.map(\.path), outPath: out)
        let details = try JSONValue.parse(data: Data(contentsOf: URL(fileURLWithPath: String(out.dropLast(5)) + ".details.json")))
        var run = BenchRun(mode: mode, peakRSSBytes: mem.rss, peakFootprintBytes: mem.footprint, wallSeconds: mem.seconds)
        for d in docs {
            let name = URL(fileURLWithPath: d.path).lastPathComponent
            guard let det = details[name], let fields = det["fields"] else { continue }
            var predicted = PolicyFields()
            predicted.insuredId = fields["insured_id"]?.stringValue
            predicted.companyName = fields["company_name"]?.stringValue
            predicted.policyNumber = fields["policy_number"]?.stringValue
            predicted.insuranceType = fields["insurance_type"]?.stringValue.flatMap(InsuranceType.init(rawValue:))
            predicted.startDate = fields["start_date"]?.stringValue
            predicted.endDate = fields["end_date"]?.stringValue
            predicted.monthlyPremiumILS = fields["monthly_premium_ils"]?.doubleValue
            predicted.deductibleILS = fields["deductible_ils"]?.doubleValue
            let score = Metrics.score(file: name, predicted: predicted, truth: gtPairs.first { $0.0 == d.gtKey }!.1)
            let secs = det["timings_sec"]?["total"]?.doubleValue ?? 0
            run.perDoc.append((name, score, secs, det["source"]?.stringValue ?? ""))
        }
        runs.append(run)
    }

    // Report
    var md = "## Rules vs on-device model vs hybrid\n\n"
    md += "Documents: \(docs.count) (\(gtPairs.count) digital + \(docs.count - gtPairs.count) scanned). Fields: 8 per document.\n\n"
    md += "| config | fields correct | wrong | field CER | field WER | sec/doc (mean) | sec/doc (max) | peak RSS | peak footprint |\n|---|---|---|---|---|---|---|---|---|\n"
    var jsonRuns: [(String, JSONValue)] = []
    for r in runs {
        let correct = r.perDoc.map(\.score.correct).reduce(0, +), total = r.perDoc.map(\.score.total).reduce(0, +)
        var cer = 0.0, wer = 0.0
        for d in r.perDoc {
            let truth = gtPairs.first { d.file.hasSuffix($0.0) }!.1
            let hyp = fieldsText(.object(PolicyFields.keys.map { k in (k, d.score.perField.first { $0.0 == k }!.2) }))
            cer += Metrics.cer(reference: fieldsText(truth), hypothesis: hyp)
            wer += Metrics.wer(reference: fieldsText(truth), hypothesis: hyp)
        }
        let n = Double(max(1, r.perDoc.count))
        let secs = r.perDoc.map(\.seconds)
        md += String(format: "| %@ | %d/%d (%.1f%%) | %d | %.1f%% | %.1f%% | %.2f | %.2f | %.0f MB | %.0f MB |\n",
                     r.mode, correct, total, Double(correct) * 100 / Double(max(1, total)), total - correct,
                     cer / n * 100, wer / n * 100, secs.reduce(0, +) / n, secs.max() ?? 0,
                     Double(r.peakRSSBytes) / 1048576, Double(r.peakFootprintBytes) / 1048576)
        jsonRuns.append((r.mode, .object([
            ("correct", .number(Double(correct))), ("total", .number(Double(total))),
            ("field_cer", .number((cer / n * 1000).rounded() / 1000)), ("field_wer", .number((wer / n * 1000).rounded() / 1000)),
            ("sec_per_doc_mean", .number((secs.reduce(0, +) / n * 1000).rounded() / 1000)),
            ("sec_per_doc", .object(r.perDoc.map { ($0.file, .number(($0.seconds * 1000).rounded() / 1000)) })),
            ("peak_rss_mb", .number((Double(r.peakRSSBytes) / 1048576).rounded())),
            ("peak_footprint_mb", .number((Double(r.peakFootprintBytes) / 1048576).rounded())),
            ("wrong", .array(r.perDoc.flatMap { d in d.score.perField.filter { !$0.1 }.map { .string(d.file + " · " + $0.0) } })),
        ])))
    }
    md += "\nPeak memory is the `bituah` process (via `/usr/bin/time -l`). Apple's Foundation Model runs in the system service `TGOnDeviceInferenceProviderService` (~0.6 GB resident while generating, measured separately with `ps`), shared by all apps and not attributable to the app process; see README.\n\n"

    // Per-document detail per config
    md += "### Per document\n\n| document | " + runs.map(\.mode).joined(separator: " | ") + " |\n|---|" + runs.map { _ in "---" }.joined(separator: "|") + "|\n"
    for d in docs {
        let name = URL(fileURLWithPath: d.path).lastPathComponent
        md += "| \(name) | " + runs.map { r in
            guard let pd = r.perDoc.first(where: { $0.file == name }) else { return "—" }
            let wrong = pd.score.perField.filter { !$0.1 }.map(\.0)
            return String(format: "%d/8, %.1fs", pd.score.correct, pd.seconds) + (wrong.isEmpty ? "" : " ❌ " + wrong.joined(separator: ", "))
        }.joined(separator: " | ") + " |\n"
    }

    // Won / lost, field by field
    if let rules = runs.first(where: { $0.mode == "rules" }) {
        for other in runs where other.mode != "rules" {
            var won: [String] = [], lost: [String] = []
            for d in docs {
                let name = URL(fileURLWithPath: d.path).lastPathComponent
                guard let a = rules.perDoc.first(where: { $0.file == name }), let b = other.perDoc.first(where: { $0.file == name }) else { continue }
                for (k, okRules, pr, _) in a.score.perField {
                    let row = b.score.perField.first { $0.0 == k }!
                    let (okOther, po) = (row.1, row.2)
                    if okOther && !okRules { won.append("\(name) · \(k): rules `\(pr.serialized(pretty: false))` → \(other.mode) `\(po.serialized(pretty: false))`") }
                    if !okOther && okRules { lost.append("\(name) · \(k): rules `\(pr.serialized(pretty: false))` → \(other.mode) `\(po.serialized(pretty: false))`") }
                }
            }
            md += "\n### \(other.mode) vs rules\n\n**Won (\(won.count))**\n" + (won.isEmpty ? "- none\n" : won.map { "- " + $0 + "\n" }.joined())
            md += "\n**Lost (\(lost.count))**\n" + (lost.isEmpty ? "- none\n" : lost.map { "- " + $0 + "\n" }.joined())
        }
    }
    print(md)
    if let o = args.opt("o", "output") {
        try write(.object(jsonRuns), to: o)
        try md.write(toFile: o.hasSuffix(".json") ? String(o.dropLast(5)) + ".md" : o + ".md", atomically: true, encoding: .utf8)
        log("wrote \(o)")
    }
}

// MARK: - Main

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = args.positional.first, !args.flag("help"), !args.flag("h") else { print(usage); exit(0) }
do {
    switch command {
    case "parse": try cmdParse(args)
    case "text": try cmdText(args)
    case "make-testset": try cmdMakeTestset(args)
    case "make-doc": try cmdMakeDoc(args)
    case "eval": try cmdEval(args)
    case "bench": try cmdBench(args)
    case "info": cmdInfo()
    default: die("unknown command: \(command)\n\n" + usage)
    }
} catch {
    die("error: \(error)")
}
