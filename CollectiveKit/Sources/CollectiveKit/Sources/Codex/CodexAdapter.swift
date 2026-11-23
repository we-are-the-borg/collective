import Foundation
import SubspaceKit

public enum CodexAdapterError: Error, Equatable {
    case notAJSONObject
    case missingField(String)
    /// Neither the root nor the app ships a usable `codex` mapping document.
    case noMapping
}

/// Translates Codex hook payloads (as wrapped by subspace) into `AgentEvent`s.
///
/// The payload is read only through the target fields of the `codex` mapping
/// document (subspace `docs/model.md`), so a renamed payload path is absorbed by
/// a new mapping revision. What the fields mean stays here.
///
/// Hooks run async and their order is no lifecycle guarantee (subspace contract
/// §6), so the adapter correlates by id (`session`, `agent`, `turn_id`), never by
/// arrival order. Child events keep the root's `session_id`; `agent` is the child
/// thread. A child thread can be reused for several turns, each ended by its own
/// `SubagentStop`, so every child turn becomes its own subagent row with the id
/// `<thread id>/<turn id>`.
///
/// The hooks don't name a child's task or parent. Both are in the first line of
/// its rollout (contract §8), which may not exist yet when the first hook
/// arrives; until it answers, the rows go without title and every later event of
/// the session retries.
///
/// To correlate, the adapter keeps per session the root turns and child turn
/// rows that ended and each child thread with its rows. Codex never sends a
/// session end, so a session's state is forgotten once none of its envelopes
/// arrived for `sessionExpiry`. Envelope time is the clock, not the wall
/// clock: replaying the event store at start ends in the same state as reading
/// live. Forgetting is safe because the store keeps terminal states sticky: a
/// hook arriving afterwards for a finished row repeats its spawn under the same
/// `<thread>/<turn>` id and neither revives nor doubles it. What it costs:
/// a resumed session rebuilds its state from its next events, a child may hang
/// under the root until its parent thread sends again, and a root `tool.pre`
/// arriving more than `sessionExpiry` late for an ended turn is no longer
/// marked as already ended. The same holds for a late root `permission.request`
/// of an ended turn, which is no longer suppressed; that is harmless in
/// practice, as a permission request blocks its turn and so cannot arrive after
/// that turn ended.
///
/// The envelope clock has two edge cases, both accepted. An envelope delivered
/// live more than `sessionExpiry` out of order can find its session already
/// forgotten, while a replay sorts it into place. And one envelope with a
/// future timestamp moves the clock forward and lets other sessions expire on
/// their next event.
public final class CodexAdapter: PushAdapter {
    public let source: SourceID = "codex"
    public let displayName = "Codex"
    /// Lobe Icons' `codex.svg`.
    public let logoName: String? = "codex"
    /// The session ID is the thread's UUID, which `codex resume` takes ahead
    /// of a thread name.
    public var resumeCommand: ResumeCommand? { ResumeCommand { ["codex", "resume", $0] } }

    private let rolloutReader: any RolloutMetaReading
    private let mapping: MappingLoader
    private var sessions: [SessionKey: SessionState] = [:]
    /// The newest `receivedAt` seen; sessions expire by it.
    private var clock: Date?
    private var lastSweep: Date?

    /// Matches the store's `waitingTimeout`, the time it waits for a waiting
    /// session without a process before calling it stale, so that a
    /// session still shown keeps its state. The app passes that timeout to
    /// `CollectiveState.markStale` (`CollectiveModel`); this constant is a
    /// separate copy, and the two must change together.
    private static let sessionExpiry: TimeInterval = 12 * 60 * 60
    /// Sweeping at most this often, in envelope time, keeps its cost per event
    /// constant; a swept-out session goes at most this much later.
    private static let sweepInterval: TimeInterval = 10 * 60

    public init(
        rolloutReader: any RolloutMetaReading = FileRolloutMetaReader(),
        mapping: MappingLoader = CodexAdapter.defaultMapping()
    ) {
        self.rolloutReader = rolloutReader
        self.mapping = mapping
    }

