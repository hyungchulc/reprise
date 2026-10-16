<p align="center"><img src="Resources/AppIcon.png" width="112" alt="Reprise 아이콘"></p>

# Reprise

**Mac에서 화면 기록과 회의의 기억을 검색하세요.**

[English](README.md) · [알파 다운로드](https://github.com/hyungchulc/reprise/releases) · [MCP](docs/MCP.md) · [개인정보](docs/PRIVACY.md)

Reprise는 전체 화면 타임라인, 로컬 화면 OCR, 회의 오디오와 전사, 원본 기억으로
연결되는 AI 답변을 제공하는 네이티브 macOS 메모리 앱입니다.
Rewind의 사용 흐름에서 영감을 받아 독립적으로 구현했으며, 공식 Rewind 제품이나
포크가 아닙니다. Rewind 데이터베이스를 읽거나 가져오는 기능도 없습니다.

> **알파 소프트웨어입니다.** 중요한 녹음은 백업하세요. 첫 바이너리 배포는
> Apple Silicon 전용이며 개발 인증서로 서명되어 있지만 **Apple 공증은 받지 않았습니다.**
> 안정적인 장기 보관이나 규정 준수 도구로 검증된 제품이 아니며, macOS가 첫 실행을 차단할 수 있습니다.

## 설치

1. [Releases](https://github.com/hyungchulc/reprise/releases)에서 DMG 또는 앱 ZIP을 다운로드합니다.
2. `Reprise.app`을 `Applications` 또는 `~/Applications`로 옮긴 뒤 그 앱을 실행합니다.
3. 온보딩을 진행합니다. 화면 캡처를 사용할 때 화면 기록 권한을 허용하세요.
   마이크와 음성 인식 권한은 각각 별도입니다.
4. 전역 단축키를 정하고, 필요하면 설치된 AI 제공자 CLI를 연결합니다.

macOS 14 이상이 필요합니다. macOS 26 이상에서는 네이티브 Liquid Glass를 사용하고,
이전 OS에서는 머티리얼 기반 컨트롤을 사용합니다. macOS 14/15는 소스의 지원 대상이며
모든 실제 기기 조합에서 검증을 마친 것은 아닙니다. 앱 UI는 현재 영어입니다.

Gatekeeper 경고가 표시되면 릴리스와 체크섬을 확인한 후 정상적인
**시스템 설정 > 개인정보 보호 및 보안 > 확인 없이 열기** 절차를 이용하세요.
Gatekeeper를 시스템 전체에서 비활성화하지 마세요. 서명 주체가 바뀌면 캡처 권한을
다시 허용하고 재시작해야 할 수 있습니다. Reprise는 시스템 권한 데이터베이스를 수정하지 않습니다.

### macOS가 앱을 확인할 수 없다고 표시하는 경우

이 알파의 Apple Development 서명은 **Developer ID 배포 승인과 다릅니다.**
배포 파일의 체크섬과 코드 서명이 유효해도 macOS가 첫 실행을 차단할 수 있습니다.
DMG에는 앱과 Applications 바로가기가 있으며 별도 설치 프로그램은 없습니다. ZIP에도 같은 앱이 들어 있습니다.

**복사나 설치 단계의 실패는 별개 문제입니다.** 앱을 원하는 Applications 폴더로 옮길 수 없다면
정확한 오류 창과 실패한 단계를 알려주세요. 확인 없이 열기는 복사 실패를 해결하는 기능이 아닙니다.
이후 관리자의 Mac에서 alpha.2 수동 설치가 성공했지만, 이전 설치 중단의 원인은 아직 확인되지 않았습니다.
다른 Mac에서도 설치된다는 검증 결과는 아닙니다.

앱 복사가 끝나고 해당 앱의 실행을 시도한 뒤,
이 소스를 신뢰하고 macOS가 해당 옵션을 제공하는 경우에만 앱별 **확인 없이 열기**를 이용하세요.
이는 사용자가 허용하는 예외이며, 검증이나 공증을 받은 설치가 아닙니다.
예외 옵션이 없거나 시스템이 악성코드를 알리면 중단하고 정확한 경고를 알려주세요.
시스템 보호를 끄거나 격리 속성을 제거하지 마세요.
[Apple 안내](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)를 참고하세요.

검토한 소스를 로컬에서 빌드하는 것도 개발용 선택지입니다. 무료 Apple 계정은 Developer ID
배포 서명이나 공증을 제공하지 않으며, 해당 기능에는 Apple Developer Program 회원 자격이 필요합니다.
이 릴리스는 지원 대상 macOS 전체에서 다운로드 설치 검증을 마쳤다고 주장하지 않습니다.

## 주요 기능

| 영역 | 알파 기능 |
| --- | --- |
| 화면 기억 | 지금 쓰는 디스플레이의 ScreenCaptureKit 주기적 스틸 캡처, 온디바이스 Vision OCR, 브라우저 페이지 주소, 로컬 전문 검색 |
| 타임라인 | 전체 화면 오버레이, 앱 아이콘과 아이콘 기반 색상, 캘린더, 기록 공백 압축, 30초 이동 |
| 검색 | 조사가 붙은 한국어 단어도 찾는 로컬 키워드 검색, AI 검색 계획, 원본 연결 답변, 후속 질문, 대화 저장 |
| 회의 | 직접 시작하는 마이크 녹음, 선택적 시스템 오디오, 종료 후 전사(Mac 안의 Apple 모델이나 Whisper, ChatGPT 요금제나 API 키로 쓰는 OpenAI 최신 모델, 또는 Google AI 요금제나 API 키로 쓰는 Gemini), 이름을 바꿀 수 있는 화자 구분, 결정 사항과 할 일까지 정리하는 자동 요약, 인라인 재생과 시간 이동 |
| 회의 어시스턴트 | 나와 상대의 말을 듣고, 상대가 질문하면 대화와 내 메모리를 근거로 1초 남짓 만에 출처 링크와 함께 답하며, 직접 입력한 질문에도 답하는 떠 있는 창(ChatGPT 요금제나 API 키로 쓰는 OpenAI Realtime 모델, 또는 AI & Models의 아무 제공자), Codex·Claude Code·API 키로 웹 검색, 직접 추가한 MCP 서버의 도구 사용, macOS 26에서는 Mac 안에서 듣기 |
| 실시간 자막 | Mac에서 재생되는 소리나 마이크를 듣고 모든 앱과 전체 화면 동영상 위에 말하는 대로 번역한 자막(ChatGPT 요금제나 API 키로 쓰는 OpenAI, 또는 macOS 26에서 Mac 안의 Apple 음성 인식과 번역), 글자 크기·색·배경·줄 수·위치 |
| AI 제공자 | CLI를 통한 Claude·Codex·Gemini·Grok·Cursor·OpenCode(무료 모델), 내 OpenAI·Anthropic·Gemini API 키, Mac 안에서 도는 Apple 온디바이스 모델과 Ollama, 설정에서 설치와 로그인, 모델 선택, 보고된 토큰 사용량 |
| MCP | Claude Desktop·Claude Code·Codex·Cursor 및 호환 로컬 클라이언트의 선택적 읽기 전용 기억 검색 |
| 모양 | 시스템/사용자 지정 강조색, 시스템/수동 밝은·어두운 모드, 글자 크기, 전환 효과와 선택적 테두리 효과 |
| 제어 | 메모리 오버레이·검색만·실시간 자막·회의 녹음·회의 어시스턴트·마지막 질문 답하기의 변경 가능한 전역 단축키, Dock/메뉴 막대 표시, 실행 옵션, 일시 정지 알림, 제외 목록과 보관 기간 |
| 업데이트 | 서명된 피드와 GitHub Releases의 서명된 배포 파일을 검증하는 Sparkle 업데이트 |

기본 단축키는 **Command + Shift + Space**입니다. 메모리 오버레이의 검색 입력창을
바로 엽니다. Escape를 한 번 누르면 검색이 접히고, 다시 누르면 오버레이가 닫힙니다.
최근 대화는 추가 AI 호출 없이 저장된 답변과 인용을 복원합니다.
오디오 검색 결과는 같은 화면에서 펼쳐지고, 녹음은 타임라인의 파형 레인에 표시됩니다.

화면 기록과 오디오 녹음은 별개의 동작입니다. 선택적 회의 감지는 녹음 여부를 묻기만 하며
자동으로 녹음하지 않습니다. 화면 기록의 자동 시작도 설정에서 직접 켜야 합니다.
샘플 라이브러리는 만들지 않습니다.

## AI 검색

**Settings > AI & Models**에서 제공자와 모델을 고르세요. **Install**은 제공자의 공식
설치 프로그램을 터미널에서 실행해 모든 단계가 보이게 하고, **Sign In**은 제공자 자체의
구독 로그인을 엽니다. CLI는 앱에 포함되지 않으며 API 키를 만들지 않습니다.
인증·가용성·한도는 각 제공자가 관리합니다.

| 제공자 | 필요한 것 |
| --- | --- |
| Claude, Codex, Grok, Cursor | 제공자 CLI와 구독 로그인 |
| Gemini | 개인용 Gemini CLI를 대체한 Google의 Antigravity CLI(`agy`)와 Google 로그인 |
| OpenCode | OpenCode CLI만 있으면 됨. 무료 모델, 계정 불필요. 데이터를 보관하지 않는 모델이 먼저 나오며, 나머지는 입력을 모델 개선에 쓸 수 있음 |
| Apple Intelligence | Apple Intelligence가 켜진 macOS 26. 이 Mac 안에서만 실행 |
| Ollama | Ollama 앱과 내려받은 모델. 설정의 **Download**로 추천 모델이나 원하는 모델을 받음 |
| OpenAI API, Anthropic API, Gemini API | 각 회사 콘솔에서 만든 API 키를 설정에 붙여 넣기. CLI 불필요, 키의 계정에 토큰 단위로 과금 |

Google은 타사 도구로 Gemini 로그인을 사용한 계정을 정지한 적이 있습니다. Reprise는 Google의
CLI를 문서화된 방식으로 실행하고 로그인 정보를 읽지 않지만, 판단은 Google이 합니다.
이 위험을 받아들일 때만 Gemini를 고르세요. Gemini API 키를 쓰면 이 위험이 없습니다.

검색은 로컬 전문 검색 인덱스에 대한 키워드를 계획한 후, 크기가 제한된 OCR·전사 근거를
선택한 제공자에게 보냅니다. 언어 모델이 라이브러리 전체를 읽지는 않습니다. 검색어와
답변은 모델이 쓰고, 그 사이에서 기억을 찾는 일은 로컬 검색이 합니다. 일반 답변은 최대
24개 기억(Apple 온디바이스 모델은 8개, Ollama는 16개)을 사용합니다.
활동 요약은 필터링된 전체 시간 구간에서 최대 96개 대표 기록을 고릅니다.
답변은 저장된 기억으로 연결되고 근거 범위를 표시합니다.
**표본 추출과 발췌 길이 제한 때문에 세부 내용이 빠질 수 있으며, 하루 전체를 빠짐없이 설명하는 것은 아닙니다.**

제공자 프로세스에는 도구 제한, 격리된 임시 설정, 시간 제한과 출력 크기 제한을 적용합니다.
지원되는 CLI 제약을 확인할 수 없으면 답변 실행을 차단합니다. 이런 조치는 에이전트의
부작용을 줄이지만, 타사 실행 파일 자체의 신뢰성을 보장하지는 않습니다.
남은 구독 한도를 확인할 수 없으면 알 수 없음으로 표시합니다. Private Cloud Compute는
타사 앱이 쓸 수 없습니다. 구독이 없으면 OpenAI API, Anthropic API, Gemini API 중 하나를 고르고 키를 붙여 넣으세요. 검색, 요약, 회의 어시스턴트가 그 API 계정에서 토큰 단위로 과금되어 돌아가고, OpenAI 키는 전사, 실시간 자막, 어시스턴트의 듣기에도, Gemini 키는 전사에도 쓰입니다.
[제공자별 동작 계약](docs/PROVIDERS.md)을 참고하세요.

## MCP 연결

**Settings > MCP & Integrations**에서 기억 접근을 허용하고 클라이언트 설정을 설치하세요.
설치 후 해당 클라이언트를 재시작합니다. 스크린샷 공유는 별도 동의가 필요하며 기본값은 꺼짐입니다.
로컬 stdio MCP를 지원하는 다른 클라이언트에는 **Copy Configuration**을 사용할 수 있습니다.

동봉된 `RepriseMCP` 도우미는 UI를 열거나 추가 모델을 실행하지 않고 같은 저장소를 검색합니다.
기억을 녹화·삭제·수정할 수 없습니다. 연결한 클라이언트가 검색한 내용을 자신의 제공자에게
보낼 수 있다는 점에 유의하세요. 원격 HTTP 서버만 지원하는 웹 클라이언트는 직접 연결할 수 없습니다.
[설정과 도구 설명](docs/MCP.md).

## 로컬 데이터와 자원 사용

기본 저장소는 `~/Library/Application Support/Reprise`입니다. 앱 버전과 무관하게 유지되며
데이터베이스, 이미지, 오디오, 전사, 검색 기록과 사용량을 담습니다.
0.6부터 저장소는 **암호화됩니다.** 데이터베이스는 SQLCipher로, 스크린샷·압축 영상·녹음은
파일마다 AES-256-GCM으로 암호화합니다. 키는 로그인 키체인에 있으며, Reprise와 MCP 헬퍼만
묻지 않고 읽을 수 있습니다. 다른 앱이 “Reprise Vault Key”를 요청하는 창이 뜨면, 직접 시작한
요청이 아니라면 거부하세요. **Settings > Privacy > Encryption**의 **복구 키**를 암호 관리자에
저장해 두세요. 새 Mac처럼 키체인에 키가 없으면 Reprise가 열릴 때 복구 키를 묻습니다.
둘 다 없으면 저장소를 열 수 없습니다. [암호화 범위](docs/PRIVACY.md#encryption).
배포 파일에는 실제 기록이나 인증 정보가 포함되지 않습니다.

캡처 기본값은 Native Retina 해상도, 이미지 품질 85%, 간격 3초입니다.
디스플레이가 여러 개면 지금 쓰는 창이 있는 디스플레이, 또는 스크롤하거나 클릭하는
디스플레이를 각자의 해상도로 기록합니다. Safari와 Chromium 계열 브라우저에서는 페이지
주소도 저장하며, 주소의 # 뒷부분과 로그인 토큰은 빼고 비공개 창은 저장하지 않습니다.
macOS가 브라우저마다 한 번 묻고, **Settings > Privacy**에서 끌 수 있습니다.
설정에서 해상도·간격·보관 기간·저장 공간 한도를 바꿀 수 있습니다.
메뉴 막대의 시계와 실시간 상태 항목은 무시하는 중복 화면 저장 방지, HEIC와 JPEG 대체 저장,
별도 400px HEIC 썸네일, 15분이 지난 화면의 HEVC 압축(표본에서 약 4–7배 작음),
7일이 지난 화면의 절반 해상도 재압축(설정에서 기간 변경 또는 끄기 가능),
화면에서 바뀐 부분만 다시 읽는 OCR, 동시 작업이 제한된 캡처/OCR, 96MB 미리 보기 캐시와 8MB 썸네일 캐시로 백그라운드 작업을 제한합니다.
이는 구현 방식이며 다른 앱보다 빠르다는 측정 결과나 보장은 아닙니다.
CPU와 프로세스 메모리 사용량은 표시하지만 GPU 사용량은 측정하지 않습니다.

자동 전사는 먼저 녹음을 저장한 뒤 **Settings > Audio & Meetings**에서 고른 엔진으로 전사합니다.
Apple 음성 모델은 고른 언어마다 Mac 안에서 전사하고 구간마다 가장 잘 맞는 언어의 결과를 남깁니다.
Whisper는 모델을 한 번 내려받은 뒤 WhisperKit으로 Mac 안에서 돌아갑니다. OpenAI 전사 모델은 Codex CLI에
로그인된 ChatGPT 요금제나 OpenAI API 키로 온라인에서 돌아가며, 둘 다 없으면 Mac 안의 Apple 모델로 대신
전사합니다. Gemini는 Antigravity CLI에 로그인된 Google AI 요금제나 Gemini API 키로 녹음을 직접 듣고,
20분 이하 녹음에서는 목소리까지 구분합니다. 그 밖의 화자 구분은 Mac 안의 화자 모델이나, ChatGPT 요금제 또는 OpenAI API 키로 쓰는
OpenAI 화자 분리 모델이 찾고, 전사에서 화자 이름을 바꿀 수 있습니다. 전사가 끝나면 선택한 AI 제공자가 개요·핵심 내용·결정 사항·할 일로
요약하고, 알림을 누르면 그 녹음이 열립니다. 요약은 녹음과 함께 암호화해 저장하고, 알림에는
회의 제목만 표시합니다. **Settings > Audio & Meetings**에서 끌 수 있고, 어떤 녹음이든
Summary 탭에서 직접 요약할 수 있습니다. macOS 26 이상에서는 언어를 고르면 음성 모델이 자동으로 설치됩니다.
실패 상태는 표시하고 원본 오디오는 보존합니다.
녹음 한 번의 최대 길이는 4시간입니다. 창 제목 기반 개인정보 보호와 회의 감지는 완전하지 않습니다.
민감한 작업을 기록하기 전에 [데이터 흐름과 제한](docs/PRIVACY.md)을 확인하세요.

실시간 자막은 Mac에서 재생되는 소리나 마이크를 듣고 모든 앱과 전체 화면 동영상 위에 자막을 띄웁니다.
메뉴 막대의 Reprise 메뉴나 **Settings > General > Shortcuts**에서 정한 단축키로 켜고, **Move Captions**로
원하는 곳에 끌어다 놓을 수 있습니다. **Settings > Live Captions**에서 자막 언어와 자막을 만들 곳을 고릅니다.
OpenAI 실시간 번역은 말하는 언어를 스스로 알아듣고 57개 언어로 쓰며, Codex CLI에 로그인된 ChatGPT
요금제나 OpenAI API 키로 돌아갑니다. macOS 26에서는 말하는 언어를 고르면 Mac 안의 Apple 음성 인식과
번역으로 오디오를 어디에도 보내지 않고 자막을 만들고, 이 Mac이 알아듣고 번역할 수 있는 언어는 설정에
표시됩니다. Automatic은 OpenAI 계정이 되면 OpenAI를, 안 되면 이 Mac을 씁니다. 자막은 화면에만 보이고 저장하지 않습니다.

회의 어시스턴트는 Reprise 메뉴나 단축키로, 또는 **Settings > Meeting Assistant**에서 켜 두면 회의를 녹음할
때마다 회의 옆에 작은 창으로 열립니다. 마이크로 내 말을, Mac 오디오로 상대의 말을 듣고 받아 적습니다.
상대가 질문하면 1초 남짓 뒤 대화와 내 메모리를 근거로 답하고, 근거가 된 메모리를 여는 버튼을 붙입니다. 직접
질문을 입력하거나 Answer Last Question 단축키를 눌러도 됩니다. ChatGPT 요금제의 Codex CLI나 OpenAI API 키로
OpenAI Realtime 모델이 가장 빨리 답하고, OpenAI가 없으면 AI & Models에서 고른 제공자가 답하며, Apple 온디바이스
모델이나 Ollama를 쓰면 모든 것이 이 Mac 안에 머뭅니다. 어시스턴트가 들은 내용은 저장하지 않으니, 전사가 필요하면
회의를 녹음하세요. 실시간 자막과 어시스턴트는 Mac이 잠자기에 들어가면 멈춥니다.

어시스턴트는 질문에 필요하면 이 Mac에서 로그인된 Codex나 Claude Code, 또는 OpenAI·Gemini·Anthropic API 키로
웹을 검색하고, 참고한 페이지를 함께 보여 줍니다. **Settings > Meeting Assistant > MCP Tools**에서 내 MCP 서버를
명령이나 주소로 추가할 수 있습니다. 읽기만 하는 도구는 켜진 채로, 무언가를 바꾸는 도구는 꺼진 채로 시작하며,
OpenAI가 답할 때 어시스턴트가 켜진 도구를 직접 호출합니다.

## 업데이트

**Settings > General > Check for Updates** 또는 메뉴 막대 명령을 사용합니다.
자동 확인은 선택 사항이며 기본값은 꺼짐입니다. Sparkle은 앱에 고정된 Ed25519 공개키로
업데이트 피드와 배포 파일을 검증한 뒤 압축을 해제합니다. 파일은 GitHub에 호스팅되며,
설치는 녹음 종료 처리가 끝난 뒤 앱을 다시 실행합니다.

이전 로컬 전용 빌드는 이 알파를 한 번 수동 설치해야 합니다. 이후에는 GitHub를 통해
업데이트합니다. 업데이트가 저장소를 교체하지는 않습니다. 알파 개발 중에는 서명과 macOS
권한 동작 때문에 사용자의 조치가 필요할 수 있습니다.

## 소스에서 빌드

macOS 26 SDK가 포함된 Xcode 26 이상과 Swift Package Manager를 사용합니다.
소스는 macOS 14 이상을 대상으로 하며, 의존성 버전은 `Package.resolved`에 고정되어 있습니다.
첫 알파 태그 이후 적용한 Swift 도구 체인 호환성 수정은 `main` 브랜치에 있습니다.

```sh
git clone https://github.com/hyungchulc/reprise.git
cd reprise
swift build
swift test --filter 'MCPTests|MomentStoreTests|MemorySearchTests'
./script/build_and_run.sh --build
```

완성된 앱은 `dist/Reprise.app`에 생성됩니다. 빌드만으로 설치된 앱을 교체하거나 다시 실행하지 않습니다.
스크립트는 사용 가능한 Apple Development 인증서 또는 직접 지정한 `REPRISE_SIGNING_IDENTITY`를 사용합니다.
일회성 ad-hoc 개발 빌드는 다음과 같습니다.

```sh
REPRISE_SIGNING_IDENTITY=- REPRISE_ALLOW_ADHOC=1 ./script/build_and_run.sh --build
```

Ad-hoc 빌드는 다시 빌드할 때 캡처 권한이 유지되지 않을 수 있습니다.
포크를 배포할 때는 업데이트 피드와 공개키를 바꾸세요. [배포 절차](docs/RELEASING.md).

## 개발과 문제 보고

SwiftUI/AppKit, ScreenCaptureKit, Vision, Speech, AVFoundation, SQLCipher(SQLite FTS5),
공식 MCP Swift SDK와 Sparkle을 사용합니다. LLM이나 벡터 데이터베이스, 상시 추론 서비스는
포함하지 않으며, Apple 온디바이스 모델과 Ollama는 고른 경우에만 실행합니다. [아키텍처](docs/ARCHITECTURE.md).

[Issues](https://github.com/hyungchulc/reprise/issues)에 macOS·앱 버전과 재현 절차를 알려주세요.
**저장소, 원본 녹음, 토큰, 개인정보가 담긴 스크린샷이나 가리지 않은 전사는 올리지 마세요.**
[보안 문제 보고](SECURITY.md)와 [타사 라이선스](THIRD_PARTY_NOTICES.md)를 참고하세요.

## 라이선스

Reprise의 원본 코드와 자산은 [MIT License](LICENSE)로 제공됩니다.
타사 구성 요소에는 각자의 라이선스가 적용됩니다. Rewind 바이너리, 추출한 자산,
사용자의 실제 기록은 포함하지 않습니다.
