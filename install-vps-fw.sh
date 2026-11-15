#!/usr/bin/env bash
# Bootstrap: bash install-vps-fw.sh FIXED_COMMIT_RAW_URL EXPECTED_SHA256
set -euo pipefail
main() {
  local url="${1:-}" expected="${2:-}" actual
  [[ "$url" =~ ^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-fA-F]{40}/.+$ ]] || { echo '需要固定 40 位 Git commit 的 GitHub Raw URL' >&2; return 1; }
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo '需要从可信发布信息取得的 SHA256' >&2; return 1; }
  [[ $(id -u) == 0 ]] || { echo '请以 root 运行安装器' >&2; return 1; }
  command -v curl >/dev/null
  command -v sha256sum >/dev/null
  VPS_FW_INSTALL_TMP="$(mktemp -d)"
  trap 'rm -rf -- "$VPS_FW_INSTALL_TMP"' EXIT
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$url" -o "$VPS_FW_INSTALL_TMP/vps-fw.sh"
  actual="$(sha256sum "$VPS_FW_INSTALL_TMP/vps-fw.sh")"
  actual="${actual%% *}"
  [[ "$actual" == "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]] || { echo 'SHA256 不匹配，未执行下载文件' >&2; return 1; }
  bash -n "$VPS_FW_INSTALL_TMP/vps-fw.sh"
  [[ -r /dev/tty ]] || { echo '需要交互终端' >&2; return 1; }
  bash "$VPS_FW_INSTALL_TMP/vps-fw.sh" </dev/tty
}
main "$@"
