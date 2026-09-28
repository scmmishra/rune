import Foundation

/// One panel file from `~/.rune/panels`: commands whose JSON output Rune draws natively.
/// Panels live only there, never in a repository, so every panel is one the user wrote.
nonisolated struct PanelDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    let icon: String
    let fileURL: URL
    /// Folders the panel belongs to, from `projects = [...]`. Empty means every project.
    var projects: [URL] = []
    var requires: [String] = []
    var check: String?
    var inputs: [PanelInput] = []
    var views: [String: PanelViewSpec] = [:]
    /// The view the panel opens on, unless a route picks one.
    var root = "list"
    var route: Route?
    /// Why the file could not be read; the drawer shows it in place of the panel.
    var problem: String?

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".rune/panels")

    /// Chooses the opening view from a command's output, such as a pull request for a
    /// feature branch or the pull request list on the default branch.
    struct Route: Sendable {
        let command: String
        /// A jq expression that yields a view name.
        let view: String
        /// The view to use when the command fails or names no view.
        var fallback: String?
    }

    var isProjectSpecific: Bool { !projects.isEmpty }

    /// A listed folder matches itself and anything inside it, so a parent folder can cover
    /// several checkouts.
    func belongs(to project: URL?) -> Bool {
        guard isProjectSpecific else { return true }
        guard let project else { return false }
        let path = project.resolvingSymlinksInPath().standardizedFileURL.path
        return projects.contains { folder in
            let folder = folder.resolvingSymlinksInPath().standardizedFileURL.path
            return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}

nonisolated struct PanelOption: Hashable, Sendable {
    let label: String
    let value: String
}

nonisolated struct PanelInput: Identifiable, Sendable {
    enum Kind: String, Sendable { case segmented, menu, search }

    struct Source: Sendable {
        let command: String
        let each: String
        let label: String
        let value: String
    }

    let id: String
    let kind: Kind
    var label: String?
    var options: [PanelOption] = []
    var source: Source?
    var defaultValue = ""
    var isOptional = false
    var debounce: Duration = .milliseconds(300)
    var cache: Duration = .seconds(600)
}

nonisolated struct PanelViewSpec: Sendable {
    enum Kind: String, Sendable { case list, detail }

    struct Pagination: Sendable {
        let variable: String
        let start: Int
        let until: String
    }

    struct Item: Sendable {
        let id: String
        let title: String
        var subtitle: String?
        var trailing: String?
        var badges: [Badge] = []
        var unread: String?
        var open: String?
    }

    struct Badge: Sendable {
        let text: String
        var when: String?
        /// A color name, or colors by badge text.
        var tints: [String: String] = [:]
        var tint: String?
    }

    struct Body: Sendable {
        enum Kind: String, Sendable { case thread, markdown }
        let kind: Kind
        var each = ".[]"
        var author: String?
        var text = "."
        var time: String?
        var side: String?
        var muted: String?
    }

    let name: String
    let kind: Kind
    var title: String?
    var command: String?
    var each = ".[]"
    var refresh: Duration?
    var pagination: Pagination?
    var empty: String?
    var item: Item?
    /// For a detail view: a jq expression picking the item from the command's output.
    var itemExpression: String?
    var body: Body?
    var actions: [PanelAction] = []
}

nonisolated struct PanelAction: Identifiable, Sendable {
    enum After: String, Sendable { case refresh, back, none }

    struct Prompt: Sendable {
        let id: String
        var isMultiline = true
        var placeholder: String?
    }

    let id: Int
    let title: String
    var icon: String?
    var prompt: Prompt?
    var command: String?
    var url: String?
    /// Nil runs without asking. Actions ask by default, since they change things elsewhere.
    var confirm: String? = "Run this command?"
    var after: After = .refresh
    var when: String?
}

// MARK: - Loading

nonisolated enum PanelLibrary {
    /// The panels for a project: global ones plus those listing it. A project-specific panel
    /// replaces a global one with the same id, so a project can swap in its own variant.
    static func load(project: URL?) -> [PanelDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: PanelDefinition.directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var panels: [String: PanelDefinition] = [:]
        for definition in files.filter({ $0.pathExtension.lowercased() == "toml" }).map(load)
        where definition.belongs(to: project) {
            if let existing = panels[definition.id], existing.isProjectSpecific, !definition.isProjectSpecific { continue }
            panels[definition.id] = definition
        }
        return panels.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func load(_ fileURL: URL) -> PanelDefinition {
        let name = fileURL.deletingPathExtension().lastPathComponent
        do {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            return try decode(TOMLParser.parse(source), fileURL: fileURL)
        } catch {
            // Listed everywhere, so the mistake shows up wherever the user looks for the panel.
            var definition = PanelDefinition(id: name, title: name, icon: "exclamationmark.triangle", fileURL: fileURL)
            definition.problem = error.localizedDescription
            return definition
        }
    }

    static func decode(_ root: PanelValue, fileURL: URL) throws -> PanelDefinition {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let panel = root["panel"] ?? .object([:])
        var definition = PanelDefinition(
            id: panel["id"]?.string ?? name,
            title: panel["title"]?.string ?? name,
            icon: panel["icon"]?.string ?? "rectangle.stack",
            fileURL: fileURL
        )
        definition.projects = (panel["projects"]?.array ?? []).compactMap(\.string).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        definition.requires = panel["requires"]?.array?.compactMap(\.string) ?? []
        definition.check = panel["check"]?.string
        definition.inputs = try (root["input"]?.array ?? []).map(input)
        var inputIDs: Set<String> = []
        if let duplicate = definition.inputs.first(where: { !inputIDs.insert($0.id).inserted }) {
            throw PanelError("Two inputs are named \(duplicate.id).")
        }

        guard case let .object(views)? = root["view"], !views.isEmpty else {
            throw PanelError("Add at least one [view.<name>] table.")
        }
        for (name, value) in views { definition.views[name] = try view(name: name, value) }
        definition.root = panel["root"]?.string ?? (views["list"] != nil ? "list" : views.keys.sorted()[0])
        guard definition.views[definition.root] != nil else { throw PanelError("The root view \(definition.root) is not defined.") }
        if let route = panel["route"] {
            guard let command = route["command"]?.string, let view = route["view"]?.string else {
                throw PanelError("[panel.route] needs a command and a view expression.")
            }
            let fallback = route["fallback"]?.string
            if let fallback, definition.views[fallback] == nil { throw PanelError("The route fallback \(fallback) is not defined.") }
            definition.route = PanelDefinition.Route(command: command, view: view, fallback: fallback)
        }
        for view in definition.views.values {
            if let open = view.item?.open, definition.views[open] == nil {
                throw PanelError("view.\(view.name) opens \(open), which is not defined.")
            }
        }
        return definition
    }

    private static func input(_ value: PanelValue) throws -> PanelInput {
        guard let id = value["id"]?.string else { throw PanelError("Every [[input]] needs an id.") }
        let kindName = value["type"]?.string ?? "segmented"
        guard let kind = PanelInput.Kind(rawValue: kindName) else { throw PanelError("input \(id) has unknown type \(kindName).") }
        var input = PanelInput(id: id, kind: kind)
        input.label = value["label"]?.string
        switch value["options"] {
        case let .array(options)?:
            input.options = options.compactMap { option in
                if let string = option.string { return PanelOption(label: string.capitalized, value: string) }
                guard let optionValue = option["value"] else { return nil }
                return PanelOption(label: option["label"]?.text ?? optionValue.text, value: optionValue.text)
            }
        case let options? where options["command"] != nil:
            input.source = PanelInput.Source(
                command: options["command"]?.string ?? "",
                each: options["each"]?.string ?? ".[]",
                label: options["label"]?.string ?? ".",
                value: options["value"]?.string ?? "."
            )
        default: break
        }
        input.isOptional = value["optional"]?.bool ?? false
        input.defaultValue = value["default"]?.text ?? (input.isOptional ? "" : input.options.first?.value ?? "")
        if let debounce = try duration(value["debounce"]) { input.debounce = debounce }
        if let cache = try duration(value["cache"]) { input.cache = cache }
        return input
    }

    private static func view(name: String, _ value: PanelValue) throws -> PanelViewSpec {
        let kindName = value["type"]?.string ?? "list"
        guard let kind = PanelViewSpec.Kind(rawValue: kindName) else { throw PanelError("view.\(name) has unknown type \(kindName).") }
        var view = PanelViewSpec(name: name, kind: kind)
        view.title = value["title"]?.string
        view.command = value["command"]?.string
        view.each = value["each"]?.string ?? ".[]"
        view.refresh = try duration(value["refresh"])
        view.empty = value["empty"]?.string
        if let paginate = value["paginate"] {
            view.pagination = PanelViewSpec.Pagination(
                variable: paginate["page"]?.string ?? "page",
                start: Int(paginate["start"]?.text ?? "") ?? 1,
                until: paginate["until"]?.string ?? "true"
            )
        }
        if kind == .detail { view.itemExpression = value["item"]?.string }
        if kind == .list {
            guard let item = value["item"], let title = item["title"]?.string else {
                throw PanelError("view.\(name) needs [view.\(name).item] with a title.")
            }
            view.item = PanelViewSpec.Item(
                id: item["id"]?.string ?? ".id",
                title: title,
                subtitle: item["subtitle"]?.string,
                trailing: item["trailing"]?.string,
                badges: (item["badges"]?.array ?? []).compactMap(badge),
                unread: item["unread"]?.string,
                open: item["open"]?.string
            )
        }
        if let body = value["body"] {
            let bodyKind = body["type"]?.string ?? "markdown"
            guard let kind = PanelViewSpec.Body.Kind(rawValue: bodyKind) else { throw PanelError("view.\(name).body has unknown type \(bodyKind).") }
            var spec = PanelViewSpec.Body(kind: kind)
            spec.each = body["each"]?.string ?? ".[]"
            spec.author = body["author"]?.string
            spec.text = body["text"]?.string ?? "."
            spec.time = body["time"]?.string
            spec.side = body["side"]?.string
            spec.muted = body["muted"]?.string
            view.body = spec
        }
        view.actions = try (value["action"]?.array ?? []).enumerated().map { index, value in
            try action(index, value, view: name)
        }
        return view
    }

    private static func badge(_ value: PanelValue) -> PanelViewSpec.Badge? {
        guard let text = value["text"]?.string else { return nil }
        var badge = PanelViewSpec.Badge(text: text, when: value["when"]?.string)
        switch value["tint"] {
        case let .string(tint)?: badge.tint = tint
        case let .object(tints)?: badge.tints = tints.compactMapValues(\.string)
        default: break
        }
        return badge
    }

    private static func action(_ index: Int, _ value: PanelValue, view: String) throws -> PanelAction {
        guard let title = value["title"]?.string else { throw PanelError("Every action in view.\(view) needs a title.") }
        var action = PanelAction(id: index, title: title)
        action.icon = value["icon"]?.string
        action.command = value["command"]?.string
        action.url = value["url"]?.string
        guard action.command != nil || action.url != nil else { throw PanelError("Action \(title) needs a command or a url.") }
        if let prompt = value["prompt"] {
            guard let id = prompt["id"]?.string else { throw PanelError("The prompt on \(title) needs an id.") }
            action.prompt = PanelAction.Prompt(
                id: id,
                isMultiline: prompt["type"]?.string != "text",
                placeholder: prompt["placeholder"]?.string
            )
        }
        switch value["confirm"] {
        case .bool(false)?: action.confirm = nil
        case let .string(message)?: action.confirm = message
        default: break
        }
        // Opening a link changes nothing, so it never asks.
        if action.command == nil { action.confirm = nil }
        if let after = value["after"]?.string {
            guard let parsed = PanelAction.After(rawValue: after) else { throw PanelError("Action \(title) has unknown after = \(after).") }
            action.after = parsed
        }
        action.when = value["when"]?.string
        return action
    }

    /// Reads `400ms`, `30s`, `5m` or `1h`.
    private static func duration(_ value: PanelValue?) throws -> Duration? {
        guard let text = value?.string else { return nil }
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            if let number = Double(text.dropLast(suffix.count)) { return .milliseconds(Int(number * scale * 1000)) }
        }
        throw PanelError("Could not read the duration \(text). Use a value like 30s, 5m or 1h.")
    }
}

nonisolated struct PanelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
