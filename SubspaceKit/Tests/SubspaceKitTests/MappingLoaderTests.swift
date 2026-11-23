import Foundation
import Testing
@testable import SubspaceKit

private final class FakeFileSystem: MappingFileSystem {
    var files: [URL: (data: Data, modified: Date)] = [:]
    var unreadable: Set<URL> = []
    private(set) var reads = 0

    func modificationDate(of url: URL) -> Date? { files[url]?.modified }

    func contents(of url: URL) throws -> Data {
        reads += 1
        if unreadable.contains(url) { throw CocoaError(.fileReadNoPermission) }
        guard let file = files[url] else { throw CocoaError(.fileNoSuchFile) }
        return file.data
    }
}

private let root = URL(filePath: "/spool/root")
private let url = root.appending(path: "model/tool.json")

private func json(revision: Int, format: Int = 1) -> Data {
    Data(#"{"format": \#(format), "revision": \#(revision), "source": "tool", "block": "tool"}"#.utf8)
}

private func bundledDoc(revision: Int, format: Int = 1) -> MappingDocument {
    try! MappingDocument(data: json(revision: revision, format: format))
}

private func loader(
    _ fs: FakeFileSystem, bundled: MappingDocument? = nil
) -> MappingLoader {
    MappingLoader(root: root, fileSystem: fs, bundled: { _ in bundled })
}

private func put(_ fs: FakeFileSystem, _ data: Data, at date: Date = Date(timeIntervalSince1970: 100)) {
    fs.files[url] = (data, date)
}

@Suite struct MappingLoaderTests {
    @Test func higherRootRevisionWins() {
        let fs = FakeFileSystem()
        put(fs, json(revision: 5))
        #expect(loader(fs, bundled: bundledDoc(revision: 3)).document(named: "tool")?.revision == 5)
    }

    @Test func higherBundledRevisionWins() {
        let fs = FakeFileSystem()
        put(fs, json(revision: 2))
        #expect(loader(fs, bundled: bundledDoc(revision: 3)).document(named: "tool")?.revision == 3)
    }

    @Test func tieGoesToRoot() {
        let fs = FakeFileSystem()
        put(fs, Data(#"{"format": 1, "revision": 3, "source": "from-root", "block": "b"}"#.utf8))
        let chosen = loader(fs, bundled: bundledDoc(revision: 3)).document(named: "tool")
        #expect(chosen?.source == SourceID(rawValue: "from-root"))
    }

    @Test func unknownRootFormatFallsBackEvenWithHigherRevision() {
        let fs = FakeFileSystem()
        put(fs, json(revision: 9, format: 2))
        #expect(loader(fs, bundled: bundledDoc(revision: 1)).document(named: "tool")?.revision == 1)
    }

    @Test func unusableRootFallsBackToBundled() {
        let bundled = bundledDoc(revision: 1)
        let cases: [(String, (FakeFileSystem) -> Void)] = [
            ("missing", { _ in }),
            ("unreadable", { fs in put(fs, json(revision: 9)); fs.unreadable = [url] }),
            ("invalid JSON", { fs in put(fs, Data("{nope".utf8)) }),
            ("not an object", { fs in put(fs, Data("[1]".utf8)) }),
            ("no block", { fs in put(fs, Data(#"{"format": 1, "revision": 9}"#.utf8)) }),
        ]
        for (label, setUp) in cases {
            let fs = FakeFileSystem()
            setUp(fs)
            #expect(loader(fs, bundled: bundled).document(named: "tool") == bundled, "\(label)")
        }
    }

    @Test func rereadsOnlyWhenModificationDateChanges() {
        let fs = FakeFileSystem()
        put(fs, json(revision: 2))
        let loader = loader(fs, bundled: bundledDoc(revision: 1))
        #expect(loader.document(named: "tool")?.revision == 2)
        #expect(loader.document(named: "tool")?.revision == 2)
        #expect(fs.reads == 1)

        put(fs, json(revision: 4), at: Date(timeIntervalSince1970: 200))
        #expect(loader.document(named: "tool")?.revision == 4)
        #expect(loader.document(named: "tool")?.revision == 4)
        #expect(fs.reads == 2)
    }

    @Test func fileAppearingAndDisappearingIsNoticed() {
        let fs = FakeFileSystem()
        let loader = loader(fs, bundled: bundledDoc(revision: 1))
        #expect(loader.document(named: "tool")?.revision == 1)
        put(fs, json(revision: 2))
        #expect(loader.document(named: "tool")?.revision == 2)
        fs.files[url] = nil
        #expect(loader.document(named: "tool")?.revision == 1)
    }

    @Test func unknownNameWithoutAnyDocumentIsNil() {
        #expect(loader(FakeFileSystem()).document(named: "tool") == nil)
        #expect(MappingLoader(root: root, fileSystem: FakeFileSystem()).document(named: "nonexistent") == nil)
    }

    @Test func readsARealDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mapping-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "model"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "model/claude-code.json")
        try json(revision: 99).write(to: file)

        let loader = MappingLoader(root: dir)
        #expect(loader.document(named: "claude-code")?.revision == 99)
        // Missing in the root: the bundled copy answers.
        #expect(loader.document(named: "codex")?.revision == 2)
    }
}

@Suite struct BundledMappingTests {
    @Test(arguments: [("claude-code", 9), ("claude-code-session", 3), ("codex", 2)] as [(String, Int64)])
    func bundledDocumentLoads(name: String, revision: Int64) {
        let document = MappingLoader.bundledDocument(named: name)
        #expect(document?.revision == revision)
        #expect(document?.format == MappingInterpreter.supportedFormat)
    }

    // The sibling subspace checkout is optional; without it the test is
    // reported as skipped (shown as such in the test output), never as passed.
    private static let subspaceModel = SubspaceDevRepo.root.appending(path: "model")

    @Test(.enabled(if: SubspaceDevRepo.isAvailable,
                  "subspace dev repo not found (expected at ../../we-are-the-borg/subspace or $SUBSPACE_DEV_DIR)"),
          arguments: ["claude-code", "claude-code-session", "codex"])
    func bundledCopyEqualsSubspaceModel(name: String) throws {
        let bundledURL = try #require(MappingLoader.bundledURL(named: name))
        let original = Self.subspaceModel.appending(path: "\(name).json")
        #expect(try Data(contentsOf: bundledURL) == Data(contentsOf: original))
    }
}
