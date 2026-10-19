param(
  [string]$Token = $env:OTOS_INSTALL_TOKEN,
  [ValidatePattern('^https://')][string]$RedeemUrl = 'https://xcgvouxpcecyxhqecyce.supabase.co/functions/v1/redeem-install-token',
  [string]$Target = (Join-Path $env:USERPROFILE 'Documents\OT.OS')
)
if ($env:OTOS_INSTALL_REDEEM_URL) { $RedeemUrl = $env:OTOS_INSTALL_REDEEM_URL }
Remove-Item Env:OTOS_INSTALL_TOKEN, Env:OTOS_INSTALL_REDEEM_URL -ErrorAction SilentlyContinue
if ($Token -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'OT.OS 설치 토큰이 없거나 올바르지 않습니다. 구매 내역에서 새 설치 명령어를 발급해 주세요.' }
if ($RedeemUrl -notmatch '^https://') { throw 'OT.OS 설치 권한 확인 주소가 올바르지 않습니다.' }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$modelSha256 = '5134a3aad27a58b93da0088d431f366da362b44e3ccfbe3462b3827a839011b1'
$runtimeArchiveUrl = 'https://github.com/ironman429100-rgb/otos-install/releases/download/windows-runtime-20261019-test/otos-windows-runtime-20261019.zip'
$runtimeArchiveSha256 = '8e6dc5d58393328800b487cdd2cd809aeb4996013d8734e9603689d59b87e5a7'
$windowsRoot = Join-Path $env:USERPROFILE 'Documents\Codex\OT.OS-Windows'

function Stop-Install([string]$Message) {
  throw "OT.OS 설치 실패: $Message"
}

# Windows buyer candidate. Keep the existing buyer token, product backup and
# Codex marketplace checks; prepare Windows dependencies before registration.
function Invoke-QuietExternal([string]$Executable, [string[]]$Arguments, [string]$LogPath, [string]$Failure) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments *> $LogPath
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) { Stop-Install $Failure }
}

function Initialize-WindowsEnvironment([string]$TemporaryRoot) {
    if ($env:OS -ne 'Windows_NT' -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
        Stop-Install 'Windows 10 22H2 이상 또는 Windows 11 x64 컴퓨터가 필요합니다.'
    }
    $build = 0
    $buildText = [string][Environment]::OSVersion.Version.Build
    if (-not [int]::TryParse([string]$buildText, [ref]$build) -or $build -lt 19045) {
        Stop-Install 'Windows 10 22H2 이상 또는 Windows 11 x64 컴퓨터가 필요합니다.'
    }
    if ($env:OTOS_WINDOWS_POSE_MODEL) { Stop-Install '사용자 지정 포즈 모델 설정을 해제한 뒤 다시 시도해주세요.' }
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Stop-Install '압축 해제 도구를 찾지 못했습니다. Windows 업데이트 후 다시 시도해주세요.' }
    $chromePaths = @()
    foreach ($base in @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'), $env:LOCALAPPDATA)) {
        if ($base) { $chromePaths += Join-Path $base 'Google\Chrome\Application\chrome.exe' }
    }
    if (-not @($chromePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count) {
        Stop-Install 'Google Chrome을 설치한 뒤 다시 시도해주세요.'
    }
    # Python is supplied and verified with the Windows product archive.
}

