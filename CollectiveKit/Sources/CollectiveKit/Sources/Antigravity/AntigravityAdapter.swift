import Foundation
import SubspaceKit

public enum AntigravityAdapterError: Error, Equatable {
    case notAJSONObject
    case missingField(String)
    /// Neither the root nor the app ships a usable `antigravity` mapping document.
    case noMapping
}

/// Translates Antigravity hook payloads (as wrapped by subspace) into `AgentEvent`s.
///
/// The payload is read only through the target fields of the `antigravity`
/// mapping document (subspace `docs/model.md` §13), so a renamed payload path
/// is absorbed by a new mapping revision. What the fields mean stays here.
///
/// Every conversation has its own `session` (`conversationId`), a subagent's
/// too; the adapter shows a subagent's as an agent of its parent's session
/// (see `childEvents`). Any hook may be a conversation's first: a resume sends no
/// `SessionStart`. A turn starts with the `PreInvocation` numbered 0 and ends
/// with a `Stop` that says the conversation is fully idle. A `Stop` that isn't
/// leaves the turn open while background subagents run; the parent's next
/// `PreInvocation` numbered 0 with the turn's prompt is their wakeup and
/// continues that turn. A denied
/// permission or an `Esc` sends no `PostToolUse` and no `Stop` (contract §6),
/// so the next turn's start closes what is still open, and until then the
/// store's timeouts guess.
///
/// Antigravity never sends a session end, so a conversation's state is
/// forgotten once none of its envelopes arrived for `sessionExpiry`, with
/// envelope time as the clock, as for Codex: replaying the event store at
/// start ends in the same state as reading live. What it costs: a turn left
/// open longer than that is no longer closed by the next one, which the store
/// has guessed over by then anyway.
public final class AntigravityAdapter: PushAdapter {
    public let source: SourceID = "antigravity"
    public let displayName = "Antigravity"
    public let logoName: String? = "antigravity"
    /// The session ID is the `conversationId`, which `agy --conversation` takes.
    public var resumeCommand: ResumeCommand? { ResumeCommand { ["agy", "--conversation", $0] } }

    private let mapping: MappingLoader
    private var sessions: [SessionKey: SessionState] = [:]
    /// The newest `receivedAt` seen; sessions expire by it.
    private var clock: Date?
    private var lastSweep: Date?

    /// Matches the store's `waitingTimeout`, as `CodexAdapter`'s does; the
    /// app passes that timeout to `CollectiveState.markStale`
    /// (`CollectiveModel`), and the copies must change together.
    private static let sessionExpiry: TimeInterval = 12 * 60 * 60
    /// Sweeping at most this often, in envelope time, keeps its cost per event
    /// constant; a swept-out session goes at most this much later.
    private static let sweepInterval: TimeInterval = 10 * 60
    /// Far more hooks than a subagent sends before its `send_message` in the
    /// captures (seven at most); one still unlinked by then runs long without
    /// a word to its parent and is shown on its own.
    private static let maxPending = 256
    /// Far more spawn calls than wait for their subagent at once; an older
    /// one is forgotten, and its subagent gets the next one's spec or none.
    private static let maxSpawns = 32

    private let transcriptReader: any AntigravityTranscriptReading

    public init(
        transcriptReader: any AntigravityTranscriptReading = FileAntigravityTranscriptReader(),
        mapping: MappingLoader = AntigravityAdapter.defaultMapping()
    ) {
        self.transcriptReader = transcriptReader
        self.mapping = mapping
    }

