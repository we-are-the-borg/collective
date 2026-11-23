import Testing
@testable import CollectiveKit

@Suite("AppVersionLabel")
struct AppVersionLabelTests {
    @Test("a build equal to the version shows the version alone")
    func buildEqualToVersion() {
        #expect(AppVersionLabel.text(short: "1.0.0", build: "1.0.0") == "1.0.0")
    }

    @Test("a build that differs from the version follows it in parentheses")
    func buildDiffers() {
        #expect(AppVersionLabel.text(short: "1.0.0", build: "42") == "1.0.0 (42)")
    }

    @Test("a missing build counts as the same as the version")
    func buildMissing() {
        #expect(AppVersionLabel.text(short: "1.0.0", build: nil) == "1.0.0")
    }

    @Test("a missing version shows a question mark")
    func versionMissing() {
        #expect(AppVersionLabel.text(short: nil, build: nil) == "?")
    }

    // The build still tells which copy is running, so it is not dropped.
    @Test("a missing version with a build keeps the build")
    func versionMissingBuildPresent() {
        #expect(AppVersionLabel.text(short: nil, build: "42") == "? (42)")
    }
}