function Initialize-OtosNative([string]$TemporaryRoot) {
    $script:OtosNativeTemporaryRoot = $TemporaryRoot
    $script:OtosNativeSelector = $null
    $script:OtosNativeSource = $null
    $script:OtosNativeMarketplace = $null
    $script:OtosNativeComplete = $false
    $script:OtosNativeSourceBackup = $null
    $script:OtosNativeSourceReplaced = $false
    $stateRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.codex' } else { Join-Path $env:HOME '.codex' }
    $desktopCli = Join-Path $stateRoot 'plugins\.plugin-appserver\codex-cli\bin\codex.exe'
    if ($env:OT_OS_CODEX_CLI) { $script:OtosNativeCli = $env:OT_OS_CODEX_CLI }
    elseif (Test-Path -LiteralPath $desktopCli -PathType Leaf) { $script:OtosNativeCli = $desktopCli }
    else {
        $script:OtosNativeCli = $null
        # Official Windows MSIX identity/path inspected in the OpenAI package directory.
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)) {
                if ($package.InstallLocation) {
                    $bundleCli = Join-Path $package.InstallLocation 'app\resources\codex.exe'
                    if (Test-Path -LiteralPath $bundleCli -PathType Leaf) { $script:OtosNativeCli = $bundleCli; break }
                }
            }
        }
        if (-not $script:OtosNativeCli) {
            $command = Get-Command codex -ErrorAction SilentlyContinue
            $script:OtosNativeCli = if ($command) { $command.Source } else { $null }
        }
    }
    if (-not $script:OtosNativeCli) { throw 'Codex 플러그인 실행기를 찾을 수 없어 구매 토큰을 사용하지 않았습니다.' }
    & $script:OtosNativeCli plugin marketplace add --help *> (Join-Path $TemporaryRoot 'marketplace-help.txt')
    if ($LASTEXITCODE -ne 0) { throw '현재 Codex 실행기는 marketplace 등록을 지원하지 않아 구매 토큰을 사용하지 않았습니다.' }
    & $script:OtosNativeCli plugin add --help *> (Join-Path $TemporaryRoot 'plugin-help.txt')
    if ($LASTEXITCODE -ne 0) { throw '현재 Codex 실행기는 플러그인 등록을 지원하지 않아 구매 토큰을 사용하지 않았습니다.' }
    $marketJson = & $script:OtosNativeCli plugin marketplace list --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
    if ($LASTEXITCODE -ne 0) { throw '기존 marketplace를 확인하지 못해 구매 토큰을 사용하지 않았습니다.' }
    $markets = ($marketJson -join "`n") | ConvertFrom-Json
    if (-not ($markets.PSObject.Properties.Name -contains 'marketplaces') -or $null -eq $markets.marketplaces -or $markets.marketplaces -isnot [array]) { throw 'marketplace JSON 배열이 올바르지 않아 구매 토큰을 사용하지 않았습니다.' }
    $matching = @()
    foreach ($market in @($markets.marketplaces)) {
        if (-not $market.name) { throw 'marketplace 식별자가 없어 구매 토큰을 사용하지 않았습니다.' }
        $listJson = & $script:OtosNativeCli plugin list --marketplace $market.name --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
        if ($LASTEXITCODE -ne 0) { throw '기존 플러그인을 확인하지 못해 구매 토큰을 사용하지 않았습니다.' }
        $list = ($listJson -join "`n") | ConvertFrom-Json
        if (-not ($list.PSObject.Properties.Name -contains 'installed') -or $null -eq $list.installed -or $list.installed -isnot [array]) { throw '기존 플러그인 JSON 배열이 올바르지 않아 구매 토큰을 사용하지 않았습니다.' }
        if (@($list.installed | Where-Object { -not $_.name -or -not $_.pluginId }).Count) { throw '기존 플러그인 식별자가 올바르지 않아 구매 토큰을 사용하지 않았습니다.' }
        $matching += @($list.installed | Where-Object { $_.name -eq 'otos-studio' })
    }
    if ($matching.Count -gt 1) { throw 'OT.OS가 여러 marketplace에 설치되어 있어 중복 등록과 토큰 사용을 중단했습니다.' }
    if ($matching.Count -eq 1) {
        $existing = $matching[0]
        if ($existing.marketplaceName -ne 'otos-buyer') {
            throw '다른 OT.OS 시험 설치가 있어 구매자 설치로 교체하지 않았습니다. 기존 설치 상태를 확인해주세요.'
        }
        if ($existing.source.source -ne 'local' -or -not $existing.source.path) {
            throw '기존 OT.OS가 로컬 설치가 아니므로 중복 등록과 토큰 사용을 중단했습니다.'
        }
        if ($existing.pluginId -ne "otos-studio@$($existing.marketplaceName)") { throw '기존 OT.OS 식별자가 올바르지 않습니다.' }
        $source = [IO.Path]::GetFullPath($existing.source.path)
        $expectedSource = [IO.Path]::GetFullPath((Join-Path $Target 'plugins\otos-studio'))
        if ($source -ne $expectedSource) { throw '기존 OT.OS 설치 경로가 달라 자동 교체를 중단했습니다.' }
        $sourceItem = Get-Item -LiteralPath $source -ErrorAction Stop
        if (-not $sourceItem.PSIsContainer -or ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw '기존 OT.OS 원본을 안전하게 교체할 수 없어 구매 토큰을 사용하지 않았습니다.'
        }
        $manifest = Get-Content -LiteralPath (Join-Path $source '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
        if ($manifest.name -ne 'otos-studio') { throw '기존 OT.OS manifest가 일치하지 않아 구매 토큰을 사용하지 않았습니다.' }
        if (Test-Path -LiteralPath (Join-Path $source '.git')) { throw '기존 OT.OS가 개발 저장소이므로 구매 토큰을 사용하지 않았습니다.' }
        $script:OtosNativeSelector = $existing.pluginId
        $script:OtosNativeMarketplace = $existing.marketplaceName
        $script:OtosNativeSource = $source
    }
}

