/// The version line of the About pane. Releases set the build number to the
/// version, so repeating it in parentheses would only add noise; it shows only
/// when it tells something the version does not. A missing build counts as
/// the same; a missing version reads "?" and keeps a build that is present,
/// e.g. "? (42)", since the build still identifies the running copy.
public enum AppVersionLabel {
    public static func text(short: String?, build: String?) -> String {
        let version = short ?? "?"
        guard let build, build != short else { return version }
        return "\(version) (\(build))"
    }
}
