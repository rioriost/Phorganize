import Darwin
import XCTest
@testable import PhorganizeCore

final class DuplicatePlanningTests: XCTestCase {
    private let options = OrganizationOptions(includeCameraFolder: false, timezoneIdentifier: "UTC")

    func testSubsetReimportFindsExistingNumberedFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, destination, a, b) = try fixtures(root)
        let organizer = FileOrganizer()
        let first = try await organizer.plan(sourceURL: source, destinationURL: destination, options: options)
        let result = await organizer.execute(plan: first, options: options)
        XCTAssertEqual(result.failed, 0)

        let subset = try await organizer.plan(sourceURL: b, destinationURL: destination, options: options)
        XCTAssertTrue(subset.files.isEmpty)
        XCTAssertEqual(subset.existingIdenticalFiles.map(\.sourceURL), [b])
        XCTAssertEqual(subset.existingIdenticalFiles[0].existingTargetURL, first.files.first {
            $0.sourceURL.lastPathComponent == b.lastPathComponent
        }?.targetURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testExpandedBatchFindsExistingUnnumberedFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, destination, a, b) = try fixtures(root)
        let organizer = FileOrganizer()
        let first = try await organizer.plan(sourceURL: a, destinationURL: destination, options: options)
        let result = await organizer.execute(plan: first, options: options)
        XCTAssertEqual(result.failed, 0)

        let expanded = try await organizer.plan(sourceURL: source, destinationURL: destination, options: options)
        XCTAssertEqual(expanded.files.map(\.sourceURL.lastPathComponent), [b.lastPathComponent])
        XCTAssertEqual(expanded.existingIdenticalFiles.map(\.sourceURL.lastPathComponent), [a.lastPathComponent])
    }

    func testGapAndMultipleIdenticalSourcesDoNotCreateExtraCopies() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (source, destination, a, b) = try fixtures(root)
        let organizer = FileOrganizer()
        let first = try await organizer.plan(sourceURL: source, destinationURL: destination, options: options)
        let result = await organizer.execute(plan: first, options: options)
        XCTAssertEqual(result.failed, 0)
        let targetA = try XCTUnwrap(first.files.first { $0.sourceURL.lastPathComponent == a.lastPathComponent }?.targetURL)
        try FileManager.default.removeItem(at: targetA)
        let sameContent = source.appendingPathComponent("c.jpg")
        try FileManager.default.copyItem(at: b, to: sameContent)

        let again = try await organizer.plan(sourceURL: source, destinationURL: destination, options: options)
        XCTAssertEqual(again.files.map(\.sourceURL.lastPathComponent), [a.lastPathComponent])
        XCTAssertEqual(Set(again.existingIdenticalFiles.map(\.sourceURL.lastPathComponent)),
                       Set([b.lastPathComponent, sameContent.lastPathComponent]))
        XCTAssertEqual(Set(again.existingIdenticalFiles.map(\.existingTargetURL)).count, 1)
    }

    func testComparatorErrorsAreNotTreatedAsDifferentContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 0)
        let candidate = MediaFileCandidate(
            sourceURL: root.appendingPathComponent("source.jpg"),
            metadata: MediaMetadata(creationDate: date, cameraModel: nil, source: .image)
        )
        let target = root.appendingPathComponent("1970/01/01/19700101-000000.jpg")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: target)
        XCTAssertThrowsError(try TargetPlanner.makePlanningResult(
            candidates: [candidate],
            destinationURL: root,
            options: options,
            existingFileComparator: { _, _ in throw CocoaError(.fileReadNoPermission) }
        ))
    }

    func testDanglingSymlinkReservesItsName() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = MediaFileCandidate(
            sourceURL: root.appendingPathComponent("source.jpg"),
            metadata: MediaMetadata(creationDate: Date(timeIntervalSince1970: 0), cameraModel: nil, source: .image)
        )
        let target = root.appendingPathComponent("1970/01/01/19700101-000000.jpg")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        let plan = try TargetPlanner.makePlan(candidates: [candidate], destinationURL: root, options: options)
        XCTAssertEqual(plan[0].targetURL.lastPathComponent, "19700101-000000_1.jpg")
    }

    private func fixtures(_ root: URL) throws -> (URL, URL, URL, URL) {
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let a = source.appendingPathComponent("a.jpg")
        let b = source.appendingPathComponent("b.jpg")
        let date = Date(timeIntervalSince1970: 1_738_833_376)
        for (url, contents) in [(a, "first"), (b, "other")] {
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        return (source, destination, a, b)
    }
}
