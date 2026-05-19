# VidLingo

VidLingo 是一个本地优先的 macOS 短视频离线翻译器。它导入本地视频，提取语音音频，用本地 Whisper 转写完整口播内容，再调用你选择的 LLM 模型翻译成简体中文。

当前版本已经不再做实时 Mac 音频捕获、麦克风录音、屏幕录制或悬浮字幕。

## 功能

- 导入本地 `.mov`、`.mp4`、`.m4v` 短视频。
- 导入后在应用内预览视频。
- 用 `ffmpeg` 本地提取语音音频。
- 用 `whisper.cpp` 本地转写。
- 开启自动检测时，优先使用 Whisper 判断口播语言。
- 用带货短视频语境 prompt 调用所选模型翻译整段内容。
- 可选择 DeepSeek、OpenAI、千问、Claude 兼容接口，或自定义 OpenAI-compatible endpoint。
- 本地保存原文和中文译文。

## 依赖

- macOS 15 或更新版本。
- Swift 6 工具链。
- `PATH` 中可用的 `ffmpeg`。
- `PATH` 中可用的 `whisper-cli` 或 whisper.cpp `main`。
- 本地 Whisper 模型，推荐 `ggml-large-v3-turbo-q5_0.bin`。
- 在应用中保存所选翻译服务的 API key。

VidLingo 会在这些目录查找 Whisper 模型：

```text
~/Library/Application Support/VidLingo/Models/
~/Library/Application Support/AirTranslate/Models/
~/.cache/whisper/
```

旧 `AirTranslate` 模型目录会继续作为迁移兼容路径读取。

## 翻译模型服务

VidLingo 用统一的 Chat Completions 风格请求支持这些内置服务：

```text
DeepSeek       https://api.deepseek.com/chat/completions        deepseek-v4-flash
OpenAI         https://api.openai.com/v1/chat/completions       gpt-4o-mini
Qwen / 千问     https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions  qwen-plus
Qwen-MT        同一个千问 endpoint，模型名如 qwen-mt-flash 或 qwen-mt-plus
Claude         https://api.anthropic.com/v1/chat/completions    claude-sonnet-4-5-20250929
Custom         用户填写的 OpenAI-compatible chat completions URL
```

API key 会按服务分别保存在 macOS Keychain 中。旧 DeepSeek key 会继续作为迁移兼容读取。

当千问模型名以 `qwen-mt-` 开头时，VidLingo 会使用 Qwen-MT 要求的 `translation_options` 请求格式，而不是普通 chat prompt。

翻译系统 prompt 打包在：

```text
Resources/TranslationSystemPrompt.md
```

## 本地运行

```bash
./script/build_and_run.sh
```

脚本会构建 Swift package，生成 `dist/VidLingo.app`，复制到 `~/Applications/VidLingo.app`，本地签名并打开。

## 本地数据

新的转写和翻译记录保存到：

```text
~/Library/Application Support/VidLingo/Transcripts/
```

应用也会读取旧目录中的记录：

```text
~/Library/Application Support/AirTranslate/Transcripts/
```

## 项目结构

```text
Sources/VidLingo/          macOS 应用界面和离线翻译流程
Sources/VidLingoCore/      转写文本整理工具
Resources/                 app icon 资源
script/                    本地构建和 app bundle 脚本
```
