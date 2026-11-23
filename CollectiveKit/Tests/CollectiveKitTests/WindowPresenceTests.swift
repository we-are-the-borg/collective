import Testing

@testable import CollectiveKit

@Suite("WindowPresence")
struct WindowPresenceTests {
    private func presence() -> WindowPresence {
        WindowPresence(counting: ["setup", "settings"])
    }

    @Test("no window open: not in the Dock")
    func noneOpen() {
        #expect(!presence().showsInDock)
    }

    @Test("an open counted window shows in the Dock")
    func openCounted() {
        var p = presence()
        p.opened("setup")
        #expect(p.showsInDock)
    }

    @Test("closing one of two open windows keeps the Dock icon")
    func closeOneOfTwo() {
        var p = presence()
        p.opened("setup")
        p.opened("settings")
        p.closed("setup")
        #expect(p.showsInDock)
        p.closed("settings")
        #expect(!p.showsInDock)
    }

    @Test("ids that are not counted are ignored")
    func unknownIgnored() {
        var p = presence()
        p.opened("popover")
        #expect(!p.showsInDock)
    }

    @Test("closing a window that never opened is harmless")
    func closeNeverOpened() {
        var p = presence()
        p.closed("setup")
        #expect(!p.showsInDock)
        p.opened("settings")
        p.closed("setup")
        #expect(p.showsInDock)
    }

    @Test("a window is open or not, it is not a counter")
    func openTwiceCloseOnce() {
        var p = presence()
        p.opened("setup")
        p.opened("setup")
        p.closed("setup")
        #expect(!p.showsInDock)
    }

    @Test("open lists what is open, for the Dock reopen")
    func openWindowsListed() {
        var p = presence()
        p.opened("settings")
        p.opened("popover")
        #expect(p.open == ["settings"])
    }
}
