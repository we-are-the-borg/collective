import Foundation
import SubspaceKit

/// How long a turn must have lasted for its end to notify, counted
/// from the user's last input to the session. The raw value is what the app
/// persists; the cases are in the order of the settings window's popup.
public enum TurnFinishedAfter: String, CaseIterable, Sendable, Equatable {
    /// Every turn's end, as before the threshold existed.
    case always
    case oneMinute
    case threeMinutes
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case never

    public static let `default`: TurnFinishedAfter = .fiveMinutes

    /// Nil for `always` and `never`, which don't measure.
    var interval: TimeInterval? {
        switch self {
        case .always, .never: nil
        case .oneMinute: 60
        case .threeMinutes: 3 * 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        }
    }

    /// The entry in the settings window's popup.
    public var optionText: LocalizedStringResource {
        switch self {
        case .always: .kit("Always", defaultValue: "Always")
        case .oneMinute: .kit("After 1 minute", defaultValue: "After 1 minute")
        case .threeMinutes: .kit("After 3 minutes", defaultValue: "After 3 minutes")
        case .fiveMinutes: .kit("After 5 minutes", defaultValue: "After 5 minutes")
        case .tenMinutes: .kit("After 10 minutes", defaultValue: "After 10 minutes")
        case .thirtyMinutes: .kit("After 30 minutes", defaultValue: "After 30 minutes")
        case .never: .kit("Never", defaultValue: "Never")
        }
    }
}

/// What the user wants to be notified of. Tools are muted rather than
/// enabled, so a tool added later notifies without the user turning it on.
public struct NotificationPreferences: Sendable, Equatable {
    /// An agent asks the user to allow a tool call.
    public var permission: Bool
    /// An agent asks the user a question.
    public var question: Bool
    /// The orchestrator ended its turn regularly, after at least this long.
    public var turnFinishedAfter: TurnFinishedAfter
    /// Tests only: replaces the threshold of `turnFinishedAfter`, as the
    /// captured turns last seconds, not minutes. Never stored.
    var turnFinishedAfterSeconds: TimeInterval? = nil
    public var sound: Bool
    public var mutedSources: Set<SourceID>

    public init(
        permission: Bool = true, question: Bool = true, turnFinishedAfter: TurnFinishedAfter = .default, sound: Bool = true,
        mutedSources: Set<SourceID> = []
    ) {
        self.permission = permission
        self.question = question
        self.turnFinishedAfter = turnFinishedAfter
        self.sound = sound
        self.mutedSources = mutedSources
    }

    public func notifies(for source: SourceID) -> Bool {
        !mutedSources.contains(source)
    }

    public mutating func setNotifies(_ notifies: Bool, for source: SourceID) {
        if notifies { mutedSources.remove(source) } else { mutedSources.insert(source) }
    }

    /// Whether a regular turn end notifies when the turn lasted `duration`
    /// since the user's last input; nil when neither that nor the turn's
    /// start is known, which only `always` notifies. The thresholds are
    /// positive, so an end before the input (hooks run async) never does.
    func notifiesTurnFinished(lasting duration: TimeInterval?) -> Bool {
        if turnFinishedAfter == .never { return false }
        if turnFinishedAfterSeconds == nil, turnFinishedAfter == .always { return true }
        guard let threshold = turnFinishedAfterSeconds ?? turnFinishedAfter.interval, let duration else { return false }
        return duration >= threshold
    }

    private enum Key {
        static let permission = "permission"
        static let question = "question"
        static let turnFinishedAfter = "turnFinishedAfter"
        /// The on/off switch the threshold replaced; only read, to migrate it.
        static let turnFinished = "turnFinished"
        static let sound = "sound"
        static let mutedSources = "mutedSources"
    }

    /// The preferences as the app persists them; a missing or damaged value
    /// falls back to its default, as does one stored before it existed.
    public init(fromStored stored: Any?) {
        let dictionary = stored as? [String: Any] ?? [:]
        let defaults = NotificationPreferences()
        self.init(
            permission: dictionary[Key.permission] as? Bool ?? defaults.permission,
            question: dictionary[Key.question] as? Bool ?? defaults.question,
            turnFinishedAfter: Self.turnFinishedAfter(in: dictionary),
            sound: dictionary[Key.sound] as? Bool ?? defaults.sound,
            mutedSources: Set((dictionary[Key.mutedSources] as? [String] ?? []).map(SourceID.init(rawValue:)))
        )
    }

