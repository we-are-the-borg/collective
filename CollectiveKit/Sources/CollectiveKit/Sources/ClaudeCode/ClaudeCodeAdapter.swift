import Foundation
import SubspaceKit

public enum ClaudeCodeAdapterError: Error, Equatable {
    case notAJSONObject
    case missingField(String)
    /// Neither the root nor the app ships a usable `claude-code` mapping document.
    case noMapping
}

/// Translates Claude Code hook payloads (as wrapped by subspace) into `AgentEvent`s.
///
/// The payload is read only through the target fields of the `claude-code`
/// mapping document (subspace `docs/model.md` §3), so a renamed payload path is
/// absorbed by a new mapping revision. What the fields mean stays here.
///
/// Hooks run async, so events can arrive in any order. The adapter therefore keeps
/// per-session state and correlates by id (`session`, `agent`, `tool_call`),
/// never by arrival order. See subspace's `docs/contract.md`, §6.
///
/// A subagent is linked to the `Agent` call that started it (which carries its title,
/// prompt and parent) from the first source that answers: `parent_tool_use_id` on
/// the subagent hooks, its `agent-<id>.meta.json`, or `spawned_agent` of the
/// `Agent` call. Until then it is emitted without title, i.e. not yet assigned. Each
/// time more becomes known the adapter emits another `agentSpawned`, which the store
/// merges.
///
/// Claude Code's internal agents may send tool hooks without ever naming a type.
/// A subagent is therefore shown only once it identifies itself: by `SubagentStart`,
/// a hook carrying its `agent_type`, a typed `SubagentStop` or the `Agent` call that
/// names it. Until then its open tool is held back, and emitted then.
///
/// A subagent ends with `SubagentStop`, or with a `StopFailure` naming it when an
/// API error interrupts it; neither ends the orchestrator's turn. Its orchestrator
/// may resume it with `SendMessage`: a new `SubagentStart` of the same id, no new
/// `Agent` call. A start after the agent's newest stop is such a resume, and a
/// resumed subagent counts as a background one from then on.
public final class ClaudeCodeAdapter: PushAdapter {
    public let source: SourceID = "claude-code"
    public let displayName = "Claude Code"
    /// Lobe Icons' `claude.svg`.
    public let logoName: String? = "claude-code"
    public var modelNaming: any ModelNaming { ClaudeCodeModelNaming() }
    /// Claude Code finds a session only from its project folder, which the
    /// popover's command changes into first.
    public var resumeCommand: ResumeCommand? { ResumeCommand { ["claude", "--resume", $0] } }

    private let metaReader: any SubagentMetaReading
    private let mapping: MappingLoader
    private var sessions: [SessionKey: SessionState] = [:]
    /// The last known model of each `claude` process, by envelope `pid`. The
    /// model belongs to the process, not the session: `/clear` starts a new
    /// session without naming it (subspace `docs/model.md` §3.3, "Session
    /// model"). Kept apart from `sessions` because the old session's end may
    /// arrive before the new one's start.
    private var modelsByPID: [Int32: String] = [:]

