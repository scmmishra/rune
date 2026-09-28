import AppKit
import Combine
import Foundation

nonisolated struct PanelItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let trailing: String?
    let badges: [PanelBadge]
    let isUnread: Bool
    /// Whether each action of the view this item opens applies to it.
    let actions: [Bool]
    let raw: PanelValue
}

nonisolated struct PanelBadge: Hashable, Sendable {
    let text: String
    /// The index of the badge rule that produced it.
    let rule: Int
}

nonisolated struct PanelMessage: Identifiable, Sendable {
    let id: Int
    let author: String?
    let text: String
    let time: String?
    let isTrailing: Bool
    let isMuted: Bool
    var label: String?
    var context: String?
}

nonisolated struct PanelHeader: Sendable {
    let title: String?
    let badges: [PanelBadge]
    let meta: [String]
}

/// The live state of one open panel: its inputs, the list, and at most one opened item.
@MainActor
final class PanelModel: ObservableObject {
    struct Detail {
        let view: PanelViewSpec
        /// Replaced by the view's `item` expression once its command runs, so titles and
        /// actions follow the latest data rather than the row it was opened from.
        var item: PanelItem
        /// The panel opened straight onto this view, so there is no list to go back to.
        var isRoot = false
        var header: PanelHeader?
        var messages: [PanelMessage] = []
        var markdown: String?
        var isLoading = false
        var hasLoaded = false
        var error: String?
    }

    struct PendingAction: Identifiable {
        let id = UUID()
        let action: PanelAction
        let arguments: [String]
    }

    let definition: PanelDefinition
    let rootURL: URL
    @Published private(set) var values: [String: String]
    @Published private(set) var fetchedOptions: [String: [PanelOption]] = [:]
    @Published private(set) var items: [PanelItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var setupProblem: String?
    @Published private(set) var detail: Detail?
    /// The view the panel opened on; nil while a route is still deciding.
    @Published private(set) var rootName: String?
    /// The action waiting on the user's text.
    @Published var prompting: PanelAction?
    @Published var promptText = ""
    /// A command shown to the user before it runs.
    @Published var confirming: PendingAction?
    @Published private(set) var runningAction: Int?
    @Published var actionError: String?

    private var page = 1
    private var isDone = true
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var isStarted = false

    // Reopening a panel shows its last results at once, then refreshes them.
    private static var listCache: [String: (items: [PanelItem], isDone: Bool)] = [:]
    private static var optionCache: [String: (options: [PanelOption], date: ContinuousClock.Instant)] = [:]
    private static var savedValues: [String: [String: String]] = [:]

    init(definition: PanelDefinition, rootURL: URL) {
        self.definition = definition
        self.rootURL = rootURL
        // Filters follow the file: a global panel keeps them across projects, a project panel per project.
        values = Self.savedValues[definition.fileURL.path]
            ?? Dictionary(uniqueKeysWithValues: definition.inputs.map { ($0.id, $0.defaultValue) })
    }

    /// Commands run in the project folder, so the same arguments can mean different data
    /// in another project. Results are cached per project as well as per panel file.
    private var cacheScope: String {
        rootURL.standardizedFileURL.path + "\u{0}" + definition.fileURL.path
    }

    var rootView: PanelViewSpec? { rootName.flatMap { definition.views[$0] } }

    private var openedView: PanelViewSpec? {
        rootView?.item?.open.flatMap { definition.views[$0] }
    }

    func options(for input: PanelInput) -> [PanelOption] {
        input.source == nil ? input.options : fetchedOptions[input.id] ?? []
    }

    func value(for input: PanelInput) -> String { values[input.id] ?? "" }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        if let problem = definition.problem {
            setupProblem = problem
            return
        }
        if let missing = definition.requires.first(where: { PanelRunner.executable(named: $0) == nil }) {
            setupProblem = "This panel needs \(missing). Install it, then reopen the panel."
            return
        }
        for input in definition.inputs where input.source != nil { loadOptions(for: input) }
        // The check runs beside the first fetch rather than before it, so a working setup costs no time.
        if let check = definition.check {
            Task {
                do {
                    _ = try await PanelRunner.run(try PanelTemplate.arguments(check, context: context()), in: rootURL)
                } catch is CancellationError {
                } catch {
                    stop()
                    isLoading = false
                    setupProblem = "`\(check)` failed. Sign in or fix the setup from your terminal, then reopen the panel.\n\n"
                        + error.localizedDescription
                }
            }
        }
        rootName = await route()
        guard setupProblem == nil, let view = rootView else { return }
        if view.kind == .detail {
            detail = Detail(view: view, item: PanelItem(
                id: "root", title: definition.title, subtitle: nil, trailing: nil, badges: [],
                isUnread: false, actions: [], raw: .null
            ), isRoot: true)
            loadDetail()
        } else {
            reload()
        }
    }