    /// The stored threshold; without one, the on/off switch it replaced: on
    /// notified every turn's end, which `always` keeps.
    private static func turnFinishedAfter(in dictionary: [String: Any]) -> TurnFinishedAfter {
        if let stored = dictionary[Key.turnFinishedAfter] {
            return (stored as? String).flatMap(TurnFinishedAfter.init(rawValue:)) ?? .default
        }
        return dictionary[Key.turnFinished] as? Bool == true ? .always : .default
    }

    /// A property list for `UserDefaults`, sources by `SourceID` raw value.
    public var stored: [String: Any] {
        [
            Key.permission: permission,
            Key.question: question,
            Key.turnFinishedAfter: turnFinishedAfter.rawValue,
            Key.sound: sound,
            Key.mutedSources: mutedSources.map(\.rawValue).sorted(),
        ]
    }
}

/// A macOS notification the app should post, with its texts resolved.
public struct NotificationWish: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case permission
        case question
        case turnFinished
    }

    /// Stable for what it reports, so the app posts and withdraws by it.
    public let id: String
    public let kind: Kind
    public let session: SessionKey
    /// The same for all of a session's notifications, so they group.
    public let threadID: String
    /// The session's card title (`Session.title`).
    public let title: String
    /// The tool's display name.
    public let subtitle: String
    public let body: String
    public let playsSound: Bool
}

/// What one batch or sweep asks the app to do with notifications.
public struct NotificationPlan: Sendable, Equatable {
    public var wishes: [NotificationWish]
    /// Ids of notifications posted earlier that report something over now.
    public var withdrawals: [String]

    public init(wishes: [NotificationWish] = [], withdrawals: [String] = []) {
        self.wishes = wishes
        self.withdrawals = withdrawals
    }
}

/// Decides which notifications the events of a batch call for, and which
/// posted ones are over. It applies the batch to the state itself: whether a
/// request is new and a turn's end still current only shows while applying.
///
/// It starts disarmed. The spool's backlog at start reports what happened
/// while the app wasn't watching, so the app arms it at
/// `SpoolReader.Output.backlogFinished` and disarms it whenever the reader
/// starts over (folder change, clear). Disarmed, batches change the state
/// but neither notify nor withdraw, and nothing is noted for later.
public struct NotificationPlanner: Sendable {
    /// Older events were delivered late, e.g. by a spool the app just found;
    /// a notification for them would only puzzle.
    static let freshness: TimeInterval = 5 * 60
    /// How much of a reply a notification shows; the system cuts it further.
    static let replyLimit = 300

    public private(set) var isArmed = false
    private let locale: Locale
    /// What the app was asked to post and not yet to withdraw, by id.
    private var delivered: [String: Delivered] = [:]

    /// - Parameter locale: The language of the texts.
    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Starts notifying. Returns the notifications posted before a restart
    /// that the state read meanwhile shows to be over.
    public mutating func arm(_ state: CollectiveState) -> [String] {
        isArmed = true
        return reconcile(state)
    }

    public mutating func disarm() {
        isArmed = false
    }

