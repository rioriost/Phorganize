import AppKit
#if SWIFT_PACKAGE
import PhorganizeCore
#endif
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhorganizeMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 620, idealWidth: 760, minHeight: 560, idealHeight: 820)
        }
        .defaultSize(width: 760, height: 820)
        .windowStyle(.titleBar)
        .commands {
            OrganizationCommands()
            CommandGroup(replacing: .help) {
                Link(L10n.string("help.privacyPolicy"), destination: URL(string: "https://github.com/rioriost/Phorganize/blob/main/PRIVACY.md")!)
                Link(L10n.string("help.support"), destination: URL(string: "https://github.com/rioriost/Phorganize/issues")!)
            }
        }
    }
}

struct OrganizationCommands: Commands {
    @FocusedObject private var model: AppModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.string("source.choose")) { model?.chooseSource() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil || model?.isProcessing == true)
            Button(L10n.string("destination.choose")) { model?.chooseDestination() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model == nil || model?.isProcessing == true)
            Divider()
            Button(model?.actionTitle ?? L10n.string("action.copyFiles")) { model?.requestRun() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model?.canRun != true)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct BookmarkOperations {
        struct Resolution {
            let url: URL
            let isStale: Bool
        }

        var create: (URL) throws -> Data
        var resolve: (Data) throws -> Resolution

        static let system = BookmarkOperations(
            create: { url in
                try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            resolve: { data in
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                return Resolution(url: url, isStale: stale)
            }
        )
    }

    struct RunContext {
        let sourceURL: URL
        let destinationURL: URL
        let options: OrganizationOptions
    }

    private struct Location {
        var path = ""
        var url: URL?
        var error: String?
    }

    private struct LocationError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct RunSignature: Equatable {
        var sourcePath: String
        var destinationPath: String
        var options: OrganizationOptions
    }

    @Published private(set) var sourcePath = ""
    @Published private(set) var destinationPath = ""
    @Published private(set) var sourceSelectionError: String?
    @Published private(set) var destinationSelectionError: String?

    @Published var options: OrganizationOptions = .default {
        didSet {
            saveOptions()
            markPendingChange()
            if oldValue.recursive != options.recursive {
                refreshSourceSummary()
            }
        }
    }

    @Published var showsMoveConfirmation = false
    @Published var isProcessing = false
    @Published var hasPendingChange = true
    @Published var phase = L10n.string("phase.ready")
    @Published var progressValue = 0.0
    @Published var progressText = ""
    @Published var resultLines: [String] = []
    @Published var sourceSummaryText = ""

    private let organizer = FileOrganizer()
    private let defaults: UserDefaults
    private let bookmarks: BookmarkOperations
    private var sourceURL: URL?
    private var destinationURL: URL?
    private var sourceSummaryRequestID = UUID()

    private enum Keys {
        static let sourcePath = "phorganize.source.path"
        static let sourceBookmark = "phorganize.source.bookmark"
        static let destinationPath = "phorganize.destination.path"
        static let destinationBookmark = "phorganize.destination.bookmark"
        static let options = "phorganize.options"
    }

    init(defaults: UserDefaults = .standard, bookmarks: BookmarkOperations = .system) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        let source = loadLocation(bookmarkKey: Keys.sourceBookmark, pathKey: Keys.sourcePath)
        sourcePath = source.path
        sourceURL = source.url
        sourceSelectionError = source.error
        let destination = loadLocation(bookmarkKey: Keys.destinationBookmark, pathKey: Keys.destinationPath)
        destinationPath = destination.path
        destinationURL = destination.url
        destinationSelectionError = destination.error
        options = loadOptions()
        refreshSourceSummary()
    }

    var canRun: Bool {
        !isProcessing
            && hasPendingChange
            && sourceSelectionError == nil
            && destinationSelectionError == nil
            && locationExists(sourceURL)
            && locationExists(destinationURL)
    }

    var actionTitle: String {
        options.operationMode == .move
            ? L10n.string("action.moveFiles")
            : L10n.string("action.copyFiles")
    }

    var destinationWarningText: String {
        guard options.recursive,
              !sourcePath.isEmpty,
              !destinationPath.isEmpty else {
            return ""
        }

        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        guard destination == source || destination.hasPrefix(source + "/") else {
            return ""
        }

        return L10n.string("destination.warningRecursiveNested")
    }

    func chooseSource() {
        chooseFolder { [weak self] url in
            self?.acceptSource(url)
        }
    }

    func chooseDestination() {
        chooseFolder { [weak self] url in
            self?.acceptDestination(url)
        }
    }

    func acceptSource(_ url: URL) {
        guard !isProcessing else { return }
        do {
            let selectedURL = try saveLocation(url: url, bookmarkKey: Keys.sourceBookmark, pathKey: Keys.sourcePath)
            sourceURL = selectedURL
            sourcePath = selectedURL.path
            sourceSelectionError = nil
            markPendingChange()
        } catch {
            sourceSelectionError = L10n.format("location.saveFailed", url.path, error.localizedDescription)
        }
        refreshSourceSummary()
    }

    func acceptDestination(_ url: URL) {
        guard !isProcessing else { return }
        do {
            let selectedURL = try saveLocation(url: url, bookmarkKey: Keys.destinationBookmark, pathKey: Keys.destinationPath)
            destinationURL = selectedURL
            destinationPath = selectedURL.path
            destinationSelectionError = nil
            markPendingChange()
        } catch {
            destinationSelectionError = L10n.format("location.saveFailed", url.path, error.localizedDescription)
        }
    }

    func makeRunContext() throws -> RunContext {
        if let error = sourceSelectionError ?? destinationSelectionError {
            throw LocationError(message: error)
        }
        guard let sourceURL, let destinationURL else {
            throw LocationError(message: L10n.string("location.selectionRequired"))
        }
        return RunContext(sourceURL: sourceURL, destinationURL: destinationURL, options: options)
    }

    func requestRun() {
        guard canRun else { return }
        if options.operationMode == .move {
            showsMoveConfirmation = true
        } else {
            run()
        }
    }

    func confirmMove() {
        showsMoveConfirmation = false
        guard canRun, options.operationMode == .move else { return }
        run()
    }

    func run() {
        guard !isProcessing else { return }
        let context: RunContext
        do {
            context = try makeRunContext()
        } catch {
            phase = L10n.string("phase.failed")
            resultLines = [error.localizedDescription]
            return
        }
        let source = context.sourceURL
        let destination = context.destinationURL
        let selectedOptions = context.options
        let runSignature = currentRunSignature()

        isProcessing = true
        progressValue = 0
        progressText = ""
        resultLines = []
        phase = L10n.string("phase.readingMetadata")

        Task { [self] in
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let destinationAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                if destinationAccess { destination.stopAccessingSecurityScopedResource() }
            }

            do {
                let plan = try await organizer.plan(
                    sourceURL: source,
                    destinationURL: destination,
                    options: selectedOptions
                ) { [weak self] completed, total in
                    await MainActor.run {
                        self?.setProgress(completed: completed, total: total)
                        self?.progressText = L10n.format("progress.metadata", completed, total)
                    }
                }

                await MainActor.run {
                    self.phase = L10n.string(selectedOptions.operationMode == .move ? "phase.movingFiles" : "phase.copyingFiles")
                    self.progressValue = 0
                    self.progressText = L10n.format("progress.files", 0, plan.files.count)
                }

                let summary = await organizer.execute(
                    plan: plan,
                    options: selectedOptions
                ) { [weak self] completed, total in
                    await MainActor.run {
                        self?.setProgress(completed: completed, total: total)
                        self?.progressText = L10n.format("progress.files", completed, total)
                    }
                }

                await MainActor.run {
                    self.isProcessing = false
                    self.hasPendingChange = self.currentRunSignature() != runSignature || summary.failed > 0
                    self.phase = L10n.string("phase.done")
                    self.progressValue = 1
                    self.resultLines = self.makeResultLines(summary)
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.hasPendingChange = true
                    self.phase = L10n.string("phase.failed")
                    self.resultLines = [error.localizedDescription]
                }
            }
        }
    }

    private func setProgress(completed: Int, total: Int) {
        progressValue = total > 0 ? Double(completed) / Double(total) : 1
    }

    private func makeResultLines(_ summary: OrganizationSummary) -> [String] {
        var lines = [
            L10n.format("summary.planned", summary.planned),
            L10n.format("summary.copied", summary.copied),
            L10n.format("summary.cloned", summary.cloned),
            L10n.format("summary.moved", summary.moved),
            L10n.format("summary.failed", summary.failed),
            L10n.format("summary.skippedUnsupported", summary.skippedUnsupported),
            L10n.format("summary.skippedMetadata", summary.skippedMetadata),
            L10n.format("summary.skippedExistingIdentical", summary.skippedExistingIdentical)
        ]

        let failedResults = summary.results.compactMap { result -> String? in
            if case .failed(let message) = result.status {
                return "\(result.plannedFile.sourceURL.path): \(message)"
            }
            if case .copiedButSourceDeleteFailed(let message) = result.status {
                return "\(result.plannedFile.sourceURL.path): \(message)"
            }
            return nil
        }

        if !failedResults.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.failedFiles"))
            lines.append(contentsOf: failedResults)
        }

        if !summary.skippedUnsupportedFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.unsupportedFiles"))
            lines.append(contentsOf: summary.skippedUnsupportedFiles.map(\.path))
        }

        if !summary.skippedMetadataFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.metadataSkippedFiles"))
            lines.append(contentsOf: summary.skippedMetadataFiles.map(\.path))
        }

        if !summary.existingIdenticalFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.existingIdenticalFiles"))
            lines.append(contentsOf: summary.existingIdenticalFiles.map {
                "\($0.sourceURL.path) -> \($0.existingTargetURL.path)"
            })
        }
        return lines
    }

    private func markPendingChange() {
        hasPendingChange = true
    }

    private func currentRunSignature() -> RunSignature {
        RunSignature(sourcePath: sourcePath, destinationPath: destinationPath, options: options)
    }

    private func refreshSourceSummary() {
        let requestID = UUID()
        sourceSummaryRequestID = requestID
        guard sourceSelectionError == nil, let sourceURL else {
            sourceSummaryText = ""
            return
        }

        let recursive = options.recursive
        sourceSummaryText = L10n.string("source.summaryScanning")

        Task {
            let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                if self.sourceSummaryRequestID == requestID {
                    self.sourceSummaryText = L10n.string("source.summaryMissing")
                }
                return
            }

            do {
                let summary = try await Task.detached {
                    try FileOrganizer().summarizeSource(
                        sourceURL: sourceURL,
                        recursive: recursive
                    )
                }.value

                guard self.sourceSummaryRequestID == requestID else {
                    return
                }
                self.sourceSummaryText = self.makeSourceSummaryText(summary)
            } catch {
                guard self.sourceSummaryRequestID == requestID else {
                    return
                }
                self.sourceSummaryText = error.localizedDescription
            }
        }
    }

    private func makeSourceSummaryText(_ summary: SourceFileSummary) -> String {
        if summary.supportedFiles == 0 {
            return L10n.format(
                "source.summaryEmpty",
                summary.totalFiles,
                summary.unsupportedFiles
            )
        }

        let typeSummary = summary.supportedExtensionCounts
            .map { "\($0.extensionName): \($0.count)" }
            .joined(separator: ", ")

        return L10n.format(
            "source.summary",
            summary.supportedFiles,
            typeSummary,
            summary.unsupportedFiles,
            summary.totalFiles
        )
    }

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { completion(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func locationExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func saveLocation(url: URL, bookmarkKey: String, pathKey: String) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        let data = try bookmarks.create(url)
        let resolved = try bookmarks.resolve(data)
        let bookmark = try refreshedBookmark(data, resolution: resolved)
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(resolved.url.path, forKey: pathKey)
        return resolved.url
    }

    private func loadLocation(bookmarkKey: String, pathKey: String) -> Location {
        let path = defaults.string(forKey: pathKey) ?? ""
        guard let data = defaults.data(forKey: bookmarkKey) else {
            return Location(
                path: path,
                error: path.isEmpty ? nil : L10n.format("location.bookmarkMissing", path)
            )
        }
        do {
            let resolved = try bookmarks.resolve(data)
            let bookmark = try refreshedBookmark(data, resolution: resolved)
            if resolved.isStale {
                defaults.set(bookmark, forKey: bookmarkKey)
            }
            defaults.set(resolved.url.path, forKey: pathKey)
            return Location(path: resolved.url.path, url: resolved.url)
        } catch {
            return Location(
                path: path,
                error: L10n.format("location.restoreFailed", path, error.localizedDescription)
            )
        }
    }

    private func refreshedBookmark(_ data: Data, resolution: BookmarkOperations.Resolution) throws -> Data {
        guard resolution.isStale else { return data }
        let access = resolution.url.startAccessingSecurityScopedResource()
        defer {
            if access { resolution.url.stopAccessingSecurityScopedResource() }
        }
        return try bookmarks.create(resolution.url)
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Keys.options)
        }
    }

    private func loadOptions() -> OrganizationOptions {
        guard let data = defaults.data(forKey: Keys.options),
              let decoded = try? JSONDecoder().decode(OrganizationOptions.self, from: data) else {
            return .default
        }
        return decoded
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("organize.title")).font(.title2.bold())
                        Text(L10n.string("organize.subtitle"))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 12) {
                        FolderDropBox(
                            title: L10n.string("source.title"),
                            subtitle: L10n.string("source.subtitle"),
                            symbol: "folder",
                            path: model.sourcePath,
                            detailText: model.sourceSelectionError ?? model.sourceSummaryText,
                            detailIsWarning: model.sourceSelectionError != nil,
                            buttonTitle: L10n.string("source.choose"),
                            onChoose: model.chooseSource,
                            onDropURL: model.acceptSource
                        )
                        FolderDropBox(
                            title: L10n.string("destination.title"),
                            subtitle: L10n.string("destination.subtitle"),
                            symbol: "folder.badge.plus",
                            path: model.destinationPath,
                            detailText: model.destinationSelectionError ?? model.destinationWarningText,
                            detailIsWarning: model.destinationSelectionError != nil || !model.destinationWarningText.isEmpty,
                            buttonTitle: L10n.string("destination.choose"),
                            onChoose: model.chooseDestination,
                            onDropURL: model.acceptDestination
                        )
                    }
                    .disabled(model.isProcessing)
                    RulesView(options: $model.options)
                        .disabled(model.isProcessing)
                    if !model.resultLines.isEmpty {
                        GroupBox(L10n.string("result.title")) {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(model.resultLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            Divider()
            ActionView(model: model)
                .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneObject(model)
        .alert(L10n.string("move.confirmTitle"), isPresented: $model.showsMoveConfirmation) {
            Button(L10n.string("action.cancel"), role: .cancel) {}
            Button(L10n.string("action.moveFiles"), role: .destructive) { model.confirmMove() }
        } message: {
            Text(L10n.format("move.confirmMessage", model.sourcePath, model.destinationPath))
        }
    }
}

struct FolderDropBox: View {
    let title: String
    let subtitle: String
    let symbol: String
    let path: String
    let detailText: String
    let detailIsWarning: Bool
    let buttonTitle: String
    let onChoose: () -> Void
    let onDropURL: (URL) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isTargeted = false
    @State private var dropError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer()
                Button(buttonTitle) {
                    dropError = nil
                    onChoose()
                }
                .help(subtitle)
            }
            Text(path.isEmpty ? subtitle : path)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(title)
                .accessibilityValue(path.isEmpty ? subtitle : path)
            if let warning = dropError ?? (detailIsWarning ? detailText : nil), !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !detailText.isEmpty {
                Text(detailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: path.isEmpty ? [5, 4] : []))
        }
        .onChange(of: path) { _ in dropError = nil }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            guard isEnabled else { return false }
            return loadDroppedURL(from: providers)
        }
    }

    private func loadDroppedURL(from providers: [NSItemProvider]) -> Bool {
        guard providers.count == 1, let provider = providers.first else {
            dropError = L10n.string("location.dropFolderOnly")
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let string = item as? String {
                url = URL(string: string)
            } else {
                url = item as? URL
            }
            DispatchQueue.main.async {
                guard isEnabled else { return }
                guard let url, url.isFileURL else {
                    dropError = L10n.string("location.dropFolderOnly")
                    return
                }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    dropError = L10n.string("location.dropFolderOnly")
                    return
                }
                dropError = nil
                onDropURL(url)
            }
        }
        return true
    }
}

