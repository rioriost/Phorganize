import Darwin
import CryptoKit
import Foundation

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = max(1, value)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

struct DestinationNameRules {
    let caseSensitive: Bool

    func key(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        return caseSensitive ? normalized : normalized.folding(
            options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func read(at destination: URL, fileManager: FileManager) throws -> Self {
        var existing = destination.standardizedFileURL
        while !fileManager.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let values = try existing.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let caseSensitive = values.volumeSupportsCaseSensitiveNames else {
            throw OrganizerError.destinationVolumeUnknown(existing.path)
        }
        return Self(caseSensitive: caseSensitive)
    }
}

private func fileEntryExists(_ url: URL) throws -> Bool {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &info)
    }
    if result == 0 { return true }
    if errno == ENOENT { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

public struct TargetPlanner {
    public typealias ExistingFileComparator = (_ sourceURL: URL, _ existingTargetURL: URL) throws -> Bool

    private struct Draft {
        var sourceURL: URL
        var directoryURL: URL
        var baseName: String
        var pathExtension: String
        var metadata: MediaMetadata
        var requiresSequence: Bool

        var key: String {
            "\(directoryURL.path)\u{0}\(baseName)\u{0}\(pathExtension)"
        }
    }

    public static func makePlan(
        candidates: [MediaFileCandidate],
        destinationURL: URL,
        options: OrganizationOptions
    ) throws -> [PlannedFile] {
        try makePlanningResult(
            candidates: candidates,
            destinationURL: destinationURL,
            options: options,
            existingFileComparator: { _, _ in false }
        ).files
    }

    public static func makePlanningResult(
        candidates: [MediaFileCandidate],
        destinationURL: URL,
        options: OrganizationOptions,
        fileManager: FileManager = .default,
        existingFileComparator: ExistingFileComparator
    ) throws -> TargetPlanningResult {
        let nameRules = try DestinationNameRules.read(at: destinationURL, fileManager: fileManager)
        let sortedCandidates = candidates.sorted { $0.sourceURL.path < $1.sourceURL.path }
        let drafts = sortedCandidates.map {
            makeDraft(candidate: $0, destinationURL: destinationURL, options: options)
        }
        let grouped = Dictionary(grouping: drafts) { nameRules.key($0.key) }
        var usedTargets = Set<String>()
        var planned: [PlannedFile] = []
        var existingIdenticalFiles: [ExistingIdenticalFile] = []
        var directoryEntries: [String: [URL]] = [:]
        var existingFamilies: [String: [URL]] = [:]

        for var draft in drafts {
            let draftKey = nameRules.key(draft.key)
            draft.requiresSequence = (grouped[draftKey]?.count ?? 0) > 1
            if existingFamilies[draftKey] == nil {
                let directoryKey = nameRules.key(draft.directoryURL.path)
                if directoryEntries[directoryKey] == nil {
                    directoryEntries[directoryKey] = try fileEntryExists(draft.directoryURL)
                        ? fileManager.contentsOfDirectory(
                            at: draft.directoryURL, includingPropertiesForKeys: nil
                        ).map { draft.directoryURL.appendingPathComponent($0.lastPathComponent) }
                        : []
                }
                existingFamilies[draftKey] = (directoryEntries[directoryKey] ?? [])
                    .filter { sequence(of: $0, for: draft, rules: nameRules) != nil }
                    .sorted {
                        let left = sequence(of: $0, for: draft, rules: nameRules) ?? 0
                        let right = sequence(of: $1, for: draft, rules: nameRules) ?? 0
                        return left == right ? $0.path < $1.path : left < right
                    }
            }

            var identicalTarget: URL?
            for target in existingFamilies[draftKey] ?? [] {
                let attributes = try fileManager.attributesOfItem(atPath: target.path)
                if attributes[.type] as? FileAttributeType == .typeRegular,
                   try existingFileComparator(draft.sourceURL, target) {
                    identicalTarget = target
                    break
                }
            }
            if let identicalTarget {
                existingIdenticalFiles.append(
                    ExistingIdenticalFile(sourceURL: draft.sourceURL, existingTargetURL: identicalTarget)
                )
                continue
            }

            var sequence = draft.requiresSequence ? 1 : 0
            while true {
                let targetURL = makeTargetURL(from: draft, sequence: sequence)
                let targetKey = nameRules.key(targetURL.path)

                if try usedTargets.contains(targetKey) || fileEntryExists(targetURL) {
                    sequence += 1
                    continue
                }

                usedTargets.insert(targetKey)
                planned.append(
                    PlannedFile(
                        sourceURL: draft.sourceURL,
                        targetURL: targetURL,
                        metadata: draft.metadata,
                        operationMode: options.operationMode
                    )
                )
                break
            }
        }

        return TargetPlanningResult(
            files: planned,
            existingIdenticalFiles: existingIdenticalFiles
        )
    }

    private static func sequence(of url: URL, for draft: Draft, rules: DestinationNameRules) -> Int? {
        guard rules.key(url.pathExtension) == rules.key(draft.pathExtension) else { return nil }
        let base = rules.key(url.deletingPathExtension().lastPathComponent)
        let expected = rules.key(draft.baseName)
        if base == expected { return 0 }
        guard base.hasPrefix(expected + "_") else { return nil }
        let suffix = base.dropFirst(expected.count + 1)
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let sequence = Int(suffix), sequence > 0 else { return nil }
        return sequence
    }

    private static func makeDraft(
        candidate: MediaFileCandidate,
        destinationURL: URL,
        options: OrganizationOptions
    ) -> Draft {
        let date = candidate.metadata.creationDate
        let timeZone = options.timeZone
        let year = format(date, "yyyy", timeZone)
        let month = format(date, "MM", timeZone)
        let day = format(date, "dd", timeZone)

        var directoryURL = destinationURL
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)

        if options.includeCameraFolder {
            directoryURL = directoryURL.appendingPathComponent(
                sanitizePathComponent(candidate.metadata.cameraModel),
                isDirectory: true
            )
        }

        if options.includeLensFolder {
            directoryURL = directoryURL.appendingPathComponent(
                sanitizePathComponent(candidate.metadata.lensModel),
                isDirectory: true
            )
        }

        let baseName = options.renameByDate
            ? format(date, "yyyyMMdd-HHmmss", timeZone)
            : candidate.sourceURL.deletingPathExtension().lastPathComponent

        return Draft(
            sourceURL: candidate.sourceURL,
            directoryURL: directoryURL,
            baseName: sanitizeFileBaseName(baseName),
            pathExtension: options.extensionCase.apply(to: candidate.sourceURL.pathExtension),
            metadata: candidate.metadata,
            requiresSequence: false
        )
    }

    private static func makeTargetURL(from draft: Draft, sequence: Int) -> URL {
        let suffix = sequence > 0 ? "_\(sequence)" : ""
        let filename = draft.pathExtension.isEmpty
            ? "\(draft.baseName)\(suffix)"
            : "\(draft.baseName)\(suffix).\(draft.pathExtension)"

        return draft.directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func format(_ date: Date, _ dateFormat: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    private static func sanitizePathComponent(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = trimmed.isEmpty ? "(null)" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func sanitizeFileBaseName(_ value: String) -> String {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sanitized.isEmpty ? "untitled" : sanitized
    }
}

struct FileSnapshot: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat, path: String) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw OrganizerError.sourceNotRegularFile(path)
        }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    static func read(at url: URL) throws -> Self {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Self(info, path: url.path)
    }

    static func read(descriptor: Int32, path: String) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try Self(info, path: path)
    }