    /// Picks the opening view: the route's jq expression names it from its command's output.
    private func route() async -> String? {
        guard let route = definition.route else { return definition.root }
        do {
            let arguments = try PanelTemplate.arguments(route.command, context: context())
            let output = try await PanelRunner.run(arguments, in: rootURL)
            let name = try await PanelRunner.jq(PanelRunner.routeProgram(route.view), input: output, in: rootURL).string
            if let name, definition.views[name] != nil { return name }
            if let fallback = route.fallback { return fallback }
            setupProblem = "The route chose \(name ?? "no view"), which is not defined."
        } catch {
            if let fallback = route.fallback { return fallback }
            guard !(error is CancellationError) else { return nil }
            setupProblem = error.localizedDescription
        }
        return nil
    }

    func stop() {
        listTask?.cancel()
        detailTask?.cancel()
    }

    func set(_ input: PanelInput, to value: String) {
        guard values[input.id] != value else { return }
        values[input.id] = value
        Self.savedValues[definition.fileURL.path] = values
        reload(after: input.kind == .search ? input.debounce : nil)
    }

    // MARK: List

    private func context(item: PanelItem? = nil, extra: [String: String] = [:]) -> PanelValue {
        var object = values.mapValues(PanelValue.string)
        object["page"] = .number(Double(page))
        if let variable = rootView?.pagination?.variable { object[variable] = .number(Double(page)) }
        object["env"] = .object(ProcessInfo.processInfo.environment.mapValues(PanelValue.string))
        if let item { object["item"] = item.raw }
        for (key, value) in extra { object[key] = .string(value) }
        return .object(object)
    }