    /// Reads the mapping from the same `$ROOT` the spool reader reads this source's
    /// events from; `chosen` is the folder the user picked for it, if any.
    public static func defaultMapping(
        chosen: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MappingLoader {
        MappingLoader(root: SubspaceRoot.resolve(ownRoot(environment: environment, home: home), chosen: chosen, environment: environment))
    }

    public func spoolRoot(environment: [String: String], home: URL) -> URL {
        Self.ownRoot(environment: environment, home: home)
    }

    /// `plugins/data/subspace-subspace` in `$CODEX_HOME`, or in `~/.codex`.
    private static func ownRoot(environment: [String: String], home: URL) -> URL {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return codexHome.appendingPathComponent("plugins/data/subspace-subspace", isDirectory: true)
    }

    public func events(from envelope: Envelope) throws -> [AgentEvent] {
        let payload = try JSONValue(data: envelope.payload)
        guard case .object = payload else { throw CodexAdapterError.notAJSONObject }
        guard let document = mappingDocument() else { throw CodexAdapterError.noMapping }
        return try events(from: envelope, mapped: MappingInterpreter.apply(document, to: payload))
    }

    public func mappingDocument() -> MappingDocument? {
        mapping.document(named: "codex")
    }

    /// A tool's output is the bulk of the payloads; what the adapter needs of
    /// it comes as target fields of its own.
    public var excludedFields: Set<String> { ["tool_response"] }

    public func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent] {
        let fields = Fields(mapped)
        guard let sessionID = fields.core("session") else { throw CodexAdapterError.missingField("session") }

        let now = max(clock ?? envelope.receivedAt, envelope.receivedAt)
        clock = now
        sweepExpired(now: now)
        let key = SessionKey(source: source, sessionID: sessionID)
        // Taken out rather than copied, so its sets aren't shared with the
        // dictionary while mutated: a shared one is copied whole on the first
        // insert, the cost of the closed history on every stop. Nothing below
        // throws or returns early, so it always goes back. Expired even if no
        // sweep was due yet, so the outcome doesn't depend on when one ran.
        var state = sessions.removeValue(forKey: key).flatMap { Self.hasExpired($0, now: now) ? nil : $0 } ?? SessionState(lastSeen: envelope.receivedAt)
        state.lastSeen = max(state.lastSeen, envelope.receivedAt)
        var out: [AgentEvent.Kind] = []
        if let agentID = fields.core("agent") {
            childEvent(agentID, fields, sessionID: sessionID, &state, &out)
        } else {
            rootEvent(fields, &state, &out)
        }
        retryUntitled(sessionID: sessionID, &state, &out)
        let terminal = envelope.terminal.isEmpty ? nil : TerminalIdentifiers(envelope.terminal)
        reportTerminal(terminal, &state, &out)
        sessions[key] = state
        // No pid, for the same reason as at the session start.
        return out.map { AgentEvent(session: key, timestamp: envelope.receivedAt, kind: $0, cwd: fields.core("cwd"), terminal: terminal) }
    }

    /// Whose the hooks' terminal is, said with the session's first hook and
    /// whenever it changes, not with every hook. Always a host's:
    /// on the shared daemon (the default) it is the terminal that started the
    /// daemon, which names the app but rarely the session's tab, and nothing
    /// tells that from a session's own (contract §6, "Terminal").
    /// Gone, as when the session moves to the ChatGPT app, it is taken
    /// back. A session Codex never ends keeps its report in the store, so a
    /// start, sent again on compaction and resume, needs none of its own. A
    /// session's state, new or forgotten after `sessionExpiry`, always says
    /// it once, even without one: the store may still keep a report from
    /// before the state was forgotten.
    private func reportTerminal(_ terminal: TerminalIdentifiers?, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        if case let .some(reported) = state.terminal, reported == terminal { return }
        out.append(.terminalReported(terminal == nil ? .unusable : .host))
        state.terminal = .some(terminal)
    }

    private func sweepExpired(now: Date) {
        if let lastSweep, now.timeIntervalSince(lastSweep) < Self.sweepInterval { return }
        lastSweep = now
        sessions = sessions.filter { !Self.hasExpired($0.value, now: now) }
    }

    private static func hasExpired(_ state: SessionState, now: Date) -> Bool {
        now.timeIntervalSince(state.lastSeen) > sessionExpiry
    }

    // MARK: Hooks

