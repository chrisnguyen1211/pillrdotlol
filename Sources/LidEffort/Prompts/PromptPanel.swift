import AppKit
import SwiftUI

// MARK: - The answer being put together

/// Where a person is in answering a prompt's questions: which question is
/// up, and what has been picked or typed on each. Pure, so the flow is
/// tested without a view.
///
/// One question at a time, and a pick only ever picks: Continue moves on,
/// Send on the last question sends. Nothing moves or goes by itself — an
/// answer is looked over, or changed, before it is given. Skip moves on
/// without an answer; on the last question it sends
/// what there is, or hands the prompt back to Claude if there is nothing.
/// The step arrows move freely, and nothing picked is ever lost.
struct PromptDraft: Equatable {
    let questions: [PendingPrompt.Question]
    private(set) var index = 0
    private(set) var chosen: [String: [String]] = [:]
    private(set) var custom: [String: String] = [:]

    init(questions: [PendingPrompt.Question]) {
        self.questions = questions
    }

    var current: PendingPrompt.Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }
    var isLast: Bool { index >= questions.count - 1 }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < questions.count - 1 }

    /// "2 / 3" — the step counter's text.
    var position: String { "\(index + 1) / \(max(1, questions.count))" }

    /// Something picked, or something typed.
    var hasAnswer: Bool {
        guard let current else { return false }
        return !picks(for: current).isEmpty || !typed(for: current).isEmpty
    }

    func isPicked(_ label: String) -> Bool { current.map { picks(for: $0).contains(label) } ?? false }
    func isPicked(_ label: String, in question: PendingPrompt.Question) -> Bool { picks(for: question).contains(label) }
    func customText(for question: PendingPrompt.Question) -> String { custom[question.question] ?? "" }

    /// The card's title for the question on screen.
    func title(for prompt: PendingPrompt) -> String {
        if let header = current?.header, !header.isEmpty { return header }
        return prompt.title
    }

    /// The status line for the question on screen.
    func status(for prompt: PendingPrompt) -> String {
        guard let current else { return prompt.statusText }
        return current.multiSelect ? L10n.t("Pick one or more") : L10n.t("Pick one")
    }

    /// Every answer given so far, question → labels, typed text last. A
    /// question with nothing is left out: skipped.
    var collected: [String: [String]] {
        var out: [String: [String]] = [:]
        for question in questions {
            var answer = picks(for: question)
            let text = typed(for: question)
            if !text.isEmpty { answer.append(text) }
            if !answer.isEmpty { out[question.question] = answer }
        }
        return out
    }

    private func picks(for question: PendingPrompt.Question) -> [String] { chosen[question.question] ?? [] }
    private func typed(for question: PendingPrompt.Question) -> String {
        (custom[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A click on an option: the pick for a single-choice question (and
    /// whatever was typed goes), on or off for a multiple-choice one.
    mutating func toggle(_ label: String) {
        guard let question = current else { return }
        if question.multiSelect {
            var set = picks(for: question)
            if let i = set.firstIndex(of: label) { set.remove(at: i) } else { set.append(label) }
            // In the order the options were offered, not the order clicked.
            let order = question.options.map(\.label)
            chosen[question.question] = set.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        } else {
            chosen[question.question] = [label]
            custom[question.question] = nil
        }
    }

    /// Typing in "Something else…". On a single-choice question it replaces
    /// the pick — the answer is one or the other.
    mutating func setCustom(_ text: String) {
        guard let question = current else { return }
        custom[question.question] = text
        if !question.multiSelect, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chosen[question.question] = nil
        }
    }

    /// Continue, or Send on the last question. Nil until the current
    /// question has an answer, and while there are questions left.
    mutating func advance() -> PromptAnswer? {
        guard hasAnswer else { return nil }
        if isLast { return .answers(collected) }
        index += 1
        return nil
    }

    /// On without an answer; on the last question, send what there is — or,
    /// with nothing at all, let Claude ask in its own dialog.
    mutating func skip() -> PromptAnswer? {
        guard isLast else { index += 1; return nil }
        let answers = collected
        return answers.isEmpty ? .passThrough : .answers(answers)
    }

    /// The step arrows.
    mutating func go(by delta: Int) {
        index = min(max(0, index + delta), max(0, questions.count - 1))
    }

    mutating func back() { go(by: -1) }
}

/// Where the prompt on screen sits among the ones waiting.
struct PromptQueuePosition: Equatable {
    let index: Int
    let count: Int
}

/// ‹ 1/2 › — pages between sessions waiting on you at the same time.
struct PromptPager: View {
    let position: PromptQueuePosition
    let onPage: (Int) -> Void

    var body: some View {
        HStack(spacing: Design.px(6)) {
            Button { onPage(-1) } label: {
                Image(systemName: "chevron.left").frame(width: Design.px(28), height: Design.px(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("\(position.index + 1)/\(position.count)")
                .font(Typography.counter)
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
                .fixedSize()
            Button { onPage(1) } label: {
                Image(systemName: "chevron.right").frame(width: Design.px(28), height: Design.px(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: Design.px(18), weight: .medium))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Design.px(8))
        .frame(height: Design.px(40))
        .background(Capsule().fill(Palette.watch.opacity(0.18)))
        .help(L10n.t("\(position.count) sessions are waiting on you"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("Prompt \(position.index + 1) of \(position.count)"))
    }
}

// MARK: - Copy

extension PendingPrompt {
    /// What the status line says it is asking for.
    var statusText: String {
        if let question = questions.first {
            return question.multiSelect ? L10n.t("Pick one or more") : L10n.t("Pick one")
        }
        switch toolName {
        case "Bash": return L10n.t("Wants to run a command")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return L10n.t("Wants to change a file")
        case "Read": return L10n.t("Wants to read a file")
        case "WebFetch": return L10n.t("Wants to open a page")
        case "WebSearch": return L10n.t("Wants to search the web")
        case "ExitPlanMode": return L10n.t("Ready to start on the plan")
        default: return L10n.t("Wants to use \(toolName)")
        }
    }

    var title: String {
        if let header = questions.first?.header, !header.isEmpty { return header }
        return isQuestion ? L10n.t("Claude asks") : L10n.t("Needs your OK")
    }

    /// The session and where it runs, as the done card says it.
    var subtitle: String {
        let place = cwd.map { ($0 as NSString).lastPathComponent }
        let name = sessionName ?? context?.title
        let branch = context?.branch.map { "⎇ \($0)" }
        return [name, place, branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Layout

/// Every height here is computed, not measured after the fact: the notch
/// sizes its cards — and what takes the mouse — before anything is drawn.
/// The card fits the question on screen, so it grows and shrinks as the
/// questions go by.
enum PromptLayout {
    /// Extra clickable margin round the small icons, on every side.
    static let openSlop = Design.px(16)
    static let gap = Design.px(14)
    /// Between the question and its options.
    static let headingGap = Design.px(18)
    /// Between the options and the footer.
    static let footerGap = Design.px(22)
    static let footerHeight = Design.px(52)
    static let optionHeight = Design.px(46)
    static let optionGap = Design.px(4)
    /// Between questions in the sliding stack; never on screen at rest.
    static let slideGap = Design.px(60)
    static let maxOptions = 4
    static let wellInset = Design.px(14)
    /// The icons in the top corner — Open and Dismiss — which the heading
    /// keeps clear of…
    static let cornerWidth = Design.px(104)
    /// …and, in the tooltip, the pager between waiting sessions beside them.
    static let pagerWidth = Design.px(150)
    /// The panel's inset inside the tooltip well.
    static let panelInset = Design.px(18)

    /// The slide between questions: quick out, long settle.
    static let slide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)

    static let headingFont = Typography.headingNSFont

    /// Where a prompt is shown, which sets how wide its heading can be.
    enum Fit: Equatable {
        /// Beside the folded pill: the card's full width.
        case card
        /// In the tooltip's well, with the pager in the corner or not.
        case tooltip(pager: Bool)
    }

    /// The full width of the prompt's column: what the options and the
    /// command's well span.
    static func contentWidth(_ fit: Fit) -> CGFloat {
        switch fit {
        case .card: return NotchLayout.cardWidth - 2 * NotchLayout.cardPadding
        case .tooltip: return NotchLayout.cardWidth - 2 * NotchLayout.cardPadding - 2 * panelInset
        }
    }

    /// `underContext`: the context lines sit beside the corner's icons, so
    /// a question under them has the column's whole width.
    static func headingWidth(_ fit: Fit, underContext: Bool = false) -> CGFloat {
        if underContext { return contentWidth(fit) }
        switch fit {
        case .card:
            return contentWidth(fit) - cornerWidth
        case .tooltip(let pager):
            return contentWidth(fit) - cornerWidth - (pager ? pagerWidth : 0)
        }
    }

    /// How many lines `text` wraps to in `width`, at least one and at most
    /// `cap`. Everything below is sized from this before it is drawn, so the
    /// fonts here have to be the ones the views set the text in.
    static func lines(_ text: String, font: NSFont, width: CGFloat, cap: Int) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(cap, max(1, Int((bounds.height / lineHeight(font)).rounded(.up))))
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { NotchLayout.lineHeight(font) }

    /// The heading's own line: it is set larger than the body, and a
    /// height counted in body lines cut two-line questions down to one.
    static let headingLineHeight = NotchLayout.lineHeight(headingFont)

    /// A question is the thing being decided: it is shown whole, up to a
    /// length no one asks at. Three lines cut a question with its reasons
    /// in it down to its first clause, and the choices under it made no
    /// sense without the rest.
    static let headingMaxLines = 8

    static func headingLines(_ text: String, fit: Fit = .card, underContext: Bool = false) -> Int {
        lines(text, font: headingFont, width: headingWidth(fit, underContext: underContext), cap: headingMaxLines)
    }

    static func headingHeight(_ text: String, fit: Fit = .card, underContext: Bool = false) -> CGFloat {
        CGFloat(headingLines(text, fit: fit, underContext: underContext)) * headingLineHeight
    }

    // MARK: Options

    /// The label is measured in its picked weight, the wider of the two, so
    /// picking a choice never pushes it onto a line it was not given.
    static let optionLabelFont = NSFont.systemFont(ofSize: Typography.bodySize, weight: .medium)
    static let optionDetailFont = NSFont.systemFont(ofSize: Typography.size(12))
    static let optionLabelMaxLines = 2
    /// What a choice means is most of what there is to go on, so it gets
    /// its own lines under the label rather than what was left beside it.
    static let optionDetailMaxLines = 6
    static let optionMark = Design.px(36)
    static let optionMarkGap = Design.px(14)
    static let optionInset = Design.px(10)
    static let optionTextGap = Design.px(2)
    /// Down from the top of the text to centre the mark on the label's
    /// first line.
    static var optionMarkLift: CGFloat { max(0, (lineHeight(optionLabelFont) - optionMark) / 2) }

    static func optionTextWidth(_ fit: Fit) -> CGFloat {
        contentWidth(fit) - 2 * optionInset - optionMark - optionMarkGap
    }

    static func optionLabelLines(_ option: PendingPrompt.Option, fit: Fit = .card) -> Int {
        lines(option.label, font: optionLabelFont, width: optionTextWidth(fit), cap: optionLabelMaxLines)
    }

    static func optionDetailLines(_ option: PendingPrompt.Option, fit: Fit = .card) -> Int {
        guard let detail = option.description, !detail.isEmpty else { return 0 }
        return lines(detail, font: optionDetailFont, width: optionTextWidth(fit), cap: optionDetailMaxLines)
    }

    /// One choice: the single-line row it always was, and a line taller
    /// for every further line of label or meaning.
    static func optionRowHeight(_ option: PendingPrompt.Option, fit: Fit = .card) -> CGFloat {
        let detail = optionDetailLines(option, fit: fit)
        return optionHeight
            + CGFloat(optionLabelLines(option, fit: fit) - 1) * lineHeight(optionLabelFont)
            + (detail > 0 ? optionTextGap + CGFloat(detail) * lineHeight(optionDetailFont) : 0)
    }

    /// One question: the question, its options, and "Something else…".
    static func questionHeight(_ question: PendingPrompt.Question, fit: Fit = .card,
                               underContext: Bool = false) -> CGFloat {
        let options = question.options.prefix(maxOptions)
        let rows = options.reduce(optionHeight) { $0 + optionRowHeight($1, fit: fit) }
        return headingHeight(question.question, fit: fit, underContext: underContext) + headingGap
            + rows + CGFloat(options.count) * optionGap
    }

    // MARK: Permissions

    /// Why Claude wants to run it, in its own words — the Bash tool's
    /// `description` — between the ask and the command.
    static let purposeFont = optionDetailFont
    static let purposeMaxLines = 3
    static let purposeGap = Design.px(6)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: Typography.size(12.5), weight: .regular)
    /// A command is what is being allowed: enough of it to read what it
    /// does. Two lines, cut in the middle, hid the part that mattered.
    static let codeMaxLines = 8

    static func purposeLines(for prompt: PendingPrompt, fit: Fit = .card) -> Int {
        guard let purpose = prompt.purpose else { return 0 }
        return lines(purpose, font: purposeFont, width: contentWidth(fit), cap: purposeMaxLines)
    }

    static func codeLines(for prompt: PendingPrompt, fit: Fit = .card) -> Int {
        lines(prompt.displaySummary, font: codeFont, width: contentWidth(fit) - 2 * wellInset, cap: codeMaxLines)
    }

    /// The command runs past the lines the well shows. Then the well scrolls,
    /// and Allow waits until it has been read to the end: what is allowed
    /// from the notch is never more than what was seen there.
    static func codeIsClipped(for prompt: PendingPrompt, fit: Fit = .card) -> Bool {
        lines(prompt.displaySummary, font: codeFont, width: contentWidth(fit) - 2 * wellInset, cap: .max) > codeMaxLines
    }

    /// A permission: what it wants to do, why, and the command or file in a well.
    static func approvalBodyHeight(for prompt: PendingPrompt, fit: Fit = .card) -> CGFloat {
        let purpose = purposeLines(for: prompt, fit: fit)
        return headingLineHeight
            + (purpose > 0 ? purposeGap + CGFloat(purpose) * lineHeight(purposeFont) : 0)
            + headingGap
            + max(2, CGFloat(codeLines(for: prompt, fit: fit))) * lineHeight(codeFont) + 2 * wellInset
    }

    static func bodyHeight(for prompt: PendingPrompt, index: Int, fit: Fit = .card) -> CGFloat {
        guard prompt.questions.indices.contains(index) else {
            return prompt.questions.isEmpty ? approvalBodyHeight(for: prompt, fit: fit) : questionHeight(prompt, 0, fit: fit)
        }
        return questionHeight(prompt, index, fit: fit)
    }

    /// Question `index` of `prompt`, as it is laid out under that prompt's
    /// context lines, if it has any.
    static func questionHeight(_ prompt: PendingPrompt, _ index: Int, fit: Fit = .card) -> CGFloat {
        questionHeight(prompt.questions[index], fit: fit, underContext: contextRows(for: prompt) > 0)
    }

    static func contentHeight(for prompt: PendingPrompt, index: Int = 0, fit: Fit = .card) -> CGFloat {
        contextHeight(for: prompt, fit: fit) + bodyHeight(for: prompt, index: index, fit: fit) + footerGap + footerHeight
    }

    /// The lines saying which piece of work this is — your last message to
    /// the session and what Claude said before asking — one line each.
    static let contextFont = NSFont.systemFont(ofSize: Typography.size(12))
    static let contextLineHeight = NotchLayout.lineHeight(contextFont)
    static let contextRowGap = Design.px(4)
    static let contextGap = Design.px(16)
    /// The rule, the "You"/"Claude" label and the gaps before the words.
    static let contextRule = Design.px(4)
    static let contextRuleGap = Design.px(14)
    static let contextLabelWidth = Design.px(88)
    static let contextLabelGap = Design.px(10)

    /// Your message gets up to two lines — it is the one that says which
    /// piece of work this is. Claude's words get up to four: they are
    /// usually the reason it is asking, and one line of them was the
    /// preamble and never the reason.
    static let contextLeadMaxLines = 4

    private static func contextTextWidth(_ width: CGFloat) -> CGFloat {
        width - contextRule - contextRuleGap - contextLabelWidth - contextLabelGap
    }

    static func contextAskLines(for prompt: PendingPrompt, fit: Fit = .card) -> Int {
        guard let ask = prompt.context?.ask else { return 0 }
        return lines(ask, font: contextFont, width: contextTextWidth(headingWidth(fit)), cap: 2)
    }

    /// Clear of the corner's icons only when it is the first row.
    static func contextLeadLines(for prompt: PendingPrompt, fit: Fit = .card) -> Int {
        guard let context = prompt.context, let lead = context.lead else { return 0 }
        let width = context.ask == nil ? headingWidth(fit) : contentWidth(fit)
        return lines(lead, font: contextFont, width: contextTextWidth(width), cap: contextLeadMaxLines)
    }

    static func contextRows(for prompt: PendingPrompt) -> Int {
        guard let context = prompt.context else { return 0 }
        return (context.ask == nil ? 0 : 1) + (context.lead == nil ? 0 : 1)
    }

    static func contextHeight(for prompt: PendingPrompt, fit: Fit = .card) -> CGFloat {
        let rows = contextRows(for: prompt)
        guard rows > 0 else { return 0 }
        let lines = contextAskLines(for: prompt, fit: fit) + contextLeadLines(for: prompt, fit: fit)
        return CGFloat(lines) * contextLineHeight + CGFloat(rows - 1) * contextRowGap + contextGap
    }

    /// The tallest the prompt gets, over all its questions — what the
    /// tooltip budgets rows against, so the list does not change length as
    /// the questions go by.
    static func maxContentHeight(for prompt: PendingPrompt, fit: Fit = .card) -> CGFloat {
        let indices = prompt.questions.isEmpty ? [0] : Array(prompt.questions.indices)
        return indices.map { contentHeight(for: prompt, index: $0, fit: fit) }.max() ?? contentHeight(for: prompt, fit: fit)
    }

    /// Where question `index` starts in the sliding stack.
    static func offset(for prompt: PendingPrompt, index: Int, fit: Fit = .card) -> CGFloat {
        (0..<min(index, prompt.questions.count)).reduce(0) { $0 + questionHeight(prompt, $1, fit: fit) + slideGap }
    }
}

// MARK: - The shared contents

/// A card that appears under a pointer already in motion must not be
/// answered by the click that pointer was making anyway — in a game, in
/// another app, or the second half of a double-click that answered the
/// question before. So a fresh screen of choices takes no clicks for a
/// moment: when the card appears, when the next question comes up, and
/// when the pager brings another session forward.
enum PromptArming {
    static let delay: Duration = .milliseconds(700)

    /// What is on screen, as far as arming goes: a change here re-arms.
    static func key(prompt: PendingPrompt, draft: PromptDraft) -> String {
        "\(prompt.id.uuidString)#\(draft.index)"
    }
}

/// The question (or what a permission is for) as the heading, the choices
/// under it, and a footer of pill actions — the same wherever a prompt is
/// shown. Questions come one at a time and slide up as they go by.
private struct PromptContent: View {
    let prompt: PendingPrompt
    @Binding var draft: PromptDraft
    let onAnswer: (PromptAnswer) -> Void
    var onOpen: (() -> Void)?
    /// In the tooltip there is no header, so the footer carries the pager.
    var inTooltip = false
    var queue: PromptQueuePosition? = nil
    var onPage: ((Int) -> Void)? = nil
    /// Offscreen renders show the card as it looks once armed: they are
    /// drawn the moment the task starts, before it could ever arm.
    @State private var armed = Runtime.isUnderTest
    @State private var hovered: String?
    /// The prompt whose command has been scrolled to its end.
    @State private var readToEnd: UUID?
    @FocusState private var typing: Bool
    @Namespace private var glide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    if PromptLayout.contextRows(for: prompt) > 0, let context = prompt.context {
                        ContextLines(context: context, trailingRoom: cornerWidth,
                                     askLines: PromptLayout.contextAskLines(for: prompt, fit: fit),
                                     leadLines: PromptLayout.contextLeadLines(for: prompt, fit: fit))
                            .frame(height: PromptLayout.contextHeight(for: prompt, fit: fit) - PromptLayout.contextGap, alignment: .top)
                            .padding(.bottom, PromptLayout.contextGap)
                    }
                    Group {
                        if prompt.isQuestion { questions } else { approval }
                    }
                    .allowsHitTesting(armed)
                    .opacity(armed ? 1 : 0.55)
                    .frame(height: PromptLayout.bodyHeight(for: prompt, index: draft.index, fit: fit), alignment: .top)
                    .clipped()
                }
                corner
            }

            footer
                .allowsHitTesting(armed)
                .opacity(armed ? 1 : 0.55)
                .padding(.top, PromptLayout.footerGap)
        }
        .frame(height: PromptLayout.contentHeight(for: prompt, index: draft.index, fit: fit), alignment: .top)
        .task(id: PromptArming.key(prompt: prompt, draft: draft)) {
            guard !Runtime.isUnderTest else { return }
            armed = false
            do { try await Task.sleep(for: PromptArming.delay) } catch { return }
            withAnimation(.easeOut(duration: 0.15)) { armed = true }
        }
    }

    // MARK: Corner

    /// Open the session, or dismiss — both hand the prompt back to Claude's
    /// own dialog; Open also takes you there.
    private var corner: some View {
        // Spaced by both targets' margins, so neither eats into the other.
        HStack(spacing: 2 * PromptLayout.openSlop) {
            if let pager {
                pager.padding(.trailing, -PromptLayout.openSlop)
            }
            if let onOpen {
                CornerIcon(symbol: "arrow.up.forward.app", help: L10n.t("Open the session and answer there"), action: onOpen)
            }
            CornerIcon(symbol: "xmark", help: L10n.t("Answer in the session instead")) {
                onAnswer(.passThrough)
            }
        }
        .frame(height: NotchLayout.cardBodyLineHeight)
    }

    /// In the tooltip there is no header to carry the pager, so it sits in
    /// the corner — the footer has no room left beside the step counter.
    private var pager: PromptPager? {
        guard inTooltip, let queue, let onPage else { return nil }
        return PromptPager(position: queue, onPage: onPage)
    }

    private var cornerWidth: CGFloat {
        PromptLayout.cornerWidth + (pager == nil ? 0 : PromptLayout.pagerWidth)
    }

    private var fit: PromptLayout.Fit { inTooltip ? .tooltip(pager: pager != nil) : .card }

    private var underContext: Bool { PromptLayout.contextRows(for: prompt) > 0 }

    // MARK: Questions

    private var questions: some View {
        VStack(alignment: .leading, spacing: PromptLayout.slideGap) {
            ForEach(Array(prompt.questions.enumerated()), id: \.offset) { i, question in
                let active = i == draft.index
                questionBlock(question, active: active)
                    .frame(height: PromptLayout.questionHeight(prompt, i, fit: fit), alignment: .top)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
            }
        }
        .offset(y: -PromptLayout.offset(for: prompt, index: draft.index, fit: fit))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func questionBlock(_ question: PendingPrompt.Question, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question.question)
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(PromptLayout.headingMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, underContext ? 0 : cornerWidth)
                .frame(height: PromptLayout.headingHeight(question.question, fit: fit, underContext: underContext),
                       alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: PromptLayout.optionGap) {
                ForEach(Array(question.options.prefix(PromptLayout.maxOptions)), id: \.self) { option in
                    OptionRow(option: option, picked: draft.isPicked(option.label, in: question),
                              multi: question.multiSelect, highlighted: active && hovered == option.label,
                              glide: glide,
                              labelLines: PromptLayout.optionLabelLines(option, fit: fit),
                              detailLines: PromptLayout.optionDetailLines(option, fit: fit)) {
                        pick(option.label, in: question)
                    }
                    .frame(height: PromptLayout.optionRowHeight(option, fit: fit))
                    .notchHover { inside in hover(option.label, inside) }
                }
                CustomRow(text: Binding(get: { draft.customText(for: question) },
                                        set: { value in if active { draft.setCustom(value) } }),
                          multi: question.multiSelect,
                          highlighted: active && hovered == CustomRow.id,
                          glide: glide,
                          focus: $typing,
                          onSubmit: { continueOn() })
                    .frame(height: PromptLayout.optionHeight)
                    .notchHover { inside in hover(CustomRow.id, inside) }
            }
            .padding(.top, PromptLayout.headingGap)
        }
    }

    private func hover(_ id: String, _ inside: Bool) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
    }

    private func pick(_ label: String, in question: PendingPrompt.Question) {
        typing = false
        // Only a pick: Continue, or Send, is what moves the card on.
        draft.toggle(label)
    }

    private func continueOn() {
        var next = draft
        let answer = next.advance()
        if let answer { onAnswer(answer); return }
        withAnimation(PromptLayout.slide) { draft = next }
    }

    private func skip() {
        var next = draft
        if let answer = next.skip() { onAnswer(answer); return }
        withAnimation(PromptLayout.slide) { draft = next }
    }

    // MARK: Approval

    /// Allow and Always wait for a command too long for the well to have
    /// been scrolled to its end.
    private var mustReadToEnd: Bool {
        !prompt.isQuestion && PromptLayout.codeIsClipped(for: prompt, fit: fit) && readToEnd != prompt.id
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(prompt.statusText)
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .padding(.trailing, cornerWidth)
                .frame(height: PromptLayout.headingLineHeight, alignment: .leading)
            let purposeLines = PromptLayout.purposeLines(for: prompt, fit: fit)
            if let purpose = prompt.purpose, purposeLines > 0 {
                Text(purpose)
                    .font(Typography.detail)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(purposeLines)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: CGFloat(purposeLines) * PromptLayout.lineHeight(PromptLayout.purposeFont), alignment: .topLeading)
                    .padding(.top, PromptLayout.purposeGap)
            }
            let codeLines = max(2, PromptLayout.codeLines(for: prompt, fit: fit))
            let wellHeight = CGFloat(codeLines) * PromptLayout.lineHeight(PromptLayout.codeFont) + 2 * PromptLayout.wellInset
            Group {
                if PromptLayout.codeIsClipped(for: prompt, fit: fit) {
                    ScrollView(.vertical) {
                        Text(prompt.displaySummary)
                            .font(Typography.code)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(PromptLayout.wellInset)
                    }
                    .scrollIndicators(.visible)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
                    } action: { _, atEnd in
                        if atEnd { readToEnd = prompt.id }
                    }
                } else {
                    Text(prompt.displaySummary)
                        .font(Typography.code)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(codeLines)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(PromptLayout.wellInset)
                }
            }
            .frame(height: wellHeight, alignment: .topLeading)
            .background(NotchWell())
            .padding(.top, PromptLayout.headingGap)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Design.px(10)) {
            if prompt.questions.count > 1 {
                StepNav(position: draft.position, canGoBack: draft.canGoBack, canGoForward: draft.canGoForward) { delta in
                    withAnimation(PromptLayout.slide) { draft.go(by: delta) }
                }
            }
            Spacer(minLength: 0)
            if prompt.isQuestion {
                NotchButton(title: L10n.t("Skip"), role: .quiet) { skip() }
                NotchButton(title: draft.isLast ? L10n.t("Send") : L10n.t("Continue"), role: .primary,
                            returnKey: true) { continueOn() }
                    .disabled(!draft.hasAnswer)
                    .opacity(draft.hasAnswer ? 1 : 0.4)
            } else {
                if mustReadToEnd {
                    Text(L10n.t("Scroll to the end to allow"))
                        .font(Typography.detail)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                NotchButton(title: L10n.t("Deny"), role: .quietDestructive) { onAnswer(.deny) }
                if prompt.canRemember {
                    NotchButton(title: L10n.t("Always")) { if !mustReadToEnd { onAnswer(.allowAlways) } }
                        .disabled(mustReadToEnd)
                        .opacity(mustReadToEnd ? 0.4 : 1)
                }
                NotchButton(title: L10n.t("Allow"), role: .primary) { if !mustReadToEnd { onAnswer(.allow) } }
                    .disabled(mustReadToEnd)
                    .opacity(mustReadToEnd ? 0.4 : 1)
            }
        }
        .frame(height: PromptLayout.footerHeight)
    }
}

