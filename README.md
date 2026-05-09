# AirTranslate

AirTranslate는 Mac에서 재생되는 소리를 실시간으로 기록하고 번역하는 SwiftPM 기반 macOS 앱입니다. AirPods Pro 같은 출력 장치에서 들리는 Mac 재생음을 대상으로 하며, 외부 마이크가 아니라 ScreenCaptureKit의 시스템 오디오 캡처를 사용합니다.

## 한 줄 요약

Mac에서 영상, 회의, 강의 같은 오디오를 재생하면 AirTranslate가 원문을 계속 기록하고, 오른쪽에는 번역을 함께 보여주며, 필요하면 번역 음성까지 읽어 줍니다.

## 주요 기능

- Mac 시스템 오디오 실시간 캡처
- Apple Speech 기반 실시간 기록
- Apple Translation 기반 실시간 번역
- 사용자가 직접 선택하는 원문/번역 언어
- macOS 선호 언어에 맞춘 한국어/영어 UI 자동 표시
- 원문과 번역을 나란히 보여주는 메모형 작업 공간
- 기록 내용이 사라지지 않는 누적 표시
- 긴 침묵 구간에서 문맥을 유지한 문단 정리
- 문단 전환 시 2중 개행으로 읽기 편한 정리
- 옵션형 기록 다듬기: macOS 맞춤법 후보 기반의 보수적 단어 교정
- 실시간 기록 일시정지/재개
- 정지 시 현재 기록 저장 후 새 세션을 시작할 수 있도록 화면 초기화
- 자동 저장된 기록 확인, 수정, 삭제
- 날짜와 내용 기반의 일반 텍스트 자동 저장
- 마지막으로 선택한 언어, 모델, 출력 옵션 재실행 시 복원
- 상태바 메뉴와 플로팅 자막 창
- 플로팅 자막 표시 모드: 원문, 원문 + 번역, 번역
- 플로팅 자막 글자 크기와 표시 줄 수 설정
- 플로팅 자막 위치 드래그 이동
- 선택적 번역 음성 출력
- 번역 음성 출력 중 원문 소리 비중 완화
- 중복 문장 음성 출력 방지
- 픽셀 아트 스타일 앱 아이콘과 소개 페이지

## 현재 동작

앱을 시작하면 선택한 원문 언어로 Mac 시스템 오디오를 듣고, 왼쪽 패널에 원문 기록을 계속 이어 붙입니다. 번역 결과는 오른쪽 패널에 표시됩니다.

짧은 실시간 업데이트는 같은 문장 안에서 부드럽게 갱신됩니다. 긴 침묵이 들어와도 새 카드나 새 대화처럼 분리하지 않고 같은 기록 안에서 문단만 나눕니다. 이때 원문과 번역 모두 문단 사이에 빈 줄이 들어가도록 정리합니다.

`일시정지`는 현재 세션을 유지한 채 입력만 멈춥니다. `정지`는 현재 기록을 저장하고 실시간 화면을 비워서 다음 시작을 새 기록처럼 진행할 수 있게 합니다.

자동 저장은 JSON이 아니라 기록된 원문 텍스트 그대로 저장합니다. 저장 파일은 `날짜_내용과-관련된-짧은-제목.txt` 형식으로 만들어지고, 같은 이름이 있으면 뒤에 번호를 붙입니다.

## 플로팅 자막

상태바 아이콘이나 앱 안의 자막 버튼으로 플로팅 자막을 켜고 끌 수 있습니다. 플로팅 자막은 영화 자막처럼 내용 중심으로 보이도록 별도 창에 표시됩니다.

설정할 수 있는 항목:

- 표시 모드: 원문, 원문 + 번역, 번역
- 글자 크기: 작게, 보통, 크게
- 표시 줄 수: 1줄, 2줄, 3줄 이상
- 위치: 자막 창을 길게 잡고 드래그해서 이동

상태바 메뉴는 앱 본창을 강제로 띄우지 않고 플로팅 자막과 캡처 상태를 빠르게 제어하도록 구성했습니다.

## 번역 음성 출력

`음성 출력`을 켜면 번역된 내용을 macOS 음성으로 읽습니다. 같은 문장이 반복해서 들어오는 실시간 기록 특성 때문에, 이미 읽은 문장과 거의 같은 문장은 다시 읽지 않도록 방어합니다.

