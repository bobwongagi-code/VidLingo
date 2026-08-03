# VidLingo

VidLingo 是一个本地优先的 macOS 短视频翻译器。它导入本地视频，在本地提取语音音频，上传到阿里云 Fun-ASR Flash 转写完整口播内容，再调用你选择的 LLM 模型翻译成简体中文。

当前版本已经不再做实时 Mac 音频捕获、麦克风录音、屏幕录制或悬浮字幕。

## 功能

- 导入本地 `.mov`、`.mp4`、`.m4v` 短视频。
- 导入后在应用内预览视频。
- 用 `ffmpeg` 本地提取语音音频。
- 所有支持的语言统一使用 `fun-asr-flash-2026-06-15` 转写。
- 开启自动检测时，根据 Fun-ASR 返回的文本在本地判断口播语言。
- 用带货短视频语境 prompt 调用所选模型翻译整段内容。
- 输出固定为简体中文；输入语言可自动检测或手动选择。
- 可选择 DeepSeek、OpenAI、千问、OpenRouter / Claude、Anthropic / Claude，或自定义 OpenAI-compatible endpoint。
- 本地保存原文和中文译文。
- 无口播时，可在单独开启云端截图授权和画面文案开关后，根据视频画面生成带来源说明的中文口播文案。

## 依赖

- macOS 15 或更新版本。
- Swift 6 工具链。
- `PATH` 中可用的 `ffmpeg`。
- 在应用中保存 Qwen / 千问 API key 供 Fun-ASR 使用，并保存所选翻译服务的 API key。选择千问翻译时，两者使用同一把 key。
- 提取出的口播音频会上传到 Fun-ASR；视频截图和无口播画面文案仍由单独的授权开关控制。
- 云端视频截图和无口播画面文案分别由默认关闭的开关控制。
- 自定义 endpoint 默认必须使用 HTTPS；本机 HTTP 仅在明确设置 `VIDLINGO_ALLOW_LOCAL_HTTP=1` 时允许。

## 翻译模型服务

VidLingo 用统一的 Chat Completions 风格请求支持这些内置服务：

```text
DeepSeek       https://api.deepseek.com/chat/completions        deepseek-v4-flash
OpenAI         https://api.openai.com/v1/chat/completions       gpt-4o-mini
Qwen / 千问     https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions  qwen3.6-plus
Qwen-MT        同一个千问 endpoint，模型名如 qwen-mt-flash 或 qwen-mt-plus
OpenRouter / Claude  https://openrouter.ai/api/v1/chat/completions  anthropic/claude-sonnet-4.5
Anthropic / Claude   https://api.anthropic.com/v1/messages             claude-sonnet-4-5
Custom         用户填写的 OpenAI-compatible chat completions URL（HTTPS）
```

自定义 endpoint 不能包含查询参数或 URL fragment；凭证应填写在服务对应的 API key 字段中。响应支持 `choices[].message.content`、内容块数组、`choices[].text`、顶层 `output_text`，以及包含文本的 `output` 结构。

API key 会按服务分别保存在 macOS Keychain 中。旧 DeepSeek key 会继续作为迁移兼容读取。

当千问模型名以 `qwen-mt-` 开头时，VidLingo 会使用 Qwen-MT 要求的 `translation_options` 请求格式，而不是普通 chat prompt。

Fun-ASR 使用当前工作空间的原生接口：

```text
https://llm-nlx73tfv3mm6w67e.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation
fun-asr-flash-2026-06-15
```

翻译系统 prompt 打包在：

```text
Resources/TranslationSystemPrompt.md
```

## 本地运行

```bash
./script/build_and_run.sh run
```

`run` 模式要求设置稳定的 `CODE_SIGN_IDENTITY`，会构建 Swift package，生成 `dist/VidLingo.app`，复制到 `~/Applications/VidLingo.app` 并打开。只有明确使用 `dev-run` 时才会用临时签名进行本地开发运行；重建后 Keychain 和隐私授权可能重置。不带参数时只构建 bundle。

## 本地数据

新的转写和翻译记录以带 manifest 的目录保存到：

```text
~/Library/Application Support/VidLingo/Transcripts/
```

应用会以只读方式读取旧目录中的记录。点击“导入旧 AirTranslate 记录”后，才会复制到 VidLingo 资料库；删除全部只删除 VidLingo 自己的记录：

```text
~/Library/Application Support/AirTranslate/Transcripts/
```

## 构建和验证

```bash
./script/build_and_run.sh build    # 只构建 dist/VidLingo.app
./script/build_and_run.sh package  # 使用稳定签名构建并打包 zip
./script/build_and_run.sh install  # 构建并安装到 ~/Applications
./script/build_and_run.sh run      # 构建、安装并打开
./script/build_and_run.sh verify   # 构建并验证签名和 bundle
./script/build_and_run.sh stop     # 明确停止正在运行的 VidLingo
swift test
```

本地 `build` 可以使用临时签名做 bundle 检查；`install`、`run`、`package` 和 `verify` 必须显式设置稳定的 Apple 签名身份，确保 Keychain 和隐私授权绑定到正确的 App 身份。只有明确的 `dev-run` 允许临时签名安装并打开。可用 `VIDLINGO_ALLOW_ADHOC_SIGNING=0` 禁止临时签名。

## 项目结构

```text
Sources/VidLingo/          macOS 应用界面和平台集成
Sources/VidLingoCore/      纯流程规则、转写文本整理和存储工具
Resources/                 app icon 资源
script/                    本地构建和 app bundle 脚本
```