/// Which piece of work the prompt belongs to, above it: your last message
/// to the session, and what Claude said just before asking — set off by a
/// thin rule like a quotation, so it reads as context and not as the ask.
private struct ContextLines: View {
    let context: PromptContext
    /// Room left at the end of the first line for the corner's icons.
    let trailingRoom: CGFloat
    /// How many lines your message takes — measured, one or two.
    let askLines: Int
    /// How many Claude's words take — measured, up to four.
    let leadLines: Int

    var body: some View {
        HStack(alignment: .top, spacing: PromptLayout.contextRuleGap) {
            Capsule()
                .fill(Palette.textSecondary.opacity(0.35))
                .frame(width: PromptLayout.contextRule)
            VStack(alignment: .leading, spacing: PromptLayout.contextRowGap) {
                if let ask = context.ask {
                    row(L10n.t("You"), ask, lines: askLines).padding(.trailing, trailingRoom)
                }
                if let lead = context.lead {
                    row(L10n.t("Claude"), lead, lines: leadLines).padding(.trailing, context.ask == nil ? trailingRoom : 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ who: String, _ text: String, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PromptLayout.contextLabelGap) {
            Text(who)
                .font(Typography.counter)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .lineLimit(1)
                .frame(width: PromptLayout.contextLabelWidth, alignment: .leading)
            Text(text)
                .font(Typography.detail)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(lines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: CGFloat(lines) * PromptLayout.contextLineHeight, alignment: .topLeading)
    }
}

/// ⌃ 2 / 3 ⌄ — which question is up; the digits roll as it changes.
private struct StepNav: View {
    let position: String
    let canGoBack: Bool
    let canGoForward: Bool
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: Design.px(4)) {
            arrow("chevron.up", enabled: canGoBack, help: L10n.t("Previous question")) { go(-1) }
            Text(position)
                .font(Typography.counter)
                .foregroundStyle(Palette.textSecondary)
                .contentTransition(.numericText())
                .fixedSize()
            arrow("chevron.down", enabled: canGoForward, help: L10n.t("Next question")) { go(1) }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.px(20), weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Design.px(40), height: Design.px(40))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }
}

/// A small icon in the card's corner, with a target bigger than it looks.
private struct CornerIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Design.px(24), weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Design.px(32), height: Design.px(32))
                // The icon is small; the target must not be. A 16 pt target
                // was missed more often than hit, and a miss does nothing
                // visible — the Allow beside it got pressed instead.
                .padding(PromptLayout.openSlop)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .padding(-PromptLayout.openSlop)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - The two places it is shown

/// In the Claude tooltip, under the row of the session that is asking: the
/// contents in a well, the same well the effort row sits in.
struct PromptPanel: View {
    let prompt: PendingPrompt
    @Binding var draft: PromptDraft
    let onAnswer: (PromptAnswer) -> Void
    var onOpen: (() -> Void)? = nil
    var queue: PromptQueuePosition? = nil
    var onPage: ((Int) -> Void)? = nil
    /// Kept for the call sites; the panel names no session either way —
    /// the row above it, or the pager, says whose it is.
    var namesSession = true