    /// Applies `batch` to `state` and plans the notifications it calls for.
    /// - Parameters:
    ///   - now: Events older than `freshness` before it notify nothing.
    ///   - sourceNames: Display names per source, from the registered
    ///     adapters; a source without one shows its raw id.
    public mutating func apply(
        _ batch: [AgentEvent], to state: inout CollectiveState, now: Date,
        preferences: NotificationPreferences, sourceNames: [SourceID: String]
    ) -> NotificationPlan {
        guard isArmed else {
            batch.forEach { state.apply($0) }
            return NotificationPlan()
        }
        let awaitedBefore = Self.awaitedRequests(in: state)
        let dialogsBefore = Self.awaitedDialogs(in: state)
        var turnEnds: [TurnEnd] = []
        var requests: [(request: PermissionRequest, tool: ToolActivity)] = []
        var asks: [(key: SessionKey, agent: AgentRef)] = []
        let oldest = now.addingTimeInterval(-Self.freshness)
        for event in batch {
            state.apply(event)
            guard event.timestamp >= oldest else { continue }
            switch event.kind {
            case .turnEnded(.completed):
                // An end older than the turn's start is the turn before's, arrived late.
                guard let session = state.sessions[event.session] else { break }
                if let start = session.turnStartedAt, event.timestamp < start { break }
                turnEnds.append(TurnEnd(
                    key: event.session, turnStart: session.turnStartedAt,
                    lastInput: session.lastInputAt ?? session.turnStartedAt, endedAt: event.timestamp
                ))
            case let .permissionRequested(agent, tool):
                requests.append((PermissionRequest(key: event.session, agent: agent, requestedAt: event.timestamp), tool))
            case let .questionAsked(agent, _, _):
                asks.append((event.session, agent))
            default:
                break
            }
        }

        let withdrawals = reconcile(state)
        var wishes: [NotificationWish] = []
        for end in turnEnds where preferences.notifiesTurnFinished(lasting: end.duration) && preferences.notifies(for: end.key.source) {
            guard let session = state.shownSession(end.key), end.isCurrent(in: session), !state.isArchived(end.key),
                  !delivered.values.contains(where: { $0.turn == end.turn }) else { continue }
            let wish = turnFinishedWish(end, session: session, preferences: preferences, sourceNames: sourceNames)
            delivered[wish.id] = .turnFinished(end)
            wishes.append(wish)
        }
        for (request, tool) in requests where preferences.permission && preferences.notifies(for: request.key.source) {
            guard let session = state.shownSession(request.key), request.isAwaited(in: session),
                  !awaitedBefore.contains(request), !state.isArchived(request.agent, in: request.key),
                  !delivered.values.contains(.permission(request)) else { continue }
            let wish = permissionWish(request, tool: tool, session: session, preferences: preferences, sourceNames: sourceNames)
            delivered[wish.id] = .permission(request)
            wishes.append(wish)
        }
        // Asked for what the agent asks once the batch is applied: one dialog
        // asks more than once, and each ask moves the request's time.
        for (key, agent) in asks where preferences.question && preferences.notifies(for: key.source) {
            guard let session = state.shownSession(key), let dialog = QuestionDialog(key: key, agent: agent, in: session),
                  !dialogsBefore.contains(where: dialog.isSame), !state.isArchived(agent, in: key),
                  !delivered.values.contains(where: { $0.dialog.map(dialog.isSame) == true }),
                  let wish = questionWish(dialog, session: session, preferences: preferences, sourceNames: sourceNames) else { continue }
            delivered[wish.id] = .question(dialog)
            wishes.append(wish)
        }
        return NotificationPlan(wishes: wishes, withdrawals: withdrawals)
    }

    /// The posted notifications `state` shows to be over. For after the app's
    /// sweep, which can end or drop a session without any event, and after
    /// the user archived something: archiving says they have seen to it. A
    /// session no longer shown (`CollectiveState.shownSessions`) keeps none.
    public mutating func reconcile(_ state: CollectiveState) -> [String] {
        guard isArmed else { return [] }
        let over = delivered.filter { _, delivered in
            switch delivered {
            case let .permission(request):
                state.shownSession(request.key).map(request.isAwaited) != true
                    || state.isArchived(request.agent, in: request.key)
            case let .question(dialog):
                state.shownSession(dialog.key).map(dialog.isAwaited) != true
                    || state.isArchived(dialog.agent, in: dialog.key)
            case let .turnFinished(end):
                state.shownSession(end.key).map(end.isCurrent) != true || state.isArchived(end.key)
            }
        }.keys.sorted()
        over.forEach { delivered[$0] = nil }
        return over
    }

    // MARK: Texts

    private func turnFinishedWish(
        _ end: TurnEnd, session: Session, preferences: NotificationPreferences, sourceNames: [SourceID: String]
    ) -> NotificationWish {
        let start = end.turnStart.map { "\(Self.milliseconds($0))" } ?? "end-\(Self.milliseconds(end.endedAt))"
        let reply = session.root.reply.flatMap(ReplyPreview.init)?.multiline ?? ""
        return wish(
            id: "turn-finished|\(Self.path(of: end.key))|\(start)", kind: .turnFinished, session: session,
            body: reply.isEmpty ? text(.kit("Finished its turn", defaultValue: "Finished its turn")) : Self.cut(reply),
            preferences: preferences, sourceNames: sourceNames
        )
    }