    private func rootEvent(_ fields: Fields, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        let kind = fields.block("kind")
        if kind == "session.start" {
            // Never the envelope pid: daemon sessions share one app-server
            // process, which would keep dead sessions alive (contract §6).
            // Also sent on compaction and resume, with the same session id.
            out.append(.sessionStarted(cwd: fields.core("cwd"), pid: nil))
        }
        // Every root hook names the model; only a change is worth an event.
        if let model = fields.block("model"), model != state.model {
            state.model = model
            out.append(.modelChanged(to: model, from: nil))
        }

        let turn = fields.block("turn_id")
        // Ended before this hook: a late one of a turn that has ended.
        let ended = turn.map(state.closedRootTurns.contains) ?? false
        switch kind {
        case "turn.start":
            out.append(fields.block("prompt").map(AgentEvent.Kind.promptSubmitted) ?? .turnStarted)

        case "tool.pre":
            // A start for a turn that already ended is still a call of that
            // turn, but must not show a tool again.
            if let tool = toolActivity(fields) {
                out.append(.toolStarted(agent: .root, tool, callID: fields.core("tool_call"), alreadyEnded: ended))
            }

        case "permission.request":
            // Like a start: a request for a turn that already ended asks nothing.
            if ended { break }
            if isReviewedAutomatically(fields) { break }
            if let tool = requestedActivity(fields) { out.append(.permissionRequested(agent: .root, tool)) }

        case "tool.post":
            out.append(.toolFinished(agent: .root, callID: fields.core("tool_call")))

        case "turn.stop", "turn.interrupt":
            // An interrupted turn gets no `Stop`; a late `PostToolUse` may still follow.
            if let turn { state.closedRootTurns.insert(turn) }
            if let reply = fields.reply { out.append(.replied(agent: .root, reply)) }
            out.append(.turnEnded(kind == "turn.interrupt" ? .interrupted : .completed))

        default:
            break // compaction and unknown hooks: ignored
        }
        if let turn, !ended, !state.rootTurnsWithEffort.contains(turn), let name = effortName(fields, turn: turn) {
            state.rootTurnsWithEffort.insert(turn)
            if let level = Self.effortLevel(named: name) { out.append(.effortReported(agent: .root, level)) }
        }
    }

    private func childEvent(_ agentID: String, _ fields: Fields, sessionID: String, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let turn = fields.block("turn_id") else { return }
        let child = state.child(agentID)
        if let type = fields.block("agent_type") { child.type = type }
        if let model = fields.block("model") { child.model = model }
        if let path = fields.block("rollout_path") { child.rolloutPath = path }
        readRollout(agentID, child)

        let row = "\(agentID)/\(turn)"
        let closed = state.closedRows.contains(row)
        switch fields.block("kind") {
        case "agent.start":
            if !closed { openRow(row, of: child) }

        case "tool.pre":
            guard !closed, let tool = toolActivity(fields) else { break }
            openRow(row, of: child)
            flush(child, sessionID: sessionID, state, &out)
            out.append(.toolStarted(agent: .subagent(row), tool, callID: fields.core("tool_call")))

        case "permission.request":
            guard !closed, let tool = requestedActivity(fields) else { break }
            openRow(row, of: child)
            flush(child, sessionID: sessionID, state, &out)
            if !isReviewedAutomatically(fields) { out.append(.permissionRequested(agent: .subagent(row), tool)) }

        case "tool.post":
            if !closed { openRow(row, of: child) }
            flush(child, sessionID: sessionID, state, &out)
            out.append(.toolFinished(agent: .subagent(row), callID: fields.core("tool_call")))

        case "agent.turn.stop", "turn.stop", "turn.interrupt":
            // Ends this turn of the child, not the thread: it may be reused.
            guard !closed else { break }
            openRow(row, of: child)
            state.closedRows.insert(row)
            child.openRows.remove(row)
            flush(child, sessionID: sessionID, state, &out)
            if let reply = fields.reply { out.append(.replied(agent: .subagent(row), reply)) }
            out.append(.agentFinished(id: row))

        default:
            break
        }
        if child.meta == nil, !child.openRows.isEmpty { state.untitled.insert(agentID) }
        flush(child, sessionID: sessionID, state, &out)
        // Only for a row the store knows, and not after its stop: a late
        // hook is no news about the turn.
        if !closed, child.rows.contains(row), !state.rowsWithEffort.contains(row), let name = effortName(fields, turn: turn) {
            state.rowsWithEffort.insert(row)
            if let level = Self.effortLevel(named: name) { out.append(.effortReported(agent: .subagent(row), level)) }
        }
    }