    static func height(for prompt: PendingPrompt, index: Int = 0, queued: Bool = false) -> CGFloat {
        2 * NotchLayout.effortWellPadding
            + PromptLayout.contentHeight(for: prompt, index: index, fit: .tooltip(pager: queued))
    }

    static func maxHeight(for prompt: PendingPrompt, queued: Bool = false) -> CGFloat {
        2 * NotchLayout.effortWellPadding + PromptLayout.maxContentHeight(for: prompt, fit: .tooltip(pager: queued))
    }

    var body: some View {
        PromptContent(prompt: prompt, draft: $draft, onAnswer: onAnswer, onOpen: onOpen,
                      inTooltip: true, queue: queue, onPage: onPage)
            .padding(.vertical, NotchLayout.effortWellPadding)
            .padding(.horizontal, PromptLayout.panelInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.height(for: prompt, index: draft.index, queued: queue != nil && onPage != nil), alignment: .top)
            .background(NotchWell())
    }
}

/// Beside the folded pill: the notch's card, exactly as the done card is
/// built — glyph, title, session — with the prompt under it. Stays until
/// it is answered.
struct PromptCard: View {
    let prompt: PendingPrompt
    @Binding var draft: PromptDraft
    var direction: NotchEdge.TooltipDirection = .trailing
    let onAnswer: (PromptAnswer) -> Void
    var onOpen: (() -> Void)? = nil
    var queue: PromptQueuePosition? = nil
    var onPage: ((Int) -> Void)? = nil