번역 음성이 나올 때는 원문 재생음보다 번역 음성이 더 잘 들리도록 시스템 출력 볼륨을 낮추는 처리를 함께 수행합니다. macOS와 출력 장치 상태에 따라 완전한 앱별 볼륨 분리는 제한될 수 있습니다.

## 저장 위치

저장된 기록은 사용자 Application Support 폴더에 일반 텍스트 파일로 보관됩니다.

```text
~/Library/Application Support/AirTranslate/Transcripts/*.txt
```

앱의 저장소 영역에서 기록을 선택하면 내용을 확인하고 수정할 수 있습니다. 필요 없는 기록은 앱에서 삭제할 수 있고, 폴더 버튼으로 Finder에서 저장 폴더를 바로 열 수 있습니다.

## 기록 다듬기

`기록 다듬기` 옵션은 반복 문장을 제거하는 기능이 아닙니다. 음성 인식 과정에서 생긴 어색한 단어, 존재하지 않는 단어, 명확한 오타성 단어를 macOS 맞춤법 후보를 이용해 보수적으로 바로잡는 기능입니다.

이 기능은 긴 침묵이나 일시정지처럼 기록이 잠시 안정되는 시점에 작동합니다. 사용자가 말한 내용 자체를 요약하거나 삭제하지 않도록 설계했습니다.

## 성능 최적화

레이턴시를 줄이기 위해 다음 경로를 정리했습니다.

- Apple Translation 지원 여부 결과 캐시
- 캡처 시작 시 번역 세션 사전 준비
- 최신 요청만 처리하는 직렬 번역 큐
- 실시간 부분 기록 번역 디바운스 단축
- 긴 입력 폭주 시 불필요한 중간 번역 생략
- 화면 텍스트 애니메이션 청크 확대와 지연 축소
- 실시간 부분 기록에서 무거운 문단 정리 반복 호출 제거
- 저장은 기록 중이 아니라 정지/종료 시점에 수행
- 오디오 샘플 버퍼마다 새 PCM 버퍼를 만들지 않고 재사용 링 버퍼 사용
- AudioBufferList 임시 할당을 스택 기반으로 처리
- Int16 오디오 샘플을 블록 단위로 복사

가장 큰 병목 후보였던 오디오 버퍼 변환 경로는 `AVAudioPCMBuffer` 재생성을 줄이는 방향으로 바꿨습니다. 이 변경은 실시간 캡처 중 메모리 할당 압박을 줄이는 데 초점을 둡니다.

## 요구 사항

- macOS 26.0 이상
- Swift 6.2 이상
- 시스템 오디오 캡처가 가능한 Mac
- Apple Speech 및 Apple Translation 프레임워크 사용 가능 환경

## 필요한 권한

AirTranslate는 다음 권한이 필요합니다.

- 화면 기록
- 시스템 오디오 녹음
- 음성 인식

권한을 처음 허용한 뒤에는 앱을 종료하고 다시 실행해야 macOS 개인정보 보호 설정이 안정적으로 반영됩니다.

권한 상태가 꼬였을 때는 다음 명령으로 AirTranslate 권한을 초기화할 수 있습니다.

```bash
./script/build_and_run.sh --reset-permissions
```

## 실행 방법

일반 실행:

```bash
./script/build_and_run.sh
```

빌드 후 실행 확인:

```bash
./script/build_and_run.sh --verify
```

로그 확인:

```bash
./script/build_and_run.sh --logs
```

SwiftPM 빌드 검증:

```bash
swift build -Xswiftc -warnings-as-errors
```

Codex 앱에서는 `.codex/environments/environment.toml`의 `Run` 액션이 `./script/build_and_run.sh`에 연결되어 있습니다.

## 사용 방법

1. 원문 언어와 번역 언어를 선택합니다.
2. 필요한 경우 모델, 기록 다듬기, 음성 출력, 플로팅 자막 옵션을 조정합니다.
3. 재생 버튼을 눌러 Mac 시스템 오디오 캡처를 시작합니다.
4. Mac에서 영상, 회의, 강의 같은 음성 콘텐츠를 재생합니다.
5. 왼쪽 원문 패널과 오른쪽 번역 패널을 확인합니다.
6. 필요하면 일시정지로 현재 세션을 잠시 멈춥니다.
7. 정지를 누르면 현재 기록이 저장되고 새 기록을 시작할 준비가 됩니다.
8. 저장소 영역이나 Finder에서 저장된 텍스트 파일을 확인합니다.