    /// Makes `row` known and the child's most recent turn, the one its own
    /// spawns hang under.
    private func openRow(_ row: String, of child: ChildThread) {
        guard child.rows.insert(row).inserted else { return }
        child.openRows.insert(row)
        child.pending.insert(row)
        child.latestRow = row
    }

    // MARK: Rollout metadata

    private func readRollout(_ agentID: String, _ child: ChildThread) {
        guard
            child.meta == nil,
            let path = child.rolloutPath,
            let meta = rolloutReader.meta(rolloutPath: path),
            meta.id == agentID
        else { return }
        child.meta = meta
    }

    /// The rollout may not exist yet when a child's first hooks arrive. This
    /// can't block, so every later event of the session retries for children
    /// with a turn still running.
    private func retryUntitled(sessionID: String, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        for id in state.untitled.sorted() {
            guard let child = state.children[id], child.meta == nil, !child.openRows.isEmpty else {
                state.untitled.remove(id)
                continue
            }
            readRollout(id, child)
            flush(child, sessionID: sessionID, state, &out)
        }
    }

    /// Emits `agentSpawned` for each row of `child` whose spec or parent
    /// changed since its last emit: the rows opened since the last flush, or,
    /// once the spec or parent changed, all of them, so a title found late
    /// reaches the finished turns too.
    private func flush(_ child: ChildThread, sessionID: String, _ state: SessionState, _ out: inout [AgentEvent.Kind]) {
        let spec = AgentSpec(
            type: child.type,
            title: child.meta?.agentPath.flatMap(Self.taskName),
            modelID: child.model
        )
        let parent = parentRef(of: child, sessionID: sessionID, state)
        let current = Emitted(spec: spec, parent: parent)
        let rows = current == child.emitted ? child.pending : child.rows
        child.emitted = current
        child.pending.removeAll()
        for id in rows.sorted() {
            out.append(.agentSpawned(id: id, parent: parent, spec: spec))
        }
    }

    /// The root, or the parent thread's most recent turn. Nested spawning is
    /// unobserved (fixtures README), so an unknown parent thread is the root.
    private func parentRef(of child: ChildThread, sessionID: String, _ state: SessionState) -> AgentRef {
        guard
            let parent = child.meta?.parentThreadID, parent != sessionID,
            let row = state.children[parent]?.latestRow
        else { return .root }
        return .subagent(row)
    }

    // MARK: Helpers

    /// Under automatic review (`approvals_reviewer = "auto_review"`) Codex
    /// still sends every request, but its reviewer answers it, not the user;
    /// only the turn's `turn_context` in the rollout tells (contract §6,
    /// `docs/model.md` §4.3). The call's tool start already shows it running,
    /// and a rejection ends with the turn's stop, so the request is dropped.
    /// Anything else, no record yet or no rollout (ephemeral) waits for the
    /// user, as a request always did. Asked only for requests; the turn's
    /// record is mostly read by then, for its effort (`effortName`).
    private func isReviewedAutomatically(_ fields: Fields) -> Bool {
        guard let path = fields.block("rollout_path"), let turn = fields.block("turn_id") else { return false }
        return rolloutReader.approvalsReviewer(rolloutPath: path, turnID: turn) == "auto_review"
    }

    /// The effort turn `turn` of the hook's own thread runs at, from its
    /// `turn_context` record in the hook's rollout, the child's own for a
    /// child (contract §6, `docs/model.md` §4.3). No hook carries it, and
    /// `/model` sends none, so a change shows from the next turn's record.
    /// Asked by the callers only until a turn's record was found: its record
    /// never changes, and a replay of the event store at start would read
    /// on in the rollout for every hook. Still asked while not found, as the
    /// rollout may lag the hooks (contract §8). Ephemeral sessions have no
    /// rollout, so their effort stays unknown.
    private func effortName(_ fields: Fields, turn: String) -> String? {
        guard let path = fields.block("rollout_path") else { return nil }
        return rolloutReader.effort(rolloutPath: path, turnID: turn)
    }

