import XCTest

final class CoverageScriptTests: XCTestCase {
    func testCoverageGateDiscoversNativeAndSwiftbuildOutputsOnEitherArchitecture() throws {
        for architecture in ["arm64", "x86_64"] {
            for names in [["PhorganizePackageTests"], ["PhorganizeCoreTests", "PhorganizeAppTests"]] {
                let result = try runGate(architecture: architecture, bundleNames: names, coverage: "80.00", threshold: "80")
                XCTAssertEqual(result.status, 0, result.output)
                for name in names {
                    XCTAssertTrue(result.arguments.contains("\(architecture)-apple-macosx/debug/\(name).xctest/Contents/MacOS/\(name)"))
                }
                XCTAssertTrue(result.arguments.contains("\(architecture)-apple-macosx/debug/codecov/default.profdata"))
                XCTAssertEqual(result.arguments.components(separatedBy: "-object").count - 1, names.count - 1)
            }
        }
    }

    func testCoverageGateEnforcesExactThresholdAndRejectsInvalidInputs() throws {
        XCTAssertNotEqual(try runGate(coverage: "79.99", threshold: "80").status, 0)
        XCTAssertEqual(try runGate(coverage: "80.01", threshold: "80").status, 0)
        XCTAssertNotEqual(try runGate(coverage: "not-a-number", threshold: "80").status, 0)
        XCTAssertNotEqual(try runGate(coverage: "80", threshold: "invalid").status, 0)
        XCTAssertNotEqual(try runGate(coverage: "80", threshold: "101").status, 0)
        XCTAssertNotEqual(try runGate(bundleNames: [], coverage: "80", threshold: "80").status, 0)
    }

    private func runGate(
        architecture: String = "arm64",
        bundleNames: [String] = ["PhorganizeCoreTests"],
        coverage: String,
        threshold: String
    ) throws -> (status: Int32, output: String, arguments: String) {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = root.appendingPathComponent("commands")
        let products = root.appendingPathComponent("build with spaces/\(architecture)-apple-macosx/debug")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        for name in bundleNames {
            let binary = products.appendingPathComponent("\(name).xctest/Contents/MacOS/\(name)")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: binary)
        }
        let swift = commands.appendingPathComponent("swift")
        try """
        #!/bin/sh
        case "$1" in
          test) exit 0 ;;
          build) printf '%s\\n' "$MOCK_PRODUCTS" ;;
          *) exit 2 ;;
        esac
        """.write(to: swift, atomically: true, encoding: .utf8)
        let xcrun = commands.appendingPathComponent("xcrun")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "$MOCK_ARGUMENTS"
        printf 'TOTAL 1 0 100%% 1 0 100%% 100 20 %s%%\\n' "$MOCK_COVERAGE"
        """.write(to: xcrun, atomically: true, encoding: .utf8)
        for command in [swift, xcrun] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        }
        let argumentLog = root.appendingPathComponent("arguments")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/check_coverage.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, threshold]
        process.environment = [
            "PATH": "\(commands.path):/usr/bin:/bin",
            "MOCK_PRODUCTS": products.path,
            "MOCK_ARGUMENTS": argumentLog.path,
            "MOCK_COVERAGE": coverage
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let arguments = FileManager.default.fileExists(atPath: argumentLog.path)
            ? try String(contentsOf: argumentLog, encoding: .utf8) : ""
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), arguments)
    }
}