function Test-OtosNativeFiles([string]$RuntimeRoot, [string]$ChecksumsPath) {
    $packageManifest = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $ChecksumsPath) 'manifest.json') -Raw | ConvertFrom-Json
    $expectedCount = $packageManifest.runtimeFiles
    if (($expectedCount -isnot [int] -and $expectedCount -isnot [long]) -or $expectedCount -le 0) { throw '배포 manifest의 runtimeFiles는 양의 정수여야 합니다.' }
    $fullRoot = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
    $entries = @()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-Content -LiteralPath $ChecksumsPath)) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw '플러그인 파일 검증표 형식이 올바르지 않습니다.' }
        $expected = $Matches[1]
        $relative = $Matches[2]
        if ($relative.StartsWith('/') -or $relative.Contains('\') -or ($relative.Split('/') -contains '..') -or ($relative.Split('/') -contains '.')) {
            throw '플러그인 파일 검증 경로가 안전하지 않습니다.'
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $relative))
        if (-not $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw '플러그인 검증 경로가 원본 밖을 가리킵니다.' }
        if (-not $seen.Add($relative)) { throw '플러그인 파일 검증표에 중복 경로가 있습니다.' }
        $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '플러그인 검증 파일이 링크이거나 파일이 아닙니다.' }
        $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "플러그인 파일 해시가 배포본과 다릅니다: $relative" }
        $entries += [pscustomobject]@{ Relative = $relative; Expected = $expected }
    }
    $allItems = @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop)
    if (@($allItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) { throw '플러그인 원본에 파일 또는 폴더 링크가 있습니다.' }
    $meaningful = @($allItems | Where-Object { -not $_.PSIsContainer -and $_.Name -ne '.DS_Store' -and -not ($_.DirectoryName -match '[\\/]__pycache__$' -and $_.Extension -eq '.pyc') })
    if ($meaningful.Count -ne $expectedCount) { throw '배포표 밖의 실행 파일이 있어 native 플러그인 검증에 실패했습니다.' }
    if ($entries.Count -ne $expectedCount) { throw '플러그인 파일 검증표와 배포 manifest의 파일 수가 일치하지 않습니다.' }
    return $entries
}

