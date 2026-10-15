# OT.OS 설치

구매 자료에서 운영체제를 선택하고 발급받은 설치 요청문 전체를 이 컴퓨터의 Codex 채팅에 붙여넣으세요. Codex가 설치 명령을 직접 실행합니다. 토큰은 개인별로 발급되며 30분간 유효합니다.

## macOS — Codex에 붙여넣기

```text
Codex, 이 컴퓨터에 OT.OS를 설치해 주세요. 아래 명령을 macOS 셸에서 직접 실행하고, 네트워크가 차단되면 실행 승인을 요청해 주세요. 토큰은 숨기고 설치 결과를 알려주세요.

curl -fsSL https://raw.githubusercontent.com/ironman429100-rgb/otos-install/main/install.sh | OTOS_INSTALL_TOKEN='<발급 토큰>' bash
```

## Windows — Codex에 붙여넣기

```text
Codex, 이 컴퓨터에 OT.OS를 설치해 주세요. 아래 명령을 Windows PowerShell로 직접 실행하고, 네트워크가 차단되면 실행 승인을 요청해 주세요. 토큰은 숨기고 설치 결과를 알려주세요.

$env:OTOS_INSTALL_TOKEN='<발급 토큰>'; irm https://raw.githubusercontent.com/ironman429100-rgb/otos-install/main/install.ps1 | iex
```

실제 상품 파일은 설치 중 구매 권한을 확인한 뒤 내려받습니다. 공개 저장소에는 설치 스크립트만 포함됩니다.

Codex의 로컬 작업에서 실행하세요. 클라우드 작업에서는 사용자 PC에 설치할 수 없습니다. 별도 터미널이나 PowerShell 창을 열 필요는 없습니다.
