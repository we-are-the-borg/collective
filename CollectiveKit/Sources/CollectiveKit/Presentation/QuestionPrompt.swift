import Foundation

/// What an agent asks the user, as the card under "Question for you" and the
/// notification show it: the first open question with its options,
/// and how many more wait. The app can read a question, not answer it, so
/// the options are no buttons and Terminal takes the answer.
public struct QuestionPrompt: Sendable, Equatable {
    /// The question's short label as the source gives it; the view
    /// uppercases it. Nil without one.
    public let header: String?
    public let text: String
    /// Whether the user may pick more than one option (`multiSelectHint`).
    public let allowsMultiple: Bool
    /// Whether the user may type an answer of their own (`Question.allowsOwnAnswer`).
    public let allowsOwnAnswer: Bool
    /// The options numbered from 1 as Terminal numbers them, "Other" last if
    /// the source offers an own answer; empty for a question without options,
    /// which leaves nothing to number.
    public let choices: [QuestionChoice]
    /// Every open question of the session, this one included: the pill's count.
    public let count: Int
    /// The app the hints send the user to, e.g. "Warp"; nil says "Terminal".
    let appName: String?

    /// The open questions of `session` that are not archived, nil without
    /// any. The orchestrator's come first, else those of the subagent that
    /// asked last, as for a permission request; the rest only count.
    /// - Parameter appName: The app that shows the session's terminal
    ///   (`TerminalAction.appName`), named in the hints.
    init?(_ session: Session, archive: SessionArchive, appName: String? = nil) {
        let requests = session.questionRequests
            .filter { ref, request in !request.questions.isEmpty && session.awaitsAnswer(ref) && !archive.isArchived(ref) }
            .sorted { lhs, rhs in
                if (lhs.key == .root) != (rhs.key == .root) { return lhs.key == .root }
                if lhs.value.date != rhs.value.date { return lhs.value.date > rhs.value.date }
                return lhs.key.sortKey < rhs.key.sortKey
            }
        guard let first = requests.first else { return nil }
        self.init(first.value.questions, count: requests.reduce(0) { $0 + $1.value.questions.count }, appName: appName)
    }

    /// The first of `questions`, nil without any.
    /// - Parameters:
    ///   - count: The open questions in all; `questions.count` when nil.
    ///   - appName: The app named in the hints; nil says "Terminal".
    init?(_ questions: [Question], count: Int? = nil, appName: String? = nil) {
        guard let question = questions.first else { return nil }
        header = question.header.flatMap { $0.isEmpty ? nil : $0 }
        text = question.text
        allowsMultiple = question.allowsMultiple
        allowsOwnAnswer = question.allowsOwnAnswer
        let options = question.options.enumerated().map { QuestionChoice(number: $0.offset + 1, label: .option($0.element.label), detail: $0.element.detail.flatMap { $0.isEmpty ? nil : $0 }) }
        choices = options.isEmpty || !allowsOwnAnswer ? options : options + [QuestionChoice(number: options.count + 1, label: .other, detail: nil)]
        self.count = count ?? questions.count
        self.appName = appName
    }

    /// How many open questions the card does not show.
    public var moreCount: Int { count - 1 }

    /// The restyled box shows at most this many lines of the question.
    public static let questionLineLimit = 4

    /// The restyled box's options: the agent's own, without "Other".
    public var listedOptions: [QuestionChoice] { choices.filter { $0.label != .other } }

    /// "Choose any" under the question, only for a multi-select one: the
    /// numbered options say "choose one" already.
    public var multiSelectHint: LocalizedStringResource? {
        allowsMultiple ? .kit("Choose any", defaultValue: "Choose any") : nil
    }

    /// The restyled box's "+1 more" under the options; nil while only this one is open.
    public var moreLine: LocalizedStringResource? {
        moreCount > 0 ? .kit("+%lld more", defaultValue: "+\(moreCount) more") : nil
    }

    public var textRole: ThemeRole { .text }
    /// The option's number, in mono.
    public var numberRole: ThemeRole { .textSubtle }
    public var labelRole: ThemeRole { .text }
    public var moreRole: ThemeRole { .textSubtle }
    /// `multiSelectHint`.
    public var hintRole: ThemeRole { .textSubtle }