## 소개 페이지

제품 소개용 정적 HTML 페이지가 포함되어 있습니다.

```bash
open intro.html
```

이 페이지는 앱 아이콘과 같은 픽셀 아트 톤을 사용해 AirTranslate의 핵심 기능을 제품 소개 형식으로 보여줍니다.

## 프로젝트 구조

```text
Package.swift
intro.html
Resources/
  AppIcon.png
Sources/AirTranslate/
  App/
    AirTranslateApp.swift
  Models/
    AirTranslateWindowID.swift
    AppText.swift
    CaptionLine.swift
    FloatingCaptionDisplayMode.swift
    FloatingCaptionLineCount.swift
    FloatingCaptionTextSize.swift
    IntelligenceModel.swift
    LanguageOption.swift
    SavedTranscript.swift
  Services/
    AppleTranslationService.swift
    LiveSpeechTranscriber.swift
    SpeechCaptioner.swift
    SystemAudioCapture.swift
    TranslatedSpeechOutput.swift
    TranslationSessionStore.swift
  Support/
    FloatingCaptionDragSurface.swift
    FloatingCaptionTextFormatter.swift
    FloatingCaptionWindowController.swift
    FloatingWindowConfigurator.swift
    MenuBarPanelController.swift
    MenuBarPanelInstaller.swift
  Views/
    CaptionBoardView.swift
    ContentView.swift
    FloatingCaptionWindowView.swift
    MenuBarStatusView.swift
    SettingsView.swift
    SidebarView.swift
    StreamingTranscriptText.swift
script/
  build_and_run.sh
```

## 핵심 구현

- `SystemAudioCapture`: ScreenCaptureKit으로 Mac 시스템 오디오를 캡처합니다.
- `LiveSpeechTranscriber`: Apple Speech의 `SpeechAnalyzer`와 `SpeechTranscriber`로 실시간 기록을 수행합니다.
- `AppleTranslationService`: Apple Translation 프레임워크로 문장 단위 번역을 수행합니다.
- `TranslationSessionStore`: 캡처, 기록, 번역, 문단 정리, 저장, 음성 출력을 조율합니다.
- `TranslatedSpeechOutput`: 번역 음성 출력, 중복 읽기 방지, 출력 볼륨 완화를 담당합니다.
- `FloatingCaptionWindowController`: 앱 바깥에 표시되는 플로팅 자막 창을 관리합니다.
- `FloatingCaptionTextFormatter`: 플로팅 자막 표시 줄 수와 표시 모드에 맞춰 텍스트를 정리합니다.
- `MenuBarPanelController`: 상태바 빠른 제어 패널을 관리합니다.
- `MenuBarStatusView`: 상태바 아이콘과 현재 상태 표시를 제공합니다.
- `CaptionBoardView`: 원문/번역 두 패널을 표시합니다.
- `SidebarView`: 캡처 제어, 언어 선택, 모델 선택, 저장된 기록 편집 UI를 제공합니다.
- `AppText`: macOS 선호 언어에 따라 한국어/영어 UI 문자열을 선택합니다.

## 알려진 한계

- Apple Speech/Translation 지원 언어와 설치된 언어 자산 상태에 따라 동작이 달라질 수 있습니다.
- macOS 개인정보 보호 권한은 서명 상태와 번들 식별자에 민감하므로, 빌드 방식이 바뀌면 권한을 다시 허용해야 할 수 있습니다.
- 시스템 오디오에 다른 앱 음성, 알림음, 번역 음성이 섞이면 기록 결과에도 섞일 수 있습니다.
- 번역 품질과 문장 분리는 Apple 프레임워크 결과에 의존합니다.
- macOS 기본 API만으로는 앱별 원문 오디오와 번역 음성을 완전히 독립 믹싱하기 어렵습니다.

## 개발 메모

이 앱은 로컬 SwiftPM macOS 앱으로 관리합니다. GUI 앱 실행은 raw executable이 아니라 `script/build_and_run.sh`가 만든 `.app` 번들을 통해 수행합니다.

빌드 산출물인 `.build/`와 `dist/`는 git에 포함하지 않습니다.
