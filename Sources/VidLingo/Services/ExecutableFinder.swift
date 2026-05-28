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
        // 先在常用目录查找
        for directory in commonDirectories {
            for name in names {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        // 再在 $PATH 中查找
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in pathDirectories {
            for name in names {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        return nil
    }
}