function Restore-OtosNativeSource {
    if (-not $script:OtosNativeSourceReplaced) { return }
    try {
        if (Test-Path -LiteralPath $script:OtosNativeSource) {
            Move-Item -LiteralPath $script:OtosNativeSource -Destination (Join-Path $script:OtosNativeSourceBackup 'failed-runtime') -ErrorAction Stop
        }
        Move-Item -LiteralPath (Join-Path $script:OtosNativeSourceBackup 'runtime') -Destination $script:OtosNativeSource -ErrorAction Stop
        $restoredJson = & $script:OtosNativeCli plugin add $script:OtosNativeSelector --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
        if ($LASTEXITCODE -ne 0) { throw '원래 selector의 CLI 복구에 실패했습니다.' }
        $restored = ($restoredJson -join "`n") | ConvertFrom-Json
        if (-not $restored.installedPath) { throw '복구된 cache 경로를 확인하지 못했습니다.' }
        $sourceFiles = @(Get-ChildItem -LiteralPath $script:OtosNativeSource -Recurse -Force -File | Where-Object { $_.Name -ne '.DS_Store' -and -not ($_.DirectoryName -match '[\\/]__pycache__$' -and $_.Extension -eq '.pyc') })
        $cacheFiles = @(Get-ChildItem -LiteralPath $restored.installedPath -Recurse -Force -File | Where-Object { $_.Name -ne '.DS_Store' -and -not ($_.DirectoryName -match '[\\/]__pycache__$' -and $_.Extension -eq '.pyc') })
        if ($sourceFiles.Count -ne $cacheFiles.Count) { throw '복구된 cache 파일 수가 원본과 다릅니다.' }
        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($script:OtosNativeSource.Length).TrimStart('\', '/')
            $cacheFile = Join-Path $restored.installedPath $relative
            if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf) -or (Get-FileHash -LiteralPath $cacheFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                throw '복구된 cache 바이트가 원래 원본과 다릅니다.'
            }
        }
        $script:OtosNativeSourceReplaced = $false
    } catch {
        Write-Warning "OT.OS 기존 플러그인 복구에도 실패했습니다. 원래 경로: $script:OtosNativeSource / 보존 자료: $script:OtosNativeSourceBackup / $($_.Exception.Message)"
        throw
    }
}