    func isSameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }
}

final class OpenedMediaFile {
    let url: URL
    let snapshot: FileSnapshot
    private let handle: FileHandle

    init(_ url: URL) throws {
        self.url = url
        _ = try FileSnapshot.read(at: url)
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        snapshot = try FileSnapshot.read(descriptor: descriptor, path: url.path)
        try verifyUnchanged()
    }

    func verifyUnchanged() throws {
        guard try FileSnapshot.read(descriptor: handle.fileDescriptor, path: url.path) == snapshot,
              try FileSnapshot.read(at: url) == snapshot else {
            throw OrganizerError.sourceIdentityChanged(url.path)
        }
    }

    func digest() throws -> SHA256.Digest {
        try verifyUnchanged()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let data = try autoreleasepool(invoking: { try handle.read(upToCount: 4 * 1_024 * 1_024) }),
              !data.isEmpty {
            hasher.update(data: data)
        }
        try verifyUnchanged()
        return hasher.finalize()
    }

    func removeIfUnchanged() throws {
        try verifyUnchanged()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public final class FileOrganizer {
    private let extractor: MediaMetadataExtractor
    private let fileManager: FileManager

    public init(extractor: MediaMetadataExtractor = MediaMetadataExtractor(), fileManager: FileManager = .default) {
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func summarizeSource(sourceURL: URL, recursive: Bool) throws -> SourceFileSummary {
        let discovered = try discoverFiles(sourceURL: sourceURL, recursive: recursive)
        let supported = discovered.filter { extractor.isSupported($0) }
        let counts = Dictionary(grouping: supported) { url in
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "(none)" : ext
        }
        .map { (extensionName: $0.key, count: $0.value.count) }
        .sorted {
            if $0.count == $1.count {
                return $0.extensionName < $1.extensionName
            }
            return $0.count > $1.count
        }
        .map { SupportedExtensionCount(extensionName: $0.extensionName, count: $0.count) }

        return SourceFileSummary(
            totalFiles: discovered.count,
            supportedFiles: supported.count,
            unsupportedFiles: discovered.count - supported.count,
            supportedExtensionCounts: counts
        )
    }

    public func plan(
        sourceURL: URL,
        destinationURL: URL,
        options: OrganizationOptions,
        progress: ((Int, Int) async -> Void)? = nil
    ) async throws -> OrganizationPlan {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw OrganizerError.sourceMissing(sourceURL.path)
        }

        try ensureDestinationCanBeCreated(destinationURL)

        let discovered = try discoverFiles(sourceURL: sourceURL, recursive: options.recursive)
        let supported = discovered.filter { extractor.isSupported($0) }
        let unsupported = discovered.filter { !extractor.isSupported($0) }
        let semaphore = AsyncSemaphore(value: options.metadataConcurrency)

        var candidates: [MediaFileCandidate] = []
        var skippedMetadataFiles: [URL] = []
        var completed = 0

        await withTaskGroup(of: (URL, MediaFileCandidate?).self) { group in
            for url in supported {
                group.addTask {
                    await semaphore.acquire()
                    let metadata = await self.extractor.extractMetadata(from: url, timeZone: options.timeZone)
                    await semaphore.release()

                    guard let metadata else {
                        return (url, nil)
                    }
                    return (url, MediaFileCandidate(sourceURL: url, metadata: metadata))
                }
            }

            for await (url, candidate) in group {
                completed += 1
                if let candidate {
                    candidates.append(candidate)
                } else {
                    skippedMetadataFiles.append(url)
                }
                await progress?(completed, supported.count)
            }
        }

        let planningResult = try TargetPlanner.makePlanningResult(
            candidates: candidates,
            destinationURL: destinationURL,
            options: options,
            fileManager: fileManager,
            existingFileComparator: { sourceURL, existingTargetURL in
                try self.filesHaveSameSHA256(sourceURL, existingTargetURL)
            }
        )

        return OrganizationPlan(
            files: planningResult.files,
            destinationURL: destinationURL,
            skippedUnsupportedCount: unsupported.count,
            skippedMetadataCount: skippedMetadataFiles.count,
            skippedUnsupportedFiles: unsupported.sorted { $0.path < $1.path },
            skippedMetadataFiles: skippedMetadataFiles.sorted { $0.path < $1.path },
            existingIdenticalFiles: planningResult.existingIdenticalFiles
        )
    }

    public func execute(
        plan: OrganizationPlan,
        options: OrganizationOptions,
        progress: ((Int, Int) async -> Void)? = nil
    ) async -> OrganizationSummary {
        let semaphore = AsyncSemaphore(value: options.copyConcurrency)
        var completed = 0
        var results: [FileExecutionResult] = []

        await withTaskGroup(of: FileExecutionResult.self) { group in
            for plannedFile in plan.files {
                group.addTask {
                    await semaphore.acquire()
                    let result = self.perform(plannedFile, destinationRootURL: plan.destinationURL)
                    await semaphore.release()
                    return result
                }
            }

            for await result in group {
                completed += 1
                results.append(result)
                await progress?(completed, plan.files.count)
            }
        }

        return OrganizationSummary(
            planned: plan.files.count,
            copied: results.filter { $0.status == .copied }.count,
            cloned: results.filter { $0.status == .cloned }.count,
            moved: results.filter { $0.status == .moved }.count,
            failed: results.filter {
                if case .failed = $0.status { return true }
                if case .copiedButSourceDeleteFailed = $0.status { return true }
                return false
            }.count,
            skippedUnsupported: plan.skippedUnsupportedCount,
            skippedMetadata: plan.skippedMetadataCount,
            skippedExistingIdentical: plan.existingIdenticalFiles.count,
            results: results.sorted { $0.plannedFile.sourceURL.path < $1.plannedFile.sourceURL.path },
            skippedUnsupportedFiles: plan.skippedUnsupportedFiles,
            skippedMetadataFiles: plan.skippedMetadataFiles,
            existingIdenticalFiles: plan.existingIdenticalFiles
        )
    }

    private func discoverFiles(sourceURL: URL, recursive: Bool) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw OrganizerError.sourceMissing(sourceURL.path)
        }

        if !isDirectory.boolValue {
            return [sourceURL]
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]

        if recursive {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    enumerationError = OrganizerError.sourceEnumerationFailed(url.path, error.localizedDescription)
                    return false
                }
            ) else {
                throw OrganizerError.sourceEnumerationFailed(sourceURL.path, "Could not start directory enumeration.")
            }

