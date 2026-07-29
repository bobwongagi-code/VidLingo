import Foundation

/// 在常用路径和 $PATH 中查找可执行文件
enum ExecutableFinder {
    static func findExecutable(
        named names: [String],
        commonDirectories: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin"
        ]
    ) -> URL? {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let directories = pathDirectories + commonDirectories

        for name in names {
            for directory in directories {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        return nil
    }

    static func findWhisperExecutable() -> URL? {
        if let configuredPath = ProcessInfo.processInfo.environment["VIDLINGO_WHISPER_CLI"],
           !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath)
            return isWhisperExecutable(configuredURL) ? configuredURL : nil
        }

        let candidates = findAllExecutableCandidates(named: ["whisper-cli", "whisper-cpp"])
        return candidates.first(where: isWhisperExecutable)
    }

    private static func findAllExecutableCandidates(named names: [String]) -> [URL] {
        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin"
        ]
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var candidates = [URL]()
        for name in names {
            for directory in pathDirectories + commonDirectories {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path), !candidates.contains(url) {
                    candidates.append(url)
                }
            }
        }
        return candidates
    }

    private static func isWhisperExecutable(_ url: URL) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = url
        process.arguments = ["--help"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            let token = ProcessCancellationToken(timeout: 2)
            let status = try ProcessSupervisor.run(process, token: token, timeout: 2)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data.prefix(32 * 1024), as: UTF8.self).lowercased()
            return status == 0 && (output.contains("whisper") || output.contains("ggml"))
        } catch {
            return false
        }
    }
}
