![AirTranslate hero](docs/assets/airtranslate-readme-hero.png)

![AirTranslate demo](docs/assets/airtranslate-readme-demo.gif)

# AirTranslate

macOS向けのリアルタイム・システム音声文字起こし/翻訳アプリ。

<p align="center">
  <a href="https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate.dmg"><img alt="Download AirTranslate.dmg" src="https://img.shields.io/badge/Download-AirTranslate.dmg-2EA44F?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/himomohi/AirTranslate/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/himomohi/AirTranslate?style=for-the-badge&label=Latest"></a>
</p>

<p align="center">
  <a href="#ダウンロード">ダウンロード</a> ·
  <a href="#必要環境">必要環境</a> ·
  <a href="#プライバシーとapiキー">プライバシー</a> ·
  <a href="README.md">English</a> ·
  <a href="README.ko.md">한국어</a> ·
  日本語 ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-0A84FF?style=flat-square&logo=apple">
  <img alt="Swift 6.2+" src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=flat-square&logo=swift&logoColor=white">
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-blue?style=flat-square"></a>
</p>

AirTranslateは、Macで再生されている音声をリアルタイムで文字起こしし、翻訳し、必要に応じてフローティング字幕として表示します。会議、講義、動画、インタビュー、配信など、外部マイク経由では扱いにくい音声をMacのシステムオーディオから直接処理するためのアプリです。

デフォルトの処理フローはAppleフレームワークを使用します。GPTベースのrealtimeモデルは任意で、ユーザーがOpenAI APIキーを入力した場合のみ利用できます。

## AirTranslateを使う理由

- **システム音声優先:** ScreenCaptureKitでMacの再生音声を直接キャプチャします。
- **読みやすいライブ画面:** 原文と翻訳を並べて表示します。
- **フローティング字幕:** 他のアプリの上に字幕を表示できます。
- **Appleがデフォルト:** Apple SpeechとApple Translationを基本経路にします。
- **任意のGPTモード:** 必要なときだけOpenAI Realtimeの文字起こし/翻訳を有効にします。
- **Keychain保存:** OpenAI APIキーはユーザーが入力し、macOS Keychainに保存します。
- **プレーンテキスト履歴:** 保存済み記録はMac内の通常の`.txt`ファイルです。

## 主な機能

- Macシステム音声のリアルタイムキャプチャ
- Apple Speechによる文字起こし
- Apple Translationによる翻訳
- OpenAI RealtimeによるGPTモード
- 翻訳のみのrealtimeモデル経路
- 原文/翻訳言語のワンクリック入れ替え
- フローティング字幕ウィンドウ
- macOSスペル候補に基づく記録補正
- 任意の翻訳音声出力
- 保存済み記録の確認、編集、削除、フォルダ表示
- Macの言語設定に応じた英語、韓国語、日本語、簡体字中国語UIの自動選択

## 処理モード

AirTranslateは、すばやい選択と詳細設定を分けています。

| モード | 適した用途 | 詳細 |
| --- | --- | --- |
| Apple標準モード | ローカル寄りの文字起こしと翻訳 | Apple Speechで文字起こしし、Apple Translationで選択した言語ペアを翻訳します。 |
| GPTモード | OpenAI Realtimeの文字起こしまたは翻訳 | GPT realtimeモデルを有効にします。APIキーが保存されていない場合、設定モーダルを開いてAPIキー入力欄にフォーカスします。 |
| 文字起こしのみ | 翻訳なしの原文字幕 | 翻訳を実行せず、原文の記録だけを残します。 |
| リアルタイム翻訳のみ | 翻訳ストリームを直接得たい場合 | realtime translationモデルが翻訳結果を直接生成する経路を使います。 |

GPTモデルの詳細、APIキー入力、記録補正、音声出力は歯車の設定モーダルで管理します。メインサイドバーには重要な選択だけを残しています。

## プライバシーとAPIキー

AirTranslateには独自のバックエンドアカウントシステムはありません。

- Apple標準モードはmacOSフレームワークとApple言語アセットを使用します。
- OpenAIへのリクエストはGPTモードまたはOpenAI翻訳モデルを有効にした場合のみ発生します。
- OpenAI APIキーはアプリに埋め込まず、コミットせず、リリースパッケージにも含めません。
- APIキーは`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`でmacOS Keychainに保存します。
- 保存済み記録はユーザーのMac上のプレーンテキストファイルです。

