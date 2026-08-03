import Foundation
import XCTest
@testable import VidLingo

final class ExecutableFinderTests: XCTestCase {
    func testFindsExecutableInProvidedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VidLingo-ExecutableFinder-\(UUID().uuidString)", isDirectory: true)
        let executableURL = directory.appendingPathComponent("vidlingo-test-tool")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertEqual(
            ExecutableFinder.findExecutable(
                named: [executableURL.lastPathComponent],
                commonDirectories: [directory.path]
            ),
            executableURL
        )
    }
}
