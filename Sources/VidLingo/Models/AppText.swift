import Foundation

enum AppText {
    static let appName = "VidLingo"
    static let ready = "就绪"
    static let close = "关闭"
    static let copy = "复制"
    static let languages = "语言"
    static let from = "原文"
    static let to = "译文"
    static let original = "Original"
    static let translation = "Translation"
    static let originalDescription = "Whisper 本地转写结果。"
    static let translationDescription = "所选模型生成的中文译文。"
    static let importVideo = "导入视频"
    static let shortVideoOfflineTranslator = "短视频离线翻译器"
    static let productContext = "商品类型"
    static let productContextPlaceholder = "请输入商品类型"
    static let inferProductContext = "商品类型为空时自动识别"
    static let inferringProductContextHelp = "商品类型为空时，翻译前先根据口播原文自动识别；支持画面理解的模型会辅助参考视频截图。"
    static let clearProductContext = "清空"
    static let unknownProductContext = "未知商品"
    static let selectedVideo = "已导入视频"
    static let playPreview = "播放预览"
    static let hidePreview = "收起预览"
    static let startOfflineTranslation = "开始翻译"
    static let processing = "处理中"
    static let processingVideo = "视频处理中"
    static let confirmVideoContent = "等待 Whisper 和所选模型处理前，先确认导入的是目标视频。"
    static let autoDetectInput = "自动检测输入语言"
    static let noCaptionsYet = "导入一个短视频"
    static let noCaptionsDescription = "选择本地 .mov 或 .mp4 文件。VidLingo 会本地转写，再用所选模型翻译完整文稿。"
    static let translating = "正在翻译..."

    static let translationModelSettings = "翻译模型"
    static let translationProvider = "模型服务"
    static let translationModelPlaceholder = "模型名，例如 gpt-4o-mini / qwen-plus"
    static let translationEndpointPlaceholder = "OpenAI-compatible chat completions URL"
    static let translationAPIKeyConfigured = "API key 已保存"
    static let translationAPIKeyNotConfigured = "未保存 API key"
    static let saveTranslationAPIKey = "保存"
    static let removeTranslationAPIKey = "删除 API key"
    static let translationAPIKeyEmpty = "保存前请输入 API key。"
    static let translationAPIKeyInvalidStoredValue = "保存的 API key 无法读取。"
    static let translationModelMissing = "翻译模型名不能为空。"
    static let translationEndpointInvalid = "Custom endpoint 不是有效 URL。"
    static let translationInvalidResponse = "模型服务返回了无效响应。"
    static let noEffectiveSpeech = "未检测到有效口播"
    static let noEffectiveSpeechDescription = "这段视频可能没有可转写的人声，或 Whisper 只生成了重复幻觉文本。请手动填写商品类型，或换有清晰口播的视频。"
    static let visualSalesCopyNotice = "未检测到有效口播。以下内容不是口播翻译，而是根据视频画面推断生成的中文口播文案。"
    static let visualFramesMissing = "没有可用于画面理解的视频截图。"

    static let savedTranscripts = "资料库"
    static let manageSavedTranscripts = "管理已保存记录"
    static let autoSaveDescription = "离线翻译完成后，原文和译文会自动保存到本地。"
    static let openSaveFolder = "打开保存文件夹"
    static let savedEmpty = "还没有保存记录"
    static let editSaved = "编辑记录"
    static let saveEdits = "保存修改"
    static let deleteSavedTranscript = "删除记录"
    static let deleteAllSavedTranscripts = "删除全部"
    static let deleteAllSavedTranscriptsConfirmation = "确定删除全部保存记录？"
    static let noSavedTranscriptSelected = "未选择记录"

    static func languageTitle(for id: String, fallback: String) -> String {
        switch id {
        case "en-US": "英语"
        case "ko-KR": "韩语"
        case "ja-JP": "日语"
        case "zh-CN": "简体中文"
        case "th-TH": "泰语"
        case "ms-MY": "马来语"
        case "id-ID": "印尼语"
        case "es-ES": "西班牙语"
        case "fr-FR": "法语"
        case "de-DE": "德语"
        default: fallback
        }
    }

    static func offlineVideoExtractingAudio(_ fileName: String) -> String {
        "正在从 \(fileName) 提取音频..."
    }

    static func offlineVideoDetectingLanguage(_ fileName: String) -> String {
        "正在检测 \(fileName) 的口播语言..."
    }

    static func offlineVideoDetectedLanguage(_ language: String) -> String {
        "已检测到口播语言：\(language)"
    }

    static func offlineVideoTranscribing(_ fileName: String) -> String {
        "正在用本地 Whisper 转写 \(fileName)..."
    }

    static func inferringProductContext(_ fileName: String) -> String {
        "正在识别 \(fileName) 的商品类型..."
    }

    static func offlineVideoTranslating(_ fileName: String, provider: String) -> String {
        "正在用 \(provider) 翻译 \(fileName)..."
    }

    static func generatingVisualSalesCopy(_ fileName: String) -> String {
        "未检测到有效口播，正在根据 \(fileName) 的画面生成中文文案..."
    }

    static func offlineVideoComplete(_ fileName: String) -> String {
        "离线翻译完成：\(fileName)"
    }

    static func offlineVideoFailed(_ message: String) -> String {
        "短视频离线翻译失败：\(message)"
    }

    static func saveLibraryFailed(_ message: String) -> String {
        "保存资料库失败：\(message)"
    }

    static func translationAPIKeyPlaceholder(_ provider: String) -> String {
        "粘贴 \(provider) API key"
    }

    static func translationAPIKeySaved(_ provider: String) -> String {
        "\(provider) API key 已保存到 Keychain。"
    }

    static func translationAPIKeyRemoved(_ provider: String) -> String {
        "\(provider) API key 已删除。"
    }

    static func translationAPIKeyMissing(_ provider: String) -> String {
        "使用 \(provider) 翻译前，请先保存 API key。"
    }

    static func translationEmptyOutput(_ provider: String) -> String {
        "\(provider) 没有返回译文。"
    }

    static func translationRequestFailed(provider: String, statusCode: Int, message: String?) -> String {
        let detail = message.map { ": \($0)" } ?? ""
        return "\(provider) 请求失败（\(statusCode)）\(detail)"
    }

    static func visualModelUnsupported(_ provider: String) -> String {
        "\(provider) 当前模型不支持视频画面理解。"
    }

    static func translationAPIKeychainFailed(_ status: OSStatus) -> String {
        "Keychain 操作失败（\(status)）。"
    }
}