    /// "+1 more question" under the options; nil while only this one is open.
    public var moreText: LocalizedStringResource? {
        moreCount > 0 ? .kit("+%lld more questions", defaultValue: "+\(moreCount) more questions") : nil
    }

    /// The card's last line; it mentions an own answer only if the source takes one,
    /// and no number when there is nothing to pick.
    public var answerHint: LocalizedStringResource {
        if let appName {
            if choices.isEmpty { return .kit("Answer in %@.", defaultValue: "Answer in \(appName).") }
            return allowsOwnAnswer
                ? .kit("Answer in %@: type a number or your own answer.", defaultValue: "Answer in \(appName): type a number or your own answer.")
                : .kit("Answer in %@: type a number.", defaultValue: "Answer in \(appName): type a number.")
        }
        if choices.isEmpty { return .kit("Answer in Terminal.", defaultValue: "Answer in Terminal.") }
        return allowsOwnAnswer
            ? .kit("Answer in Terminal: type a number or your own answer.", defaultValue: "Answer in Terminal: type a number or your own answer.")
            : .kit("Answer in Terminal: type a number.", defaultValue: "Answer in Terminal: type a number.")
    }

    /// What VoiceOver reads for the question after the card's label:
    /// "Mapping, choose one: Which revision …? Options: 1 Revision 5, Bundled
    /// today; 2 Revision 6; 3 Other. +1 more question. Answer in Terminal."
    /// Without an own answer the options end with the agent's last.
    public var accessibilityText: LocalizedStringResource {
        let asked: LocalizedStringResource = switch (header, allowsMultiple) {
        case let (header?, false): .kit("%@, choose one: %@", defaultValue: "\(header), choose one: \(text)")
        case let (header?, true): .kit("%@, choose any: %@", defaultValue: "\(header), choose any: \(text)")
        case (nil, false): .kit("Choose one: %@", defaultValue: "Choose one: \(text)")
        case (nil, true): .kit("Choose any: %@", defaultValue: "Choose any: \(text)")
        }
        let answer: LocalizedStringResource = if let moreText, let appName {
            .kit("%@. Answer in %@.", defaultValue: "\(moreText). Answer in \(appName).")
        } else if let moreText {
            .kit("%@. Answer in Terminal.", defaultValue: "\(moreText). Answer in Terminal.")
        } else if let appName {
            .kit("Answer in %@.", defaultValue: "Answer in \(appName).")
        } else {
            .kit("Answer in Terminal.", defaultValue: "Answer in Terminal.")
        }
        guard let last = choices.last else {
            return .kit("%@ %@", defaultValue: "\(asked) \(answer)")
        }
        // The options' labels and descriptions are the agent's own words, not
        // catalog texts; only "Other" is translated.
        let options = choices.compactMap { choice in
            choice.optionLabel.map { label in
                "\(choice.number) " + ([label] + [choice.detail].compactMap { $0 }).joined(separator: ", ")
            }
        }.joined(separator: "; ")
        guard last.label == .other else {
            return .kit("%@ Options: %@. %@", defaultValue: "\(asked) Options: \(options). \(answer)")
        }
        return .kit(
            "%@ Options: %@; %lld %@. %@",
            defaultValue: "\(asked) Options: \(options); \(last.number) \(QuestionChoice.otherText). \(answer)"
        )
    }
}

/// One numbered entry under a question.
public struct QuestionChoice: Sendable, Equatable {
    /// What the user types in Terminal to pick it.
    public let number: Int
    public let label: Label
    /// What the option means, in the agent's words; nil for "Other" and for
    /// an option the source does not describe.
    public let detail: String?

    public enum Label: Sendable, Equatable {
        /// One of the agent's options, its label in the agent's words.
        case option(String)
        /// The user's own answer (`QuestionChoice.otherText`).
        case other
    }

    /// The last choice, for an answer of the user's own.
    public static var otherText: LocalizedStringResource { .kit("Other", defaultValue: "Other") }

    var optionLabel: String? {
        if case let .option(label) = label { label } else { nil }
    }
}

extension AgentRef {
    /// A tiebreak for subagents that asked or started in the same second.
    var sortKey: String {
        switch self {
        case .root: ""
        case let .subagent(id): id
        }
    }
}
