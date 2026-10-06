import AppKit
import SwiftUI

// MARK: - Sections and search

/// One entry in the sidebar, grouped by what a person is trying to do
/// rather than by how the setting is stored.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case lid, notch, sessions, notifications, accounts, api, costs, localModels, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lid:           return L10n.t("Lid & Effort")
        case .notch:         return L10n.t("Notch")
        case .sessions:      return L10n.t("Sessions & Approvals")
        case .notifications: return L10n.t("Notifications")
        case .accounts:      return L10n.t("Accounts")
        case .api:           return L10n.t("API Keys")
        case .costs:         return L10n.t("Costs")
        case .localModels:   return L10n.t("Local Models")
        case .general:       return L10n.t("General")
        }
    }

    /// The tab's label: a word, so all nine sit on one line.
    var tabTitle: String {
        switch self {
        case .lid:           return L10n.t("Lid")
        case .notch:         return L10n.t("Notch")
        case .sessions:      return L10n.t("Sessions")
        case .notifications: return L10n.t("Alerts")
        case .accounts:      return L10n.t("Accounts")
        case .api:           return "API"
        case .costs:         return L10n.t("Costs")
        case .localModels:   return L10n.t("Local models")
        case .general:       return L10n.t("General")
        }
    }

    /// The pane's one-sentence introduction, under its title.
    var summary: String {
        switch self {
        case .lid:
            return L10n.t("Hold ⌘ and move the lid to set how hard your agents think. Let go to apply.")
        case .notch:
            return L10n.t("Where the notch sits, how it looks, and what its rings show.")
        case .sessions:
            return L10n.t("Which sessions the tooltip lists, and answering Claude without leaving what you are doing.")
        case .notifications:
            return L10n.t("What the notch says, and plays, when a session finishes or a limit changes.")
        case .accounts:
            return L10n.t("The assistants read from this Mac. Each connected one gets a ring, in this order.")
        case .api:
            return L10n.t("API keys you add to track a balance or usage. The notch shows them together, in one API keys cell.")
        case .costs:
            return L10n.t("What each project spent of each login's allowance, priced from your plan.")
        case .localModels:
            return L10n.t("Models running on this Mac through Ollama or LM Studio.")
        case .general:
            return L10n.t("Startup, updates and language.")
        }
    }

    var icon: String {
        switch self {
        case .lid:           return "laptopcomputer"
        case .notch:         return "capsule.inset.filled"
        case .sessions:      return "checkmark.bubble.fill"
        case .notifications: return "bell.badge.fill"
        case .accounts:      return "person.crop.circle.fill"
        case .api:           return "key.horizontal.fill"
        case .costs:         return "chart.pie.fill"
        case .localModels:   return "cpu"
        case .general:       return "gearshape.fill"
        }
    }

    /// The badge colour behind the symbol — what makes System Settings'
    /// sidebar recognisable at a glance.
    var tint: Color {
        switch self {
        case .lid:           return .orange
        case .notch:         return .indigo
        case .sessions:      return .green
        case .notifications: return .red
        case .accounts:      return .blue
        case .api:           return .yellow
        case .costs:         return .teal
        case .localModels:   return .purple
        case .general:       return .gray
        }
    }
}

/// Every setting by name, and the words someone might type looking for it
/// — so "sound", "monitor" or "codex" finds the row, not only a pane whose
/// title happens to contain the word.
struct SettingsIndex {
    struct Entry: Identifiable, Hashable {
        let section: SettingsSection
        let title: String
        let keywords: [String]
        var id: String { "\(section.rawValue)/\(title)" }
    }

