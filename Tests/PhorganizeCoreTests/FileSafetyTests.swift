import Darwin
import XCTest
@testable import PhorganizeCore

final class FileSafetyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_738_833_376)
    private var options: OrganizationOptions {
        OrganizationOptions(includeCameraFolder: false, operationMode: .move, timezoneIdentifier: "UTC", copyConcurrency: 2)
    }

    func testNameRulesRespectCaseSensitivityAndCanonicalUnicode() {
        let sensitive = DestinationNameRules(caseSensitive: true)
        let insensitive = DestinationNameRules(caseSensitive: false)
        XCTAssertNotEqual(sensitive.key("photo.jpg"), sensitive.key("photo.JPG"))
        XCTAssertEqual(insensitive.key("photo.jpg"), insensitive.key("photo.JPG"))
        XCTAssertEqual(sensitive.key("caf\u{e9}"), sensitive.key("cafe\u{301}"))
    }

    func testParallelCaseVariantMovesPreserveEveryFile() async throws {
        for _ in 0..<12 {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try directory(root, "source")
            let destination = try directory(root, "destination")
            let first = try file(source, "first.jpg", "FIRST")
            let second = try file(source, "second.JPG", "OTHER")
            let organizer = FileOrganizer()
            let plan = try await organizer.plan(sourceURL: source, destinationURL: destination, options: options)
            let rules = try DestinationNameRules.read(at: destination, fileManager: .default)
            XCTAssertEqual(Set(plan.files.map { rules.key($0.targetURL.path) }).count, 2)

            let result = await organizer.execute(plan: plan, options: options)

            XCTAssertEqual(result.moved, 2)
            XCTAssertEqual(result.failed, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
            let contents = try plan.files.map { try String(contentsOf: $0.targetURL, encoding: .utf8) }
            XCTAssertEqual(Set(contents), ["FIRST", "OTHER"])
        }
    }

    func testSeparatePlansCannotReplaceEachOthersMoves() async throws {
        for _ in 0..<12 {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceA = try directory(root, "a")
            let sourceB = try directory(root, "b")
            let destination = try directory(root, "destination")
            let first = try file(sourceA, "first.jpg", "FIRST")
            let second = try file(sourceB, "second.jpg", "OTHER")
            let organizer = FileOrganizer()
            let planA = try await organizer.plan(sourceURL: sourceA, destinationURL: destination, options: options)
            let planB = try await organizer.plan(sourceURL: sourceB, destinationURL: destination, options: options)
            XCTAssertEqual(planA.files[0].targetURL, planB.files[0].targetURL)

            async let a = organizer.execute(plan: planA, options: options)
            async let b = organizer.execute(plan: planB, options: options)
            let results = await [a, b]

            XCTAssertEqual(results.map(\.moved).reduce(0, +), 1)
            XCTAssertEqual(results.map(\.failed).reduce(0, +), 1)
            let remaining = [first, second].filter { FileManager.default.fileExists(atPath: $0.path) }
            XCTAssertEqual(remaining.count, 1)
            let target = try String(contentsOf: planA.files[0].targetURL, encoding: .utf8)
            let original = try String(contentsOf: XCTUnwrap(remaining.first), encoding: .utf8)
            XCTAssertEqual(Set([target, original]), ["FIRST", "OTHER"])
            let outputNames = try FileManager.default.contentsOfDirectory(
                atPath: planA.files[0].targetURL.deletingLastPathComponent().path
            )
            XCTAssertEqual(outputNames.count, 1)
        }
    }

    func testExclusivePromotionPreservesExistingAndDanglingSymlinkTargets() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = try file(root, "temporary", "FIRST")
        let target = try file(root, "target", "OTHER")
        XCTAssertThrowsError(try FileOrganizer.promoteWithoutReplacing(temporary, to: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "OTHER")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try FileOrganizer.promoteWithoutReplacing(temporary, to: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), root.appendingPathComponent("missing").path)
    }

    func testSameSizeEditAfterCopyPreventsSourceDeletion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try file(root, "source.jpg", "ORIG")
        let copy = root.appendingPathComponent("copy.jpg")
        let opened = try OpenedMediaFile(original)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileOrganizer.verifyCopy(source: opened, copiedURL: copy, verifyContents: true)

        let writer = try FileHandle(forWritingTo: original)
        try writer.write(contentsOf: Data("EDIT".utf8))
        try writer.close()
        XCTAssertTrue(try FileSnapshot.read(at: original).isSameFile(as: opened.snapshot))
        XCTAssertThrowsError(try opened.removeIfUnchanged())
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "EDIT")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "ORIG")
    }

    func testSizeChangeAndSourceReplacementPreventDeletion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try file(root, "source.jpg", "ORIG")
        let opened = try OpenedMediaFile(original)
        let writer = try FileHandle(forWritingTo: original)
        try writer.write(contentsOf: Data("LONGER".utf8))
        try writer.close()
        XCTAssertThrowsError(try opened.removeIfUnchanged())
        try FileManager.default.removeItem(at: original)
        try Data("NEW".utf8).write(to: original)
        XCTAssertThrowsError(try opened.removeIfUnchanged())
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "NEW")
    }

    func testVerificationRejectsSameSizeCorruptionAndWrongSize() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try file(root, "source.jpg", "ORIG")
        let copy = try file(root, "copy.jpg", "EDIT")
        let opened = try OpenedMediaFile(original)
        XCTAssertThrowsError(try FileOrganizer.verifyCopy(source: opened, copiedURL: copy, verifyContents: true))
        try Data("SHORT".utf8).write(to: copy)
        XCTAssertThrowsError(try FileOrganizer.verifyCopy(source: opened, copiedURL: copy, verifyContents: false))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "ORIG")
    }

    func testUnreadableSubdirectoryFailsPlanningAndSummary() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root can read mode-000 directories.") }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(root, "source")
        let locked = try directory(source, "locked")
        let destination = try directory(root, "destination")
        _ = try file(locked, "source.jpg", "ORIG")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let organizer = FileOrganizer()
        XCTAssertThrowsError(try organizer.summarizeSource(sourceURL: source, recursive: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("locked"))
        }
        var recursive = options
        recursive.recursive = true
        do {
            _ = try await organizer.plan(sourceURL: source, destinationURL: destination, options: recursive)
            XCTFail("An incomplete enumeration must not produce a successful plan.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("locked"))
        }
    }

    func testNonDirectoryDestinationFailsPlanning() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root, "source.jpg", "ORIG")
        let destination = try file(root, "destination", "KEEP")
        do {
            _ = try await FileOrganizer().plan(sourceURL: source, destinationURL: destination, options: options)
            XCTFail("Expected a non-directory destination to fail.")
        } catch OrganizerError.destinationParentMissing {}
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "KEEP")
    }

    func testMoveReportsPartialFailureWhenSourceDirectoryPreventsDeletion() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root can delete files from read-only directories.") }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = try directory(root, "source")
        let original = try file(sourceDirectory, "source.jpg", "ORIG")
        let destination = try directory(root, "destination")
        let organizer = FileOrganizer()
        let plan = try await organizer.plan(sourceURL: original, destinationURL: destination, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sourceDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceDirectory.path) }

        let result = await organizer.execute(plan: plan, options: options)

        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, 1)
        guard case .copiedButSourceDeleteFailed = result.results[0].status else {
            return XCTFail("Expected a preserved copy and explicit source deletion failure.")
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "ORIG")
        XCTAssertEqual(try String(contentsOf: plan.files[0].targetURL, encoding: .utf8), "ORIG")
    }

    private func directory(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ parent: URL, _ name: String, _ contents: String) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }
}
