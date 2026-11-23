import Foundation
import Testing
@testable import SubspaceKit

/// Golden-file conformance against the subspace dev repo (`docs/model.md` §7,
/// §12): every captured payload run through the repo's current mapping must
/// give exactly the committed expectation. This keeps the Swift interpreter in
/// step with the reference one (`tools/model/apply.py`).
///
/// The sibling checkout is located relative to this file, or via
/// `SUBSPACE_DEV_DIR`. Without it the suite is reported as skipped, never as
/// passed with nothing checked.
private enum Subspace {
    static var root: URL { SubspaceDevRepo.root }
    static var isAvailable: Bool { SubspaceDevRepo.isAvailable }

    struct Pair {
        let input: URL
        let expected: URL
        let mapping: String
    }

    struct Kind: Sendable {
        let name: String
        let inputFolder: String
        let expectedFolder: String
        /// Mapping file name (without `.json`) for a fixture's source folder.
        let mapping: @Sendable (String) -> String
        let sources: Set<String>?
    }

    static let kinds = [
        Kind(name: "events", inputFolder: "events", expectedFolder: "expected", mapping: { $0 }, sources: nil),
        Kind(name: "status", inputFolder: "status", expectedFolder: "status-expected",
             mapping: { "\($0)-session" }, sources: ["claude-code"]),
    ]

    /// Pairs for one kind plus the problems found while pairing (an input
    /// without expectation or the other way round).
    static func discover(_ kind: Kind) -> (pairs: [Pair], problems: [String]) {
        let fm = FileManager.default
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        var pairs: [Pair] = []
        var problems: [String] = []
        func files(in directory: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        func folders(in directory: URL) -> [String] {
            files(in: directory).filter {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: directory.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
            }
        }
        for source in folders(in: fixtures) where kind.sources?.contains(source) ?? true {
            let sourceDir = fixtures.appendingPathComponent(source, isDirectory: true)
            for version in folders(in: sourceDir) {
                let versionDir = sourceDir.appendingPathComponent(version, isDirectory: true)
                for run in folders(in: versionDir) {
                    let runDir = versionDir.appendingPathComponent(run, isDirectory: true)
                    let inputDir = runDir.appendingPathComponent(kind.inputFolder, isDirectory: true)
                    let expectedDir = runDir.appendingPathComponent(kind.expectedFolder, isDirectory: true)
                    let inputs = Set(files(in: inputDir))
                    let expecteds = Set(files(in: expectedDir))
                    for name in inputs.sorted() {
                        if expecteds.contains(name) {
                            pairs.append(Pair(input: inputDir.appendingPathComponent(name),
                                              expected: expectedDir.appendingPathComponent(name),
                                              mapping: kind.mapping(source)))
                        } else {
                            problems.append("no \(kind.expectedFolder)/ file for \(inputDir.appendingPathComponent(name).path)")
                        }
                    }
                    for name in expecteds.subtracting(inputs).sorted() {
                        problems.append("no \(kind.inputFolder)/ file for \(expectedDir.appendingPathComponent(name).path)")
                    }
                }
            }
        }
        return (pairs, problems)
    }
}

/// Compact JSON with sorted keys, for failure messages.
private func compact(_ value: JSONValue?) -> String {
    switch value {
    case nil: return "<absent>"
    case .null?: return "null"
    case let .bool(b)?: return b ? "true" : "false"
    case let .integer(i)?: return String(i)
    case let .bigInteger(digits)?: return digits
    case let .number(d)?: return String(d)
    case let .string(s)?:
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    case let .array(a)?: return "[" + a.map { compact($0) }.joined(separator: ",") + "]"
    case let .object(o)?:
        return "{" + o.keys.sorted().map { compact(.string($0.string)) + ":" + compact(o[$0]) }.joined(separator: ",") + "}"
    }
}

@Suite(.enabled(if: Subspace.isAvailable,
                "subspace dev repo not found (expected at ../../we-are-the-borg/subspace or $SUBSPACE_DEV_DIR); golden-file conformance NOT checked"))
struct MappingConformanceTests {
    @Test(arguments: Subspace.kinds.map(\.name))
    func goldenFilesMatch(kindName: String) throws {
        let kind = try #require(Subspace.kinds.first { $0.name == kindName })
        let (pairs, problems) = Subspace.discover(kind)
        #expect(problems.isEmpty, "unpaired fixtures:\n\(problems.joined(separator: "\n"))")
        #expect(!pairs.isEmpty, "no \(kind.name) pairs found under \(Subspace.root.path)")

        var documents: [String: MappingDocument] = [:]
        var mismatches = 0
        for pair in pairs {
            let document: MappingDocument
            if let cached = documents[pair.mapping] {
                document = cached
            } else {
                let url = Subspace.root.appendingPathComponent("model/\(pair.mapping).json")
                document = try MappingDocument(data: Data(contentsOf: url))
                documents[pair.mapping] = document
            }
            let input = try JSONValue(data: Data(contentsOf: pair.input))
            let expected = try JSONValue(data: Data(contentsOf: pair.expected))
            let actual = MappingInterpreter.apply(document, to: input).jsonValue
            if !expected.isSemanticallyEqual(to: actual) {
                mismatches += 1
                Issue.record("""
                    mismatch for \(pair.input.path) (mapping \(pair.mapping).json)
                      expected: \(compact(expected))
                      actual:   \(compact(actual))
                    """)
            }
        }
        // Surfaces the count in the test output so "0 checked" cannot pass unseen.
        print("MappingConformance: checked \(pairs.count) \(kind.name) pairs, \(mismatches) mismatches, \(problems.count) unpaired")
    }

    /// The same event pairs through the spool path: each captured payload in an
    /// envelope, read by `SpoolFile.parsed(from:documents:)`. Catches the
    /// envelope reader altering a payload before mapping. Status files are not
    /// spool envelopes, so only `events` pairs are checked.
    @Test func spoolFilesMatchGoldenFiles() throws {
        let kind = try #require(Subspace.kinds.first { $0.name == "events" })
        let (pairs, _) = Subspace.discover(kind)
        #expect(!pairs.isEmpty, "no events pairs found under \(Subspace.root.path)")

        var documents: [String: MappingDocument] = [:]
        var mismatches = 0
        for pair in pairs {
            let document: MappingDocument
            if let cached = documents[pair.mapping] {
                document = cached
            } else {
                let url = Subspace.root.appendingPathComponent("model/\(pair.mapping).json")
                document = try MappingDocument(data: Data(contentsOf: url))
                documents[pair.mapping] = document
            }
            let source = SourceID(rawValue: pair.mapping)
            let data = envelopeJSON(source: pair.mapping, rawPayload: try Data(contentsOf: pair.input))
            let expected = try JSONValue(data: Data(contentsOf: pair.expected))
            guard case let .mapped(envelope, result) = SpoolFile.parsed(from: data, documents: [source: document]) else {
                mismatches += 1
                Issue.record("expected .mapped for \(pair.input.path)")
                continue
            }
            #expect(envelope.source == source)
            let actual = result.jsonValue
            if !expected.isSemanticallyEqual(to: actual) {
                mismatches += 1
                Issue.record("""
                    spool mismatch for \(pair.input.path) (mapping \(pair.mapping).json)
                      expected: \(compact(expected))
                      actual:   \(compact(actual))
                    """)
            }
        }
        print("MappingConformance: checked \(pairs.count) events pairs through SpoolFile.parsed, \(mismatches) mismatches")
    }
}