function Install-OtosNative([string]$ProductRoot) {
    $payload = Join-Path $ProductRoot 'plugins\otos-studio'
    $checksums = Join-Path $ProductRoot 'otos-studio-client-sha256.txt'
    $manifest = Get-Content -LiteralPath (Join-Path $payload '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'otos-studio') { throw 'OT.OS native 플러그인 manifest가 없습니다.' }
    $entries = @(Test-OtosNativeFiles $payload $checksums)
    if ($script:OtosNativeSelector) {
        if ([IO.Path]::GetFullPath($script:OtosNativeSource) -ne [IO.Path]::GetFullPath($payload)) {
            $different = $false
            try { Test-OtosNativeFiles $script:OtosNativeSource $checksums | Out-Null } catch { $different = $true }
            if ($different) {
                $staging = Join-Path (Split-Path -Parent $script:OtosNativeSource) ('.ot-os-plugin-staging.' + [guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
                Get-ChildItem -LiteralPath $payload -Force | Copy-Item -Destination $staging -Recurse -Force -ErrorAction Stop
                Test-OtosNativeFiles $staging $checksums | Out-Null
                $backup = Join-Path (Split-Path -Parent $script:OtosNativeSource) ('.ot-os-plugin-backup.' + [guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
                Move-Item -LiteralPath $script:OtosNativeSource -Destination (Join-Path $backup 'runtime') -ErrorAction Stop
                try { Move-Item -LiteralPath $staging -Destination $script:OtosNativeSource -ErrorAction Stop }
                catch {
                    Move-Item -LiteralPath (Join-Path $backup 'runtime') -Destination $script:OtosNativeSource -ErrorAction Stop
                    throw
                }
                $script:OtosNativeSourceBackup = $backup
                $script:OtosNativeSourceReplaced = $true
            }
        }
    } else {
        $market = Get-Content -LiteralPath (Join-Path $ProductRoot '.agents\plugins\marketplace.json') -Raw | ConvertFrom-Json
        if ($market.name -ne 'otos-buyer') { throw 'OT.OS 전용 marketplace manifest가 없습니다.' }
        $marketJson = & $script:OtosNativeCli plugin marketplace add $ProductRoot --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
        if ($LASTEXITCODE -ne 0) { throw 'OT.OS 전용 marketplace 등록에 실패했습니다.' }
        $marketJson | Set-Content -LiteralPath (Join-Path $script:OtosNativeTemporaryRoot 'marketplace-add.json')
        $script:OtosNativeSelector = 'otos-studio@otos-buyer'
        $script:OtosNativeMarketplace = 'otos-buyer'
    }
    try {
    $installJson = & $script:OtosNativeCli plugin add $script:OtosNativeSelector --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
    if ($LASTEXITCODE -ne 0) { throw 'Codex native 플러그인 등록에 실패했습니다. 파일 복사만 완료된 상태입니다.' }
    $installed = ($installJson -join "`n") | ConvertFrom-Json
    if ($installed.pluginId -ne $script:OtosNativeSelector -or -not $installed.installedPath -or -not $installed.version -or $installed.version -ne $manifest.version) { throw '등록 결과의 식별자, 설치 경로 또는 버전이 일치하지 않습니다.' }
    Test-OtosNativeFiles $installed.installedPath $checksums | Out-Null
    $listJson = & $script:OtosNativeCli plugin list --marketplace $script:OtosNativeMarketplace --json 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
    if ($LASTEXITCODE -ne 0) { throw '등록한 OT.OS 상태를 확인하지 못했습니다.' }
    $list = ($listJson -join "`n") | ConvertFrom-Json
    if (-not ($list.PSObject.Properties.Name -contains 'installed') -or $null -eq $list.installed -or $list.installed -isnot [array]) { throw '등록 후 플러그인 JSON 배열이 올바르지 않습니다.' }
    $enabled = @($list.installed | Where-Object { $_.pluginId -eq $script:OtosNativeSelector -and $_.enabled -eq $true })
    if ($enabled.Count -ne 1) { throw '등록된 OT.OS 플러그인이 활성화되지 않았습니다.' }
    $script:OtosNativeComplete = $true
    # Only the enclosing installer may now write nativeComplete=true in its receipt.
    return $installed
    } catch {
        $originalError = $_
        try { Restore-OtosNativeSource } catch { Write-Warning $_.Exception.Message }
        throw $originalError
    }
}

function Test-WindowsPackage([string]$ProductRoot, $Reply) {
    if ($Reply.platform -ne 'windows') { Stop-Install 'Windows용 설치 권한과 배포본을 확인하지 못했습니다.' }
    $plugin = Join-Path $ProductRoot 'plugins\otos-studio'
    foreach ($relative in @('requirements.txt', 'requirements-windows.txt', 'scripts\windows_pose.py', 'scripts\browser_probe.py')) {
        if (-not (Test-Path -LiteralPath (Join-Path $plugin $relative) -PathType Leaf)) {
            Stop-Install 'Windows용 플러그인 파일이 빠져 있습니다. 새 설치명령어를 받아 다시 시도해주세요.'
        }
    }
    return $plugin
}

function Initialize-WindowsRuntime([string]$ProductRoot, [string]$PluginRoot, [string]$TemporaryRoot) {
    $bundle = Join-Path $ProductRoot 'windows-runtime'
    $manifestPath = Join-Path $bundle 'files.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-Install 'Windows 실행 환경이 배포본에 없습니다. 새 설치 명령어를 받아주세요.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.platform -ne 'win-x64' -or -not $manifest.files) { Stop-Install 'Windows 실행 환경 검증표가 올바르지 않습니다.' }
    $verified = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        if (-not $relative -or $relative.Contains('\') -or $relative.Contains(':') -or $relative.StartsWith('/') -or ($relative.Split('/') -contains '') -or ($relative.Split('/') -contains '..') -or ($relative.Split('/') -contains '.') -or $entry.sha256 -notmatch '^[0-9a-f]{64}$' -or -not $verified.Add($relative)) {
            Stop-Install 'Windows 실행 환경 검증표에 안전하지 않은 경로가 있습니다.'
        }
        $file = Join-Path $bundle $relative
        $item = Get-Item -LiteralPath $file -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
            Stop-Install 'Windows 실행 환경 파일 검증에 실패했습니다.'
        }
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $bundle -Recurse -File -Force | Where-Object { $_.Name -ne 'files.json' })
    if ($actualFiles.Count -ne $verified.Count) { Stop-Install 'Windows 실행 환경 파일 수가 검증표와 다릅니다.' }
    $runtime = Join-Path $bundle 'python\python.exe'
    $modelSource = Join-Path $bundle 'models\pose_landmarker_full.task'
    $browserSource = Join-Path $bundle 'browsers'
    if (-not (Test-Path -LiteralPath $runtime -PathType Leaf) -or -not (Test-Path -LiteralPath $modelSource -PathType Leaf) -or -not (Test-Path -LiteralPath $browserSource -PathType Container) -or @((Get-ChildItem -LiteralPath $browserSource -Directory)).Count -eq 0) {
        Stop-Install 'Windows 실행 환경의 필수 파일이 빠졌습니다.'
    }
    if (Test-Path -LiteralPath $windowsRoot) {
        $rootItem = Get-Item -LiteralPath $windowsRoot -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-Install 'Windows 실행 환경 경로를 안전하게 사용할 수 없습니다.'
        }
    }
    New-Item -ItemType Directory -Path $windowsRoot -Force -ErrorAction Stop | Out-Null
    $modelDirectory = Join-Path $windowsRoot 'models'
    New-Item -ItemType Directory -Path $modelDirectory -Force -ErrorAction Stop | Out-Null
    $modelDirectoryItem = Get-Item -LiteralPath $modelDirectory -ErrorAction Stop
    if ($modelDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-Install 'Windows 포즈 모델 폴더가 연결 경로여서 설치를 중단했습니다.'
    }
    $model = Join-Path $modelDirectory 'pose_landmarker_full.task'
    if (Test-Path -LiteralPath $model) {
        $modelItem = Get-Item -LiteralPath $model -ErrorAction Stop
        if ($modelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Stop-Install 'Windows 포즈 모델 파일이 연결 경로여서 설치를 중단했습니다.'
        }
    }
    if ((Get-FileHash -LiteralPath $modelSource -Algorithm SHA256).Hash.ToLowerInvariant() -ne $modelSha256) { Stop-Install '배포본의 Windows 포즈 모델 검증에 실패했습니다.' }
    if (-not (Test-Path -LiteralPath $model -PathType Leaf)) { Copy-Item -LiteralPath $modelSource -Destination $model -ErrorAction Stop }
    if ((Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant() -ne $modelSha256) {
        Stop-Install '기존 Windows 포즈 모델의 파일 검증에 실패했습니다. 설치 상태를 확인해주세요.'
    }

    $browserTarget = Join-Path $env:LOCALAPPDATA 'ms-playwright'
    New-Item -ItemType Directory -Path $browserTarget -Force -ErrorAction Stop | Out-Null
    foreach ($browser in @(Get-ChildItem -LiteralPath $browserSource -Directory)) {
        $destination = Join-Path $browserTarget $browser.Name
        if (Test-Path -LiteralPath $destination) {
            $existing = Get-Item -LiteralPath $destination -ErrorAction Stop
            if (-not $existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Stop-Install '기존 브라우저 캐시 경로를 안전하게 사용할 수 없습니다.' }
        }
        Copy-Item -LiteralPath $browser.FullName -Destination $browserTarget -Recurse -Force -ErrorAction Stop
    }
    foreach ($entry in @($manifest.files | Where-Object { $_.path -like 'browsers/*' })) {
        $relative = ([string]$entry.path).Substring('browsers/'.Length)
        $installedBrowserFile = Join-Path $browserTarget $relative
        if (-not (Test-Path -LiteralPath $installedBrowserFile -PathType Leaf) -or (Get-FileHash -LiteralPath $installedBrowserFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
            Stop-Install '상세 출력용 브라우저 파일 검증에 실패했습니다.'
        }
    }

    $poseProbe = @'
import importlib.util
import pathlib
import sys
from PIL import Image
from playwright.async_api import async_playwright
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('otos_windows_pose', root / 'scripts' / 'windows_pose.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.prepare()
'@
    Invoke-QuietExternal $runtime @('-c', $poseProbe, $PluginRoot) (Join-Path $TemporaryRoot 'windows-pose.log') 'Windows 포즈 분석 환경 확인에 실패했습니다.'
    return $runtime
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ot-os-installer-" + [guid]::NewGuid().ToString('N'))
$stage = $null
$preserveFailureDiagnostics = $false
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $installStep = '설치 환경 확인'
  Write-Host '[1/4] 설치를 준비하고 있습니다.'
  Initialize-WindowsEnvironment $tempRoot
  Initialize-OtosNative $tempRoot
  $installationId = [guid]::NewGuid().ToString()
  $installStep = '구매 권한 확인'
  Write-Host '[2/4] 구매 권한을 확인하고 있습니다.'
  try {
    $reply = Invoke-RestMethod -Method Post -Uri $RedeemUrl -ContentType 'application/json' -Body (@{
      token = $Token
      installationId = $installationId
      appVersion = 'bootstrap-windows-v1'
    } | ConvertTo-Json -Compress)
  } catch {
    Stop-Install '설치 서버에 연결하지 못했습니다. 같은 설치 명령으로 다시 시도해주세요.'
  }

  if ($reply.platform -ne 'windows') { Stop-Install 'Windows용 배포 주소를 받지 못했습니다. 같은 설치 명령으로 다시 시도해주세요.' }
  if (-not $reply.archiveUrl -or $reply.archiveUrl -notmatch '^https://') { Stop-Install '안전한 OT.OS 배포 주소를 받지 못했습니다.' }
  $archive = Join-Path $tempRoot 'ot-os.tar.gz'
  $source = Join-Path $tempRoot 'source'
  New-Item -ItemType Directory -Path $source | Out-Null
  $installStep = '설치 파일 다운로드 및 확인'
  Write-Host '[3/4] 설치 파일과 Windows 실행 환경을 확인하고 있습니다.'
  Invoke-WebRequest -UseBasicParsing -Uri $reply.archiveUrl -OutFile $archive
  Invoke-QuietExternal 'tar.exe' @('-xzf', $archive, '-C', $source, '--strip-components=1') (Join-Path $tempRoot 'extract.log') '배포 파일을 풀지 못했습니다.'

  $product = Join-Path $source 'product'
  $manifestPath = Join-Path $product 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-Install '배포본에 product/manifest.json이 없습니다.' }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.productId -ne 'otos' -or -not $manifest.version -or $manifest.platform -ne 'windows') {
    Stop-Install 'Windows용 OT.OS 배포본을 확인할 수 없습니다. 같은 설치 명령으로 다시 시도해주세요.'
  }

  Test-OtosNativeFiles (Join-Path $product 'plugins\otos-studio') (Join-Path $product 'otos-studio-client-sha256.txt') | Out-Null
  $plugin = Test-WindowsPackage $product $reply
  if (Test-Path -LiteralPath (Join-Path $product 'windows-runtime')) { Stop-Install 'Windows 실행 환경이 중복되어 설치를 중단했습니다.' }
  $runtimeArchive = Join-Path $tempRoot 'windows-runtime.zip'
  try { Invoke-WebRequest -UseBasicParsing -Uri $runtimeArchiveUrl -OutFile $runtimeArchive -ErrorAction Stop }
  catch { Stop-Install 'Windows 실행 환경을 내려받지 못했습니다. 같은 설치 명령으로 다시 시도해주세요.' }
  if ((Get-FileHash -LiteralPath $runtimeArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtimeArchiveSha256) {
    Stop-Install 'Windows 실행 환경 ZIP의 SHA-256 검증에 실패했습니다.'
  }
  Expand-Archive -LiteralPath $runtimeArchive -DestinationPath $product -ErrorAction Stop
  $runtime = Initialize-WindowsRuntime $product $plugin $tempRoot

  $parent = Split-Path -Parent $Target
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $stage = Join-Path $parent ('.ot-os-staging-' + [guid]::NewGuid().ToString('N'))
  Copy-Item -LiteralPath $product -Destination $stage -Recurse
  $backup = $null
  if (Test-Path -LiteralPath $Target) {
    $backup = "$Target.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')-$installationId"
    Move-Item -LiteralPath $Target -Destination $backup
    Write-Host "기존 설치본을 백업했습니다: $backup"
  }
  try {
    Move-Item -LiteralPath $stage -Destination $Target
  } catch {
    $activationError = $_
    if ($backup -and -not (Test-Path -LiteralPath $Target)) {
      try { Move-Item -LiteralPath $backup -Destination $Target } catch { Write-Warning "기존 설치 폴더를 자동 복구하지 못했습니다. 보존 위치: $backup" }
    }
    throw $activationError
  }
  $stage = $null
  $runtime = Join-Path $Target 'windows-runtime\python\python.exe'
  $installStep = '플러그인 등록 및 활성화'
  Write-Host '[4/4] Codex에 OT.OS를 설치하고 있습니다.'
  try {
    $nativeInstalled = Install-OtosNative $Target
    $installedPlugin = Join-Path $Target 'plugins\otos-studio'
    Invoke-QuietExternal $runtime @((Join-Path $installedPlugin 'scripts\browser_probe.py'), '--resolve-python', '--python', $runtime) (Join-Path $tempRoot 'runtime-resolution.log') 'Codex 작업용 Python 연결을 확인하지 못했습니다.'
  } catch {
    $nativeError = $_
    $buyerSource = [IO.Path]::GetFullPath((Join-Path $Target 'plugins\otos-studio'))
    if ($backup -and $script:OtosNativeSource -eq $buyerSource) {
      $failedTarget = Join-Path $parent ('.ot-os-failed-' + [guid]::NewGuid().ToString('N'))
      try {
        Move-Item -LiteralPath $Target -Destination $failedTarget
        Move-Item -LiteralPath $backup -Destination $Target
        & $script:OtosNativeCli plugin add $script:OtosNativeSelector --json > (Join-Path $tempRoot 'product-restore.json') 2> (Join-Path $script:OtosNativeTemporaryRoot 'codex.stderr')
        if ($LASTEXITCODE -ne 0) { Write-Warning "기존 플러그인 재등록을 확인하지 못했습니다. 보존 위치: $failedTarget" }
      } catch { Write-Warning "기존 설치 폴더를 자동 복구하지 못했습니다. 보존 위치: $backup / $failedTarget" }
    }
    throw $nativeError
  }
  [ordered]@{
    status = 'installed_not_workflow_verified'
    platform = 'windows'
    nativeComplete = $script:OtosNativeComplete
    nativePluginId = $nativeInstalled.pluginId
    nativePluginVersion = $nativeInstalled.version
    nativeInstalledPath = $nativeInstalled.installedPath
    nativeVerifiedFiles = $manifest.runtimeFiles
    runtimeClientSha256 = $manifest.runtimeClientSha256
    windowsRuntimeReady = $true
    windowsPython = $runtime
    windowsPoseModelSha256 = $modelSha256
    productId = 'otos'
    version = $manifest.version
    repository = $reply.repository
    ref = $reply.ref
    installedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Target '.ot-os-install.json') -Encoding utf8
  Write-Host '설치 완료 — OT.OS 등록·활성화와 Windows 실행 환경을 확인했습니다.'
  Write-Host '이제 Codex에서 OT.OS로 원하는 작업과 상품 URL을 보내세요.'
} catch {
  $originalError = $_
  $detail = '네트워크 접근을 확인한 뒤 같은 설치 명령으로 다시 시도해주세요.'
  $cause = [string]$originalError.Exception.Message
  if ($Token) { $cause = $cause.Replace($Token, '[토큰 가림]') }
  if ($installStep -eq '설치 환경 확인') {
    $preserveFailureDiagnostics = $true
    $detail = '환경 검사 오류 원문: ' + $cause + '. 진단 파일: ' + (Join-Path $tempRoot 'failure.txt') + '. 구매 토큰은 사용하지 않았습니다.'
  }
  if ($cause.StartsWith('OT.OS 설치 실패: ')) { $detail = $cause.Substring('OT.OS 설치 실패: '.Length) }
  @(
    ('단계: ' + $installStep),
    ('오류: ' + $cause),
    ('기록 시각(UTC): ' + [DateTime]::UtcNow.ToString('o'))
  ) | Set-Content -LiteralPath (Join-Path $tempRoot 'failure.txt') -Encoding UTF8
  throw ('설치 미완료 — ' + $installStep + ' 단계에서 멈췄습니다. ' + $detail)
} finally {
  if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
  if (-not $preserveFailureDiagnostics) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