    public init(
        metaReader: any SubagentMetaReading = FileSubagentMetaReader(),
        mapping: MappingLoader = ClaudeCodeAdapter.defaultMapping()
    ) {
        self.metaReader = metaReader
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

    /// `plugins/data/subspace-subspace` in Claude Code's config folder.
    private static func ownRoot(environment: [String: String], home: URL) -> URL {
        configDirectory(environment: environment, home: home)
            .appendingPathComponent("plugins/data/subspace-subspace", isDirectory: true)
    }

    /// `$CLAUDE_CONFIG_DIR` or `~/.claude`.
    static func configDirectory(environment: [String: String], home: URL) -> URL {
        environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    public func events(from envelope: Envelope) throws -> [AgentEvent] {
        let payload = try JSONValue(data: envelope.payload)
        guard case .object = payload else { throw ClaudeCodeAdapterError.notAJSONObject }
        guard let document = mappingDocument() else { throw ClaudeCodeAdapterError.noMapping }
        return try events(from: envelope, mapped: MappingInterpreter.apply(document, to: payload))
    }

    public func mappingDocument() -> MappingDocument? {
        mapping.document(named: "claude-code")
    }

    /// A tool's output is the bulk of the payloads; what the adapter needs of
    /// it comes as target fields of its own.
    public var excludedFields: Set<String> { ["tool_response"] }

    public func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent] {
        let fields = Fields(mapped)
        guard let sessionID = fields.core("session") else { throw ClaudeCodeAdapterError.missingField("session") }

        let key = SessionKey(source: source, sessionID: sessionID)
        var state = sessions[key] ?? SessionState()
        if let path = fields.block("transcript_path") { state.transcriptPath = path }

        var out: [AgentEvent.Kind] = []
        let kind = fields.block("kind")
        switch kind {
        case "session.start":
            out.append(.sessionStarted(cwd: fields.core("cwd"), pid: envelope.pid))
            // Also sent on `/compact`, possibly naming the model from before
            // a switch; the store orders by time.
            if let model = fields.block("model") {
                if let pid = envelope.pid { modelsByPID[pid] = model }
                out.append(.modelChanged(to: model, from: nil))
            } else if fields.block("start_source") == "clear" {
                if let model = envelope.pid.flatMap({ modelsByPID[$0] }) { out.append(.modelChanged(to: model, from: nil)) }
            } else if let pid = envelope.pid {
                // Never on a resume: that is a new process with a model of its own,
                // possibly on the pid of a crashed one that sent no `SessionEnd`.
                modelsByPID[pid] = nil
            }

        case "model.change":
            if let model = fields.block("to_model") {
                if let pid = envelope.pid { modelsByPID[pid] = model }
                out.append(.modelChanged(to: model, from: fields.block("from_model")))
            }

        case "turn.start":
            guard let prompt = fields.block("prompt") else { break }
            // The result of a background subagent comes back as a prompt the
            // user didn't type. The orchestrator works again; the shown prompt stays.
            let handBack = prompt.hasPrefix("<task-notification>") || prompt.hasPrefix("<agent-message ")
            out.append(handBack ? .turnStarted : .promptSubmitted(prompt))

        case "tool.pre", "tool.post", "tool.failure":
            // Hooks run async, so a tool hook may come after the typeless stop that
            // dropped its agent. Whether typed or not, such a late hook must not
            // make the agent appear as working.
            if let id = fields.core("agent"), state.droppedStops.contains(id) { break }
            if fields.block("kind") == "tool.pre" {
                preToolUse(fields, &state, &out)
            } else {
                postToolUse(fields, at: envelope.receivedAt, &state, &out)
            }

        case "permission.request":
            if let id = fields.core("agent"), state.droppedStops.contains(id) { break }
            permissionRequest(fields, &state, &out)

        case "agent.start":
            guard let id = fields.core("agent") else { break }
            let agent = state.agent(id)
            agent.type = fields.block("agent_type")
            link(id, fields, &state)
            // A start after the agent's newest stop is its orchestrator
            // resuming it (`SendMessage`), with no new `Agent` call. Hook times
            // are whole seconds, so a stop in the same second may be this
            // run's own, delivered before its start: no resume then.
            let resumes = agent.stoppedAt.map { $0 < envelope.receivedAt } ?? false
            if resumes {
                agent.finished = false
                agent.resumedAt = max(agent.resumedAt ?? envelope.receivedAt, envelope.receivedAt)
            }
            flush(id, &state, &out)
            if resumes { out.append(.agentResumed(id: id)) }

        case "agent.stop":
            subagentStop(fields, at: envelope.receivedAt, &state, &out)
            endStoppedBackgroundAgents(fields, at: envelope.receivedAt, &state, &out)
            // An internal agent's stop stays unseen, its snapshot with it:
            // the next stop of the session lists the shells again.
            if fields.core("agent").map({ !state.droppedStops.contains($0) }) ?? true { listBackgroundShells(fields, &out) }

        case "turn.failure" where fields.core("agent") != nil:
            // A subagent interrupted by an API error (e.g. its spend limit)
            // ends with a `StopFailure` of its own instead of `SubagentStop`;
            // the orchestrator's turn goes on. `Stop` is only ever the
            // orchestrator's.
            subagentStop(fields, at: envelope.receivedAt, &state, &out)

        case "turn.stop", "turn.failure":
            if let reply = fields.reply { out.append(.replied(agent: .root, reply)) }
            out.append(.turnEnded(kind == "turn.failure" ? .failed : .completed))
            endStoppedBackgroundAgents(fields, at: envelope.receivedAt, &state, &out)
            listBackgroundShells(fields, &out)

        case "session.end":
            sessions[key] = nil
            // `/clear` keeps the process running; any other end lets the pid go.
            if fields.block("end_reason") != "clear", let pid = envelope.pid { modelsByPID[pid] = nil }
            return [AgentEvent(session: key, timestamp: envelope.receivedAt, kind: .sessionEnded, cwd: fields.core("cwd"), pid: envelope.pid,
                               terminal: Self.terminal(of: envelope))]

        default:
            break // unknown or irrelevant hook: ignored (contract §6)
        }

        retryUnlinked(&state, &out)
        reportEffort(fields, state, &out)
        sessions[key] = state
        // Every hook comes from the session's own process (contract §6).
        let terminal = Self.terminal(of: envelope)
        return out.map { AgentEvent(session: key, timestamp: envelope.receivedAt, kind: $0, cwd: fields.core("cwd"), pid: envelope.pid, terminal: terminal) }
    }

    /// The hook's terminal, an envelope field rather than one of the payload.
    /// Whether it is the session's own only the status file tells (contract
    /// §6, "Terminal"): a background session's hooks see the daemon's.
    private static func terminal(of envelope: Envelope) -> TerminalIdentifiers? {
        envelope.terminal.isEmpty ? nil : TerminalIdentifiers(envelope.terminal)
    }

    // MARK: Hooks

    private func preToolUse(_ fields: Fields, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let tool = fields.block("tool_name"), let toolUseID = fields.core("tool_call") else { return }
        let actor = fields.agentRef
        identify(fields, &state, &out)

        if fields.isSpawn {
            state.calls[toolUseID] = AgentCall(
                parent: actor,
                type: fields.block("spawn_type"),
                title: fields.block("spawn_description"),
                prompt: fields.block("spawn_prompt"),
                modelAlias: fields.block("spawn_model"),
                isBackground: fields.bool("spawn_background")
            )
            // Subagents that were linked to this call before the call arrived.
            for (agent, use) in state.toolUseByAgent where use == toolUseID { flush(agent, &state, &out) }
        }
        // A late `PreToolUse` after its `PostToolUse` still names the call,
        // but must not leave a tool running.
        let alreadyEnded = state.finishedTools.contains(toolUseID)
        let activity = ToolActivity(name: tool, detail: Self.detail(fields))
        if let id = fields.core("agent"), state.agents[id] == nil {
            if !alreadyEnded { state.openTools[id] = OpenTool(call: toolUseID, activity: activity) }
            return
        }
        out.append(.toolStarted(agent: actor, activity, callID: toolUseID, alreadyEnded: alreadyEnded))
        // Asked only while the call can still wait for the answer. An agent
        // not identified yet returned above: its questions are dropped like
        // its permission requests.
        if !alreadyEnded, let questions = Self.questions(fields) {
            out.append(.questionAsked(agent: actor, questions, callID: toolUseID))
        }
    }

    /// For `tool.post` and `tool.failure` alike: both end their `tool.pre`.
    private func postToolUse(_ fields: Fields, at time: Date, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        if let toolUseID = fields.core("tool_call") {
            state.finishedTools.insert(toolUseID)
            if let id = fields.core("agent"), state.openTools[id]?.call == toolUseID { state.openTools[id] = nil }
        }
        identify(fields, &state, &out)
        // The end of a held-back tool is held back with it.
        if fields.core("agent").map({ state.agents[$0] != nil }) ?? true {
            let duration = fields.integer("duration_ms").map { TimeInterval($0) / 1000 }
            out.append(.toolFinished(agent: fields.agentRef, callID: fields.core("tool_call"), duration: duration))
            if fields.block("kind") == "tool.post", let questions = Self.questions(fields) {
                out.append(.questionAnswered(agent: fields.agentRef, questions, callID: fields.core("tool_call")))
            }
        }
        // A `Bash` call with `run_in_background` posts at once, naming the
        // shell it left running (subspace `docs/model.md` §3.3). Not held
        // back with the tool: the shell is the session's whoever started it.
        if fields.block("kind") == "tool.post", let shellID = fields.block("spawned_shell") {
            out.append(.backgroundShellStarted(id: shellID))
        }

        // Source 3 of the subagent link: the `Agent` call names its subagent.
        // Only a successful call has started one.
        guard
            fields.block("kind") == "tool.post", fields.isSpawn,
            let toolUseID = fields.core("tool_call"),
            let agentID = fields.block("spawned_agent")
        else { return }
        state.agent(agentID)
        // Interactive sessions don't send `run_in_background`; a launch that
        // returns at once (`spawned_async`) is how a background subagent shows.
        if fields.bool("spawned_async") == true { state.asyncLaunches[toolUseID] = time }
        // A foreground subagent's stop comes before this; the flush below still updates it.
        if let model = fields.block("spawned_model") { state.spawnedModels[toolUseID] = model }
        if state.toolUseByAgent[agentID] == nil { state.toolUseByAgent[agentID] = toolUseID }
        flush(agentID, &state, &out)
    }

    /// Claude Code asks its questions through the permission dialog; they are
    /// no permission.
    private static let questionTools: Set<String> = ["AskUserQuestion"]

    private func permissionRequest(_ fields: Fields, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        identify(fields, &state, &out)
        guard let tool = fields.block("tool_name") else { return }
        // Unlike a tool start, the request of an agent not identified yet is
        // dropped, not held back: it carries no `tool_call`, so a held
        // request could not be matched to its call's end and might outlive it.
        if let id = fields.core("agent"), state.agents[id] == nil { return }
        // Asked again alongside the call's start; the store merges the two.
        if let questions = Self.questions(fields) {
            out.append(.questionAsked(agent: fields.agentRef, questions))
            return
        }
        guard !Self.questionTools.contains(tool) else { return }
        out.append(.permissionRequested(agent: fields.agentRef, ToolActivity(name: tool, detail: Self.detail(fields)).requesting(fields.block("command"))))
    }

    /// A tool hook that names the agent's type identifies an agent not known
    /// yet, e.g. one whose `SubagentStart` is still on its way.
    private func identify(_ fields: Fields, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let id = fields.core("agent"), state.agents[id] == nil, let type = fields.block("agent_type") else { return }
        state.agent(id).type = type
        link(id, fields, &state)
        flush(id, &state, &out)
    }

    /// For `SubagentStop` and a subagent's `StopFailure` alike.
    private func subagentStop(_ fields: Fields, at time: Date, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let id = fields.core("agent") else { return }
        let type = fields.block("agent_type")
        // Whatever it still had open ends with it.
        state.openTools[id] = nil
        // Claude Code's own agents (e.g. `/compact`) stop without ever starting
        // and without a type; they stay unseen.
        guard state.agents[id] != nil || type != nil else {
            state.droppedStops.insert(id)
            return
        }

        let agent = state.agent(id)
        if agent.type == nil { agent.type = type }
        // A stop strictly older than the resume is the run before's, arriving
        // late: the resumed run goes on, as in the store.
        if agent.resumedAt.map({ $0 <= time }) ?? true { agent.finished = true }
        agent.stoppedAt = max(agent.stoppedAt ?? time, time)
        link(id, fields, &state)
        // For a stop that arrived before its start this creates the agent first.
        flush(id, &state, &out)
        if let reply = fields.reply { out.append(.replied(agent: .subagent(id), reply)) }
        out.append(.agentFinished(id: id))
    }

    /// A background agent stopped by the user sends no `agent.stop`; it only
    /// drops out of `background_agents` (subspace `docs/model.md` §3.3). Only
    /// agents whose `Agent` call launched async or that were resumed are
    /// considered, so a foreground agent is never ended here.
    /// Hooks are written late and `ts` has whole seconds, so a snapshot from the
    /// same second as the launch or the resume may not list the agent yet.
    private func endStoppedBackgroundAgents(_ fields: Fields, at time: Date, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let running = fields.blockStrings("background_agents").map(Set.init) else { return }
        for (id, agent) in state.agents.sorted(by: { $0.key < $1.key }) where !agent.finished && !running.contains(id) {
            let runsSince = agent.resumedAt ?? state.toolUseByAgent[id].flatMap { state.asyncLaunches[$0] }
            guard let runsSince, runsSince < time else { continue }
            agent.finished = true
            // Its end, like a stop: a later start resumes it.
            agent.stoppedAt = max(agent.stoppedAt ?? time, time)
            out.append(.agentFinished(id: id))
        }
    }

    /// The snapshot of `background_shells` (subspace `docs/model.md` §3.2),
    /// after the hook's own events, which make the session known to the store.
    /// The entries are Claude Code's own objects, read defensively like the
    /// questions: one without an id is left out. Absent field, no listing.
    private func listBackgroundShells(_ fields: Fields, _ out: inout [AgentEvent.Kind]) {
        guard let entries = fields.blockObjects("background_shells") else { return }
        out.append(.backgroundShellsListed(entries.compactMap { entry in
            guard let id = Fields.string(entry["id"]) else { return nil }
            return BackgroundShell(id: id, command: Fields.string(entry["command"]), description: Fields.string(entry["description"]))
        }))
    }

    /// Claude Code's effort levels on the five steps; any
    /// other level is off the scale.
    private static let effortSteps = ["low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5]

    /// The level of the agent that fired the hook, its own or the one it
    /// inherits (subspace `docs/model.md` §3.3, "Effort"). An absent level is
    /// unknown, so it leaves a known one alone; `/effort` fires no hook, the
    /// next hook carrying the field shows the change. Last, since the store
    /// drops a report for an agent it doesn't know yet. An agent not
    /// identified or whose typeless stop was dropped gets none, as
    /// Claude Code's internal agents stay unseen; the next hook carries the
    /// level again, so nothing is held back.
    private func reportEffort(_ fields: Fields, _ state: SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let name = fields.block("effort"), let level = Self.effortSteps[name].flatMap({ EffortLevel(step: $0, name: name) }) else { return }
        if let id = fields.core("agent"), state.agents[id] == nil || state.droppedStops.contains(id) { return }
        out.append(.effortReported(agent: fields.agentRef, level))
    }

    // MARK: Linking subagents to their `Agent` call

    /// Sources 1 and 2: `parent_tool_use_id` on the hook, then the meta file.
    private func link(_ id: String, _ fields: Fields, _ state: inout SessionState) {
        guard state.toolUseByAgent[id] == nil else { return }
        if let toolUseID = fields.block("parent_tool_use_id") {
            state.toolUseByAgent[id] = toolUseID
            return
        }
        readMeta(id, &state)
    }

    private func readMeta(_ id: String, _ state: inout SessionState) {
        guard
            state.toolUseByAgent[id] == nil,
            let path = state.transcriptPath,
            let meta = metaReader.meta(transcriptPath: path, agentID: id)
        else { return }
        state.agent(id).meta = meta
        state.toolUseByAgent[id] = meta.toolUseID
    }

    /// The meta file may not exist yet when `SubagentStart` arrives. This can't
    /// block, so every later event of the session retries for agents still unlinked.
    private func retryUnlinked(_ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        for (id, agent) in state.agents where state.toolUseByAgent[id] == nil && !agent.finished {
            readMeta(id, &state)
            flush(id, &state, &out)
        }
    }

    /// Emits `agentSpawned` with everything known about the subagent, if that
    /// changed since the last emit, then the tool it had open before it was known.
    private func flush(_ id: String, _ state: inout SessionState, _ out: inout [AgentEvent.Kind]) {
        guard let agent = state.agents[id] else { return }
        let toolUseID = state.toolUseByAgent[id]
        let call = toolUseID.flatMap { state.calls[$0] }
        let launchedAsync = toolUseID.flatMap { state.asyncLaunches[$0] } != nil
        let spec = AgentSpec(
            type: agent.type ?? call?.type,
            title: call?.title ?? agent.meta?.description,
            prompt: call?.prompt,
            modelAlias: call?.modelAlias,
            modelID: toolUseID.flatMap { state.spawnedModels[$0] },
            // A resumed subagent runs on its own, however it was launched:
            // `SendMessage` returns at once.
            isBackground: agent.resumedAt != nil ? true : call?.isBackground ?? (launchedAsync ? true : agent.meta?.isBackground)
        )
        let parent = call?.parent ?? .root
        if agent.emitted != Emitted(spec: spec, parent: parent) {
            agent.emitted = Emitted(spec: spec, parent: parent)
            out.append(.agentSpawned(id: id, parent: parent, spec: spec))
        }
        if let open = state.openTools.removeValue(forKey: id) { out.append(.toolStarted(agent: .subagent(id), open.activity, callID: open.call)) }
    }

    // MARK: Helpers

    /// The one line shown for a tool call, its start and its permission request alike.
    private static func detail(_ fields: Fields) -> String? {
        fields.block("file_path").flatMap(firstLine) ?? fields.block("command").flatMap(firstLine)
            ?? inputDetail(fields.blockValue("tool_input"))
    }

    /// The questions of an `AskUserQuestion` call, each with its answer if the
    /// hook carries one, keyed by the question's text (subspace `docs/model.md`
    /// §3.3, "Questions"). The entries are Claude Code's own objects, so they
    /// are read defensively: a question without text or an option without
    /// label is left out, anything unexpected reads as absent.
    private static func questions(_ fields: Fields) -> [Question]? {
        guard let entries = fields.blockObjects("questions") else { return nil }
        let answers = fields.blockObject("answers") ?? [:]
        let questions = entries.compactMap { entry -> Question? in
            guard let text = Fields.string(entry["question"]) else { return nil }
            var options: [QuestionOption] = []
            if case let .array(values)? = entry["options"] {
                options = values.compactMap { value in
                    guard case let .object(option) = value, let label = Fields.string(option["label"]) else { return nil }
                    return QuestionOption(label: label, detail: Fields.string(option["description"]))
                }
            }
            var allowsMultiple = false
            if case let .bool(value)? = entry["multiSelect"] { allowsMultiple = value }
            return Question(
                header: Fields.string(entry["header"]),
                text: text,
                options: options,
                allowsMultiple: allowsMultiple,
                // Claude Code's dialog always ends with a free-text entry
                // ("Type something", subspace `docs/model.md` §3.3).
                allowsOwnAnswer: true,
                answer: Fields.string(answers[JSONKey(text)])
            )
        }
        return questions.isEmpty ? nil : questions
    }

    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// A short, one-line description of what a tool call works on, read from
    /// inside the opaque `tool_input` field (subspace `docs/model.md` §9). Besides
    /// `meta.json` this is the only place that knows Claude Code's payload format;
    /// if those keys drift, only the detail line goes blank. A `Bash` command
    /// comes from the target field `command` instead; these keys wait
    /// for target fields of their own.
    private static func inputDetail(_ input: JSONValue?) -> String? {
        guard case let .object(input)? = input else { return nil }
        for key in ["pattern", "url", "query", "description", "path"] {
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

    /// A non-empty string field of the `claude_code` block.
    func block(_ name: String) -> String? { Self.string(result.block[JSONKey(name)]) }

    func blockValue(_ name: String) -> JSONValue? { result.block[JSONKey(name)] }

    /// A block field that is an array of strings; `nil` when absent, non-string elements left out.
    func blockStrings(_ name: String) -> [String]? {
        guard case let .array(values)? = result.block[JSONKey(name)] else { return nil }
        return values.compactMap(Self.string)
    }

    /// A block field that is an array of objects; `nil` when absent, other elements left out.
    func blockObjects(_ name: String) -> [[JSONKey: JSONValue]]? {
        guard case let .array(values)? = result.block[JSONKey(name)] else { return nil }
        return values.compactMap { value in
            guard case let .object(object) = value else { return nil }
            return object
        }
    }

    func blockObject(_ name: String) -> [JSONKey: JSONValue]? {
        guard case let .object(object)? = result.block[JSONKey(name)] else { return nil }
        return object
    }

    func integer(_ name: String) -> Int64? {
        guard case let .integer(value)? = result.block[JSONKey(name)] else { return nil }
        return value
    }

    func bool(_ name: String) -> Bool? {
        guard case let .bool(value)? = result.block[JSONKey(name)] else { return nil }
        return value
    }

    /// What the agent said last, as sent; a blank message is no reply.
    var reply: String? { block("last_assistant_message").flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } }

    /// The agent a hook belongs to: `agent` is present only inside a subagent.
    var agentRef: AgentRef { core("agent").map(AgentRef.subagent) ?? .root }

    /// A call that starts a subagent. An absent or unknown `tool` is `other`.
    var isSpawn: Bool { core("tool") == "spawn_agent" }

    /// A non-empty string, also for values inside a field.
    static func string(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - State

private struct AgentCall {
    var parent: AgentRef
    /// `subagent_type` of the call, for a subagent whose hooks don't name its type.
    var type: String?
    var title: String?
    var prompt: String?
    /// `model` of the call, often an alias; absent when the subagent inherits.
    var modelAlias: String?
    var isBackground: Bool?
}

private struct OpenTool {
    /// `tool_use_id`, to match its end.
    var call: String
    var activity: ToolActivity
}

private struct Emitted: Equatable {
    var spec: AgentSpec
    var parent: AgentRef
}

private final class AgentInfo {
    var type: String?
    var meta: SubagentMeta?
    var finished = false
    /// The envelope `ts` of its newest stop, to tell a resume from a start
    /// delivered late.
    var stoppedAt: Date?
    /// Set once it was resumed; the newest resume.
    var resumedAt: Date?
    var emitted: Emitted?
}

private struct SessionState {
    var transcriptPath: String?
    /// `Agent` calls by their `tool_use_id`.
    var calls: [String: AgentCall] = [:]
    /// `agent_id` → `tool_use_id` of the `Agent` call that started it.
    var toolUseByAgent: [String: String] = [:]
    var agents: [String: AgentInfo] = [:]
    /// `Agent` calls that returned at once because the subagent runs in the background,
    /// with the envelope `ts` of their `PostToolUse`.
    var asyncLaunches: [String: Date] = [:]
    /// The full model each `Agent` call's subagent runs with, by `tool_use_id`.
    var spawnedModels: [String: String] = [:]
    /// Tool calls whose end was seen, to ignore a start that arrives late.
    var finishedTools: Set<String> = []
    /// The tool each agent not yet in `agents` has open. Claude Code's internal
    /// agents may send tool hooks and never identify themselves, so these are
    /// held back until the agent does. Kept apart from `agents` so such an
    /// agent gets no meta lookup or `agentSpawned` meanwhile.
    var openTools: [String: OpenTool] = [:]
    /// Agents whose typeless stop came before they identified themselves. Their
    /// later tool hooks are ignored, so none can identify them afterwards.
    var droppedStops: Set<String> = []

    @discardableResult
    mutating func agent(_ id: String) -> AgentInfo {
        if let existing = agents[id] { return existing }
        let created = AgentInfo()
        agents[id] = created
        return created
    }
}
