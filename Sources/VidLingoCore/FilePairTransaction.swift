import Foundation

public enum FilePairTransactionError: LocalizedError, Sendable, Equatable {
    case filesMustShareDirectory
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .filesMustShareDirectory:
            "原文和译文必须位于同一资料库目录。"
        case let .rollbackFailed(message):
            "资料库操作回滚失败：\(message)"
        }
    }
}

/// 以同目录临时隔离目录完成一对文件的删除，失败时尽量恢复原文件。
public enum FilePairTransaction {
    public static func retire(
        sourceURL: URL,
        translationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        let translationDirectory = translationURL.deletingLastPathComponent().standardizedFileURL
        guard sourceDirectory == translationDirectory else {
            throw FilePairTransactionError.filesMustShareDirectory
        }

        let quarantineURL = sourceDirectory.appendingPathComponent(
            ".staging-retire-\(UUID().uuidString)",
            isDirectory: true
        )
        let quarantinedSourceURL = quarantineURL.appendingPathComponent("original.txt")
        let quarantinedTranslationURL = quarantineURL.appendingPathComponent("translation.txt")
        try fileManager.createDirectory(at: quarantineURL, withIntermediateDirectories: true)

        var movedSource = false
        var movedTranslation = false
        do {
            try fileManager.moveItem(at: sourceURL, to: quarantinedSourceURL)
            movedSource = true
            try fileManager.moveItem(at: translationURL, to: quarantinedTranslationURL)
            movedTranslation = true
            try fileManager.removeItem(at: quarantineURL)
        } catch {
            do {
                if movedTranslation {
                    try fileManager.moveItem(at: quarantinedTranslationURL, to: translationURL)
                }
                if movedSource {
                    try fileManager.moveItem(at: quarantinedSourceURL, to: sourceURL)
                }
                try? fileManager.removeItem(at: quarantineURL)
            } catch {
                throw FilePairTransactionError.rollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }
}
