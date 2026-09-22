import XCTest
import Foundation
@testable import BituahCore

/// End-to-end: the three take-home PDFs must match ground_truth.json field for field (text-layer tier).
/// Skipped when the samples are not present (e.g. a trimmed checkout).
final class GoldenTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testDigitalSamplesMatchGroundTruth() throws {
        let gtURL = Self.root.appendingPathComponent("ground_truth.json")
        let samples = Self.root.appendingPathComponent("Samples")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: gtURL.path), "ground_truth.json missing")
        guard case let .object(pairs) = try JSONValue.parse(data: Data(contentsOf: gtURL)) else { return XCTFail("bad GT") }
        let parser = PolicyParser(options: ParserOptions())
        var total = 0, correct = 0
        for (file, truth) in pairs {
            let url = samples.appendingPathComponent(file)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(file) missing")
            let r = try parser.parse(url: url)
            XCTAssertEqual(r.source, .pdfTextLayer)
            let s = Metrics.score(file: file, predicted: r.fields, truth: truth)
            for (k, ok, p, t) in s.perField where !ok { XCTFail("\(file) \(k): got \(p.serialized(pretty: false)) expected \(t.serialized(pretty: false))") }
            total += s.total; correct += s.correct
        }
        XCTAssertEqual(correct, total)
    }

    func testVisualOrderVariantsMatchGroundTruth() throws {
        let gtURL = Self.root.appendingPathComponent("ground_truth.json")
        let variants = Self.root.appendingPathComponent("Samples/variants")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: gtURL.path), "ground_truth.json missing")
        guard case let .object(pairs) = try JSONValue.parse(data: Data(contentsOf: gtURL)) else { return XCTFail("bad GT") }
        let parser = PolicyParser(options: ParserOptions())
        for (file, truth) in pairs {
            let url = variants.appendingPathComponent("visual_" + file)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "variant missing; run `bituah make-testset`")
            let r = try parser.parse(url: url)
            XCTAssertTrue(r.warnings.contains { $0.contains("inverted") || $0.contains("reversed") }, "normalizer should report the repair: \(r.warnings)")
            let s = Metrics.score(file: file, predicted: r.fields, truth: truth)
            XCTAssertEqual(s.correct, s.total, "\(file): \(s.perField.filter { !$0.1 }.map(\.0))")
        }
    }
}
