import Foundation
import PhorganizeCore
@testable import PhorganizeApp
import XCTest

final class AppModelTests: XCTestCase {
    @MainActor
    func testTwoModelsKeepTheirOwnFoldersAndOptionsWithSharedDefaults() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let defaults = MemoryDefaults()
        let first = AppModel(defaults: defaults)
        first.acceptSource(folders.source)
        first.acceptDestination(folders.destination)
        first.options.operationMode = .move

        let second = AppModel(defaults: defaults)
        second.acceptSource(folders.otherSource)
        second.acceptDestination(folders.otherDestination)
        second.options.operationMode = .copy

        let firstContext = try first.makeRunContext()
        let secondContext = try second.makeRunContext()
        XCTAssertEqual(first.sourcePath, folders.source.path)
        XCTAssertEqual(first.destinationPath, folders.destination.path)
        XCTAssertEqual(firstContext.sourceURL.path, first.sourcePath)
        XCTAssertEqual(firstContext.destinationURL.path, first.destinationPath)
        XCTAssertEqual(firstContext.options.operationMode, .move)
        XCTAssertEqual(secondContext.sourceURL.path, folders.otherSource.path)
        XCTAssertEqual(secondContext.destinationURL.path, folders.otherDestination.path)
        XCTAssertEqual(secondContext.options.operationMode, .copy)
        XCTAssertEqual(defaults.string(forKey: "phorganize.source.path"), second.sourcePath)
        XCTAssertEqual(defaults.string(forKey: "phorganize.destination.path"), second.destinationPath)
        XCTAssertTrue(first.canRun)
        XCTAssertTrue(second.canRun)
    }

    @MainActor
    func testRunContextRemainsConsistentAfterLaterSelectionsAndRuleChanges() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let model = AppModel(defaults: MemoryDefaults(), bookmarks: plainBookmarks())
        model.acceptSource(folders.source)
        model.acceptDestination(folders.destination)
        model.options.operationMode = .move
        let context = try model.makeRunContext()

        model.acceptSource(folders.otherSource)
        model.acceptDestination(folders.otherDestination)
        model.options.operationMode = .copy

        XCTAssertEqual(context.sourceURL, folders.source)
        XCTAssertEqual(context.destinationURL, folders.destination)
        XCTAssertEqual(context.options.operationMode, .move)
        XCTAssertEqual(try model.makeRunContext().sourceURL, folders.otherSource)
        XCTAssertEqual(try model.makeRunContext().destinationURL, folders.otherDestination)
    }

    @MainActor
    func testBookmarkCreationFailureKeepsPreviousSelectionAndDisablesRunning() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for isSource in [true, false] {
            let defaults = MemoryDefaults()
            var rejectedURL: URL?
            var bookmarks = plainBookmarks()
            bookmarks.create = { url in
                if url == rejectedURL { throw BookmarkFailure() }
                return Data(url.path.utf8)
            }
            let model = AppModel(defaults: defaults, bookmarks: bookmarks)
            model.acceptSource(folders.source)
            model.acceptDestination(folders.destination)
            let prefix = isSource ? "phorganize.source" : "phorganize.destination"
            let previousPath = defaults.string(forKey: prefix + ".path")
            let previousBookmark = defaults.data(forKey: prefix + ".bookmark")
            rejectedURL = isSource ? folders.otherSource : folders.otherDestination

            if isSource {
                model.acceptSource(try XCTUnwrap(rejectedURL))
            } else {
                model.acceptDestination(try XCTUnwrap(rejectedURL))
            }

            XCTAssertEqual(model.sourcePath, folders.source.path)
            XCTAssertEqual(model.destinationPath, folders.destination.path)
            XCTAssertEqual(defaults.string(forKey: prefix + ".path"), previousPath)
            XCTAssertEqual(defaults.data(forKey: prefix + ".bookmark"), previousBookmark)
            let error = try XCTUnwrap(isSource ? model.sourceSelectionError : model.destinationSelectionError)
            XCTAssertTrue(error.contains(try XCTUnwrap(rejectedURL).path))
            XCTAssertTrue(error.contains("Expected bookmark failure"))
            XCTAssertFalse(model.canRun)
            XCTAssertThrowsError(try model.makeRunContext())
            model.run()
            XCTAssertFalse(model.isProcessing)
            XCTAssertEqual(model.resultLines, [error])

            rejectedURL = nil
            if isSource {
                model.acceptSource(folders.otherSource)
            } else {
                model.acceptDestination(folders.otherDestination)
            }
            XCTAssertNil(model.sourceSelectionError)
            XCTAssertNil(model.destinationSelectionError)
            XCTAssertTrue(model.canRun)
        }
    }

    @MainActor
    func testBookmarkResolutionFailureDuringSelectionDoesNotOverwriteSavedSelection() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for isSource in [true, false] {
            let defaults = MemoryDefaults()
            let rejectedURL = isSource ? folders.otherSource : folders.otherDestination
            var bookmarks = plainBookmarks()
            let resolve = bookmarks.resolve
            bookmarks.resolve = { data in
                if data == Data(rejectedURL.path.utf8) { throw BookmarkFailure() }
                return try resolve(data)
            }
            let model = AppModel(defaults: defaults, bookmarks: bookmarks)
            model.acceptSource(folders.source)
            model.acceptDestination(folders.destination)
            let prefix = isSource ? "phorganize.source" : "phorganize.destination"
            let previousBookmark = defaults.data(forKey: prefix + ".bookmark")
            if isSource {
                model.acceptSource(rejectedURL)
            } else {
                model.acceptDestination(rejectedURL)
            }
            XCTAssertEqual(model.sourcePath, folders.source.path)
            XCTAssertEqual(model.destinationPath, folders.destination.path)
            XCTAssertEqual(defaults.data(forKey: prefix + ".bookmark"), previousBookmark)
            XCTAssertEqual(defaults.string(forKey: prefix + ".path"), isSource ? model.sourcePath : model.destinationPath)
            XCTAssertFalse(model.canRun)
            XCTAssertThrowsError(try model.makeRunContext())
        }
    }

    @MainActor
    func testRestoredBookmarksUpdateDisplayedPathsAndAreNotRereadAtRunTime() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let defaults = MemoryDefaults()
        save(folders.source, as: "source", in: defaults)
        save(folders.destination, as: "destination", in: defaults)
        defaults.set("old source path", forKey: "phorganize.source.path")
        defaults.set("old destination path", forKey: "phorganize.destination.path")
        var resolutions = 0
        var bookmarks = plainBookmarks()
        let resolve = bookmarks.resolve
        bookmarks.resolve = { data in
            resolutions += 1
            return try resolve(data)
        }
        let model = AppModel(defaults: defaults, bookmarks: bookmarks)
        XCTAssertEqual(resolutions, 2)
        XCTAssertEqual(model.sourcePath, folders.source.path)
        XCTAssertEqual(model.destinationPath, folders.destination.path)
        XCTAssertEqual(defaults.string(forKey: "phorganize.source.path"), model.sourcePath)
        XCTAssertEqual(defaults.string(forKey: "phorganize.destination.path"), model.destinationPath)

        save(folders.otherSource, as: "source", in: defaults)
        save(folders.otherDestination, as: "destination", in: defaults)
        let context = try model.makeRunContext()
        XCTAssertEqual(context.sourceURL, folders.source)
        XCTAssertEqual(context.destinationURL, folders.destination)
        XCTAssertEqual(resolutions, 2)
    }

    @MainActor
    func testFailedRestorationDoesNotFallBackToAnUnscopedSavedPath() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for role in ["source", "destination"] {
            let defaults = MemoryDefaults()
            save(folders.source, as: "source", in: defaults)
            save(folders.destination, as: "destination", in: defaults)
            let invalidBookmark = Data("invalid".utf8)
            defaults.set(invalidBookmark, forKey: "phorganize.\(role).bookmark")
            var bookmarks = plainBookmarks()
            let resolve = bookmarks.resolve
            bookmarks.resolve = { data in
                if data == invalidBookmark { throw BookmarkFailure() }
                return try resolve(data)
            }
            let model = AppModel(defaults: defaults, bookmarks: bookmarks)
            XCTAssertEqual(model.sourcePath, folders.source.path)
            XCTAssertEqual(model.destinationPath, folders.destination.path)
            XCTAssertNotNil(role == "source" ? model.sourceSelectionError : model.destinationSelectionError)
            XCTAssertEqual(defaults.data(forKey: "phorganize.\(role).bookmark"), invalidBookmark)
            XCTAssertFalse(model.canRun)
            XCTAssertThrowsError(try model.makeRunContext())

            if role == "source" {
                model.acceptSource(folders.source)
            } else {
                model.acceptDestination(folders.destination)
            }
            XCTAssertTrue(model.canRun)
        }
    }

    @MainActor
    func testStaleBookmarksAreRenewedAndPersistedForBothLocations() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let defaults = MemoryDefaults()
        defaults.set(Data("old-source".utf8), forKey: "phorganize.source.bookmark")
        defaults.set(Data("old-destination".utf8), forKey: "phorganize.destination.bookmark")
        var renewed: [URL] = []
        var bookmarks = plainBookmarks()
        let resolve = bookmarks.resolve
        bookmarks.create = { url in
            renewed.append(url)
            return Data(url.path.utf8)
        }
        bookmarks.resolve = { data in
            switch String(decoding: data, as: UTF8.self) {
            case "old-source":
                return .init(url: folders.source, isStale: true)
            case "old-destination":
                return .init(url: folders.destination, isStale: true)
            default:
                return try resolve(data)
            }
        }
        let model = AppModel(defaults: defaults, bookmarks: bookmarks)
        XCTAssertEqual(renewed, [folders.source, folders.destination])
        XCTAssertEqual(defaults.data(forKey: "phorganize.source.bookmark"), Data(folders.source.path.utf8))
        XCTAssertEqual(defaults.data(forKey: "phorganize.destination.bookmark"), Data(folders.destination.path.utf8))
        XCTAssertEqual(try model.makeRunContext().sourceURL, folders.source)
        XCTAssertEqual(try model.makeRunContext().destinationURL, folders.destination)
        let relaunched = AppModel(defaults: defaults, bookmarks: bookmarks)
        XCTAssertEqual(renewed.count, 2)
        XCTAssertTrue(relaunched.canRun)
    }

    @MainActor
    func testFailedStaleBookmarkRenewalRequiresReselectionAndPreservesSavedData() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for role in ["source", "destination"] {
            let defaults = MemoryDefaults()
            save(folders.source, as: "source", in: defaults)
            save(folders.destination, as: "destination", in: defaults)
            let staleURL = role == "source" ? folders.source : folders.destination
            var bookmarks = plainBookmarks()
            let resolve = bookmarks.resolve
            bookmarks.resolve = { data in
                let result = try resolve(data)
                return .init(url: result.url, isStale: result.url == staleURL)
            }
            bookmarks.create = { _ in throw BookmarkFailure() }
            let model = AppModel(defaults: defaults, bookmarks: bookmarks)
            XCTAssertEqual(model.sourcePath, folders.source.path)
            XCTAssertEqual(model.destinationPath, folders.destination.path)
            XCTAssertEqual(defaults.data(forKey: "phorganize.\(role).bookmark"), Data(staleURL.path.utf8))
            XCTAssertNotNil(role == "source" ? model.sourceSelectionError : model.destinationSelectionError)
            XCTAssertFalse(model.canRun)
            XCTAssertThrowsError(try model.makeRunContext())
        }
    }

    @MainActor
    func testSavedPathWithoutBookmarkIsDisplayedButRequiresReselection() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let defaults = MemoryDefaults()
        defaults.set(folders.source.path, forKey: "phorganize.source.path")
        defaults.set(folders.destination.path, forKey: "phorganize.destination.path")
        let model = AppModel(defaults: defaults, bookmarks: plainBookmarks())
        XCTAssertEqual(model.sourcePath, folders.source.path)
        XCTAssertEqual(model.destinationPath, folders.destination.path)
        XCTAssertNotNil(model.sourceSelectionError)
        XCTAssertNotNil(model.destinationSelectionError)
        XCTAssertFalse(model.canRun)
        XCTAssertThrowsError(try model.makeRunContext())
        model.acceptSource(folders.source)
        model.acceptDestination(folders.destination)
        XCTAssertTrue(model.canRun)
    }

    @MainActor
    func testEmptySelectionsCannotStartAnOperation() async throws {
        let model = AppModel(defaults: MemoryDefaults(), bookmarks: plainBookmarks())
        XCTAssertEqual(model.sourcePath, "")
        XCTAssertEqual(model.destinationPath, "")
        XCTAssertNil(model.sourceSelectionError)
        XCTAssertNil(model.destinationSelectionError)
        XCTAssertFalse(model.canRun)
        XCTAssertThrowsError(try model.makeRunContext())
        model.run()
        XCTAssertFalse(model.isProcessing)
        XCTAssertFalse(model.resultLines.isEmpty)
    }

    func testPrivacyManifestDeclaresUserSelectedFileTimestampAccess() throws {
        let manifest = repositoryRoot
            .appendingPathComponent("Sources/PhorganizeApp/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifest)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let APIs = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let timestamps = try XCTUnwrap(APIs.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp"
        })
        XCTAssertEqual(timestamps["NSPrivacyAccessedAPITypeReasons"] as? [String], ["3B52.1"])
    }

    @MainActor
    private func plainBookmarks() -> AppModel.BookmarkOperations {
        AppModel.BookmarkOperations(
            create: { Data($0.path.utf8) },
            resolve: {
                .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false)
            }
        )
    }

    private func save(_ url: URL, as role: String, in defaults: UserDefaults) {
        defaults.set(url.path, forKey: "phorganize.\(role).path")
        defaults.set(Data(url.path.utf8), forKey: "phorganize.\(role).bookmark")
    }
}

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct BookmarkFailure: LocalizedError {
    var errorDescription: String? { "Expected bookmark failure" }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private struct Folders {
    let root: URL
    var source: URL { root.appendingPathComponent("source") }
    var destination: URL { root.appendingPathComponent("destination") }
    var otherSource: URL { root.appendingPathComponent("other-source") }
    var otherDestination: URL { root.appendingPathComponent("other-destination") }

    init() throws {
        root = repositoryRoot.appendingPathComponent(".app-test-fixtures").appendingPathComponent(UUID().uuidString)
        for directory in [source, destination, otherSource, otherDestination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