    static var entries: [Entry] {
        func e(_ section: SettingsSection, _ title: String, _ keywords: String) -> Entry {
            Entry(section: section, title: title, keywords: keywords.split(separator: " ").map(String.init))
        }
        return [
            e(.lid, L10n.t("Lid level"), "effort reasoning think level low medium high xhigh max ultracode"),
            e(.lid, L10n.t("Lid gesture"), "lid command cmd ⌘ gesture angle hinge degrees sensor"),
            e(.lid, L10n.t("Agents"), "agent claude code codex grok config target"),
            e(.lid, L10n.t("Claude Desktop (experimental)"), "claude desktop app accessibility composer type experiment"),
            e(.notch, L10n.t("Edge"), "edge side left right top bottom position move"),
            e(.notch, L10n.t("Show on"), "display displays screen monitor external main all every active window follow"),
            e(.notch, L10n.t("Show"), "show hide visibility hover always"),
            e(.notch, L10n.t("Size"), "size scale bigger smaller large small zoom pill"),
            e(.notch, L10n.t("Tooltip size"), "tooltip card size text bigger smaller zoom scale font"),
            e(.notch, L10n.t("Surface"), "surface glass solid liquid material"),
            e(.notch, L10n.t("Transparency"), "transparency frost opacity see-through clear"),
            e(.notch, L10n.t("Move handle"), "handle arc move drag"),
            e(.notch, L10n.t("Recentre the notch"), "recentre recenter centre center middle reset position along edge nudge option alt ⌥ drag move slide"),
            e(.notch, L10n.t("Reset time"), "reset time clock countdown format"),
            e(.notch, L10n.t("Weekly ring"), "weekly week ring limit"),
            e(.notch, L10n.t("Usage pace"), "pace deficit reserve usage"),
            e(.notch, L10n.t("Accent color"), "accent colour color tint theme"),
            e(.sessions, L10n.t("Sessions in the tooltip"), "session tooltip list limit count"),
            e(.sessions, L10n.t("Hide idle sessions"), "idle stale hide clean old"),
            e(.sessions, L10n.t("Answer Claude from the notch"), "approval approve permission allow deny question answer hook prompt"),
            e(.notifications, L10n.t("When Claude asks"), "approval question prompt permission sound alert ask claude"),
            e(.notifications, L10n.t("Approval and question sounds"), "approval question sound chime ping funk"),
            e(.notifications, L10n.t("Remind me"), "remind reminder repeat again unanswered minutes"),
            e(.notifications, L10n.t("macOS notification"), "macos notification center banner system"),
            e(.notifications, L10n.t("Over full-screen apps"), "full screen fullscreen game video presentation sound only"),
            e(.notifications, L10n.t("When a session ends"), "finished done peek open session end"),
            e(.notifications, L10n.t("Sounds"), "sound chime play audio alert"),
            e(.notifications, L10n.t("When a limit is reached"), "limit reached quota spent session weekly"),
            e(.notifications, L10n.t("When a limit resets"), "reset limit back cheer"),
            e(.notifications, L10n.t("Threshold alerts"), "threshold 80% 100% crossing mute"),
            e(.accounts, L10n.t("Accounts"), "account provider sign login connect claude codex cursor gemini antigravity grok copilot kimi deepseek glm opencode devin kiro amp apify kilo minimax qianwen qianwenai"),
            e(.accounts, L10n.t("Ring order"), "order reorder drag ring arrange"),
            e(.api, L10n.t("API keys"), "api key keys token secret balance credits spend usage add provider openrouter openai anthropic xai grok mistral gemini groq together fireworks deepinfra novita deepseek kimi moonshot siliconflow stepfun glm zhipu minimax elevenlabs deepgram tavily serpapi firecrawl exa jina apify ollama"),
            e(.api, L10n.t("Custom Endpoints"), "custom endpoint openai compatible anthropic gemini api proxy openrouter groq vllm llama litellm local model key budget"),
            e(.costs, L10n.t("Billing"), "cost costs money price billing plan subscription api token spend project"),
            e(.costs, L10n.t("Monthly price"), "monthly price plan subscription pay currency"),
            e(.costs, L10n.t("Market data"), "exchange rate currency token prices openrouter market"),
            e(.costs, L10n.t("Activity"), "activity timeline day week month sessions projects cost"),
            e(.localModels, "Ollama", "ollama local model llm"),
            e(.localModels, "LM Studio", "lm studio lmstudio local model llm"),
            e(.general, L10n.t("Open at login"), "login startup launch boot"),
            e(.general, L10n.t("Updates"), "update version sparkle install"),
            e(.general, L10n.t("Language"), "language localization vietnamese english chinese"),
            e(.general, L10n.t("App icon"), "icon dock menu bar presence"),
        ]
    }

