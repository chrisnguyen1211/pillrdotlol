import AppKit
import Combine
import SwiftUI

// MARK: - The base providers' own pasted keys

/// The key a provider's own ring reads when somebody pasted it into pillr —
/// GLM's, MiniMax's Coding Plan, Ollama's, Apify's. Each lives where it
/// always has; this only puts the four behind one face for the API tab.
enum BaseKeySlot {
    static let bases = ExtraKey.bases

    /// Attributes only: free to ask, and never a prompt.
    static func isPresent(_ base: String) -> Bool {
        switch base {
        case "glm":
            return KeychainItem.modifiedAt(service: GLMCredentials.keychainService,
                                           account: GLMCredentials.keychainAccount) != nil
        case "minimax":
            return KeychainItem.modifiedAt(service: MiniMaxCredentials.apiKeyService,
                                           account: MiniMaxCredentials.keychainAccount) != nil
        case "ollama":
            return KeychainItem.modifiedAt(service: OllamaCredentials.keychainService,
                                           account: OllamaCredentials.keychainAccount) != nil
        case "apify":
            return ApifyCredentials.isSettingsTokenPresent()
        default:
            return false
        }
    }

    /// Files the key, with its region where the provider has one.
    @MainActor
    static func store(_ base: String, key: String, region: String?, preferences: Preferences) {
        switch base {
        case "glm":
            GLMCredentials.pastedIsChina = region == "china"
            _ = GLMCredentials.storePasted(key)
        case "minimax":
            preferences.minimaxRegion = region.flatMap(MiniMaxRegion.init(rawValue:)) ?? .international
            MiniMaxCredentials.storeAPIKey(key)
        case "ollama":
            _ = OllamaCredentials.store(key)
        case "apify":
            ApifyCredentials.storeSettingsToken(key)
        default:
            break
        }
    }

    static func delete(_ base: String) {
        switch base {
        case "glm": _ = GLMCredentials.deletePasted()
        case "minimax": MiniMaxCredentials.deleteAPIKey()
        case "ollama": _ = OllamaCredentials.delete()
        case "apify": ApifyCredentials.deleteSettingsToken()
        default: break
        }
    }
}

// MARK: - The pane

/// One line of the key list: a base provider's own pasted key, or an extra
/// or catalog key.
struct APIKeyItem: Identifiable, Equatable {
    /// The provider id its ring and reading are kept under.
    let id: String
    let entryID: String
    /// "GLM · Key 1", "OpenRouter · Work".
    let title: String
    /// Nil for a base provider's own key, which cannot be renamed.
    let extra: ExtraKey?

    var entry: APICatalogEntry? { APICatalog.entry(id: entryID) }

    /// Base keys first, in the order Settings has always listed them, then
    /// every other key in the order it was added — the order of the API keys
    /// cell. A base provider is listed once a key was pasted for it, or when
    /// `alsoListed` says so: switched on and reading a key some coding tool
    /// holds, since it is drawn in that cell too.
    @MainActor
    static func all(preferences: Preferences, basePresent: (String) -> Bool = BaseKeySlot.isPresent,
                    alsoListed: (String) -> Bool = { _ in false }) -> [APIKeyItem] {
        let bases = BaseKeySlot.bases.filter { basePresent($0) || alsoListed($0) }.map { base in
            APIKeyItem(id: base, entryID: base,
                       title: ExtraKey.displayName(base: base, name: L10n.t("Key \(1)")), extra: nil)
        }
        let extras = preferences.extraKeys.compactMap { extra -> APIKeyItem? in
            guard APICatalog.entry(id: extra.base) != nil else { return nil }
            return APIKeyItem(id: extra.id, entryID: extra.base, title: extra.displayName, extra: extra)
        }
        return bases + extras
    }
}

/// Settings › API: every key pillr was handed, how each one reads, the one
/// button that adds another — and, under them, the custom endpoints.
struct APIKeysPane: View {
    @ObservedObject var preferences: Preferences
    var usageStore: UsageStore?
    /// A provider to open the form on, asked for from an Accounts row.
    @Binding var addRequest: String?
    /// Forgets a base provider's readings when its only key goes.
    var signOut: (String) -> Void = { _ in }
    /// A key was added: the list places its row among the connected ones.
    var didAdd: (String) -> Void = { _ in }
    /// For renders: open the form with this provider chosen, and these keys.
    var initialForm: String? = nil
    var basePresent: (String) -> Bool = BaseKeySlot.isPresent
    var snapshotsForRender: [ProviderSnapshot] = []
    var queryForRender: String? = nil

