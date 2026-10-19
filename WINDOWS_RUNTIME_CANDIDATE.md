# Windows 실행 환경 포함 설치 후보

상태: 로컬 코드 후보. 공개 설치 명령과 고객 배포본에는 아직 적용되지 않았습니다.

`install.ps1`은 이제 고객 PC의 Python을 찾거나 pip/Playwright/포즈 모델을 내려받지 않습니다. Windows 제품 압축파일의 `product/windows-runtime`을 해시 검증한 뒤 사용합니다. 해당 폴더가 없으면 구매 토큰 사용 후 설치 파일 확인 단계에서 실패하며, 기존 설치본은 교체하지 않습니다.

## Windows 배포본 준비

1. 실제 고객에게 제공할 `product` 스테이징 폴더를 Windows x64 빌드 PC에 준비합니다. `product/plugins/otos-studio`와 기존 제품 manifest 및 해시 검증표를 보존합니다.
2. Python 3.11 x64가 설치된 **빌드 PC**에서 공식 Windows embeddable ZIP을 받습니다. ZIP의 게시된 SHA-256을 독립적으로 확인합니다.
3. `build-windows-runtime.ps1 -ProductRoot <product 폴더> -BuilderPython <빌드 PC의 Python 3.11 경로> -EmbeddedPythonZip <ZIP 경로> -EmbeddedPythonZipSha256 <확인한 해시>`를 실행합니다.
4. 생성된 `windows-runtime/files.json`과 모든 파일을 포함하여 Windows 제품 압축파일을 다시 만듭니다. 기존 제품 파일 검증표와 배포 manifest는 실제 최종 파일에 맞게 생성하고 검증합니다.
5. 격리된 Windows 10 22H2 또는 Windows 11 x64에서 Python을 PATH에서 제거한 상태로, 테스트용 구매 권한과 설치 명령을 사용해 4/4단계까지 확인합니다. Codex 재시작 후 상품 URL을 사용한 실제 작업도 별도로 검증합니다.

`build-windows-runtime.ps1`은 고객용 스크립트가 아닙니다. Python 패키지와 Chromium을 **빌드 PC에서** 준비합니다. 고객용 배포 전에 Windows 빌드 및 실제 기기 설치 확인이 필요합니다.