    /// Entries matching every word typed, in any order, ignoring case and
    /// accents — "claude hook" finds the approval switch.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map { String($0).folding(options: .diacriticInsensitive, locale: nil) }
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = ([entry.title, entry.section.title] + entry.keywords)
                .joined(separator: " ").lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

// MARK: - Pieces

/// A rounded-square badge behind a white symbol — the icon style System
/// Settings uses in its sidebar and at the head of each pane.
struct SettingsBadge: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

/// The head of a pane: what it is for, in a sentence. The tab above
/// already names it.
struct PaneHero: View {
    let section: SettingsSection
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(section.summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

// MARK: - The settings' form

/// How every pane lays out its `Form`: no boxes. A section is a small
/// capitalised heading with a tick of the accent colour before it, and its
/// rows sit straight on the window with a hairline between them — the
/// notch's own dark glass all the way through, rather than grouped cards.
struct NotchFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        if !section.header.isEmpty {
                            HStack(spacing: 8) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: 14, height: 3)
                                section.header
                                    .font(.system(size: 11, weight: .semibold))
                                    .textCase(.uppercase)
                                    .tracking(1.1)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 6)
                        }
                        let last = section.content.last?.id
                        ForEach(subviews: section.content) { row in
                            VStack(alignment: .leading, spacing: 0) {
                                row
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 11)
                                if row.id != last {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(height: 1)
                                }
                            }
                        }
                        if !section.footer.isEmpty {
                            section.footer
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(NotchRowToggleStyle())
        .labeledContentStyle(NotchRowLabeledStyle())
    }
}

/// A switch at the end of its row, the label taking the rest.
struct NotchRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label
            Spacer(minLength: 0)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// The label on the left, the control on the right.
struct NotchRowLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// A setting's name, a short line under it, and — when there is more to
/// say — an ⓘ that says it in a popover instead of a paragraph under
/// every switch.
struct SettingLabel: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let info { InfoButton(text: info) }
        }
    }
}

/// ⓘ, with the long explanation behind it.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
        .accessibilityLabel(L10n.t("More information"))
    }
}

/// A small coloured state: "On", "Hook installed", "No sensor".
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// The edge, chosen by pointing at it: a little screen per side, the notch
/// drawn where it would sit — the way Displays arranges screens, rather
/// than a row of words.
struct EdgePicker: View {
    @Binding var selection: NotchEdge

    var body: some View {
        HStack(spacing: 10) {
            ForEach(NotchEdge.allCases) { edge in
                Button { selection = edge } label: {
                    VStack(spacing: 6) {
                        EdgeThumbnail(edge: edge, selected: selection == edge)
                            .frame(width: 70, height: 46)
                        Text(edge.title)
                            .font(.system(size: 11, weight: selection == edge ? .medium : .regular))
                            .foregroundStyle(selection == edge ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(edge.title)
                .accessibilityAddTraits(selection == edge ? .isSelected : [])
            }
        }
    }
}

private struct EdgeThumbnail: View {
    let edge: NotchEdge
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pill: CGSize = edge.isVertical ? CGSize(width: 5, height: h * 0.34) : CGSize(width: w * 0.3, height: 5)
            let origin: CGPoint = {
                switch edge {
                case .left:   return CGPoint(x: 3, y: (h - pill.height) / 2)
                case .right:  return CGPoint(x: w - 3 - pill.width, y: (h - pill.height) / 2)
                case .top:    return CGPoint(x: (w - pill.width) / 2, y: 3)
                case .bottom: return CGPoint(x: (w - pill.width) / 2, y: h - 3 - pill.height)
                }
            }()
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: pill.width, height: pill.height)
                    .offset(x: origin.x, y: origin.y)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: selected ? 2.5 : 1)
            )
        }
    }
}