    /// Reads the mapping from the same `$ROOT`s the spool reader reads this source's
    /// events from, the highest revision among them; `chosen` is the folder the
    /// user picked for it, if any.
    public static func defaultMapping(
        chosen: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MappingLoader {
        MappingLoader(roots: SubspaceRoot.resolveAll(ownRoots(home: home), chosen: chosen, environment: environment))
    }

    public func spoolRoot(environment: [String: String], home: URL) -> URL {
        Self.ownRoots(home: home)[0]
    }

    public func spoolRoots(environment: [String: String], home: URL) -> [URL] {
        Self.ownRoots(home: home)
    }

    /// The CLI's plugin data (`agy`) first, then the desktop app's (contract §2).
    /// The desktop app's path was verified with Desktop App 2.35.1 and an
    /// installed plugin; contract §2 still lists it as unverified until
    /// subspace updates it.
    private static func ownRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".gemini/antigravity-cli/plugin_data/subspace", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity/plugin_data/subspace", isDirectory: true),
        ]
    }

    public func events(from envelope: Envelope) throws -> [AgentEvent] {
        let payload = try JSONValue(data: envelope.payload)
        guard case .object = payload else { throw AntigravityAdapterError.notAJSONObject }
        guard let document = mappingDocument() else { throw AntigravityAdapterError.noMapping }
        return try events(from: envelope, mapped: MappingInterpreter.apply(document, to: payload))
    }

    public func mappingDocument() -> MappingDocument? {
        mapping.document(named: "antigravity")
    }

    /// A call's whole arguments, e.g. all of a `write_file`'s content; what
    /// the adapter needs of them comes as target fields of their own.
    public var excludedFields: Set<String> { ["tool_input"] }

    public func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent] {
        let fields = Fields(mapped)
        guard let sessionID = fields.core("session") else { throw AntigravityAdapterError.missingField("session") }

        let now = max(clock ?? envelope.receivedAt, envelope.receivedAt)
        clock = now
        sweepExpired(now: now)
        let key = SessionKey(source: source, sessionID: sessionID)
        // Expired even if no sweep was due yet, so the outcome doesn't depend on when one ran.
        var state = sessions.removeValue(forKey: key).flatMap { Self.hasExpired($0, now: now) ? nil : $0 }
            ?? SessionState(lastSeen: envelope.receivedAt, child: fields.block("last_user_input") == nil ? Child() : nil)
        state.lastSeen = max(state.lastSeen, envelope.receivedAt)
        let hook = Hook(fields: fields, receivedAt: envelope.receivedAt, terminal: envelope.terminal.isEmpty ? nil : TerminalIdentifiers(envelope.terminal))
        // The one place that decides whose events a conversation's are: a
        // subagent's go to its parent's session once it is linked.
        let events = state.child == nil ? rootEvents(hook, key: key, &state) : childEvents(hook, id: sessionID, &state)
        sessions[key] = state
        return events
    }

    /// A conversation of its own: its hooks are its session's.
    private func rootEvents(_ hook: Hook, key: SessionKey, _ state: inout SessionState) -> [AgentEvent] {
        var out: [AgentEvent.Kind] = []
        rootEvent(hook.fields, &state, &out)
        reportTerminal(hook.terminal, &state, &out)
        // No pid, for the same reason as at the session start.
        return out.map { AgentEvent(session: key, timestamp: hook.receivedAt, kind: $0, cwd: hook.fields.core("cwd"), terminal: hook.terminal) }
    }

    /// The CLI runs in the user's terminal and the app names itself
    /// (`__CFBundleIdentifier`), so the identifiers are the session's own
    /// (contract §6, "Terminal"). Said with the conversation's first hook
    /// and whenever they change; gone, they are taken back.
    private func reportTerminal(_ terminal: TerminalIdentifiers?, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        if case let .some(reported) = state.terminal, reported == terminal { return }
        out.append(.terminalReported(terminal == nil ? .unusable : .session))
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
            // Never the envelope pid: the conversations of one `agy` or of the
            // app share their host's, which would keep dead sessions alive
            // (contract §6, "Session liveness").
            out.append(.sessionStarted(cwd: fields.core("cwd"), pid: nil))
        }
        // Every hook names the model; only a change is worth an event.
        if let model = fields.block("model"), model != state.model {
            state.model = model
            out.append(.modelChanged(to: model, from: nil))
        }

        switch kind {
        case "invocation.pre":
            // Later invocations of a turn are its steps, no news.
            guard fields.integer("invocation_num") == 0 else { break }
            let prompt = fields.block("last_user_input")
            // A start with another prompt is the user's, not the subagents'
            // wakeup: the turn that waited for them was left.
            if state.awaitsWakeup {
                state.awaitsWakeup = false
                if prompt == state.turn?.prompt { break }
            }
            closeTurn(&state, &out)
            state.turn = Turn(prompt: prompt)
            out.append(prompt.map(AgentEvent.Kind.promptSubmitted) ?? .turnStarted)

        case "tool.pre", "tool.post":
            toolEvent(fields, of: .root, &state, &out)

        case "turn.stop":
            // Not fully idle: background subagents still run, and their
            // messages wake the turn up again.
            if fields.boolean("fully_idle") == false {
                state.awaitsWakeup = true
                break
            }
            state.turn = nil
            state.awaitsWakeup = false
            out.append(.turnEnded(fields.block("error") == nil ? .completed : .failed))

        default:
            break // invocation ends and unknown hooks: ignored
        }
        reportEffort(of: .root, &state, &out)
    }

    /// A turn that got no fully idle `Stop` ended without one: its calls and
    /// the turn itself were denied or interrupted.
    private func closeTurn(_ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard state.turn != nil else { return }
        closeCalls(of: .root, &state, &out)
        out.append(.turnEnded(.interrupted))
        state.turn = nil
    }

    private func closeCalls(of agent: AgentRef, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        for call in state.turn?.openCalls.sorted() ?? [] {
            out.append(.toolFinished(agent: agent, callID: call))
        }
        state.turn?.openCalls.removeAll()
    }

    /// A call's start or end. An `invoke_subagent` call is kept until a
    /// child conversation is matched to it (`takeSpawn`).
    private func toolEvent(_ fields: Fields, of agent: AgentRef, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        let call = fields.core("tool_call")
        guard fields.block("kind") == "tool.pre" else {
            if let call { state.turn?.openCalls.remove(call) }
            out.append(.toolFinished(agent: agent, callID: call))
            return
        }
        guard let tool = toolActivity(fields) else { return }
        if let call { state.turn?.openCalls.insert(call) }
        if fields.core("tool") == "spawn_agent" {
            let spawn = Spawn(
                type: fields.block("spawn_type"),
                role: fields.block("spawn_role"),
                prompt: fields.block("spawn_prompt"),
                model: fields.block("spawn_model")
            )
            // Its subagent may have linked before it arrived; the spec it
            // lacks then comes again, which the store merges into it.
            if let late = takeLinkedChild(of: fields.core("session"), prompt: spawn.prompt) {
                out.append(.agentSpawned(id: late.id, parent: late.parent, spec: Self.spec(of: spawn, prompt: nil, modelID: nil)))
            } else {
                state.spawns.append(spawn)
                if state.spawns.count > Self.maxSpawns { state.spawns.removeFirst() }
            }
        }
        out.append(.toolStarted(agent: agent, tool, callID: call))
    }

    /// Once per turn, and again if the model changes within it.
    private func reportEffort(of agent: AgentRef, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard var turn = state.turn, let model = state.model, turn.effortModel != model else { return }
        turn.effortModel = model
        state.turn = turn
        if let level = Self.effortLevel(model: model) { out.append(.effortReported(agent: agent, level)) }
    }

    // MARK: Subagents

    /// A subagent's conversation, until it is linked to its parent: its hooks
    /// are kept, and every one retries the link. Its transcript names the
    /// parent in its first step (contract §8), written asynchronously;
    /// without it, the subagent's first `send_message` names its recipient,
    /// the parent, but only after the subagent did its work. Linked, the
    /// kept hooks and every later one are a subagent's in the parent's session.
    ///
    /// One that can't be linked by its fully idle `Stop`, or keeps more hooks
    /// than `maxPending`, is shown as a session of its own after all, with
    /// all its hooks, as before subagents were linked: a subagent of unknown
    /// parent is better seen apart than not at all. One whose hook has a
    /// prompt before it is linked was a root that started without one, and
    /// is shown so from then on. A linked one stays a subagent: no captured
    /// subagent's hook has a prompt, and its parent named it as its own.
    private func childEvents(_ hook: Hook, id: String, _ state: inout SessionState) -> [AgentEvent] {
        guard var child = state.child else { return [] }
        if let link = child.link {
            var out: [AgentEvent.Kind] = []
            childEvent(hook.fields, id: id, link: link, &state, &out)
            return out.map { linkedEvent($0, of: hook, link: link) }
        }

        child.pending.append(hook)
        // A prompt is the user's: a root that started without one, e.g. with only an image.
        let prompted = hook.fields.block("last_user_input") != nil
        if !prompted {
            if let path = hook.fields.block("transcript_path") { child.transcriptPath = path }
            let origin = child.transcriptPath.flatMap(transcriptReader.origin(transcriptPath:))
            let parent = origin?.parent ?? hook.fields.block("message_recipient")
            if let parent, parent != id, let link = resolve(parent) {
                let pending = child.pending
                child.pending = []
                child.link = link
                state.child = child
                return linkEvents(pending, id: id, parent: parent, prompt: origin?.prompt, link: link, &state)
            }
        }

        let idle = hook.fields.block("kind") == "turn.stop" && hook.fields.boolean("fully_idle") != false
        guard prompted || idle || child.pending.count > Self.maxPending else {
            state.child = child
            return []
        }
        state.child = nil
        let key = SessionKey(source: source, sessionID: id)
        return child.pending.flatMap { rootEvents($0, key: key, &state) }
    }

    /// Where a subagent of `conversation` shows: under the root of its
    /// session, or under it if it is a linked subagent itself. `nil` while
    /// it is a subagent not linked yet.
    private func resolve(_ conversation: String) -> Link? {
        let key = SessionKey(source: source, sessionID: conversation)
        guard let child = sessions[key]?.child else { return Link(session: key, parent: .root) }
        return child.link.map { Link(session: $0.session, parent: .subagent(conversation)) }
    }

    /// The spawn, then the kept hooks, each at its own time.
    private func linkEvents(_ pending: [Hook], id: String, parent: String, prompt: String?, link: Link, _ state: inout SessionState) -> [AgentEvent] {
        guard let first = pending.first else { return [] }
        let spawn = takeSpawn(of: parent, prompt: prompt)
        let model = first.fields.block("model")
        state.model = model
        if spawn == nil, let prompt { state.child?.awaitedSpawn = AwaitedSpawn(parent: parent, prompt: prompt) }
        let spec = Self.spec(of: spawn, prompt: prompt, modelID: model)
        var events = [linkedEvent(.agentSpawned(id: id, parent: link.parent, spec: spec), of: first, link: link)]
        for hook in pending {
            var out: [AgentEvent.Kind] = []
            childEvent(hook.fields, id: id, link: link, &state, &out)
            events += out.map { linkedEvent($0, of: hook, link: link) }
        }
        return events
    }

    /// The parent's `invoke_subagent` call the subagent was started with: the
    /// one with its prompt. Only without a prompt to tell them apart, the
    /// oldest no subagent was matched to yet: one that matches none is
    /// another subagent's, which may still link.
    private func takeSpawn(of parent: String, prompt: String?) -> Spawn? {
        let key = SessionKey(source: source, sessionID: parent)
        guard var state = sessions[key], !state.spawns.isEmpty else { return nil }
        let index: Int? = if let prompt { state.spawns.firstIndex { $0.prompt.map(Self.trimmed) == Self.trimmed(prompt) } } else { 0 }
        guard let index else { return nil }
        let spawn = state.spawns.remove(at: index)
        sessions[key] = state
        return spawn
    }

    /// The linked subagent of `parent` with `prompt` that no spawn call was
    /// matched to, for a call that arrived after it linked. Of two with the
    /// same prompt, which the calls can't tell apart either, the lower ID,
    /// so a replay picks the same.
    private func takeLinkedChild(of parent: String?, prompt: String?) -> (id: String, parent: AgentRef)? {
        guard let parent, let prompt, let clock else { return nil }
        let waiting = sessions.filter { key, state in
            guard let awaited = state.child?.awaitedSpawn, !Self.hasExpired(state, now: clock) else { return false }
            return awaited.parent == parent && Self.trimmed(awaited.prompt) == Self.trimmed(prompt)
        }
        guard let (key, state) = waiting.min(by: { $0.key.sessionID < $1.key.sessionID }),
              let link = state.child?.link else { return nil }
        sessions[key]?.child?.awaitedSpawn = nil
        return (key.sessionID, link.parent)
    }

    /// A subagent's spec from its spawn call, else from what its transcript said.
    private static func spec(of spawn: Spawn?, prompt: String?, modelID: String?) -> AgentSpec {
        AgentSpec(
            type: spawn?.type,
            title: spawn?.role,
            prompt: spawn?.prompt ?? prompt,
            // `inherit` is the parent's model, which `modelID` names.
            modelAlias: spawn?.model == "inherit" ? nil : spawn?.model,
            modelID: modelID
        )
    }

    /// The terminal is the parent's own, reported with its hooks.
    private func linkedEvent(_ kind: AgentEvent.Kind, of hook: Hook, link: Link) -> AgentEvent {
        AgentEvent(session: link.session, timestamp: hook.receivedAt, kind: kind, cwd: hook.fields.core("cwd"))
    }

    /// A linked subagent's hook. Its model goes into its spec, its turn's end
    /// is its finish; a turn started after that resumes it.
    private func childEvent(_ fields: Fields, id: String, link: Link, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        let agent = AgentRef.subagent(id)
        if let model = fields.block("model"), model != state.model {
            state.model = model
            out.append(.agentSpawned(id: id, parent: link.parent, spec: AgentSpec(modelID: model)))
        }
        switch fields.block("kind") {
        case "invocation.pre":
            guard fields.integer("invocation_num") == 0 else { break }
            if state.awaitsWakeup {
                state.awaitsWakeup = false
                break
            }
            closeCalls(of: agent, &state, &out)
            if state.child?.finished == true {
                state.child?.finished = false
                out.append(.agentResumed(id: id))
            }
            state.turn = Turn()

        case "tool.pre", "tool.post":
            toolEvent(fields, of: agent, &state, &out)

        case "turn.stop":
            if fields.boolean("fully_idle") == false {
                state.awaitsWakeup = true
                break
            }
            state.turn = nil
            state.awaitsWakeup = false
            state.child?.finished = true
            out.append(.agentFinished(id: id))

        default:
            break
        }
        reportEffort(of: agent, &state, &out)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// Antigravity's effort levels on the five steps, the same name on the
    /// same step as Codex's. Unknown is not cleared: nothing is reported.
    private static let effortSteps = [
        "minimal": 1, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 5,
    ]

    /// The effort the model ID ends in, e.g. `high` of `gemini-4-neon-high`
    /// (contract §6, "Model"). No hook names it apart; the ID is still shown
    /// as it is. A model without a known suffix has no effort.
    static func effortLevel(model: String) -> EffortLevel? {
        guard let dash = model.lastIndex(of: "-"), dash != model.startIndex else { return nil }
        let name = String(model[model.index(after: dash)...])
        return effortSteps[name].flatMap { EffortLevel(step: $0, name: name) }
    }

    private func toolActivity(_ fields: Fields) -> ToolActivity? {
        guard let name = fields.block("tool_name") else { return nil }
        // At most one of them is mapped for a call, by its tool's name.
        let detail = fields.block("command").flatMap(Self.firstLine) ?? fields.block("file_path")
            ?? fields.block("spawn_role") ?? fields.block("spawn_type")
        return ToolActivity(name: name, detail: detail)
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

/// The target fields of one payload.
private struct Fields {
    private let result: MappingResult

    init(_ result: MappingResult) { self.result = result }

    /// A non-empty string core field.
    func core(_ name: String) -> String? { Self.string(result.core[JSONKey(name)]) }

    /// A non-empty string field of the `antigravity` block.
    func block(_ name: String) -> String? { Self.string(result.block[JSONKey(name)]) }

    func integer(_ name: String) -> Int? {
        guard case let .integer(value)? = result.block[JSONKey(name)] else { return nil }
        return Int(exactly: value)
    }

    func boolean(_ name: String) -> Bool? {
        guard case let .bool(value)? = result.block[JSONKey(name)] else { return nil }
        return value
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - State

private struct Turn {
    /// The user's prompt the turn started with, `nil` for a subagent's.
    var prompt: String?
    /// Calls started without an end yet, closed with the turn if it ends without a `Stop`.
    var openCalls: Set<String> = []
    /// The model whose effort was reported for this turn.
    var effortModel: String?
}

/// One envelope's hook, as far as the adapter needs it.
private struct Hook {
    let fields: Fields
    let receivedAt: Date
    let terminal: TerminalIdentifiers?
}

/// Where a linked subagent's events go.
private struct Link {
    let session: SessionKey
    let parent: AgentRef
}

/// What a subagent's conversation needs beyond a session's.
private struct Child {
    /// `nil` until the parent is known.
    var link: Link?
    /// The hooks before the link, in arrival order.
    var pending: [Hook] = []
    /// The newest the hooks named.
    var transcriptPath: String?
    /// Its turn ended fully idle; another one resumes it.
    var finished = false
    /// Linked with its transcript's prompt but without a spawn call, which
    /// may still come (`takeLinkedChild`).
    var awaitedSpawn: AwaitedSpawn?
}

/// What a spawn call that arrives after its subagent linked is matched by.
private struct AwaitedSpawn {
    /// The parent's conversation.
    let parent: String
    let prompt: String
}

/// An `invoke_subagent` call no subagent was matched to yet.
private struct Spawn {
    let type: String?
    let role: String?
    let prompt: String?
    let model: String?
}

private struct SessionState {
    /// The newest `receivedAt` of the session's envelopes.
    var lastSeen: Date
    /// Set for a subagent's conversation (`last_user_input` empty on its
    /// first hook), until it is shown as a session of its own.
    var child: Child?
    /// The conversation's `invoke_subagent` calls, oldest first.
    var spawns: [Spawn] = []
    /// The model last emitted.
    var model: String?
    /// The terminal last reported, `nil` inside when it was reported gone;
    /// `nil` before the first report.
    var terminal: TerminalIdentifiers??
    /// The turn that started and got no fully idle `Stop` yet.
    var turn: Turn?
    /// The turn's last `Stop` wasn't fully idle: its next start is a wakeup.
    var awaitsWakeup = false
}
