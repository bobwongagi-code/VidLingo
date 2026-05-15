![AirTranslate hero](docs/assets/airtranslate-readme-hero.png)

![AirTranslate demo](docs/assets/airtranslate-readme-demo.gif)

# AirTranslate

适用于 macOS 的实时系统音频转写与翻译应用。

<p align="center">
  <a href="https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg"><img alt="Download AirTranslate.dmg" src="https://img.shields.io/badge/Download-AirTranslate.dmg-2EA44F?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/himomohi/AirTranslate/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/himomohi/AirTranslate?style=for-the-badge&label=Latest"></a>
</p>

<p align="center">
  <a href="#下载">下载</a> ·
  <a href="#环境要求">环境要求</a> ·
  <a href="#隐私与-api-key">隐私</a> ·
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ja.md">日本語</a> ·
  中文
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-0A84FF?style=flat-square&logo=apple">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square"></a>
</p>

AirTranslate 可以捕获 Mac 正在播放的音频，实时转写并翻译，也可以通过悬浮字幕窗口显示结果。它适用于会议、课程、视频、采访和直播等场景，避免通过外部麦克风转录造成的麻烦和音质损失。

默认流程使用 Apple 框架。基于 GPT 的 realtime 模型是可选功能，只有在用户提供自己的 OpenAI API key 后才会启用。

## 为什么选择 AirTranslate

- **优先使用系统音频:** 通过 ScreenCaptureKit 直接捕获 Mac 播放音频。
- **易读的实时工作区:** 原文和译文并排显示。
- **悬浮字幕:** 可在其他应用上方显示字幕。
- **默认 Apple 流程:** 以 Apple Speech 和 Apple Translation 作为基础路径。
- **可选 GPT 模式:** 仅在需要时启用 OpenAI Realtime 转写/翻译。
- **Keychain 存储:** OpenAI API key 由用户输入，并保存在 macOS Keychain。
- **纯文本历史:** 已保存记录是 Mac 上普通的 `.txt` 文件。

## 核心功能

- 实时捕获 Mac 系统音频
- Apple Speech 转写
- Apple Translation 翻译
- 基于 OpenAI Realtime 的 GPT 模式
- 仅实时翻译的模型路径
- 一键交换原文/译文语言
- 悬浮字幕窗口
- 基于 macOS 拼写建议的记录修正
- 可选译文语音输出
- 查看、编辑、删除和打开已保存记录文件夹
- 根据 Mac 语言设置自动选择英语、韩语、日语或简体中文界面

## 处理模式

AirTranslate 将快速选择和详细设置分开。

| 模式 | 适用场景 | 说明 |
| --- | --- | --- |
| Apple 默认模式 | 本地优先的转写和翻译 | 使用 Apple Speech 转写，并用 Apple Translation 翻译所选语言对。 |
| GPT 模式 | OpenAI Realtime 转写或翻译 | 启用 GPT realtime 模型。如果没有保存 API key，AirTranslate 会打开设置弹窗并聚焦 API key 输入框。 |
| 仅转写 | 只需要原文字幕 | 不运行翻译，只保留原文记录。 |
| 仅实时翻译 | 需要模型直接生成译文流 | 使用 realtime translation 模型直接生成翻译结果。 |

GPT 模型细节、API key 输入、记录修正和语音输出都在齿轮设置弹窗中管理。主侧边栏只保留最常用的选择。

## 隐私与 API key

AirTranslate 不包含自有后端账号系统。

- Apple 默认模式使用 macOS 框架和 Apple 语言资源。
- 只有启用 GPT 模式或 OpenAI 翻译模型时才会发送 OpenAI 请求。
- OpenAI API key 不会硬编码、提交到仓库，也不会包含在发布包中。
- API key 使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 保存到 macOS Keychain。
- 已保存记录是用户 Mac 上的纯文本文件。

