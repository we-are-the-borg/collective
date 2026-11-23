/// What one `EventStore.ingest` stored, split by whether the app was given the
/// file's event before, so a mapping change doesn't hand it everything again
/// as if it were new.
///
/// An app that builds state from events applies `new` as it comes. For
/// `remapped` it either replaces the earlier event's effect, if its state
/// allows that (e.g. a list keyed by root, day and name), or rebuilds its
/// state from `replay()`, which already holds the re-mapped rows and the new
/// ones, so `new` needs no extra handling then.
public struct IngestResult: Sendable, Equatable {
    /// Events the app has not been given: files the store did not know, and
    /// known files that were not a valid envelope before but are now (a
    /// package that reads a newer envelope version), in the contract's order
    /// (mtime, then name).
    public let new: [StoredEvent]
    /// Events of rows a mapping change replaced, in the contract's order. Each
    /// replaces an event of the same root, day and name that an earlier
    /// `ingest` or `replay` returned.
    public let remapped: [StoredEvent]
}
