import CoreText
import Foundation
import OSLog
import SwiftUI

/// The IBM Plex Sans weights the design uses.
public enum PlexSansWeight: Sendable, CaseIterable {
    case regular, medium, semibold
}

/// The IBM Plex Mono weights the design uses; Plex Mono is the code font.
public enum PlexMonoWeight: Sendable, CaseIterable {
    case regular, medium
}

extension Font {
    /// IBM Plex Sans at a fixed point size, as the design gives sizes in pt (11.5, 12.5, …).
    /// The first call registers the bundled faces, so neither the app nor previews wire anything.
    /// `italic` picks the family's own italic face: `Font.italic()` on a custom font finds
    /// no face to switch to and leaves the text upright.
    public static func plexSans(_ size: CGFloat, weight: PlexSansWeight = .regular, italic: Bool = false) -> Font {
        PlexFace.registerAll()
        return .custom(PlexFace(weight, italic: italic).postScriptName, fixedSize: size)
    }

    /// IBM Plex Mono at a fixed point size; registers the faces like `plexSans`.
    public static func plexMono(_ size: CGFloat, weight: PlexMonoWeight = .regular) -> Font {
        PlexFace.registerAll()
        return .custom(PlexFace(weight).postScriptName, fixedSize: size)
    }
}

/// One bundled font file, `Resources/Fonts/<family>/<file name>.ttf`.
enum PlexFace: String, CaseIterable, Sendable {
    case sansRegular = "IBMPlexSans-Regular"
    case sansMedium = "IBMPlexSans-Medium"
    case sansSemiBold = "IBMPlexSans-SemiBold"
    case sansItalic = "IBMPlexSans-Italic"
    case sansMediumItalic = "IBMPlexSans-MediumItalic"
    case sansSemiBoldItalic = "IBMPlexSans-SemiBoldItalic"
    case monoRegular = "IBMPlexMono-Regular"
    case monoMedium = "IBMPlexMono-Medium"

    init(_ weight: PlexSansWeight, italic: Bool = false) {
        switch (weight, italic) {
        case (.regular, false): self = .sansRegular
        case (.medium, false): self = .sansMedium
        case (.semibold, false): self = .sansSemiBold
        case (.regular, true): self = .sansItalic
        case (.medium, true): self = .sansMediumItalic
        case (.semibold, true): self = .sansSemiBoldItalic
        }
    }

    init(_ weight: PlexMonoWeight) {
        switch weight {
        case .regular: self = .monoRegular
        case .medium: self = .monoMedium
        }
    }

    var fileName: String { rawValue }

    /// The names inside the files, which IBM shortened for the non-regular weights; a face
    /// asked for by its file name would silently fall back to Helvetica.
    var postScriptName: String {
        switch self {
        case .sansRegular: "IBMPlexSans"
        case .sansMedium: "IBMPlexSans-Medm"
        case .sansSemiBold: "IBMPlexSans-SmBld"
        case .sansItalic: "IBMPlexSans-Italic"
        case .sansMediumItalic: "IBMPlexSans-MedmItalic"
        case .sansSemiBoldItalic: "IBMPlexSans-SmBldItalic"
        case .monoRegular: "IBMPlexMono"
        case .monoMedium: "IBMPlexMono-Medm"
        }
    }

    private var directory: String {
        switch self {
        case .sansRegular, .sansMedium, .sansSemiBold, .sansItalic, .sansMediumItalic, .sansSemiBoldItalic:
            "ibm-plex-sans"
        case .monoRegular, .monoMedium: "ibm-plex-mono"
        }
    }

    var url: URL? {
        Bundle.module.url(forResource: fileName, withExtension: "ttf", subdirectory: "Fonts/\(directory)")
    }

    private static let log = Logger(subsystem: "CollectiveKit", category: "fonts")

    /// A static `let` initializes once per process and thread-safely, which is all the
    /// once-only registration needs.
    private static let registration: Void = {
        for error in register() {
            log.error("Could not register a bundled font: \(error.localizedDescription, privacy: .public)")
        }
    }()

    static func registerAll() {
        _ = registration
    }

    /// Registers every face for this process. A face that is already registered is not an
    /// error: CoreText keeps the first registration and changes nothing.
    static func register() -> [Error] {
        allCases.compactMap { face in
            guard let url = face.url else {
                return CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fonts/\(face.directory)/\(face.fileName).ttf"])
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return nil }
            guard let error = error?.takeRetainedValue() else { return nil }
            if CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { return nil }
            return error
        }
    }
}
