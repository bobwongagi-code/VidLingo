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

    static func findWhisperExecutable(
        configuredPath: String? = ProcessInfo.processInfo.environment["VIDLINGO_WHISPER_CLI"]
    ) -> URL? {
        if let configuredPath,
           !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath)
            return FileManager.default.isExecutableFile(atPath: configuredURL.path) ? configuredURL : nil
        }

        // 不在发现阶段执行 --help；泰语分段并发时重复启动 CLI 会误报“未安装”。
        return findAllExecutableCandidates(named: ["whisper-cli", "whisper-cpp"]).first
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
}