    @State private var snapshots: [String: ProviderSnapshot] = [:]
    @State private var refreshing: Set<String> = []
    @State private var form: APIKeyFormRequest?
    /// Bumped when a base key is filed or deleted, which no publisher tells.
    @State private var revision = 0

    private var items: [APIKeyItem] {
        _ = revision
        let reading = Set((usageStore?.providerSummaries ?? []).filter { $0.account != nil }.map(\.id))
        return APIKeyItem.all(preferences: preferences, basePresent: basePresent,
                              alsoListed: reading.contains)
    }

    var body: some View {
        // Read once a draw: a base key's presence is a keychain query.
        let items = self.items
        Form {
            Section {
                PaneHero(section: .api)
            }

            Section {
                // With no key yet, the form is the pane's opening line rather
                // than something to find a button for.
                if let form = form ?? (items.isEmpty ? APIKeyFormRequest.firstKey : nil) {
                    APIKeyForm(preferences: preferences, usageStore: usageStore,
                               preset: form.preset, hasOwnKey: hasOwnKey,
                               canCancel: !items.isEmpty, queryForRender: queryForRender) { added in
                        withAnimation(.snappy(duration: 0.22)) { self.form = nil }
                        if let added {
                            revision += 1
                            didAdd(added)
                        }
                    }
                    .id(form.id)
                }
                ForEach(items) { item in
                    APIKeyRow(item: item, preferences: preferences, usageStore: usageStore,
                              snapshot: snapshots[item.id], isChecking: refreshing.contains(item.id),
                              remove: { remove(item) })
                }
                if !items.isEmpty {
                    Text(L10n.t("Keys are kept in your login keychain. The notch shows them together in one API keys cell, which you can move under Accounts; switch a key off here to stop reading it."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                HStack(spacing: 8) {
                    Text(L10n.t("API keys"))
                    Spacer(minLength: 8)
                    if form == nil && !items.isEmpty { addButton }
                }
            }

            // Accounts this Mac does not already hold: an API the user points
            // pillr at. Once saved, each one is a ring under Accounts too.
            CustomEndpointsSettingsView(preferences: preferences)
        }
        .formStyle(NotchFormStyle())
        .animation(.snappy(duration: 0.22), value: items.map(\.id))
        .onAppear {
            if !snapshotsForRender.isEmpty {
                snapshots = Dictionary(snapshotsForRender.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            if let initialForm { form = APIKeyFormRequest(preset: initialForm.isEmpty ? nil : initialForm) }
            takeRequest()
        }
        .onChange(of: addRequest) { _, _ in takeRequest() }
        .onReceive((usageStore?.$snapshots.eraseToAnyPublisher()
                    ?? Empty<[ProviderSnapshot], Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { list in
                snapshots = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
        .onReceive((usageStore?.$refreshing.eraseToAnyPublisher()
                    ?? Empty<Set<String>, Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { refreshing = $0 }
    }

    private var addButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { form = APIKeyFormRequest(preset: nil) }
        } label: {
            Label(L10n.t("Add Key"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        // The heading it sits beside is small capitals; the button is not.
        .textCase(nil)
        .tracking(0)
        .font(.system(size: 12))
        .help(L10n.t("Add an API key to track"))
    }

    private func takeRequest() {
        guard let request = addRequest else { return }
        addRequest = nil
        withAnimation(.snappy(duration: 0.22)) {
            form = APIKeyFormRequest(preset: request.isEmpty ? nil : request)
        }
    }

    /// Whether a base provider's own ring already reads a key — a pasted one,
    /// or one borrowed from a coding tool. Then a new one is its second.
    private func hasOwnKey(_ base: String) -> Bool {
        if basePresent(base) { return true }
        return usageStore?.providerSummaries.first { $0.id == base }?.account != nil
    }

    private func remove(_ item: APIKeyItem) {
        if item.extra != nil {
            ExtraKeyVerifier.remove(item.id, from: preferences)
            return
        }
        BaseKeySlot.delete(item.id)
        revision += 1
        // A base provider may still read a key some coding tool holds; only
        // when nothing is left is its ring switched off and forgotten.
        if let store = usageStore {
            store.reauthorize(providerID: item.id)
            if store.providerSummaries.first(where: { $0.id == item.id })?.account == nil {
                signOut(item.id)
                preferences.setConnected(false, for: item.id)
            }
        }
    }
}

/// Opening the form, with a provider already chosen or not. A fresh id each
/// time so the form starts clean.
struct APIKeyFormRequest: Identifiable, Equatable {
    var id = UUID()
    let preset: String?

    /// The form an empty pane opens with — one id, so it is not rebuilt on
    /// every draw.
    static let firstKey = APIKeyFormRequest(id: UUID(), preset: nil)
}

// MARK: - A key's row

struct APIKeyRow: View {
    let item: APIKeyItem
    @ObservedObject var preferences: Preferences
    var usageStore: UsageStore?
    let snapshot: ProviderSnapshot?
    let isChecking: Bool
    let remove: () -> Void

    @State private var renaming = false
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var confirmingRemove = false
    @FocusState private var renameFocused: Bool

    private var entry: APICatalogEntry? { item.entry }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderGlyphView(glyph: entry?.glyph ?? .apiKey, size: 16)
                .foregroundStyle(isOn ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 3) {
                if renaming, let extra = item.extra {
                    renameField(extra)
                } else {
                    Text(item.title)
                        .foregroundStyle(isOn ? .primary : .secondary)
                }
                statusLine
                    .font(.caption)
            }
            Spacer(minLength: 8)
            // Switched on and off here: its line in the API keys cell is the
            // only place a key is drawn.
            Toggle(item.title, isOn: Binding(get: { isOn },
                                             set: { preferences.setConnected($0, for: item.id) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(L10n.t("Read this key, or stop reading it. A key switched off keeps its place."))
            menu
        }
        .confirmationDialog(L10n.t("Remove \(item.title)?"), isPresented: $confirmingRemove) {
            Button(L10n.t("Remove"), role: .destructive) { remove() }
        } message: {
            Text(L10n.t("Deletes this key from your login keychain. Its readings go with it."))
        }
    }

    private var isOn: Bool { preferences.isConnected(item.id) }

    /// One line: what the key last read, or why it could not.
    @ViewBuilder
    private var statusLine: some View {
        if isChecking {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(L10n.t("Checking…")).foregroundStyle(.secondary)
            }
        } else if !isOn {
            Text(L10n.t("Switched off. Nothing is read."))
                .foregroundStyle(.tertiary)
        } else if let line = Self.line(for: snapshot) {
            Text(line.text)
                .foregroundStyle(line.isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L10n.t("Not read yet"))
                .foregroundStyle(.tertiary)
        }
    }

    /// The row's words for a reading. Pure, for the tests.
    static func line(for snapshot: ProviderSnapshot?) -> (text: String, isProblem: Bool)? {
        guard let snapshot else { return nil }
        switch snapshot.status {
        case .needsAuth, .accessDenied, .signedOutByOwner, .error, .unsupported:
            return (APIKeyGroup.problem(for: snapshot) ?? L10n.t("That key was not accepted"), true)
        case .ok, .stale:
            guard let headline = snapshot.headline else {
                return snapshot.status.staleSince == .distantPast ? nil : (L10n.t("No reading"), false)
            }
            // Every figure the key gave — left, this month, in total — the
            // headline first.
            let others = snapshot.windows.filter { $0.id != headline.id }
            let texts = ([headline] + others).map { $0.detail ?? $0.summary }
            return (texts.joined(separator: " · "), false)
        }
    }

    private var menu: some View {
        Menu {
            if let extra = item.extra {
                Button(L10n.t("Rename…")) {
                    renameText = extra.name
                    renameError = nil
                    renaming = true
                    renameFocused = true
                }
            }
            Button(L10n.t("Check now")) { usageStore?.reauthorize(providerID: item.id) }
                .disabled(usageStore == nil || !isOn)
            if let entry {
                Button(L10n.t("Open \(entry.consoleURL.host ?? entry.name)")) {
                    NSWorkspace.shared.open(entry.consoleURL)
                }
            }
            Divider()
            Button(L10n.t("Remove…"), role: .destructive) { confirmingRemove = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("Rename, check or remove this key"))
        .accessibilityLabel(L10n.t("Key actions"))
    }

    private func renameField(_ extra: ExtraKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(ExtraKey.providerName(for: extra.base) + " ·")
                TextField(L10n.t("Name"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 160)
                    .focused($renameFocused)
                    .onSubmit { commitRename(extra) }
                    .onExitCommand { renaming = false; renameError = nil }
            }
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func commitRename(_ extra: ExtraKey) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == extra.name { renaming = false; return }
        if preferences.renameExtraKey(id: extra.id, to: name) {
            renaming = false
            renameError = nil
        } else {
            renameError = name.isEmpty
                ? L10n.t("Give the key a name")
                : L10n.t("There is already a key called \(name)")
        }
    }
}

// MARK: - Adding one

/// Where Add has got to.
enum APIKeyFormPhase: Equatable {
    case idle
    case checking
    case failed(String)
}

/// The add form: a provider, the key, and only what that provider needs
/// besides. Add checks the key with a real request and keeps it only if
/// that came back; Return adds, Escape cancels.
struct APIKeyForm: View {
    @ObservedObject var preferences: Preferences
    var usageStore: UsageStore?
    let preset: String?
    /// Whether a base provider's own ring already reads a key.
    var hasOwnKey: (String) -> Bool = { _ in true }
    /// Whether there is anywhere to go back to: with no key yet, the form is
    /// the pane's invitation and stays.
    var canCancel = true
    /// For renders: what has been typed into the provider field.
    var queryForRender: String? = nil
    /// The id of the key added, or nil when the form was cancelled.
    let done: (String?) -> Void

    @State private var entryID: String?
    @State private var key = ""
    @State private var name = ""
    @State private var region = ""
    @State private var fields: [String: String] = [:]
    @State private var phase: APIKeyFormPhase = .idle
    /// What is typed into the provider field.
    @State private var query = ""
    /// The suggestions are showing: while typing, or when the arrow asked.
    @State private var searching = false
    /// The suggestion Return takes; the arrow keys move it.
    @State private var highlight = 0
    @FocusState private var keyFocused: Bool
    @FocusState private var providerFocused: Bool

    private var suggestions: [APICatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? APICatalog.popular : APICatalog.search(trimmed)
    }

    private var entry: APICatalogEntry? { entryID.flatMap(APICatalog.entry(id:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("Add an API key"))
                .font(.system(size: 13, weight: .semibold))

            row(L10n.t("Provider")) { providerField }
            if searching {
                APIProviderSuggestions(query: query, results: suggestions, highlight: highlight,
                                       selected: entryID, hover: { highlight = $0 }, choose: choose)
                    .padding(.leading, Self.labelWidth + 10)
                    .transition(.opacity)
            }

            // A provider whose ordinary key is refused says so before
            // anything is pasted: which key, and where it is made.
            if let entry, !searching, let guide = APICatalog.keyGuide(for: entry.id) {
                KeyGuideCallout(text: guide, keyURL: entry.consoleURL)
                    .padding(.leading, Self.labelWidth + 10)
                    .transition(.opacity)
            }

            // The three a key always needs are there from the start; the
            // rest only once the provider says it wants them.
            row(L10n.t("API key")) {
                SecureField(entry?.keyPrefix.map { "\($0)…" } ?? L10n.t("Paste your key"), text: $key)
                    // An API key is not a website password: without this,
                    // macOS offers "Passwords…" over the field.
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .focused($keyFocused)
                    .onSubmit(add)
            }
            row(L10n.t("Name")) {
                TextField(entry.map(defaultName(for:)) ?? L10n.t("Key \(1)"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .onSubmit(add)
            }

            if let entry {
                if entry.regions.count > 1 {
                    row(L10n.t("Region")) {
                        Picker(selection: $region) {
                            ForEach(entry.regions, id: \.id) { Text($0.title()).tag($0.id) }
                        } label: { EmptyView() }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                    }
                }
                ForEach(entry.fields, id: \.id) { field in
                    row(field.title()) {
                        TextField(field.placeholder.isEmpty ? (field.required ? "" : L10n.t("Optional")) : field.placeholder,
                                  text: binding(for: field.id))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 260)
                            .onSubmit(add)
                    }
                }
                // With a key guide above, its link and its words about the
                // key are already said: only what will be shown is left.
                let guided = APICatalog.keyGuide(for: entry.id) != nil
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(guided ? entry.shownNote : entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.labelWidth + 10)
                if !guided {
                    Link(L10n.t("Get a key"), destination: entry.consoleURL)
                        .font(.caption)
                        .padding(.leading, Self.labelWidth + 10)
                }
            }

            if case .failed(let reason) = phase {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.labelWidth + 10)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if canCancel {
                    Button(L10n.t("Cancel")) { done(nil) }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
                if phase == .checking {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("Checking…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(L10n.t("Add"), action: add)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canAdd)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .animation(.snappy(duration: 0.18), value: searching)
        .onAppear {
            if let preset, APICatalog.entry(id: preset) != nil {
                choose(preset)
            } else {
                // Nothing chosen: the provider is the first thing to type.
                DispatchQueue.main.async { providerFocused = true }
            }
            if let queryForRender {
                query = queryForRender
                searching = true
            }
        }
    }

    static let labelWidth: CGFloat = 78

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Type to search; the suggestions open under it as you go. Once a
    /// provider is chosen the field wears its mark and name, and typing over
    /// it searches again.
    private var providerField: some View {
        HStack(spacing: 7) {
            Group {
                if let entry, query == entry.name {
                    ProviderGlyphView(glyph: entry.glyph, size: 14)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            TextField(L10n.t("Search providers"), text: $query)
                .textFieldStyle(.plain)
                .focused($providerFocused)
                .onChange(of: query) { _, text in
                    guard text != entry?.name else { return }
                    searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
                    highlight = 0
                }
                .onKeyPress(.downArrow) {
                    guard searching else { searching = true; return .handled }
                    highlight = min(highlight + 1, max(suggestions.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlight = max(highlight - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Back to the provider already chosen, if there is one;
                    // otherwise Escape is the form's to cancel.
                    // Close the list, back to the provider already chosen;
                    // with no list open, Escape is the form's to cancel.
                    guard searching else { return .ignored }
                    searching = false
                    if let entry { query = entry.name }
                    return .handled
                }
                .onSubmit {
                    if searching, suggestions.indices.contains(highlight) {
                        choose(suggestions[highlight].id)
                    } else if !searching {
                        add()
                    }
                }
            // Clears what was typed, or opens the list to browse.
            let typing = !query.isEmpty && query != entry?.name
            Button {
                if typing {
                    query = ""
                    searching = false
                } else {
                    highlight = 0
                    searching.toggle()
                }
                providerFocused = true
            } label: {
                Image(systemName: typing ? "xmark.circle.fill" : "chevron.down")
                    .font(.system(size: typing ? 11 : 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(typing ? L10n.t("Clear the search")
                  : entry == nil ? L10n.t("Show providers") : L10n.t("Choose another provider"))
        }
        .padding(.horizontal, 8)
        .frame(width: 360, height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(providerFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.15),
                          lineWidth: providerFocused ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Provider"))
        .accessibilityValue(entry?.name ?? "")
    }

    private func choose(_ id: String) {
        guard let entry = APICatalog.entry(id: id) else { return }
        query = entry.name
        searching = false
        guard id != entryID else {
            DispatchQueue.main.async { keyFocused = true }
            return
        }
        entryID = id
        region = (entry.id == "glm" || entry.id == "minimax")
            ? (ExtraKey.defaultRegion(for: entry.id) ?? entry.regions.first?.id ?? "")
            : (entry.regions.first?.id ?? "")
        fields = [:]
        phase = .idle
        DispatchQueue.main.async { keyFocused = true }
    }

    private func binding(for field: String) -> Binding<String> {
        Binding(get: { fields[field] ?? "" }, set: { fields[field] = $0 })
    }

    private func defaultName(for entry: APICatalogEntry) -> String {
        ExtraKey.defaultName(base: entry.id, existing: preferences.extraKeys,
                             hasOwnKey: ExtraKey.bases.contains(entry.id) ? hasOwnKey(entry.id) : false)
    }

    private var canAdd: Bool {
        guard let entry, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return entry.fields.allSatisfy { !$0.required || !(fields[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func add() {
        guard canAdd, phase != .checking, let entry else { return }
        let base = entry.id
        let secret = key
        let typedName = name
        let chosenRegion = entry.regions.isEmpty ? nil : region
        let extraFields = fields
        phase = .checking
        Task { @MainActor in
            // A base provider with nothing to read yet takes the key as its
            // own, so its ring under Accounts comes alive rather than a second
            // one appearing beside an empty first.
            if ExtraKey.bases.contains(base), let store = usageStore,
               !hasOwnKey(base), typedName.trimmingCharacters(in: .whitespaces).isEmpty {
                BaseKeySlot.store(base, key: secret, region: chosenRegion, preferences: preferences)
                let status = await store.probe(providerID: base)
                switch status {
                case .ok, .stale:
                    preferences.setConnected(true, for: base)
                    store.refresh(providerID: base)
                    done(base)
                default:
                    BaseKeySlot.delete(base)
                    phase = .failed(ExtraKeyVerifier.reason(for: status))
                    keyFocused = true
                }
                return
            }
            let outcome = await ExtraKeyVerifier.add(
                base: base, name: typedName, key: secret, region: chosenRegion, fields: extraFields,
                existing: preferences.extraKeys,
                hasOwnKey: ExtraKey.bases.contains(base) ? hasOwnKey(base) : false)
            switch outcome {
            case .added(let extra):
                preferences.addExtraKey(extra)
                done(extra.id)
            case .failed(let reason):
                phase = .failed(reason)
                keyFocused = true
            }
        }
    }
}

/// The note a special key gets: which one, where to make it — tinted, so
/// it is read before the wrong key is pasted.
struct KeyGuideCallout: View {
    let text: String
    let keyURL: URL

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(L10n.t("Open \(keyURL.host ?? keyURL.absoluteString)"), destination: keyURL)
                    .font(.system(size: 11.5, weight: .medium))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.30), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The provider suggestions

/// What the provider field offers as you type: the best matches first, the
/// typed letters in bold, each with its group and what its key can tell.
/// Before anything is typed, the keys people most often hold.
struct APIProviderSuggestions: View {
    let query: String
    let results: [APICatalogEntry]
    let highlight: Int
    let selected: String?
    let hover: (Int) -> Void
    let choose: (String) -> Void
    /// Rows before the list scrolls; renders show them all.
    var shown = Self.shown

    static let shown = 7
    static let rowHeight: CGFloat = 30

    private var typed: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(typed ? L10n.t("Suggestions") : L10n.t("Popular"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 3)
            if results.isEmpty {
                Text(L10n.t("No provider matches “\(query)”"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                row(entry, index: index).id(index)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(results.count, shown)) * Self.rowHeight)
                    .onChange(of: highlight) { _, index in proxy.scrollTo(index) }
                }
            }
            Text(typed
                 ? L10n.t("↑↓ to move · Return to choose")
                 : L10n.t("Type a name, or what it does: voice, search, China… \(APICatalog.entries.count) providers"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 7)
        }
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func row(_ entry: APICatalogEntry, index: Int) -> some View {
        let lit = index == highlight
        return Button { choose(entry.id) } label: {
            HStack(spacing: 8) {
                ProviderGlyphView(glyph: entry.glyph, size: 14)
                    .foregroundStyle(.primary)
                    .frame(width: 16)
                Text(highlighted(entry.name))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.category.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if entry.id == selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 8)
                ReadabilityBadge(readability: entry.readability)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(lit ? Color.accentColor.opacity(0.16) : Color.clear)
                .padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hover(index) } }
        .help(entry.note)
    }

    /// The name with what was typed in bold.
    private func highlighted(_ name: String) -> AttributedString {
        var text = AttributedString(name)
        for range in APICatalog.matchedRanges(in: name, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .system(size: 13, weight: .bold)
        }
        return text
    }
}

/// What a provider's key can tell, as a small capsule.
struct ReadabilityBadge: View {
    let readability: APIKeyReadability

    private var color: Color {
        switch readability {
        case .usage: return .green
        case .adminKey: return .orange
        case .keyCheck: return .secondary
        }
    }

    var body: some View {
        Text(readability.badge)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(readability == .keyCheck ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
            .fixedSize()
    }
}