            var discovered: [URL] = []
            for case let url as URL in enumerator {
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    if values.isRegularFile == true, values.isHidden != true {
                        discovered.append(url)
                    }
                } catch {
                    throw OrganizerError.sourceEnumerationFailed(url.path, error.localizedDescription)
                }
            }
            if let enumerationError { throw enumerationError }
            return discovered.sorted { $0.path < $1.path }
        }

        return try fileManager
            .contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter {
                let values = try $0.resourceValues(forKeys: Set(keys))
                return values.isRegularFile == true && values.isHidden != true
            }
            .sorted { $0.path < $1.path }
    }

    private func ensureDestinationCanBeCreated(_ destinationURL: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw OrganizerError.destinationParentMissing(destinationURL.path)
            }
            return
        }

        let parent = destinationURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OrganizerError.destinationParentMissing(parent.path)
        }
    }

    private func perform(_ plannedFile: PlannedFile, destinationRootURL: URL?) -> FileExecutionResult {
        do {
            let source = try OpenedMediaFile(plannedFile.sourceURL)
            let usedClone = try copySafely(
                from: source,
                to: plannedFile.targetURL,
                destinationRootURL: destinationRootURL,
                verifyContents: plannedFile.operationMode == .move
            )
            if plannedFile.operationMode == .move {
                do {
                    try source.removeIfUnchanged()
                } catch {
                    return FileExecutionResult(
                        plannedFile: plannedFile,
                        status: .copiedButSourceDeleteFailed(error.localizedDescription)
                    )
                }
                return FileExecutionResult(plannedFile: plannedFile, status: .moved)
            }
            return FileExecutionResult(plannedFile: plannedFile, status: usedClone ? .cloned : .copied)
        } catch {
            return FileExecutionResult(plannedFile: plannedFile, status: .failed(error.localizedDescription))
        }
    }

    private func copySafely(
        from source: OpenedMediaFile,
        to targetURL: URL,
        destinationRootURL: URL?,
        verifyContents: Bool
    ) throws -> Bool {
        let sourceURL = source.url
        let targetDirectory = targetURL.deletingLastPathComponent()
        try prepareDestinationDirectory(targetDirectory, destinationRootURL: destinationRootURL)

        guard try !fileEntryExists(targetURL) else {
            throw OrganizerError.targetAlreadyExists(targetURL.path)
        }

        let temporaryURL = targetDirectory.appendingPathComponent(
            ".\(targetURL.lastPathComponent).phorganize-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var usedClone = false
        do {
            guard try !fileEntryExists(temporaryURL) else {
                throw OrganizerError.targetAlreadyExists(temporaryURL.path)
            }

            if isSameVolume(sourceURL, targetDirectory), cloneFile(from: sourceURL, to: temporaryURL) {
                usedClone = true
            } else {
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            }

            try Self.verifyCopy(source: source, copiedURL: temporaryURL, verifyContents: verifyContents)
            let temporarySnapshot = try FileSnapshot.read(at: temporaryURL)
            try Self.promoteWithoutReplacing(temporaryURL, to: targetURL)
            let targetSnapshot = try FileSnapshot.read(at: targetURL)
            guard targetSnapshot.isSameFile(as: temporarySnapshot),
                  targetSnapshot.size == temporarySnapshot.size else {
                throw OrganizerError.copyVerificationFailed(targetURL.path)
            }
            return usedClone
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    static func verifyCopy(source: OpenedMediaFile, copiedURL: URL, verifyContents: Bool) throws {
        let copy = try OpenedMediaFile(copiedURL)
        guard source.snapshot.size == copy.snapshot.size else {
            throw OrganizerError.copyVerificationFailed(copiedURL.path)
        }
        if verifyContents, try source.digest() != copy.digest() {
            throw OrganizerError.copyVerificationFailed(copiedURL.path)
        }
        try source.verifyUnchanged()
        try copy.verifyUnchanged()
    }

    static func promoteWithoutReplacing(_ temporaryURL: URL, to targetURL: URL) throws {
        let result = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
            targetURL.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else { return Int32(-1) }
                return renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, targetPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw OrganizerError.targetAlreadyExists(targetURL.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func prepareDestinationDirectory(_ targetDirectory: URL, destinationRootURL: URL?) throws {
        let rootURL = (destinationRootURL ?? targetDirectory).standardizedFileURL
        let targetURL = targetDirectory.standardizedFileURL
        let rootPath = rootURL.path
        let targetPath = targetURL.path

        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw OrganizerError.destinationEscapesRoot(targetPath)
        }

        try createDirectoryRejectingSymlink(rootURL)

        let rootComponents = rootURL.pathComponents
        let targetComponents = targetURL.pathComponents
        var current = rootURL

        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            try createDirectoryRejectingSymlink(current)
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let resolvedTarget = targetURL.resolvingSymlinksInPath().path
        guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw OrganizerError.destinationEscapesRoot(targetPath)
        }
    }

    private func createDirectoryRejectingSymlink(_ url: URL) throws {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        if result == 0 {
            if (statBuffer.st_mode & S_IFMT) == S_IFLNK {
                throw OrganizerError.destinationContainsSymbolicLink(url.path)
            }
            guard (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
                throw OrganizerError.destinationParentMissing(url.path)
            }
            return
        }

        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            if try fileEntryExists(url) {
                try ensureDirectoryWithoutSymlink(url)
                return
            }
            throw error
        }
        try ensureDirectoryWithoutSymlink(url)
    }

    private func ensureDirectoryWithoutSymlink(_ url: URL) throws {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        if result == 0, (statBuffer.st_mode & S_IFMT) == S_IFLNK {
            throw OrganizerError.destinationContainsSymbolicLink(url.path)
        }
        guard result == 0, (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
            throw OrganizerError.destinationParentMissing(url.path)
        }
    }

    private func isSameVolume(_ sourceURL: URL, _ targetDirectory: URL) -> Bool {
        guard let sourceVolume = try? sourceURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let targetVolume = try? targetDirectory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }

        return (sourceVolume as AnyObject).isEqual(targetVolume)
    }

    private func cloneFile(from sourceURL: URL, to targetURL: URL) -> Bool {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            targetURL.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else {
                    return Int32(-1)
                }
                return clonefile(sourcePath, targetPath, 0)
            }
        }

        return result == 0
    }

    private func filesHaveSameSHA256(_ sourceURL: URL, _ targetURL: URL) throws -> Bool {
        let source = try OpenedMediaFile(sourceURL)
        let target = try OpenedMediaFile(targetURL)
        guard source.snapshot.size == target.snapshot.size else {
            return false
        }
        let equal = try source.digest() == target.digest()
        try source.verifyUnchanged()
        return equal
    }
}
