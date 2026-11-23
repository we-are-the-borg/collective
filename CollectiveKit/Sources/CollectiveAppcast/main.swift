import CollectiveKit
import Foundation

// Writes the appcast for one release (not part of the app):
//
//   swift run -c release collective-appcast --version X.Y.Z --length N --ed-signature SIG \
//     --notes ReleaseNotes.md [--previous appcast.xml] --output appcast.xml
//
// `scripts/release.sh publish` runs it with what `sign_update` printed for the
// notarized zip and the latest release's appcast; see `Appcast`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("collective-appcast: \(message)\n".utf8))
    exit(1)
}

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    let known = ["--version", "--length", "--ed-signature", "--notes", "--previous", "--output"]
    guard known.contains(flag) else { fail("unknown argument \(flag)") }
    guard let value = arguments.popFirst() else { fail("\(flag) needs a value") }
    options[flag] = value
}
let parsed = options
func required(_ flag: String) -> String {
    guard let value = parsed[flag] else { fail("\(flag) is missing") }
    return value
}

let version = required("--version")
guard let length = Int(required("--length")), length > 0 else { fail("--length is no size in bytes") }
do {
    let notes = try String(contentsOfFile: required("--notes"), encoding: .utf8)
    let previous = try parsed["--previous"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    let item = Appcast.Item(version: version, length: length, edSignature: required("--ed-signature"),
                            notesHTML: try Appcast.notesHTML(releaseNotes: notes, version: version), date: Date())
    try Appcast.adding(item, to: previous).write(to: URL(fileURLWithPath: required("--output")))
} catch {
    fail(String(describing: error))
}
