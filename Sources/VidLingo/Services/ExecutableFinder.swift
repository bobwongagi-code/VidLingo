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

}