    private func permissionWish(
        _ request: PermissionRequest, tool: ToolActivity, session: Session,
        preferences: NotificationPreferences, sourceNames: [SourceID: String]
    ) -> NotificationWish {
        let name = tool.name
        let detail = tool.detail.flatMap { $0.isEmpty ? nil : $0 }
        let body: LocalizedStringResource
        switch request.agent {
        case .root:
            body = if let detail {
                .kit("Needs your permission: %@ · %@", defaultValue: "Needs your permission: \(name) · \(detail)")
            } else {
                .kit("Needs your permission: %@", defaultValue: "Needs your permission: \(name)")
            }
        case .subagent:
            if let type = session.agents[request.agent]?.spec.type, !type.isEmpty {
                body = if let detail {
                    .kit("%@ needs your permission: %@ · %@", defaultValue: "\(type) needs your permission: \(name) · \(detail)")
                } else {
                    .kit("%@ needs your permission: %@", defaultValue: "\(type) needs your permission: \(name)")
                }
            } else {
                body = if let detail {
                    .kit("A subagent needs your permission: %@ · %@", defaultValue: "A subagent needs your permission: \(name) · \(detail)")
                } else {
                    .kit("A subagent needs your permission: %@", defaultValue: "A subagent needs your permission: \(name)")
                }
            }
        }
        return wish(
            id: "permission|\(Self.path(of: request.key))|\(Self.agentPath(request.agent))|\(Self.milliseconds(request.requestedAt))",
            kind: .permission, session: session, body: text(body),
            preferences: preferences, sourceNames: sourceNames
        )
    }

    /// "Question for you: <text>", the options numbered as Terminal numbers
    /// them, and how many more questions the dialog asks, one line each.
    private func questionWish(
        _ dialog: QuestionDialog, session: Session, preferences: NotificationPreferences, sourceNames: [SourceID: String]
    ) -> NotificationWish? {
        guard let prompt = QuestionPrompt(dialog.questions) else { return nil }
        let question = prompt.text
        let asked: LocalizedStringResource = switch dialog.agent {
        case .root:
            .kit("Question for you: %@", defaultValue: "Question for you: \(question)")
        case .subagent:
            if let type = session.agents[dialog.agent]?.spec.type, !type.isEmpty {
                .kit("%@ has a question for you: %@", defaultValue: "\(type) has a question for you: \(question)")
            } else {
                .kit("A subagent has a question for you: %@", defaultValue: "A subagent has a question for you: \(question)")
            }
        }
        var lines = [text(asked)]
        if !prompt.choices.isEmpty {
            lines.append(prompt.choices.map { choice in
                switch choice.label {
                case let .option(label): "\(choice.number) \(label)"
                case .other: "\(choice.number) \(text(QuestionChoice.otherText))"
                }
            }.joined(separator: " · "))
        }
        if let more = prompt.moreText { lines.append(text(more)) }
        return wish(
            id: "question|\(Self.path(of: dialog.key))|\(Self.agentPath(dialog.agent))|\(Self.milliseconds(dialog.askedAt))",
            kind: .question, session: session, body: lines.joined(separator: "\n"),
            preferences: preferences, sourceNames: sourceNames
        )
    }

    private func wish(
        id: String, kind: NotificationWish.Kind, session: Session, body: String,
        preferences: NotificationPreferences, sourceNames: [SourceID: String]
    ) -> NotificationWish {
        NotificationWish(
            id: id, kind: kind, session: session.key, threadID: "session|\(Self.path(of: session.key))",
            title: session.title, subtitle: sourceNames[session.key.source] ?? session.key.source.rawValue,
            body: body, playsSound: preferences.sound
        )
    }