需要 API key 时，请打开 [OpenAI API key 页面](https://platform.openai.com/api-keys)，创建 key 后粘贴到 AirTranslate 设置弹窗。

## Apple 翻译语言包

Apple 默认模式使用 macOS 管理的翻译语言资源。使用新的语言对之前，请先下载所需的 Apple 翻译语言包。

1. 打开**系统设置**。
2. 前往**通用 > 语言与地区**。
3. 点击**翻译语言**。
4. 为要使用的源语言和目标语言分别点击**下载**。
5. 可选：如果希望 macOS 尽可能在 Mac 本机处理支持的翻译，请开启**设备端模式**。

如果所选语言对不可用或尚未下载，Apple 默认模式的翻译可能无法开始，或在 macOS 准备好所需语言资源之前显示不可用状态。

## 权限

AirTranslate 只请求捕获和转写流程需要的权限。

- 屏幕录制
- 系统音频录制
- 语音识别

由于 ScreenCaptureKit 的系统音频捕获路径需要屏幕录制权限，因此应用会请求该权限。AirTranslate 不会把屏幕画面保存为录制文件。

更改 macOS 隐私权限后，请退出并重新启动应用，以便签名后的应用 bundle 获得新的授权状态。

## 下载

最新开源构建可在 [GitHub Releases](https://github.com/himomohi/AirTranslate/releases/latest) 下载，也可以直接下载 ZIP。

- [下载 AirTranslate-1.2.1.zip](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate-1.2.1.zip)
- [查看版本历史](Release/VERSION-HISTORY.md)

发布 ZIP 是面向开源分发的 ad-hoc 签名构建。首次启动时，macOS 可能要求你在“隐私与安全性”中批准运行。

## 环境要求

- macOS 26.0 或更高版本
- Swift 6.2 或更高版本
- 支持系统音频捕获的 Mac
- 可使用 Apple Speech 和 Apple Translation 框架的环境
- 可选: GPT 模式需要 OpenAI API key

## 从源码构建

运行应用 bundle：

```bash
./script/build_and_run.sh
```

构建并验证启动：

```bash
./script/build_and_run.sh --verify
```

查看日志：

```bash
./script/build_and_run.sh --logs
```

开发时重置权限：

```bash
./script/build_and_run.sh --reset-permissions
```

SwiftPM 检查：

```bash
swift build
swift test
```

## 基本用法

1. 选择原文语言和译文语言。
2. 如需反向翻译，点击中间的语言交换按钮。
3. 选择 Apple 默认模式或 GPT 模式。
4. 如果 GPT 模式提示需要 API key，请在设置弹窗中输入 OpenAI API key。
5. 点击开始。
6. 在 Mac 上播放会议、课程、视频、采访或直播音频。
7. 在主工作区或悬浮字幕窗口查看原文和译文。
8. 点击停止后，当前记录会被保存。

## 已保存记录

已保存记录以纯文本文件保存：

```text
~/Library/Application Support/AirTranslate/Transcripts/*.txt
```

同时保存原文和译文时，AirTranslate 会分别写入 `_original.txt` 和 `_translation.txt` 文件，并在应用资料库 UI 中显示为一个组合项目。

## 项目结构

```text
Package.swift
Resources/
  AppIcon.png
  AppIcon.icns
Sources/AirTranslate/
  App/
  Models/
  Services/
  Support/
  Views/
Sources/AirTranslateCore/
Tests/
script/
  build_and_run.sh
docs/assets/
  airtranslate-readme-hero.png
```

## 关键实现区域

- `SystemAudioCapture`: 通过 ScreenCaptureKit 捕获 Mac 系统音频。
- `LiveSpeechTranscriber`: 通过 Apple Speech 流式转写。
- `AppleTranslationService`: 隔离 Apple Translation 翻译工作。
- `OpenAIRealtimeTranscriber`: 处理可选 realtime 转写。
- `OpenAITranslationService`: 处理可选 realtime 翻译请求。
- `OpenAIAPIKeyStore`: 将 API key 保存到 macOS Keychain。
- `TranslationSessionStore`: 协调捕获、记录状态、翻译、保存和语音输出。
- `SidebarView`: 提供语言、处理方式、会话和设置入口。
- `CaptionBoardView`: 显示实时记录、翻译、控制项和音频仪表。
- `TranscriptLibraryView`: 管理已保存记录。
- `FloatingCaptionWindowController`: 管理悬浮字幕窗口生命周期。

## 许可证

AirTranslate 基于 [Apache License 2.0](LICENSE) 发布。版权声明见 [NOTICE](NOTICE)。

AirTranslate 是独立的开源项目，不隶属于 Apple 或 OpenAI，也未与其建立合作关系。
