param(
  [Parameter(Mandatory=$true)][string]$ProductRoot,
  [Parameter(Mandatory=$true)][string]$BuilderPython,
  [Parameter(Mandatory=$true)][string]$EmbeddedPythonZip,
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$EmbeddedPythonZipSha256
)
$ErrorActionPreference = 'Stop'
$product = [IO.Path]::GetFullPath($ProductRoot)
$plugin = Join-Path $product 'plugins\otos-studio'
$bundle = Join-Path $product 'windows-runtime'
if (-not (Test-Path -LiteralPath (Join-Path $plugin 'requirements-windows.txt') -PathType Leaf)) { throw 'Windows 플러그인 배포본이 필요합니다.' }
if (Test-Path -LiteralPath $bundle) { throw 'windows-runtime이 이미 있습니다. 새 제품 스테이징 폴더에서 빌드하세요.' }
if ((Get-FileHash -LiteralPath $EmbeddedPythonZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $EmbeddedPythonZipSha256.ToLowerInvariant()) { throw 'Embedded Python ZIP 해시가 다릅니다.' }

$pythonRoot = Join-Path $bundle 'python'
$sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
$browsers = Join-Path $bundle 'browsers'
$models = Join-Path $bundle 'models'
New-Item -ItemType Directory -Path $sitePackages, $browsers, $models -Force | Out-Null
Expand-Archive -LiteralPath $EmbeddedPythonZip -DestinationPath $pythonRoot
$pth = Get-ChildItem -LiteralPath $pythonRoot -Filter 'python*._pth' -File | Select-Object -First 1
if (-not $pth) { throw 'Windows Embedded Python 경로 파일이 없습니다.' }
$stdlibZip = $pth.Name -replace '\._pth$', '.zip'
@($stdlibZip, '.', 'Lib\site-packages', 'import site') | Set-Content -LiteralPath $pth.FullName -Encoding ASCII
$runtime = Join-Path $pythonRoot 'python.exe'
& $runtime -c 'import sys; assert sys.version_info[:2] == (3, 11) and sys.maxsize > 2**32' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Embedded Python 3.11 x64가 필요합니다.' }
& $BuilderPython -m pip install --disable-pip-version-check --only-binary=:all: --target $sitePackages -r (Join-Path $plugin 'requirements.txt') -r (Join-Path $plugin 'requirements-windows.txt')
if ($LASTEXITCODE -ne 0) { throw 'Windows 패키지 빌드에 실패했습니다.' }
& $runtime -c 'import PIL, mediapipe, playwright.async_api' | Out-Null
if ($LASTEXITCODE -ne 0) { throw '포함된 Python 패키지를 실행하지 못했습니다.' }
$previousBrowserPath = $env:PLAYWRIGHT_BROWSERS_PATH
try {
  $env:PLAYWRIGHT_BROWSERS_PATH = $browsers
  & $runtime -m playwright install chromium
  if ($LASTEXITCODE -ne 0) { throw 'Chromium 포함에 실패했습니다.' }
} finally { $env:PLAYWRIGHT_BROWSERS_PATH = $previousBrowserPath }
if (@(Get-ChildItem -LiteralPath $browsers -Directory).Count -eq 0) { throw 'Chromium 배포 파일이 비어 있습니다.' }

$model = Join-Path $models 'pose_landmarker_full.task'
Invoke-WebRequest -UseBasicParsing -Uri 'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task' -OutFile $model
if ((Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant() -ne '5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1') { throw '포즈 모델 해시가 다릅니다.' }
$files = @(Get-ChildItem -LiteralPath $bundle -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
  [ordered]@{ path = $_.FullName.Substring($bundle.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
[ordered]@{ schema = 1; platform = 'win-x64'; files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bundle 'files.json') -Encoding UTF8
Write-Host "Windows 실행 환경 생성 완료: $bundle ($($files.Count)개 파일)"