    private func text(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// A reply cut to `replyLimit` characters, between two words unless that
    /// would drop much more, the cut marked.
    static func cut(_ reply: String) -> String {
        guard reply.count > replyLimit else { return reply }
        var kept = reply.prefix(replyLimit - 1)
        if !reply[kept.endIndex].isWhitespace, let space = kept.lastIndex(where: \.isWhitespace),
           kept.distance(from: space, to: kept.endIndex) <= 30 {
            kept = kept[..<space]
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func path(of key: SessionKey) -> String {
        "\(key.source.rawValue)|\(key.sessionID)"
    }

    private static func agentPath(_ agent: AgentRef) -> String {
        switch agent {
        case .root: "root"
        case let .subagent(id): "subagent:\(id)"
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: What was posted

    private static func awaitedRequests(in state: CollectiveState) -> Set<PermissionRequest> {
        Set(state.sessions.values.flatMap { session in
            session.permissionRequests.compactMap { agent, date in
                let request = PermissionRequest(key: session.key, agent: agent, requestedAt: date)
                return request.isAwaited(in: session) ? request : nil
            }
        })
    }

    /// The dialogs open before a batch, so asking again is no new one.
    private static func awaitedDialogs(in state: CollectiveState) -> [QuestionDialog] {
        state.sessions.values.flatMap { session in
            session.questionRequests.keys.compactMap { QuestionDialog(key: session.key, agent: $0, in: session) }
        }
    }

    private enum Delivered: Sendable, Equatable {
        case permission(PermissionRequest)
        case question(QuestionDialog)
        case turnFinished(TurnEnd)

        var dialog: QuestionDialog? {
            guard case let .question(dialog) = self else { return nil }
            return dialog
        }

        var turn: Turn? {
            guard case let .turnFinished(end) = self else { return nil }
            return end.turn
        }
    }

    /// One request of one agent; a later one of the same agent is another.
    private struct PermissionRequest: Sendable, Hashable {
        let key: SessionKey
        let agent: AgentRef
        let requestedAt: Date

        /// Still the agent's open request: not answered, not replaced by a
        /// newer one, and the agent still alive to be answered.
        func isAwaited(in session: Session) -> Bool {
            session.permissionRequests[agent] == requestedAt && session.awaitsPermission(agent)
        }
    }

    /// The questions one agent asks in one dialog. Unlike a permission
    /// request it is not known by its time: a source may report one dialog
    /// more than once, e.g. with the call's start and again as the dialog
    /// opens, and each report moves the request's time. The questions tell
    /// dialogs apart, and the call once both name one.
    private struct QuestionDialog: Sendable, Equatable {
        let key: SessionKey
        let agent: AgentRef
        let questions: [Question]
        let callID: String?
        /// When it was last asked when the planner saw it.
        let askedAt: Date

        /// What `agent` asks while it awaits the answer; nil when it asks nothing.
        init?(key: SessionKey, agent: AgentRef, in session: Session) {
            guard session.awaitsAnswer(agent), let request = session.questionRequests[agent], !request.questions.isEmpty else { return nil }
            self.key = key
            self.agent = agent
            questions = request.questions
            callID = request.callID
            askedAt = request.date
        }

        func isSame(_ other: QuestionDialog) -> Bool {
            key == other.key && agent == other.agent && questions == other.questions
                && (callID == nil || other.callID == nil || callID == other.callID)
        }

        /// Still open: the agent asks the same and awaits the answer.
        func isAwaited(in session: Session) -> Bool {
            QuestionDialog(key: key, agent: agent, in: session).map(isSame) ?? false
        }
    }

    /// A turn of a session, known by its start; nil when its start was never seen.
    private struct Turn: Sendable, Hashable {
        let key: SessionKey
        let start: Date?
    }

    private struct TurnEnd: Sendable, Hashable {
        let key: SessionKey
        let turnStart: Date?
        /// What the turn's length counts from: the user's last input, else
        /// the turn's start. A hand-back starts a turn but is no input, so
        /// its turn counts from the prompt or answer before.
        let lastInput: Date?
        let endedAt: Date

        var turn: Turn { Turn(key: key, start: turnStart) }

        var duration: TimeInterval? { lastInput.map { endedAt.timeIntervalSince($0) } }

        /// The session still rests after this end: it neither ended nor
        /// started a turn since. Hook times are whole seconds, so a start in
        /// the end's second that came later counts as the next turn's.
        func isCurrent(in session: Session) -> Bool {
            guard session.endedAt == nil else { return false }
            guard let start = session.turnStartedAt, start != turnStart else { return true }
            return start < endedAt
        }
    }
}

extension SessionKey {
    private static let sourceKey = "source"
    private static let sessionIDKey = "sessionID"

    /// What a posted notification carries, so a click on it knows its session.
    public static func notificationUserInfo(for key: SessionKey) -> [String: String] {
        [sourceKey: key.source.rawValue, sessionIDKey: key.sessionID]
    }

    /// The session a clicked notification was posted for; nil for one that
    /// names none, e.g. posted by a build before notifications carried it.
    public init?(notificationUserInfo userInfo: [AnyHashable: Any]) {
        guard let source = userInfo[Self.sourceKey] as? String,
              let sessionID = userInfo[Self.sessionIDKey] as? String else { return nil }
        self.init(source: SourceID(rawValue: source), sessionID: sessionID)
    }
}