    static func cardHeight(for prompt: PendingPrompt, index: Int = 0) -> CGFloat {
        2 * NotchLayout.cardPadding + NotchCardHeader.height
            + NotchLayout.headerToBlock + PromptLayout.contentHeight(for: prompt, index: index)
    }

    var body: some View {
        NotchCardChrome(height: Self.cardHeight(for: prompt, index: draft.index), direction: direction) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    NotchCardHeader(glyph: .claude, title: draft.title(for: prompt),
                                    subtitle: prompt.subtitle.isEmpty ? L10n.t("Claude Code") : prompt.subtitle)
                    Spacer(minLength: Design.px(12))
                    if let queue, let onPage {
                        PromptPager(position: queue, onPage: onPage)
                    }
                }
                PromptContent(prompt: prompt, draft: $draft, onAnswer: onAnswer, onOpen: onOpen)
                    .padding(.top, NotchLayout.headerToBlock)
            }
        }
    }
}

// MARK: - After the answer

/// What the card says for a moment once it is answered, in its place:
/// "Answers sent", "Allowed", … — so the answer is seen to have gone.
struct PromptEcho: Equatable, Identifiable {
    enum Tone: Equatable { case sent, declined, handedBack }
    /// Where it was answered, which is the one place it is said: an answer
    /// given in the tooltip is not announced again beside the pill once
    /// the tooltip has closed.
    enum Origin: Equatable { case tooltip, card }
    let id = UUID()
    let pid: pid_t?
    let text: String
    let tone: Tone
    let origin: Origin