struct RulesView: View {
    @Binding var options: OrganizationOptions
    @State private var showsAdvanced = false

    private var timeZoneIdentifiers: [String] {
        let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
        if identifiers.contains(options.timezoneIdentifier) { return identifiers }
        return ([options.timezoneIdentifier] + identifiers).filter { !$0.isEmpty }
    }

    var body: some View {
        GroupBox(L10n.string("rules.title")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.string("rules.mode"))
                    Spacer()
                    Picker(L10n.string("rules.mode"), selection: $options.operationMode) {
                        Text(L10n.string("mode.copy")).tag(OperationMode.copy)
                        Text(L10n.string("mode.move")).tag(OperationMode.move)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                Text(L10n.string(options.operationMode == .copy ? "mode.copyHelp" : "mode.moveHelp"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(L10n.string("rules.recursive"), isOn: $options.recursive)
                Toggle(L10n.string("rules.cameraFolder"), isOn: $options.includeCameraFolder)
                Toggle(L10n.string("rules.lensFolder"), isOn: $options.includeLensFolder)
                Toggle(L10n.string("rules.renameByDate"), isOn: $options.renameByDate)
                Divider()
                Picker(L10n.string("rules.extensionCase"), selection: $options.extensionCase) {
                    Text(L10n.string("extension.preserve")).tag(ExtensionCase.preserve)
                    Text(L10n.string("extension.lower")).tag(ExtensionCase.lower)
                    Text(L10n.string("extension.upper")).tag(ExtensionCase.upper)
                }
                .pickerStyle(.menu)
                Picker(L10n.string("rules.timezone"), selection: $options.timezoneIdentifier) {
                    ForEach(timeZoneIdentifiers, id: \.self) { identifier in
                        Text(timeZoneLabel(identifier)).tag(identifier)
                    }
                }
                .pickerStyle(.menu)
                Divider()
                DisclosureGroup(L10n.string("rules.advanced"), isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(L10n.format("rules.metadataParallelism", options.metadataConcurrency), value: $options.metadataConcurrency, in: 1...64)
                        Stepper(L10n.format("rules.copyParallelism", options.copyConcurrency), value: $options.copyConcurrency, in: 1...16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeZoneLabel(_ identifier: String) -> String {
        guard let timeZone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = timeZone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        return "\(identifier) (GMT\(sign)\(String(format: "%02d:%02d", absolute / 3_600, (absolute % 3_600) / 60)))"
    }
}

struct ActionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.phase).font(.headline)
                    if !model.isProcessing && (model.sourcePath.isEmpty || model.destinationPath.isEmpty) {
                        Text(L10n.string("location.selectionRequired"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !model.progressText.isEmpty {
                        Text(model.progressText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(model.actionTitle) { model.requestRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRun)
            }
            if model.isProcessing {
                ProgressView(value: model.progressValue)
                    .accessibilityLabel(model.phase)
                    .accessibilityValue(model.progressText)
            }
        }
    }
}
