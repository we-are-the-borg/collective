import Foundation
import Testing
@testable import CollectiveKit

@Suite("Release notes")
struct ReleaseNotesTests {
    @Test func everyVersionSectionIsARelease() {
        let notes = ReleaseNotes(markdown: """
        # Release Notes

        What changed for users.

        ## 1.2.0

        - Newer things

        ## 1.1.0

        - Older things
        """, installedVersion: "1.2.0")
        #expect(notes.releases.map(\.version) == ["1.2.0", "1.1.0"])
        #expect(notes.releases.map(\.markdown) == ["- Newer things", "- Older things"])
    }

    /// The hint `prepare` leaves, and any other comment, is for the writer, not for users; a
    /// section with nothing else is unwritten and does not show.
    @Test func commentsAreRemovedAndUnwrittenSectionsDropped() {
        let notes = ReleaseNotes(markdown: """
        # Release Notes

        ## 1.3.0

        <!-- What changed for users. Required. -->

        ## 1.2.0

        <!-- a hint,
        over two lines -->

        - Kept <!-- inline --> text

        <!-- another -->

        ## 1.1.0

        ## 1.0.0

        - First
        """, installedVersion: "1.3.0")
        #expect(notes.releases.map(\.version) == ["1.2.0", "1.0.0"])
        #expect(notes.releases.first?.markdown == "- Kept  text")
    }

    /// An unclosed comment hides the rest of its section, as `scripts/release.sh publish` treats
    /// it for the GitHub release, which also gets only its own section.
    @Test func anUnclosedCommentHidesTheRestOfItsSection() {
        let notes = ReleaseNotes(markdown: """
        ## 1.1.0

        - Shown
        <!-- never closed
        - Hidden

        ## 1.0.0

        - Still shown
        """, installedVersion: "1.1.0")
        #expect(notes.releases.map(\.markdown) == ["- Shown", "- Still shown"])
    }

    /// Written out of order and with a heading that is no release: numeric order, 1.10.0 above 1.9.0.
    private static let mixed = """
    ## 1.9.0

    - Nine

    ## 1.10.0

    - Ten

    ## 1.10.1-rc1

    - A pre-release heading is no version

    ## 2.0.0

    - Not out yet for this copy

    ## 1.2.0

    - Two
    """

    @Test func releasesUpToTheInstalledOneShowNewestFirstWithTheInstalledFlagged() {
        let notes = ReleaseNotes(markdown: Self.mixed, installedVersion: "1.10.0")
        #expect(notes.releases.map(\.version) == ["1.10.0", "1.9.0", "1.2.0"])
        #expect(notes.releases.map(\.isInstalled) == [true, false, false])
    }

    /// A copy whose version has no section of its own (a build between releases, notes not
    /// written yet) shows what came before it, with nothing flagged.
    @Test func anInstalledVersionWithoutSectionShowsTheOlderOnesUnflagged() {
        let notes = ReleaseNotes(markdown: Self.mixed, installedVersion: "1.9.5")
        #expect(notes.releases.map(\.version) == ["1.9.0", "1.2.0"])
        #expect(notes.releases.allSatisfy { !$0.isInstalled })
    }

    /// Without a readable version there is no bound: every release shows, none flagged.
    @Test(arguments: [nil, "?", "1.2"])
    func anUnreadableInstalledVersionShowsEveryRelease(installed: String?) {
        let notes = ReleaseNotes(markdown: Self.mixed, installedVersion: installed)
        #expect(notes.releases.map(\.version) == ["2.0.0", "1.10.0", "1.9.0", "1.2.0"])
        #expect(notes.releases.allSatisfy { !$0.isInstalled })
    }

    /// The sheet lays the notes out with the reply views, so they come as the reply's blocks.
    @Test func aReleaseComesAsReplyBlocks() {
        let notes = ReleaseNotes(markdown: """
        ## 1.0.0

        <!-- hint -->

        - **Bold** first
        - Second
        """, installedVersion: "1.0.0")
        #expect(notes.releases.first?.blocks == [
            .list([
                ReplyListItem(marker: "•", blocks: [.paragraph([ReplyRun("Bold", isStrong: true), ReplyRun(" first")])]),
                ReplyListItem(marker: "•", blocks: [.paragraph([ReplyRun("Second")])]),
            ]),
        ])
    }

    /// `publish` reads the first `## X.Y.Z`; a second one with the same version is not shown,
    /// even when the first is still unwritten.
    @Test func aRepeatedHeadingIsIgnored() {
        let notes = ReleaseNotes(markdown: """
        ## 1.0.0

        <!-- hint -->

        ## 1.0.0

        - Stray
        """, installedVersion: "1.0.0")
        #expect(notes.releases.isEmpty)
    }

    /// A heading with trailing whitespace is not a release. `scripts/release.sh` `markdown_section`
    /// matches the heading exactly too (`$0 == heading`), so `publish` would not find it either:
    /// app and script agree.
    @Test func aHeadingWithTrailingWhitespaceIsNotARelease() {
        let notes = ReleaseNotes(markdown: "## 1.2.0 \n\n- Newer things\n", installedVersion: "1.2.0")
        #expect(notes.releases.isEmpty)
    }

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../..")
        .standardized

    /// `ReleaseNotes.md` in the repo root is the one written by hand; the app ships a copy.
    @Test func theBundledCopyIsTheRepositoryFile() throws {
        let root = try Data(contentsOf: Self.repository.appending(path: "ReleaseNotes.md"))
        let bundled = try Data(contentsOf: Self.repository
            .appending(path: "CollectiveKit/Sources/CollectiveKit/Resources/ReleaseNotes.md"))
        #expect(bundled == root, "run: cp ReleaseNotes.md CollectiveKit/Sources/CollectiveKit/Resources/ReleaseNotes.md")
    }

    /// What the app reads at runtime: the resource in the kit's bundle, every release written.
    @Test func theBundledNotesParse() {
        let notes = ReleaseNotes.bundled(installedVersion: "1.2.0")
        #expect(notes.releases.map(\.version).prefix(3) == ["1.2.0", "1.1.0", "1.0.0"])
        #expect(notes.releases.first?.isInstalled == true)
        #expect(notes.releases.allSatisfy { !$0.blocks.isEmpty })
    }
}
