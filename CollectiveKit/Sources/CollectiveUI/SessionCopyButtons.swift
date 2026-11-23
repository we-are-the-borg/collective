import AppKit
import CollectiveKit
import SwiftUI

/// "Copy Session ID", "Copy Path" and "Copy Resume Command" in the menu of a
/// card, an idle row and a finished row, so the session can be taken up in a
/// terminal. No feedback: the menu just closes. A session without a known
/// folder gets no path, a tool without a resume command no command.
struct SessionCopyButtons: View {
    let sessionID: String
    let path: String?
    let resumeCommand: String?

    var body: some View {
        Button { copyToPasteboard(sessionID) } label: { Text("Copy Session ID", bundle: .module) }
        if let path {
            Button { copyToPasteboard(path) } label: { Text("Copy Path", bundle: .module) }
        }
        if let resumeCommand {
            Button { copyToPasteboard(resumeCommand) } label: { Text("Copy Resume Command", bundle: .module) }
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