APIキーが必要な場合は、[OpenAI APIキーページ](https://platform.openai.com/api-keys)でキーを作成し、AirTranslateの設定モーダルに貼り付けてください。

## Apple翻訳言語パック

Apple標準モードは、macOSが管理する翻訳言語アセットを使用します。新しい言語ペアでApple標準モードを使う前に、必要なApple翻訳言語パックをダウンロードしてください。

1. **システム設定**を開きます。
2. **一般 > 言語と地域**に移動します。
3. **翻訳言語**をクリックします。
4. 使いたい原文言語と翻訳先言語ごとに**ダウンロード**をクリックします。
5. 任意: 対応する翻訳を可能な限りMac上で処理したい場合は、**オンデバイスモード**をオンにします。

選択した言語ペアが利用できない、またはまだダウンロードされていない場合、macOSに必要な言語アセットが準備されるまでApple標準モードの翻訳が開始されない、または利用不可の状態が表示されることがあります。

## 権限

AirTranslateは、キャプチャと文字起こしに必要な権限だけを要求します。

- 画面収録
- システムオーディオ録音
- 音声認識

ScreenCaptureKitのシステム音声キャプチャ経路を使うため、画面収録権限が必要です。AirTranslateは画面フレームを録画ファイルとして保存しません。

macOSのプライバシー権限を変更した後は、アプリを終了して再起動すると新しい権限状態が安定して反映されます。

## ダウンロード

最新のオープンソースビルドは[GitHub Releases](https://github.com/himomohi/AirTranslate/releases/latest)からダウンロードできます。ZIPを直接取得することもできます。

- [AirTranslate-1.2.1.zipをダウンロード](https://github.com/himomohi/AirTranslate/releases/latest/download/AirTranslate-1.2.1.zip)
- [バージョン履歴を見る](Release/VERSION-HISTORY.md)

リリースZIPはオープンソース配布用のad-hoc署名ビルドです。初回起動時にmacOSのプライバシーとセキュリティ設定で許可が必要になる場合があります。

## 必要環境

- macOS 26.0以降
- Swift 6.2以降
- システム音声キャプチャに対応したMac
- Apple SpeechとApple Translationフレームワークが利用できる環境
- 任意: GPTモード用のOpenAI APIキー

## ソースからビルド

アプリバンドルを実行:

```bash
./script/build_and_run.sh
```

ビルドして起動確認:

```bash
./script/build_and_run.sh --verify
```

ログを表示:

```bash
./script/build_and_run.sh --logs
```

開発中に権限をリセット:

```bash
./script/build_and_run.sh --reset-permissions
```

SwiftPMチェック:

```bash
swift build
swift test
```

## 基本的な使い方

1. 原文言語と翻訳言語を選びます。
2. 方向を逆にしたい場合は中央の言語入れ替えボタンを押します。
3. Apple標準モードまたはGPTモードを選びます。
4. GPTモードで案内が出たら、設定モーダルにOpenAI APIキーを入力します。
5. 開始ボタンを押します。
6. Macで会議、講義、動画、インタビュー、配信音声を再生します。
7. メイン画面またはフローティング字幕で原文と翻訳を確認します。
8. 停止すると現在の記録が保存されます。

## 保存済み記録

保存済み記録はプレーンテキストファイルとして保存されます。

```text
~/Library/Application Support/AirTranslate/Transcripts/*.txt
```

原文と翻訳を一緒に保存する場合、`_original.txt`と`_translation.txt`に分けて保存し、アプリのライブラリUIでは1つの項目として表示します。

## プロジェクト構成

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

## 主要な実装領域

- `SystemAudioCapture`: ScreenCaptureKitでMacのシステム音声をキャプチャします。
- `LiveSpeechTranscriber`: Apple Speechによる文字起こしをストリーミングします。
- `AppleTranslationService`: Apple Translationの処理を分離します。
- `OpenAIRealtimeTranscriber`: 任意のrealtime文字起こしを処理します。
- `OpenAITranslationService`: 任意のrealtime翻訳リクエストを処理します。
- `OpenAIAPIKeyStore`: APIキーをmacOS Keychainに保存します。
- `TranslationSessionStore`: キャプチャ、記録状態、翻訳、保存、音声出力を調整します。
- `SidebarView`: 言語、処理方式、セッション、設定への入口を提供します。
- `CaptionBoardView`: ライブ記録、翻訳、操作、オーディオメーターを表示します。
- `TranscriptLibraryView`: 保存済み記録を管理します。
- `FloatingCaptionWindowController`: フローティング字幕ウィンドウのライフサイクルを管理します。

## ライセンス

AirTranslateは[Apache License 2.0](LICENSE)の下で公開されています。著作権表示は[NOTICE](NOTICE)にあります。

AirTranslateは独立したオープンソースプロジェクトであり、AppleまたはOpenAIと提携していません。
