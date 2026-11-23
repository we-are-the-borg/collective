import CoreText
import Foundation
import SwiftUI
import Testing
@testable import CollectiveUI

/// The bundled IBM Plex faces: they register on first use and resolve by PostScript name to
/// the right family and weight, with each family's license next to its fonts.
@Suite struct PlexFontTests {
    /// The OS/2 table's `usWeightClass` (bytes 4–5, big-endian): the weight the face declares,
    /// independent of how CoreText normalizes it into a trait.
    private func weightClass(_ font: CTFont) throws -> Int {
        let table = try #require(CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?)
        return Int(table[4]) << 8 | Int(table[5])
    }

    @Test(arguments: [
        (PlexFace.sansRegular, "IBMPlexSans", "IBM Plex Sans", 400, false),
        (.sansMedium, "IBMPlexSans-Medm", "IBM Plex Sans", 500, false),
        (.sansSemiBold, "IBMPlexSans-SmBld", "IBM Plex Sans", 600, false),
        (.sansItalic, "IBMPlexSans-Italic", "IBM Plex Sans", 400, true),
        (.sansMediumItalic, "IBMPlexSans-MedmItalic", "IBM Plex Sans", 500, true),
        (.sansSemiBoldItalic, "IBMPlexSans-SmBldItalic", "IBM Plex Sans", 600, true),
        (.monoRegular, "IBMPlexMono", "IBM Plex Mono", 400, false),
        (.monoMedium, "IBMPlexMono-Medm", "IBM Plex Mono", 500, false),
    ])
    func everyFaceResolvesToItsFamilyWeightAndSlantAfterFirstUse(
        _ face: PlexFace, postScriptName: String, family: String, weight: Int, isItalic: Bool
    ) throws {
        _ = Font.plexSans(12)
        #expect(face.postScriptName == postScriptName)
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        // An unknown name falls back to Helvetica instead of failing.
        #expect(CTFontCopyPostScriptName(font) as String == postScriptName)
        #expect(CTFontCopyFamilyName(font) as String == family)
        #expect(try weightClass(font) == weight)
        #expect(CTFontGetSymbolicTraits(font).contains(.traitItalic) == isItalic)
    }

    @Test func theWeightsPickTheirFaces() {
        #expect(PlexSansWeight.allCases.map { PlexFace($0) } == [.sansRegular, .sansMedium, .sansSemiBold])
        #expect(PlexSansWeight.allCases.map { PlexFace($0, italic: true) } == [.sansItalic, .sansMediumItalic, .sansSemiBoldItalic])
        #expect(PlexMonoWeight.allCases.map(PlexFace.init) == [.monoRegular, .monoMedium])
    }

    @Test func registeringTwiceRaisesNothingAndChangesNothing() {
        PlexFace.registerAll()
        let before = CTFontManagerCopyAvailablePostScriptNames() as! [String]
        let errors = PlexFace.register()
        let after = CTFontManagerCopyAvailablePostScriptNames() as! [String]
        #expect(errors.isEmpty)
        #expect(before.sorted() == after.sorted())
    }

    @Test(arguments: PlexFace.allCases)
    func everyFontFileHasItsFamilysLicenseInTheBundle(_ face: PlexFace) throws {
        let url = try #require(face.url)
        let license = url.deletingLastPathComponent().appendingPathComponent("license.txt")
        let text = try String(contentsOf: license, encoding: .utf8)
        #expect(text.contains("SIL Open Font License, Version 1.1"))
        #expect(text.contains("Copyright © 2017 IBM Corp."))
    }

    @Test func theFontsHaveANotice() throws {
        let notice = try #require(Bundle.collectiveUI.url(forResource: "NOTICE", withExtension: "md", subdirectory: "Fonts"))
        let text = try String(contentsOf: notice, encoding: .utf8)
        for face in PlexFace.allCases {
            #expect(text.contains("\(face.fileName).ttf"), "\(face)")
        }
    }
}