    init(answer: PromptAnswer, prompt: PendingPrompt, origin: Origin = .card) {
        pid = prompt.pid
        self.origin = origin
        switch answer {
        case .allow: text = L10n.t("Allowed"); tone = .sent
        case .allowAlways: text = L10n.t("Allowed · won't ask again"); tone = .sent
        case .deny: text = L10n.t("Declined"); tone = .declined
        case .answers: text = L10n.t("Answers sent"); tone = .sent
        case .passThrough: text = L10n.t("Over to the session"); tone = .handedBack
        }
    }

    static func == (lhs: PromptEcho, rhs: PromptEcho) -> Bool { lhs.id == rhs.id }

    static let lasts: Duration = .milliseconds(1400)
}

/// The pill that says so.
struct PromptEchoPill: View {
    let echo: PromptEcho

    private var tint: Color {
        switch echo.tone {
        case .sent: return Palette.ample
        case .declined: return Palette.critical
        case .handedBack: return Palette.textSecondary
        }
    }

    private var symbol: String {
        switch echo.tone {
        case .sent: return "checkmark"
        case .declined: return "xmark"
        case .handedBack: return "arrow.uturn.backward"
        }
    }

    var body: some View {
        HStack(spacing: Design.px(10)) {
            Image(systemName: symbol)
                .font(.system(size: Design.px(18), weight: .semibold))
                .foregroundStyle(Color(dark: .black, light: .white))
                .frame(width: Design.px(34), height: Design.px(34))
                .background(Circle().fill(tint))
            Text(echo.text)
                .font(Typography.control)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.leading, Design.px(6))
        .padding(.trailing, Design.px(20))
        .frame(height: Design.px(46))
        .background(Capsule().fill(tint.opacity(0.16)))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    static let height = Design.px(46)
}

// MARK: - Pieces shared with the rest of the notch

/// The inset surface inside a card — the effort row's, the command's, a
/// prompt's in the tooltip.
struct NotchWell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
            .fill(Palette.textPrimary.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
                    .strokeBorder(Palette.textPrimary.opacity(0.1), lineWidth: 1)
            )
    }
}

