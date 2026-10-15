# OT.OS 설치

구매 자료에서 운영체제를 선택하고 발급받은 한 줄을 실행하세요. 토큰은 개인별로 발급되며 30분간 유효합니다.

## macOS 터미널

```bash
curl -fsSL https://raw.githubusercontent.com/ironman429100-rgb/otos-install/main/install.sh | OTOS_INSTALL_TOKEN='<발급 토큰>' bash
```

## Windows PowerShell

```powershell
$env:OTOS_INSTALL_TOKEN='<발급 토큰>'; irm https://raw.githubusercontent.com/ironman429100-rgb/otos-install/main/install.ps1 | iex
```

실제 상품 파일은 설치 중 구매 권한을 확인한 뒤 내려받습니다. 공개 저장소에는 설치 스크립트만 포함됩니다.
