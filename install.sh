#!/bin/bash
set -Eeuo pipefail
install_step="설치 준비"
trap 'printf "설치 미완료 — %s 단계에서 멈췄습니다. 같은 설치 명령으로 다시 시도해주세요.\n" "$install_step" >&2' ERR

say() {
  printf '%s\n' "$1"
}

fail() {
  printf '설치 미완료 — %s\n' "$1" >&2
  exit 1
}


otos_native_fail() { printf 'OT.OS 플러그인 설치 실패: %s\n' "$1" >&2; return 1; }

otos_native_json() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

otos_native_require_array() {
  /usr/bin/plutil -convert xml1 -o "$otos_native_temp/json-check.plist" "$1" >/dev/null 2>&1 &&
    /usr/bin/plutil -lint "$otos_native_temp/json-check.plist" >/dev/null 2>&1 &&
    /usr/bin/plutil -extract "$2" json -o "$otos_native_temp/array-check.json" "$1" 2>/dev/null &&
    [ "$(/usr/bin/head -c 1 "$otos_native_temp/array-check.json")" = '[' ] || {
      otos_native_fail 'Codex JSON의 필수 배열이 올바르지 않습니다.'; return 1;
    }
}

otos_native_preflight() {
  otos_native_temp="$1"
  otos_native_selector=""
  otos_native_source=""
  otos_native_marketplace=""
  otos_source_backup=""
  otos_source_replaced=0
  otos_native_complete=false
  otos_codex_state_root="${CODEX_HOME:-${HOME}/.codex}"
  otos_native_cli=""
  if [ -n "${OT_OS_CODEX_CLI:-}" ]; then
    otos_native_cli="$OT_OS_CODEX_CLI"
  elif [ -x "$otos_codex_state_root/plugins/.plugin-appserver/codex-cli/bin/codex" ]; then
    otos_native_cli="$otos_codex_state_root/plugins/.plugin-appserver/codex-cli/bin/codex"
  else
    for otos_bundle_root in /Applications/ChatGPT.app /Applications/Codex.app "$HOME/Applications/ChatGPT.app" "$HOME/Applications/Codex.app"; do
      for otos_bundle_cli in "$otos_bundle_root/Contents/Resources/codex-cli/bin/codex" "$otos_bundle_root/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"; do
        if [ -x "$otos_bundle_cli" ]; then otos_native_cli="$otos_bundle_cli"; break 2; fi
      done
    done
  fi
  if [ -z "$otos_native_cli" ] && command -v codex >/dev/null 2>&1; then
    otos_native_cli="$(command -v codex)"
  fi
  [ -n "$otos_native_cli" ] && [ -x "$otos_native_cli" ] || {
    otos_native_fail 'Codex 플러그인 실행기를 찾을 수 없어 구매 토큰을 사용하지 않았습니다.'; return 1;
  }
  "$otos_native_cli" plugin marketplace add --help > "$otos_native_temp/marketplace-help.txt" 2>&1 &&
    "$otos_native_cli" plugin add --help > "$otos_native_temp/plugin-help.txt" 2>&1 || {
      otos_native_fail '현재 Codex 실행기는 정식 플러그인 등록을 지원하지 않아 구매 토큰을 사용하지 않았습니다.'; return 1;
    }
  "$otos_native_cli" plugin marketplace list --json > "$otos_native_temp/marketplaces.json" || {
    otos_native_fail '현재 Codex marketplace를 확인하지 못해 구매 토큰을 사용하지 않았습니다.'; return 1;
  }
  otos_native_require_array "$otos_native_temp/marketplaces.json" marketplaces || return 1
  otos_market_index=0
  otos_installed_count=0
  while /usr/bin/plutil -extract "marketplaces.$otos_market_index" json -o /dev/null "$otos_native_temp/marketplaces.json" 2>/dev/null; do
    otos_market_name="$(otos_native_json "$otos_native_temp/marketplaces.json" "marketplaces.$otos_market_index.name" || true)"
    [ -n "$otos_market_name" ] || { otos_native_fail 'marketplace 식별자가 없어 구매 토큰을 사용하지 않았습니다.'; return 1; }
    otos_list_file="$otos_native_temp/plugins-$otos_market_index.json"
    "$otos_native_cli" plugin list --marketplace "$otos_market_name" --json > "$otos_list_file" || {
      otos_native_fail '기존 플러그인을 확인하지 못해 구매 토큰을 사용하지 않았습니다.'; return 1;
    }
    otos_native_require_array "$otos_list_file" installed || return 1
    otos_plugin_index=0
    while /usr/bin/plutil -extract "installed.$otos_plugin_index" json -o /dev/null "$otos_list_file" 2>/dev/null; do
      otos_plugin_name="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.name" || true)"
      otos_plugin_id="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.pluginId" || true)"
      [ -n "$otos_plugin_name" ] && [ -n "$otos_plugin_id" ] || { otos_native_fail '기존 플러그인 식별자가 없어 구매 토큰을 사용하지 않았습니다.'; return 1; }
      if [ "$otos_plugin_name" = 'otos-studio' ]; then
        otos_installed_count=$((otos_installed_count + 1))
        otos_native_selector="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.pluginId")"
        otos_native_marketplace="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.marketplaceName")"
        otos_source_type="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.source.source" || true)"
        otos_native_source="$(otos_native_json "$otos_list_file" "installed.$otos_plugin_index.source.path" || true)"
        [ "$otos_source_type" = 'local' ] && [ -n "$otos_native_source" ] || {
          otos_native_fail '기존 OT.OS가 로컬 설치가 아니므로 중복 등록을 피하기 위해 구매 토큰을 사용하지 않았습니다.'; return 1;
        }
      fi
      otos_plugin_index=$((otos_plugin_index + 1))
    done
    otos_market_index=$((otos_market_index + 1))
  done
  [ "$otos_installed_count" -le 1 ] || {
    otos_native_fail '기존 OT.OS가 여러 marketplace에 설치되어 있어 추가 등록과 토큰 사용을 중단했습니다.'; return 1;
  }
  if [ "$otos_installed_count" -eq 1 ]; then
    case "$otos_native_selector" in
      "otos-studio@$otos_native_marketplace") ;;
      *) otos_native_fail '기존 OT.OS 식별자가 일치하지 않아 구매 토큰을 사용하지 않았습니다.'; return 1 ;;
    esac
    case "$otos_native_source" in
      /*) ;;
      *) otos_native_fail '기존 OT.OS 원본 경로가 올바르지 않아 구매 토큰을 사용하지 않았습니다.'; return 1 ;;
    esac
    [ ! -L "$otos_native_source" ] && [ -d "$otos_native_source" ] &&
      [ "$(otos_native_json "$otos_native_source/.codex-plugin/plugin.json" name || true)" = 'otos-studio' ] || {
        otos_native_fail '기존 OT.OS 원본을 안전하게 교체할 수 없어 구매 토큰을 사용하지 않았습니다.'; return 1;
      }
    [ ! -e "$otos_native_source/.git" ] || {
      otos_native_fail '기존 OT.OS가 개발 저장소이므로 구매 토큰을 사용하지 않았습니다.'; return 1;
    }
  fi
}

otos_native_verify_files() {
  otos_verify_root="$1"
  otos_verify_manifest="$2"
  [ -f "$otos_verify_manifest" ] || { otos_native_fail '플러그인 파일 검증표가 없습니다.'; return 1; }
  otos_expected_files="$(/usr/bin/plutil -extract runtimeFiles raw -expect integer -o - "$(dirname "$otos_verify_manifest")/manifest.json" 2>/dev/null)" || {
    otos_native_fail '배포 manifest의 runtimeFiles가 정수가 아닙니다.'; return 1;
  }
  [[ "$otos_expected_files" =~ ^[1-9][0-9]*$ ]] || {
    otos_native_fail '배포 manifest의 runtimeFiles는 양의 정수여야 합니다.'; return 1;
  }
  otos_verify_count=0
  while IFS= read -r otos_checksum_line; do
    [[ "$otos_checksum_line" =~ ^[0-9a-f]{64}\ \ .+ ]] || {
      otos_native_fail '플러그인 파일 검증표 형식이 올바르지 않습니다.'; return 1;
    }
    otos_relative_path="${otos_checksum_line#*  }"
    case "$otos_relative_path" in
      ''|/*|..|../*|*/../*|*/..|./*|*/./*|*\\*) otos_native_fail '플러그인 파일 검증 경로가 안전하지 않습니다.'; return 1 ;;
    esac
    [ -f "$otos_verify_root/$otos_relative_path" ] && [ ! -L "$otos_verify_root/$otos_relative_path" ] || {
      otos_native_fail '플러그인 검증 파일이 없거나 링크입니다.'; return 1;
    }
    otos_verify_count=$((otos_verify_count + 1))
  done < "$otos_verify_manifest"
  [ "$otos_verify_count" -eq "$otos_expected_files" ] || { otos_native_fail '플러그인 파일 검증표와 배포 manifest의 파일 수가 일치하지 않습니다.'; return 1; }
  /usr/bin/awk '{ path=substr($0,67); if (seen[path]++) exit 1 }' "$otos_verify_manifest" || {
    otos_native_fail '플러그인 검증표에 중복 파일 경로가 있습니다.'; return 1;
  }
  [ -z "$(/usr/bin/find "$otos_verify_root" -type l -print -quit)" ] || {
    otos_native_fail '플러그인 원본에 파일 또는 폴더 링크가 있습니다.'; return 1;
  }
  otos_actual_files="$(/usr/bin/find "$otos_verify_root" -type f ! -name .DS_Store ! -path '*/__pycache__/*.pyc' -print | /usr/bin/wc -l | tr -d '[:space:]')"
  [ "$otos_actual_files" -eq "$otos_expected_files" ] || {
    otos_native_fail '배포표 밖의 실행 파일이 있어 native 플러그인 검증에 실패했습니다.'; return 1;
  }
  (cd "$otos_verify_root" && /usr/bin/shasum -a 256 -c "$otos_verify_manifest" > "$otos_native_temp/native-file-verification.txt") || {
    otos_native_fail '플러그인 파일의 해시가 배포본과 다릅니다.'; return 1;
  }
}

otos_native_restore_source() {
  [ "$otos_source_replaced" -eq 1 ] || return 0
  otos_restore_failed=0
  if [ -e "$otos_native_source" ]; then
    mv "$otos_native_source" "$otos_source_backup/failed-runtime" || otos_restore_failed=1
  fi
  if [ "$otos_restore_failed" -eq 0 ]; then
    mv "$otos_source_backup/runtime" "$otos_native_source" || otos_restore_failed=1
  fi
  if [ "$otos_restore_failed" -eq 0 ]; then
    "$otos_native_cli" plugin add "$otos_native_selector" --json > "$otos_native_temp/plugin-restore.json" 2> "$otos_native_temp/plugin-restore.stderr" || otos_restore_failed=1
  fi
  if [ "$otos_restore_failed" -eq 0 ]; then
    otos_restored_path="$(otos_native_json "$otos_native_temp/plugin-restore.json" installedPath || true)"
    [ -d "$otos_restored_path" ] && /usr/bin/diff -qr -x .DS_Store -x __pycache__ "$otos_native_source" "$otos_restored_path" > "$otos_native_temp/plugin-restore-diff.txt" || otos_restore_failed=1
  fi
  if [ "$otos_restore_failed" -ne 0 ]; then
    printf 'OT.OS 기존 플러그인 복구에도 실패했습니다. 원래 경로: %s / 보존 자료: %s\n' "$otos_native_source" "$otos_source_backup" >&2
    return 1
  fi
  otos_source_replaced=0
}

otos_native_install() {
  otos_product_root="$1"
  otos_payload="$otos_product_root/plugins/otos-studio"
  otos_checksums="$otos_product_root/otos-studio-client-sha256.txt"
  [ "$(otos_native_json "$otos_payload/.codex-plugin/plugin.json" name || true)" = 'otos-studio' ] || {
    otos_native_fail 'OT.OS native 플러그인 manifest가 없습니다.'; return 1;
  }
  otos_native_verify_files "$otos_payload" "$otos_checksums" || return 1
  if [ -n "$otos_native_selector" ]; then
    # Reuse the existing identity; never add a second active copy under another marketplace.
    if [ "$otos_native_source" != "$otos_payload" ]; then
      if ! otos_native_verify_files "$otos_native_source" "$otos_checksums" >/dev/null 2>&1; then
        otos_source_staging="$(mktemp -d "$(dirname "$otos_native_source")/.ot-os-plugin-staging.XXXXXX")"
        ditto "$otos_payload" "$otos_source_staging" || return 1
        otos_native_verify_files "$otos_source_staging" "$otos_checksums" || return 1
        otos_source_backup="$(mktemp -d "$(dirname "$otos_native_source")/.ot-os-plugin-backup.XXXXXX")"
        mv "$otos_native_source" "$otos_source_backup/runtime" || return 1
        if ! mv "$otos_source_staging" "$otos_native_source"; then
          mv "$otos_source_backup/runtime" "$otos_native_source" || printf 'OT.OS 원본 경로 복구에 실패했습니다: %s\n' "$otos_source_backup" >&2
          return 1
        fi
        otos_source_replaced=1
      fi
    fi
  else
    [ "$(otos_native_json "$otos_product_root/.agents/plugins/marketplace.json" name || true)" = 'otos-buyer' ] || {
      otos_native_fail 'OT.OS 전용 marketplace manifest가 없습니다.'; return 1;
    }
    "$otos_native_cli" plugin marketplace add "$otos_product_root" --json > "$otos_native_temp/marketplace-add.json" || {
      otos_native_fail 'OT.OS 전용 marketplace 등록에 실패했습니다.'; return 1;
    }
    otos_native_selector='otos-studio@otos-buyer'
    otos_native_marketplace='otos-buyer'
  fi
  "$otos_native_cli" plugin add "$otos_native_selector" --json > "$otos_native_temp/plugin-add.json" || {
    otos_native_restore_source || true
    otos_native_fail 'Codex native 플러그인 등록에 실패했습니다. 파일 복사만 완료된 상태입니다.'; return 1;
  }
  [ "$(otos_native_json "$otos_native_temp/plugin-add.json" pluginId || true)" = "$otos_native_selector" ] || {
    otos_native_restore_source || true
    otos_native_fail '등록 결과의 OT.OS 식별자가 다릅니다.'; return 1;
  }
  otos_installed_path="$(otos_native_json "$otos_native_temp/plugin-add.json" installedPath || true)"
  [ -n "$otos_installed_path" ] && [ -d "$otos_installed_path" ] || {
    otos_native_restore_source || true
    otos_native_fail '등록된 플러그인의 설치 경로를 확인하지 못했습니다.'; return 1;
  }
  if ! otos_native_verify_files "$otos_installed_path" "$otos_checksums"; then otos_native_restore_source || true; return 1; fi
  if ! "$otos_native_cli" plugin list --marketplace "$otos_native_marketplace" --json > "$otos_native_temp/plugins-after.json"; then otos_native_restore_source || true; return 1; fi
  if ! otos_native_require_array "$otos_native_temp/plugins-after.json" installed; then otos_native_restore_source || true; return 1; fi
  otos_native_enabled=0
  otos_plugin_index=0
  while otos_plugin_id="$(otos_native_json "$otos_native_temp/plugins-after.json" "installed.$otos_plugin_index.pluginId")"; do
    if [ "$otos_plugin_id" = "$otos_native_selector" ] &&
      [ "$(otos_native_json "$otos_native_temp/plugins-after.json" "installed.$otos_plugin_index.enabled" || true)" = 'true' ]; then
      otos_native_enabled=1
    fi
    otos_plugin_index=$((otos_plugin_index + 1))
  done
  [ "$otos_native_enabled" -eq 1 ] || { otos_native_restore_source || true; otos_native_fail '등록된 OT.OS 플러그인이 활성화되지 않았습니다.'; return 1; }
  otos_native_plugin_version="$(otos_native_json "$otos_native_temp/plugin-add.json" version || true)"
  [ -n "$otos_native_plugin_version" ] && [ "$otos_native_plugin_version" = "$(otos_native_json "$otos_payload/.codex-plugin/plugin.json" version || true)" ] || { otos_native_restore_source || true; otos_native_fail '등록된 OT.OS 버전이 배포본과 다릅니다.'; return 1; }
  otos_native_complete=true
  # Only the enclosing installer may now write nativeComplete=true in its receipt.
}


token="${OTOS_INSTALL_TOKEN:-}"
redeem_url="${OTOS_INSTALL_REDEEM_URL:-https://xcgvouxpcecyxhqecyce.supabase.co/functions/v1/redeem-install-token}"
unset OTOS_INSTALL_TOKEN OTOS_INSTALL_REDEEM_URL
target="${OT_OS_INSTALL_DIR:-${HOME}/Documents/OT.OS}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      [ "$#" -ge 2 ] || fail "설치 토큰이 비어 있습니다."
      token="$2"
      shift 2
      ;;
    --redeem-url)
      [ "$#" -ge 2 ] || fail "설치 권한 확인 주소가 비어 있습니다."
      redeem_url="$2"
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || fail "설치 경로가 비어 있습니다."
      target="$2"
      shift 2
      ;;
    *)
      fail "알 수 없는 옵션입니다: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "현재 설치기는 macOS만 지원합니다."
[[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || fail "설치 토큰 형식이 올바르지 않습니다."
case "$redeem_url" in
  https://*) ;;
  *) fail "설치 권한 확인 주소는 HTTPS여야 합니다." ;;
esac

for command_name in curl tar plutil uuidgen ditto; do
  command -v "$command_name" >/dev/null 2>&1 || fail "필수 명령을 찾을 수 없습니다: $command_name"
done

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/ot-os-installer.XXXXXX")"
cleanup() {
  case "$temp_root" in
    "${TMPDIR:-/tmp}"/ot-os-installer.*) rm -rf -- "$temp_root" ;;
  esac
}
trap cleanup EXIT INT TERM

install_step="설치를 준비하고 있습니다."
say "[1/4] 설치를 준비하고 있습니다."
otos_native_preflight "$temp_root" || fail "플러그인 설치 환경을 확인하지 못했습니다. 구매 토큰은 사용하지 않았습니다."

response_file="$temp_root/redeem.json"
archive_file="$temp_root/ot-os.tar.gz"
source_dir="$temp_root/source"
installation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

install_step="구매 권한을 확인하고 있습니다."
say "[2/4] 구매 권한을 확인하고 있습니다."
http_status="$(curl -sS --proto '=https' --tlsv1.2 \
  -o "$response_file" \
  -w '%{http_code}' \
  -X POST "$redeem_url" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"token\":\"$token\",\"installationId\":\"$installation_id\",\"appVersion\":\"bootstrap-v1\"}" 2> "$temp_root/redeem.stderr")" || fail "구매 권한 서버에 연결하지 못했습니다. 네트워크 접근을 허용한 뒤 다시 시도해주세요."

if [ "$http_status" != "200" ]; then
  error_code="$(plutil -extract code raw -o - "$response_file" 2>/dev/null || true)"
  fail "구매 권한을 확인하지 못했습니다 (${error_code:-HTTP $http_status}). 같은 설치 명령으로 다시 시도해주세요."
fi

archive_url="$(plutil -extract archiveUrl raw -o - "$response_file" 2>/dev/null || true)"
repository="$(plutil -extract repository raw -o - "$response_file" 2>/dev/null || true)"
ref="$(plutil -extract ref raw -o - "$response_file" 2>/dev/null || true)"
case "$archive_url" in
  https://*) ;;
  *) fail "안전한 OT.OS 배포 주소를 받지 못했습니다." ;;
esac

install_step="설치 파일을 내려받고 확인하고 있습니다."
say "[3/4] 설치 파일을 내려받고 확인하고 있습니다."
curl -fsSL --proto '=https' --tlsv1.2 "$archive_url" -o "$archive_file" 2> "$temp_root/download.stderr" || fail "설치 파일을 내려받지 못했습니다. 네트워크 접근을 허용한 뒤 다시 시도해주세요."
mkdir -p "$source_dir"
tar -xzf "$archive_file" -C "$source_dir" --strip-components=1 2> "$temp_root/extract.stderr" || fail "설치 파일을 풀지 못했습니다. 같은 설치 명령으로 다시 시도해주세요."

manifest="$source_dir/product/manifest.json"
[ -f "$manifest" ] || fail "배포본에 product/manifest.json이 없습니다. 설치를 중단합니다."
product_id="$(plutil -extract productId raw -o - "$manifest" 2>/dev/null || true)"
version="$(plutil -extract version raw -o - "$manifest" 2>/dev/null || true)"
[ "$product_id" = "otos" ] || fail "OT.OS 배포본이 아닙니다."
[ -n "$version" ] || fail "배포본 버전을 확인할 수 없습니다."

otos_native_verify_files "$source_dir/product/plugins/otos-studio" "$source_dir/product/otos-studio-client-sha256.txt" || fail "플러그인 배포 파일 검증에 실패했습니다."

target_parent="$(dirname "$target")"
mkdir -p "$target_parent"
staging="$(mktemp -d "$target_parent/.ot-os-staging.XXXXXX")"
ditto "$source_dir/product" "$staging"

backup=""
if [ -e "$target" ]; then
  backup="$target.backup.$(date '+%Y%m%d-%H%M%S')-$installation_id"
  mv "$target" "$backup"
  say "기존 설치본을 백업했습니다: $backup"
fi
if ! mv "$staging" "$target"; then
  if [ -n "$backup" ] && [ ! -e "$target" ]; then
    mv "$backup" "$target" || say "기존 설치 폴더 복구를 확인하지 못했습니다. 보존 위치: $backup"
  fi
  fail "설치 폴더 활성화에 실패했습니다. 기존 자료와 staging은 보존했습니다."
fi

install_step="Codex에 OT.OS를 설치하고 있습니다."
say "[4/4] Codex에 OT.OS를 설치하고 있습니다."
if ! otos_native_install "$target"; then
  # The outer folder backup also protects an existing buyer marketplace source.
  if [ -n "$backup" ] && [ "$otos_native_source" -ef "$target/plugins/otos-studio" ]; then
    failed_target="$(mktemp -d "$target_parent/.ot-os-failed.XXXXXX")"
    if mv "$target" "$failed_target/product" && mv "$backup" "$target"; then
      "$otos_native_cli" plugin add "$otos_native_selector" --json > "$temp_root/product-restore.json" 2> "$temp_root/product-restore.stderr" || say "기존 플러그인 재등록을 확인하지 못했습니다. 보존 위치: $failed_target"
    else
      say "기존 설치 폴더를 자동 복구하지 못했습니다. 보존 위치: $backup / $failed_target"
    fi
  fi
  fail "정식 플러그인 등록·검증을 완료하지 못했습니다. 설치 완료로 기록하지 않았습니다."
fi

receipt="$temp_root/install-receipt.json"
/usr/bin/plutil -create xml1 "$receipt"
/usr/bin/plutil -insert productId -string otos "$receipt"
/usr/bin/plutil -insert version -string "$version" "$receipt"
/usr/bin/plutil -insert repository -string "$repository" "$receipt"
/usr/bin/plutil -insert ref -string "$ref" "$receipt"
/usr/bin/plutil -insert installedAt -string "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$receipt"
/usr/bin/plutil -insert nativeComplete -bool YES "$receipt"
/usr/bin/plutil -insert nativePluginId -string "$otos_native_selector" "$receipt"
/usr/bin/plutil -insert nativePluginVersion -string "$otos_native_plugin_version" "$receipt"
/usr/bin/plutil -insert nativeInstalledPath -string "$otos_installed_path" "$receipt"
/usr/bin/plutil -insert nativeVerifiedFiles -integer "$otos_expected_files" "$receipt"
/usr/bin/plutil -insert runtimeClientSha256 -string "$(otos_native_json "$manifest" runtimeClientSha256)" "$receipt"
/usr/bin/plutil -convert json "$receipt"
mv "$receipt" "$target/.ot-os-install.json"

say "설치 완료 — OT.OS 등록과 활성화를 확인했습니다."
say "이제 Codex에서 OT.OS로 원하는 작업과 상품 URL을 보내세요."
