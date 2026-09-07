import AppKit
import SwiftUI

struct ChangeGuideDrawer: View {
    let rootURL: URL
    @ObservedObject var model: ChangeGuideModel
    let onClose: () -> Void
    @EnvironmentObject private var repository: GitSidebarModel
    @AppStorage(GuideAgent.preferenceKey) private var preferredAgent = GuideAgent.defaultPreference
    @State private var openedReference: GuideSnapshot.Reference?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.scope == .pr {
                HStack(spacing: 10) {
                    Text("Compare against")
                    TextField("Branch or remote branch", text: $model.comparisonBranch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(model.isGenerating)
                    Text("Committed changes since the branches diverged")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .runeFont(size: 11)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            if let reference = openedReference, let entry = model.entry {
                HStack {
                    Button { openedReference = nil } label: {
                        Label("Back to Brief", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(reference.path).lineLimit(1).truncationMode(.middle)
                    Text("Captured diff").foregroundStyle(.secondary)
                }
                .runeFont(size: 11)
                .padding(14)
                Divider()
                CodeEditorView(
                    text: .constant(entry.snapshot.files[reference.fileIndex].patch),
                    fileURL: rootURL.appending(path: reference.path),
                    isEditable: false, presentation: .diff
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // AppKit rulers can draw beyond their SwiftUI host; keep them below the guide headers.
                .clipped()
            } else if let entry = model.entry {
                status
                HStack(spacing: 0) {
                    outline(entry.guide)
                    Divider()
                    readingArea(entry)
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        .background {
            GitPreviewEscapeMonitor {
                if openedReference != nil { openedReference = nil } else { onClose() }
            }
        }
        .task(id: "\(model.scope.rawValue):\(model.comparisonBranch):\(repository.contentRevision):\(model.paletteRequestID)") {
            if model.scope == .pr {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            await model.check(rootURL: rootURL)
            guard !Task.isCancelled, model.openFromPalette else { return }
            model.openFromPalette = false
            if model.entry == nil {
                model.generate(rootURL: rootURL, agent: preferredAgent)
            }
        }
        .onChange(of: model.paletteRequestID) {
            openedReference = nil
        }
        .onChange(of: model.comparisonBranch) {
            openedReference = nil
            model.selectedSection = -1
        }
        .onChange(of: model.scope) {
            openedReference = nil
            model.selectedSection = -1
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Change Brief", systemImage: "sparkles")
                .runeFont(size: 12, weight: .medium)
            Picker("Changes", selection: $model.scope) {
                ForEach(GuideScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                        .disabled(scope == .pr && !model.allowsPR)
                }
            }
            .labelsHidden()
            .frame(width: 135)
            .disabled(model.isGenerating)
            Spacer(minLength: 0)
            Picker("Agent", selection: $preferredAgent) {
                ForEach(GuideAgent.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 125)
            .disabled(model.isGenerating)
            if model.isGenerating {
                GuideProgressView()
                Button("Cancel", action: model.cancel)
            } else {
                Button(model.entry == nil ? "Generate Brief" : "Refresh") {
                    openedReference = nil
                    model.generate(rootURL: rootURL, agent: preferredAgent)
                }
                .disabled(model.isChecking || model.currentSnapshot == nil)
            }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(WorkspaceButtonStyle())
                .help("Close Brief (Esc)")
                .accessibilityLabel("Close brief")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private var status: some View {
        if model.isGenerating || model.isStale || model.errorMessage != nil {
            HStack(spacing: 8) {
                Image(systemName: model.errorMessage == nil ? "info.circle" : "exclamationmark.triangle")
                Text(model.errorMessage ?? (model.isGenerating
                    ? "Generating with \((model.generatingAgent ?? preferredAgent).rawValue)… You can keep working while it runs."
                    : "Changes have updated. Refresh the brief when you’re ready; these diffs show the captured version."))
                Spacer(minLength: 0)
            }
            .runeFont(size: 11)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(Color.primary.opacity(0.035))
            Divider()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.isGenerating ? "Putting the changes together" : "Understand your changes")
                .runeFont(size: 20, weight: .medium)
            Text(model.isGenerating
                 ? "\((model.generatingAgent ?? preferredAgent).rawValue) is reading the diff and related code. You can close this panel and return when it’s ready."
                 : "Get a reading order, focused explanations, and diagrams linked to the code that changed.")
                .multilineTextAlignment(.center)
                .runeFont(size: 13)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 390)
            if model.isGenerating || model.isChecking { GuideProgressView() }
            if let error = model.errorMessage {
                Text(error).runeFont(size: 12).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 430)
            }
            if !model.isGenerating {
                Text("Uses your installed agent and its existing login. Working Tree includes unstaged and untracked files.")
                    .runeFont(size: 11).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 390)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outline(_ guide: ChangeGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                outlineRow("Overview", index: -1)
                ForEach(guide.sections.indices, id: \.self) { index in
                    outlineRow("\(index + 1). \(guide.sections[index].title)", index: index)
                }
            }
            .padding(10)
        }
        .frame(width: 237.5)
        .background(Color.primary.opacity(0.025))
    }

    private func outlineRow(_ title: String, index: Int) -> some View {
        Button { model.selectedSection = index } label: {
            Text(title)
                .runeFont(size: 12, weight: model.selectedSection == index ? .medium : .regular)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .contentShape(Rectangle())
                .background(model.selectedSection == index ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedSection == index ? .isSelected : [])
    }

    private func readingArea(_ entry: ChangeGuideModel.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if entry.guide.sections.indices.contains(model.selectedSection) {
                    let section = entry.guide.sections[model.selectedSection]
                    Text(section.title).runeFont(size: 23, weight: .semibold)
                    Text(section.explanation).runeFont(size: 13).lineSpacing(5).textSelection(.enabled)
                    if !section.mermaid.isEmpty {
                        GuideDiagramView(source: section.mermaid, explanation: section.explanation, model: model)
                    }
                    Text("RELEVANT CHANGES").runeFont(size: 10, weight: .semibold).foregroundStyle(.secondary)
                    ForEach(entry.snapshot.references.filter { section.references.contains($0.id) }) { reference in
                        referenceCard(reference)
                    }
                } else {
                    Text(entry.guide.title).runeFont(size: 25, weight: .semibold)
                    Text(entry.guide.overview).runeFont(size: 13).lineSpacing(5).textSelection(.enabled)
                    Text("\(entry.snapshot.files.count) files · \(entry.guide.sections.count) sections · Generated with \(entry.agent.rawValue)")
                        .runeFont(size: 11).foregroundStyle(.secondary)
                    Divider()
                    ForEach(entry.guide.sections.indices, id: \.self) { index in
                        Button { model.selectedSection = index } label: {
                            HStack {
                                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 24)
                                Text(entry.guide.sections[index].title)
                                Spacer()
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            }
                            .runeFont(size: 13, weight: .medium)
                            .padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(model.selectedSection)
    }

    private func referenceCard(_ reference: GuideSnapshot.Reference) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openedReference = reference } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text(reference.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.runeFont(size: 11, weight: .medium).padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open full captured diff")
            Divider()
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(reference.patch.components(separatedBy: "\n").prefix(16).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
            }
            if reference.patch.components(separatedBy: "\n").count > 16 {
                Text("Open full diff to see more").runeFont(size: 10).foregroundStyle(.tertiary).padding([.horizontal, .bottom], 12)
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

private struct GuideDiagramView: View {
    let source: String
    let explanation: String
    @ObservedObject var model: ChangeGuideModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel(explanation)
            } else if failed {
                Label("Diagram unavailable. The explanation above covers this change.", systemImage: "text.alignleft")
                    .runeFont(size: 11).foregroundStyle(.secondary)
            } else {
                GuideProgressView().frame(height: 100)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .task(id: "\(colorScheme):\(source)") {
            image = nil
            failed = false
            do {
                image = try await model.diagram(source: source, dark: colorScheme == .dark)
                failed = image == nil
            } catch is CancellationError { } catch { failed = true }
        }
    }
}
