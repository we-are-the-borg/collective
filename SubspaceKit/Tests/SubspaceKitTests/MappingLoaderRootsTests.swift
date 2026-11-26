import Foundation
import Testing
@testable import SubspaceKit

/// A file system in memory, so the roots' mapping files need no disk.
private final class RootsFileSystem: MappingFileSystem {
    var files: [URL: (data: Data, modified: Date)] = [:]

    func modificationDate(of url: URL) -> Date? { files[url]?.modified }

    func contents(of url: URL) throws -> Data {
        guard let file = files[url] else { throw CocoaError(.fileNoSuchFile) }
        return file.data
    }
}

private let cli = URL(filePath: "/cli/root", directoryHint: .isDirectory)
private let desktop = URL(filePath: "/desktop/root", directoryHint: .isDirectory)

/// The bundled Codex document with its `revision` rewritten, and its `source`
/// too, so a test can tell which copy won.
private func codexDocument(revision: Int, marking mark: String) throws -> Data {
    let url = try #require(MappingLoader.bundledURL(named: "codex"))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(#""revision": 2,"#) && text.contains(#""source": "codex","#))
    return Data(text
        .replacingOccurrences(of: #""revision": 2,"#, with: #""revision": \#(revision),"#)
        .replacingOccurrences(of: #""source": "codex","#, with: #""source": "\#(mark)","#)
        .utf8)
}

private func put(_ fs: RootsFileSystem, _ data: Data, in root: URL, at date: Date = Date(timeIntervalSince1970: 100)) {
    fs.files[root.appending(path: "model/codex.json")] = (data, date)
}

private func loader(_ fs: RootsFileSystem, bundled: MappingDocument?) -> MappingLoader {
    MappingLoader(roots: [cli, desktop], fileSystem: fs, bundled: { _ in bundled })
}

@Suite struct MappingLoaderRootsTests {
    @Test func theHighestRevisionAcrossRootsAndBundledWins() throws {
        let bundled = try MappingDocument(data: codexDocument(revision: 3, marking: "bundled"))
        let fs = RootsFileSystem()
        put(fs, try codexDocument(revision: 4, marking: "cli"), in: cli)
        put(fs, try codexDocument(revision: 5, marking: "desktop"), in: desktop)
        #expect(loader(fs, bundled: bundled).document(named: "codex")?.source == "desktop")

        put(fs, try codexDocument(revision: 6, marking: "cli"), in: cli, at: Date(timeIntervalSince1970: 200))
        #expect(loader(fs, bundled: bundled).document(named: "codex")?.source == "cli")

        let newer = try MappingDocument(data: codexDocument(revision: 7, marking: "bundled"))
        #expect(loader(fs, bundled: newer).document(named: "codex")?.source == "bundled")
    }

    @Test func aTieGoesToTheEarlierRootAndAnyRootBeatsTheBundledCopy() throws {
        let bundled = try MappingDocument(data: codexDocument(revision: 5, marking: "bundled"))
        let fs = RootsFileSystem()
        put(fs, try codexDocument(revision: 5, marking: "desktop"), in: desktop)
        #expect(loader(fs, bundled: bundled).document(named: "codex")?.source == "desktop")

        put(fs, try codexDocument(revision: 5, marking: "cli"), in: cli)
        #expect(loader(fs, bundled: bundled).document(named: "codex")?.source == "cli")
    }

    @Test func aRootWithoutTheFileLeavesTheChoiceToTheOthers() throws {
        let bundled = try MappingDocument(data: codexDocument(revision: 3, marking: "bundled"))
        let fs = RootsFileSystem()
        #expect(loader(fs, bundled: bundled).document(named: "codex")?.source == "bundled")
        #expect(MappingLoader(roots: [cli, desktop], fileSystem: fs, bundled: { _ in nil }).document(named: "codex") == nil)
    }

    @Test func aRootsFileIsReadAgainWhenItsModificationDateChanges() throws {
        let fs = RootsFileSystem()
        let loader = loader(fs, bundled: nil)
        put(fs, try codexDocument(revision: 4, marking: "cli"), in: cli)
        put(fs, try codexDocument(revision: 5, marking: "desktop"), in: desktop)
        #expect(loader.document(named: "codex")?.source == "desktop")

        // Same date: the cached copy stands, even though the bytes changed.
        put(fs, try codexDocument(revision: 9, marking: "cli"), in: cli)
        #expect(loader.document(named: "codex")?.source == "desktop")

        put(fs, try codexDocument(revision: 9, marking: "cli"), in: cli, at: Date(timeIntervalSince1970: 200))
        #expect(loader.document(named: "codex")?.source == "cli")
    }
}