/// One control for size: a slider with the three presets marked on it.
/// Landing near a mark is that preset; anywhere else is a custom size —
/// the two old controls, Preset/Custom and the slider, as one.
struct NotchSizeControl: View {
    @ObservedObject var preferences: Preferences

    static let snap = 0.035

    private var value: Binding<Double> {
        Binding(
            get: { preferences.usesCustomNotchScale ? preferences.customNotchScale : Double(preferences.notchSize.scale) },
            set: { newValue in
                if let preset = NotchSize.allCases.first(where: { abs(Double($0.scale) - newValue) < Self.snap }) {
                    preferences.notchSize = preset
                    preferences.usesCustomNotchScale = false
                } else {
                    preferences.customNotchScale = newValue
                    preferences.usesCustomNotchScale = true
                }
            }
        )
    }

    /// The slider's width, fixed so the marks can sit under the right
    /// places on it.
    static let trackWidth: CGFloat = 200
    /// How far the thumb's centre stays in from either end of the track.
    static let thumbInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 8) {
                Slider(value: value, in: Preferences.customScaleRange)
                    .labelsHidden()
                    .frame(width: Self.trackWidth)
                Text(label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            ZStack(alignment: .topLeading) {
                ForEach(NotchSize.allCases) { size in
                    let range = Preferences.customScaleRange
                    let fraction = (Double(size.scale) - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let x = Self.thumbInset + (Self.trackWidth - 2 * Self.thumbInset) * fraction
                    VStack(spacing: 1) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 4)
                        Text(size.title)
                            .font(.system(size: 10))
                            .foregroundStyle(isAt(size) ? .primary : .tertiary)
                            .fixedSize()
                    }
                    .position(x: x, y: 9)
                }
            }
            .frame(width: Self.trackWidth, height: 18)
            .padding(.trailing, 64)
        }
    }

    private func isAt(_ size: NotchSize) -> Bool {
        !preferences.usesCustomNotchScale && preferences.notchSize == size
    }

    private var label: String {
        if !preferences.usesCustomNotchScale { return preferences.notchSize.title }
        return "\(Int((preferences.customNotchScale * 100).rounded()))%"
    }
}

/// The sidebar's search field, drawn the way System Settings draws its own:
/// a rounded well with the magnifying glass inside and a clear button.
struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(L10n.t("Search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.t("Clear"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 1))
    }
}

/// The cards' size — tooltips, questions, the done card — on the same kind
/// of slider as the pill's, with its three marks. Landing near a mark snaps
/// to it; anywhere else is kept as it is.
struct CardSizeControl: View {
    @ObservedObject var preferences: Preferences

    static let snap = 0.03

    private var value: Binding<Double> {
        Binding(
            get: { preferences.cardScale },
            set: { newValue in
                let mark = Preferences.cardScaleMarks.first { abs($0.value - newValue) < Self.snap }
                preferences.cardScale = mark?.value ?? newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 8) {
                Slider(value: value, in: Preferences.cardScaleRange)
                    .labelsHidden()
                    .frame(width: NotchSizeControl.trackWidth)
                Text(label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Preferences.cardScaleMarks, id: \.value) { mark in
                    let range = Preferences.cardScaleRange
                    let fraction = (mark.value - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let x = NotchSizeControl.thumbInset + (NotchSizeControl.trackWidth - 2 * NotchSizeControl.thumbInset) * fraction
                    VStack(spacing: 1) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 4)
                        Text(mark.title)
                            .font(.system(size: 10))
                            .foregroundStyle(preferences.cardScale == mark.value ? .primary : .tertiary)
                            .fixedSize()
                    }
                    .position(x: x, y: 9)
                }
            }
            .frame(width: NotchSizeControl.trackWidth, height: 18)
            .padding(.trailing, 64)
        }
    }

    private var label: String {
        if let mark = Preferences.cardScaleMarks.first(where: { $0.value == preferences.cardScale }) { return mark.title }
        return "\(Int((preferences.cardScale * 100).rounded()))%"
    }
}
