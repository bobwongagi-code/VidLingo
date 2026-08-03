import Foundation
import VidLingoCore

enum WhisperModelResolver {
    private static let generalModelNames = [
        "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo-q8_0.bin",
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3-q5_0.bin",
        "ggml-large-v3.bin",
        "ggml-large-v2-q5_0.bin",
        "ggml-large-v2.bin",
        "ggml-medium-q5_0.bin",
        "ggml-medium.bin",
        "ggml-small-q5_1.bin",
        "ggml-small.bin",
        "ggml-base.bin",
        "ggml-tiny.bin"
    ]

    private static var modelDirectories: [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? home.appendingPathComponent("Library/Application Support")
        return [
            applicationSupportURL.appendingPathComponent("VidLingo/Models"),
            applicationSupportURL.appendingPathComponent("AirTranslate/Models"),
            applicationSupportURL.appendingPathComponent("whisper/Models"),
            home.appendingPathComponent(".cache/whisper"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp"),
            URL(fileURLWithPath: "/usr/local/share/whisper.cpp")
        ]
    }

    static func cliExecutableURL() -> URL? {
        ExecutableFinder.findWhisperExecutable()
    }

    static var modelCandidatePaths: [URL] {
        candidatePaths(for: generalModelNames)
    }

    static var generalModelURL: URL? {
        candidatePaths(for: generalModelNames).first(where: isUsableModel)
    }

    static var preferredModelDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("VidLingo/Models")
    }

    private static func candidatePaths(for names: [String]) -> [URL] {
        names.flatMap { name in modelDirectories.map { $0.appendingPathComponent(name) } }
    }

    private static func isUsableModel(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber,
        size.int64Value >= 30 * 1_024 * 1_024,
        let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44) else { return false }
        return WhisperModelValidator.hasValidGGMLHeader(header)
    }
}