/// A capsule button in the notch's type and colours.
struct NotchButton: View {
    enum Role { case normal, primary, destructive, quiet, quietDestructive }
    let title: String
    var role: Role = .normal
    /// Shows ⏎ after the title: Return does it, from the answer field.
    var returnKey = false
    let action: () -> Void

    private var foreground: Color {
        switch role {
        // The primary capsule is filled with the text colour, so its label
        // is the opposite of it in either appearance.
        case .primary: return Color(dark: .black, light: .white)
        case .destructive, .quietDestructive: return Palette.critical
        case .quiet: return Palette.textSecondary
        case .normal: return Palette.textPrimary
        }
    }

    private var fill: Color {
        switch role {
        case .primary: return Palette.textPrimary
        case .quiet, .quietDestructive: return .clear
        case .normal, .destructive: return Palette.textPrimary.opacity(0.1)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.px(8)) {
                Text(title)
                if returnKey {
                    Image(systemName: "return")
                        .font(.system(size: Design.px(18), weight: .medium))
                        .opacity(0.6)
                }
            }
            .font(Typography.control)
            .foregroundStyle(foreground)
            .padding(.horizontal, Design.px(22))
            .frame(maxHeight: .infinity)
            .frame(minWidth: Design.px(80))
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The colour of the card under the text: what a filled control's mark
/// is drawn in.
private let canvas = Color(dark: .black, light: .white)

/// One choice: a radio or a box, the label, and what it means in quieter
/// type. The hover highlight glides from row to row.
private struct OptionRow: View {
    let option: PendingPrompt.Option
    let picked: Bool
    let multi: Bool
    let highlighted: Bool
    let glide: Namespace.ID
    /// Measured by `PromptLayout`, which sized the row for them.
    var labelLines = 1
    var detailLines = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Top-aligned: beside a label and a paragraph under it, a mark
            // centred on the lot sat by nothing in particular.
            HStack(alignment: detailLines > 0 || labelLines > 1 ? .top : .center, spacing: PromptLayout.optionMarkGap) {
                ChoiceMark(on: picked, multi: multi)
                    .padding(.top, detailLines > 0 || labelLines > 1 ? PromptLayout.optionMarkLift : 0)
                // The meaning under the label, not beside it: beside it, it
                // had whatever the label left of one line, which for a
                // label of any length was nothing.
                VStack(alignment: .leading, spacing: PromptLayout.optionTextGap) {
                    Text(option.label)
                        .font(picked ? Typography.cardLabel : Typography.cardBody)
                        .foregroundStyle(picked ? Palette.textPrimary : Palette.textPrimary.opacity(0.82))
                        .lineLimit(labelLines)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = option.description, !description.isEmpty, detailLines > 0 {
                        Text(description)
                            .font(Typography.detail)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(detailLines)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PromptLayout.optionInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background { GlideHighlight(on: highlighted, glide: glide) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// "Something else…": an answer of your own, sent as it is typed.
private struct CustomRow: View {
    static let id = "\u{1}custom"
    @Binding var text: String
    let multi: Bool
    let highlighted: Bool
    let glide: Namespace.ID
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    @Environment(\.drawsFieldsAsText) private var drawsFieldAsText

    var body: some View {
        HStack(spacing: Design.px(14)) {
            Image(systemName: "pencil")
                .font(.system(size: Design.px(20), weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Design.px(36), height: Design.px(36))
            if drawsFieldAsText {
                // Offscreen renders cannot draw an AppKit text field; the
                // words are what the check is about.
                Text(text.isEmpty ? L10n.t("Something else…") : text)
                    .font(Typography.cardBody)
                    .foregroundStyle(text.isEmpty ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(1)
            } else {
                TextField(L10n.t("Something else…"), text: $text)
                    .textFieldStyle(.plain)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textPrimary)
                    .focused(focus)
                    .onSubmit(onSubmit)
                    .accessibilityLabel(L10n.t("Your own answer"))
            }
        }
        .padding(.horizontal, Design.px(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { GlideHighlight(on: highlighted || !text.isEmpty, glide: glide, glides: highlighted) }
        // The whole row is the field's target, pencil included — not only
        // the run of placeholder text.
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
    }
}

extension EnvironmentValues {
    /// Set by offscreen renders, which cannot draw an AppKit text field.
    @Entry var drawsFieldsAsText = false
}

/// The row highlight that moves with the pointer — one shape, handed
/// from row to row, so it slides rather than blinks.
private struct GlideHighlight: View {
    let on: Bool
    let glide: Namespace.ID
    var glides = true

    var body: some View {
        if on {
            let shape = RoundedRectangle(cornerRadius: Design.px(14), style: .continuous)
                .fill(Palette.textPrimary.opacity(0.08))
            if glides {
                shape.matchedGeometryEffect(id: "hover", in: glide)
            } else {
                shape
            }
        }
    }
}

/// A radio or a checkbox: an outline when off, filled with the text colour
/// when on, its mark in the card's colour.
private struct ChoiceMark: View {
    let on: Bool
    let multi: Bool

    var body: some View {
        let size = Design.px(36)
        ZStack {
            if multi {
                RoundedRectangle(cornerRadius: Design.px(10), style: .continuous)
                    .fill(on ? Palette.textPrimary : .clear)
                RoundedRectangle(cornerRadius: Design.px(10), style: .continuous)
                    .strokeBorder(Palette.textSecondary.opacity(on ? 0 : 0.8), lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: Design.px(20), weight: .heavy))
                    .foregroundStyle(canvas)
                    .opacity(on ? 1 : 0)
            } else {
                Circle().fill(on ? Palette.textPrimary : .clear)
                Circle().strokeBorder(Palette.textSecondary.opacity(on ? 0 : 0.8), lineWidth: 1.5)
                Circle().fill(canvas)
                    .frame(width: Design.px(12), height: Design.px(12))
                    .scaleEffect(on ? 1 : 0.01)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}