    /// Codex's effort levels on the five steps, the same name on the same
    /// step as Claude Code's. `none`
    /// thinks not at all, so no gauge; any other level is off the scale and
    /// shows none either. Unknown is not cleared: nothing is reported.
    private static let effortSteps = [
        "minimal": 1, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 5,
    ]

    static func effortLevel(named name: String) -> EffortLevel? {
        effortSteps[name].flatMap { EffortLevel(step: $0, name: name) }
    }

    private func toolActivity(_ fields: Fields) -> ToolActivity? {
        guard let name = fields.block("tool_name") else { return nil }
        let detail = fields.block("command").flatMap(Self.firstLine) ?? Self.inputDetail(fields.blockValue("tool_input"))
        return ToolActivity(name: name, detail: detail)
    }

    private func requestedActivity(_ fields: Fields) -> ToolActivity? {
        toolActivity(fields)?.requesting(fields.block("command"))
    }

    /// `alpha` of `/root/alpha`.
    private static func taskName(_ path: String) -> String? {
        path.split(separator: "/").last.map(String.init)
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// A short, one-line description of what a tool call works on, read from
    /// inside the opaque `tool_input` field (subspace `docs/model.md` §9). Besides
    /// the rollout records (first line, `turn_context`) this is the only place
    /// that knows Codex's payload format; if those keys drift, only the detail
    /// line goes blank. Never the collaboration tools' `message`: it is encrypted.
    private static func inputDetail(_ input: JSONValue?) -> String? {
        guard case let .object(input)? = input else { return nil }
        for key in ["task_name", "target", "path", "pattern", "url", "query"] {
            if case let .string(value)? = input[JSONKey(key)], !value.isEmpty { return firstLine(value) }
        }
        return nil
    }
}

/// The target fields of one payload.
private struct Fields {
    private let result: MappingResult

    init(_ result: MappingResult) { self.result = result }

    /// A non-empty string core field.
    func core(_ name: String) -> String? { Self.string(result.core[JSONKey(name)]) }

    /// A non-empty string field of the `codex` block.
    func block(_ name: String) -> String? { Self.string(result.block[JSONKey(name)]) }

    func blockValue(_ name: String) -> JSONValue? { result.block[JSONKey(name)] }

    /// What the agent said last, as sent; a blank message is no reply.
    var reply: String? { block("last_assistant_message").flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - State

private struct Emitted: Equatable {
    var spec: AgentSpec
    var parent: AgentRef
}

private final class ChildThread {
    var type: String?
    var model: String?
    var rolloutPath: String?
    var meta: RolloutMeta?
    /// One row per turn, by row id `<thread>/<turn>`.
    var rows: Set<String> = []
    /// Rows whose stop wasn't seen yet; only for these a missing title is retried.
    var openRows: Set<String> = []
    /// Rows without an `agentSpawned` carrying `emitted` yet.
    var pending: Set<String> = []
    /// What the last flush emitted for every row; `nil` before the first.
    var emitted: Emitted?
    var latestRow: String?
}

private struct SessionState {
    /// The newest `receivedAt` of the session's envelopes.
    var lastSeen: Date
    /// The root model last emitted.
    var model: String?
    /// The terminal last reported, `nil` inside when it was reported gone;
    /// `nil` before the first report.
    var terminal: TerminalIdentifiers??
    var closedRootTurns: Set<String> = []
    /// Root turns whose `turn_context` record was found, so its effort isn't
    /// looked up again.
    var rootTurnsWithEffort: Set<String> = []
    /// Child turn rows whose stop was seen, to ignore events that arrive late.
    var closedRows: Set<String> = []
    /// Child turn rows whose `turn_context` record was found.
    var rowsWithEffort: Set<String> = []
    var children: [String: ChildThread] = [:]
    /// Children that may have gone without a title while a turn of theirs was
    /// open; the retry drops those that got one or have none open anymore.
    var untitled: Set<String> = []

    mutating func child(_ id: String) -> ChildThread {
        if let existing = children[id] { return existing }
        let created = ChildThread()
        children[id] = created
        return created
    }
}