    /// Fetches the first page again. A silent reload keeps the rows on screen until it lands.
    func reload(after delay: Duration? = nil, silently: Bool = false) {
        guard setupProblem == nil, let view = rootView, view.kind == .list, let command = view.command else { return }
        listTask?.cancel()
        listTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            page = view.pagination?.start ?? 1
            let key: String
            let arguments: [String]
            do {
                arguments = try PanelTemplate.arguments(command, context: context())
                key = cacheScope + "\u{0}" + arguments.joined(separator: "\u{0}")
            } catch {
                self.error = error.localizedDescription
                return
            }
            if !silently {
                if let cached = Self.listCache[key] {
                    items = cached.items
                    isDone = cached.isDone
                } else {
                    items = []
                }
            }
            isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let (loaded, done) = try await fetch(arguments, view: view)
                guard !Task.isCancelled else { return }
                items = loaded
                isDone = done
                error = nil
                Self.listCache[key] = (loaded, done)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Loads the next page when the last row scrolls into view.
    func loadMore() {
        guard let view = rootView, let command = view.command, view.pagination != nil,
              !isDone, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        page += 1
        listTask = Task {
            defer { isLoadingMore = false }
            do {
                let arguments = try PanelTemplate.arguments(command, context: context())
                let (loaded, done) = try await fetch(arguments, view: view)
                guard !Task.isCancelled else { return }
                let known = Set(items.map(\.id))
                items += loaded.filter { !known.contains($0.id) }
                isDone = done || loaded.isEmpty
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                page -= 1
                self.error = error.localizedDescription
            }
        }
    }

    /// The refresh timer. Paging past the first page resets on refresh, so the timer skips it
    /// rather than jump the list back to the top under the reader.
    func refreshInBackground() {
        if detail?.isRoot == true {
            loadDetail()
        } else if detail == nil, page == (rootView?.pagination?.start ?? 1) {
            reload(silently: true)
        }
    }

    private func fetch(_ arguments: [String], view: PanelViewSpec) async throws -> ([PanelItem], Bool) {
        let output = try await PanelRunner.run(arguments, in: rootURL)
        let program = PanelRunner.listProgram(view, openedActions: openedView?.actions ?? [])
        let mapped = try await PanelRunner.jq(program, input: output, in: rootURL)
        var seen: Set<String> = []
        let items = (mapped["items"]?.array ?? []).enumerated().compactMap { index, value -> PanelItem? in
            // Rows without an id fall back to their position; duplicates would confuse the list.
            let id = value["id"]?.string ?? "#\(index)"
            guard seen.insert(id).inserted else { return nil }
            return PanelItem(
                id: id,
                title: value["title"]?.string ?? "",
                subtitle: value["subtitle"]?.string,
                trailing: value["trailing"]?.string,
                badges: Self.badges(value["badges"]),
                isUnread: value["unread"]?.bool ?? false,
                actions: value["actions"]?.array?.map { $0.bool ?? false } ?? [],
                raw: value["raw"] ?? .null
            )
        }
        return (items, mapped["done"]?.bool ?? true)
    }

    private static func badges(_ value: PanelValue?) -> [PanelBadge] {
        value?.array?.compactMap { badge in
            guard let text = badge["text"]?.string else { return nil }
            return PanelBadge(text: text, rule: Int(badge["rule"]?.text ?? "") ?? 0)
        } ?? []
    }

    private func loadOptions(for input: PanelInput) {
        guard let source = input.source else { return }
        let cacheKey = cacheScope + "\u{0}" + source.command
        if let cached = Self.optionCache[cacheKey], cached.date.duration(to: .now) < input.cache {
            fetchedOptions[input.id] = cached.options
            return
        }
        Task {
            do {
                let arguments = try PanelTemplate.arguments(source.command, context: context())
                let output = try await PanelRunner.run(arguments, in: rootURL)
                let mapped = try await PanelRunner.jq(PanelRunner.optionsProgram(source), input: output, in: rootURL)
                let options = (mapped.array ?? []).compactMap { option -> PanelOption? in
                    guard let value = option["value"]?.string else { return nil }
                    return PanelOption(label: option["label"]?.string ?? value, value: value)
                }
                fetchedOptions[input.id] = options
                Self.optionCache[cacheKey] = (options, .now)
            } catch {
                // The menu stays empty; the list itself still works without this filter.
            }
        }
    }

    // MARK: Detail

    func open(_ item: PanelItem) {
        guard let view = openedView else { return }
        detail = Detail(view: view, item: item)
        loadDetail()
    }

    var canGoBack: Bool {
        guard let detail else { return false }
        return !detail.isRoot || detail.view.back != nil
    }

    func closeDetail() {
        guard let current = detail, canGoBack else { return }
        detailTask?.cancel()
        // A view the panel opened on steps back to its list, which becomes the panel's view.
        if current.isRoot, let back = current.view.back {
            rootName = back
            detail = nil
            reload()
        }
        prompting = nil
        promptText = ""
        actionError = nil
        detail = nil
    }

    func title(of detail: Detail) -> String {
        guard let title = detail.view.title else { return detail.item.title }
        let rendered = PanelTemplate.render(title, context: context(item: detail.item))
        // A root view has no item until its command lands.
        if rendered.isMissing, case .null = detail.item.raw { return definition.title }
        return rendered.text
    }

    func loadDetail() {
        guard let current = detail, let command = current.view.command else { return }
        detailTask?.cancel()
        detail?.isLoading = true
        detailTask = Task {
            do {
                let arguments = try PanelTemplate.arguments(command, context: context(item: current.item))
                let output = try await PanelRunner.run(arguments, in: rootURL)
                let mapped = try await PanelRunner.jq(PanelRunner.detailProgram(current.view), input: output, in: rootURL)
                guard !Task.isCancelled, detail?.item.id == current.item.id else { return }
                if let raw = mapped["item"], raw != .null {
                    let item = current.item
                    detail?.item = PanelItem(
                        id: item.id, title: item.title, subtitle: item.subtitle, trailing: item.trailing,
                        badges: item.badges, isUnread: item.isUnread,
                        actions: mapped["actions"]?.array?.map { $0.bool ?? false } ?? [], raw: raw
                    )
                }
                if let header = mapped["header"], header != .null {
                    detail?.header = PanelHeader(
                        title: header["title"]?.string,
                        badges: Self.badges(header["badges"]),
                        meta: header["meta"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
                    )
                }
                let body = mapped["body"] ?? .null
                switch current.view.body?.kind {
                case .markdown?:
                    detail?.markdown = body.string ?? ""
                case .thread?, .timeline?:
                    detail?.messages = (body.array ?? []).enumerated().map { index, value in
                        PanelMessage(
                            id: index,
                            author: value["author"]?.string,
                            text: value["text"]?.string ?? "",
                            time: value["time"]?.string,
                            isTrailing: value["side"]?.string == "trailing",
                            isMuted: value["muted"]?.bool ?? false,
                            label: value["label"]?.string,
                            context: value["context"]?.string
                        )
                    }
                case nil: break
                }
                detail?.error = nil
                detail?.isLoading = false
                detail?.hasLoaded = true
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), detail?.item.id == current.item.id else { return }
                detail?.error = error.localizedDescription
                detail?.isLoading = false
            }
        }
    }

    // MARK: Actions

    func visibleActions(in detail: Detail) -> [PanelAction] {
        detail.view.actions.filter { action in
            guard action.when != nil else { return true }
            return detail.item.actions.indices.contains(action.id) && detail.item.actions[action.id]
        }
    }

    func trigger(_ action: PanelAction) {
        guard let detail else { return }
        actionError = nil
        if let url = action.url {
            let rendered = PanelTemplate.render(url, context: context(item: detail.item))
            guard !rendered.isMissing, let target = URL(string: rendered.text) else {
                actionError = "Could not build the link for \(action.title)."
                return
            }
            NSWorkspace.shared.open(target)
            return
        }
        if action.prompt != nil {
            prompting = action
            promptText = ""
            return
        }
        prepare(action, text: nil)
    }

    func submitPrompt() {
        guard let action = prompting else { return }
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prepare(action, text: text)
    }

    private func prepare(_ action: PanelAction, text: String?) {
        guard let detail, let command = action.command else { return }
        do {
            let extra = action.prompt.map { [$0.id: text ?? ""] } ?? [:]
            let arguments = try PanelTemplate.arguments(command, context: context(item: detail.item, extra: extra))
            let pending = PendingAction(action: action, arguments: arguments)
            if action.confirm == nil { run(pending) } else { confirming = pending }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func run(_ pending: PendingAction) {
        confirming = nil
        runningAction = pending.action.id
        Task {
            defer { runningAction = nil }
            do {
                _ = try await PanelRunner.run(pending.arguments, in: rootURL)
                if prompting?.id == pending.action.id {
                    prompting = nil
                    promptText = ""
                }
                switch pending.action.after {
                case .refresh: loadDetail()
                // A root view has nothing to go back to, so it shows the change instead.
                case .back: if detail?.isRoot == true { loadDetail() } else { closeDetail() }
                case .none: break
                }
                // Whatever the action changed likely shows in the list too.
                reload(silently: true)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
