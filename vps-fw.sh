#!/usr/bin/env bash
# ============================================================================
# VPS-FW: Debian / Ubuntu 主机防火墙面板 (Pure Bash + nftables)
# 目标系统: Debian 13 + nftables 1.1.3 + systemd；其他发行版未经验证
# 核心特性:
#   1. 零 Python/第三方依赖，单文件运行，支持本地执行与 GitHub curl 一键启动
#   2. 云安全组边界模型 (priority -150): 宿主机 + Docker/Podman 容器统一纳管，
#      适用于单公网接口及常规 bridge 网络；其他模式需单独验证
#   3. 放行同机容器间内部互访，不影响 docker-compose 内部 Redis/DB 通信
#   4. 300 秒未确认进入网络隔离（VNC 恢复，不自动放开） + systemd 每 5 秒完整性检查，异常隔离
# ============================================================================

set -u
set -o pipefail

VERSION="3.1.3"
# 上传到 GitHub 后，可将下面地址改为你的 raw.githubusercontent.com 链接，即可支持 curl | bash 一键安装运行
RAW_URL="${VPS_FW_RAW_URL:-https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/vps-fw.sh}"
# 必须在顶层取值：管道启动 (curl | bash) 时顶层 BASH_SOURCE 为空，而函数内会变成 "main"，
# 若在函数内判断，当前目录下名为 main 的文件会被误当作脚本本体安装。
SCRIPT_SELF="${BASH_SOURCE[0]:-}"

EXEC_PATH="/usr/local/sbin/vps-fw"
BIN_LINK="/usr/local/bin/fw"
CONF_DIR="/etc/vps-fw"
LOCK_FILE="/run/vps-fw.lock"
GUARD_LOCK_FILE="/run/vps-fw-guard.lock"
GUARD_UNIT="vps-fw-quarantine.service"
WATCH_BUSY_FILE="/run/vps-fw-watch-busy.since"
TABLE_NAME="vps_fw"

DEMO_MODE=0
DEMO_TMP=""
DRAFT_DIR=""
OWNED_DRAFT_DIR=""
CHANGES_PENDING=0

# ---------- 终端色彩与排版工具 ----------
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_WHITE=$'\033[37m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
  C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_WHITE=""
fi

info()  { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf '%s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '%s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g'
}

# 计算含中文 UTF-8 字符串的终端显示宽度（兼容 macOS Bash 3.2 与 Linux Bash 5）
display_width() {
  local clean
  clean="$(strip_ansi "$1")"
  # 用 LC_ALL=C 逐字节解析 UTF-8 码点，100% 跨平台不依赖 locale
  LC_ALL=C awk -v s="$clean" 'BEGIN {
    for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    w = 0; i = 1; n = length(s)
    while (i <= n) {
      b1 = ord[substr(s, i, 1)]
      if (b1 < 128) {
        w += 1; i += 1
      } else if (b1 >= 192 && b1 < 224) {
        w += 1; i += 2
      } else if (b1 >= 224 && b1 < 240) {
        b2 = ord[substr(s, i+1, 1)]
        b3 = ord[substr(s, i+2, 1)]
        cp = (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
        # 框线/几何符号/箭头 U+2000..U+27FF 为宽度 1；CJK/全角为宽度 2
        if ((cp >= 8192 && cp <= 10239) || cp == 9679 || cp == 9675) {
          w += 1
        } else if ((cp >= 11904 && cp <= 55295) || (cp >= 63744 && cp <= 65519)) {
          w += 2
        } else {
          w += 1
        }
        i += 3
      } else if (b1 >= 240) {
        w += 2; i += 4
      } else {
        w += 1; i += 1
      }
    }
    print w
  }'
}

repeat_char() {
  local ch="$1" count="$2" out=""
  local i=0
  while (( i < count )); do
    out+="$ch"
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

pad_right() {
  local text="$1" target="$2"
  local w pad
  w="$(display_width "$text")"
  pad=$(( target - w ))
  printf '%s' "$text"
  if (( pad > 0 )); then
    printf '%*s' "$pad" ''
  fi
}

truncate_str() {
  local text="$1" maxw="$2"
  local w
  w="$(display_width "$text")"
  if (( w <= maxw )); then
    printf '%s' "$text"
    return
  fi
  LC_ALL=C awk -v s="$text" -v maxw="$maxw" 'BEGIN {
    for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    cw = 0; i = 1; n = length(s); out = ""
    while (i <= n) {
      b1 = ord[substr(s, i, 1)]
      if (b1 < 128) {
        step = 1; chw = 1
      } else if (b1 >= 192 && b1 < 224) {
        step = 2; chw = 1
      } else if (b1 >= 224 && b1 < 240) {
        b2 = ord[substr(s, i+1, 1)]
        b3 = ord[substr(s, i+2, 1)]
        cp = (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
        if ((cp >= 8192 && cp <= 10239) || cp == 9679 || cp == 9675) {
          chw = 1
        } else if ((cp >= 11904 && cp <= 55295) || (cp >= 63744 && cp <= 65519)) {
          chw = 2
        } else {
          chw = 1
        }
        step = 3
      } else if (b1 >= 240) {
        step = 4; chw = 2
      } else {
        step = 1; chw = 1
      }
      if (cw + chw > maxw - 2) break
      out = out substr(s, i, step)
      cw += chw
      i += step
    }
    printf "%s..", out
  }'
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

clear_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H'
  fi
}

pause_prompt() {
  if [[ -t 0 ]]; then
    printf '\n  %s按回车键继续...%s' "$C_DIM" "$C_RESET"
    read -r _
  fi
}

ask_yesno() {
  local msg="$1" default="${2:-n}" ans prompt
  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi
  printf '  %s %s: ' "$msg" "$prompt"
  read -r ans || return 1
  ans="$(to_lower "$(trim "$ans")")"
  if [[ -z "$ans" ]]; then
    [[ "$default" == "y" ]]
    return $?
  fi
  [[ "$ans" == "y" || "$ans" == "yes" || "$ans" == "1" ]]
}

# ---------- 路径与配置读写 ----------
fprint_file() { printf '%s/live.sha256' "$1"; }
pend_file()   { printf '%s/pending.state' "$1"; }

# 全局配置变量
CFG_WAN_IF="eth0"
CFG_PING_ALLOW="1"
CFG_OUTBOUND_POLICY="accept"
CFG_DOCKER_TO_HOST="drop"
CFG_DOCKER_HOST_DNS="1"
CFG_SAFE_ROLLBACK="1"
CFG_ROLLBACK_SECS="300"
CFG_TRUSTED_IFS=""
CFG_NEXT_ID="1"
CFG_SSH_PORT="22"
  CFG_SSH_MODE="none"
  CFG_SSH_BLOCK=""
  CFG_SSH_SOURCES=""

load_conf() {
  local dir="${1:-$CONF_DIR}"
  local f k v seen="," required
  f="$(conf_file "$dir")"
  CFG_WAN_IF="$(detect_wan_if)"
  CFG_PING_ALLOW="1"
  CFG_OUTBOUND_POLICY="accept"
  CFG_DOCKER_TO_HOST="drop"
  CFG_DOCKER_HOST_DNS="1"
  CFG_SAFE_ROLLBACK="1"
  CFG_ROLLBACK_SECS="300"
  CFG_TRUSTED_IFS=""
  CFG_NEXT_ID="1"
  CFG_SSH_PORT="22"
  CFG_SSH_MODE="none"
  CFG_SSH_BLOCK=""
  CFG_SSH_SOURCES=""
  [[ -f "$f" ]] || return 1
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    [[ "$seen" != *",$k,"* && "$v" == \"*\" ]] || { err "配置重复或格式不正确: $k"; return 1; }
    seen+="$k,"
    v="${v#\"}"
    v="${v%\"}"
    case "$k" in
      WAN_IF)          CFG_WAN_IF="$v" ;;
      PING_ALLOW)      CFG_PING_ALLOW="$v" ;;
      OUTBOUND_POLICY) CFG_OUTBOUND_POLICY="$v" ;;
      DOCKER_TO_HOST)  CFG_DOCKER_TO_HOST="$v" ;;
      DOCKER_HOST_DNS) CFG_DOCKER_HOST_DNS="$v" ;;
      SAFE_ROLLBACK)   CFG_SAFE_ROLLBACK="$v" ;;
      ROLLBACK_SECS)   CFG_ROLLBACK_SECS="$v" ;;
      TRUSTED_IFS)     CFG_TRUSTED_IFS="$v" ;;
      NEXT_ID)         CFG_NEXT_ID="$v" ;;
      SSH_PORT)        CFG_SSH_PORT="$v" ;;
      SSH_MODE)        CFG_SSH_MODE="$v" ;;
      SSH_BLOCK)       CFG_SSH_BLOCK="$v" ;;
      SSH_SOURCES)     CFG_SSH_SOURCES="$v" ;;
      SSH_DENY_FIRST)  : ;; # legacy option: ordinary rules are no longer promoted
      *) err "未知配置项: $k"; return 1 ;;
    esac
  done < "$f"
  for required in WAN_IF PING_ALLOW OUTBOUND_POLICY DOCKER_TO_HOST DOCKER_HOST_DNS ROLLBACK_SECS TRUSTED_IFS NEXT_ID SSH_PORT; do
    [[ "$seen" == *",$required,"* ]] || { err "配置缺少字段: $required"; return 1; }
  done
  return 0
}

save_conf() {
  local dir="${1:-$CONF_DIR}"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1
  local tmp
  tmp="$(mktemp "$dir/.fw.conf.XXXXXX")" || return 1
  cat > "$tmp" <<EOF
WAN_IF="$CFG_WAN_IF"
PING_ALLOW="$CFG_PING_ALLOW"
OUTBOUND_POLICY="$CFG_OUTBOUND_POLICY"
DOCKER_TO_HOST="$CFG_DOCKER_TO_HOST"
DOCKER_HOST_DNS="$CFG_DOCKER_HOST_DNS"
SAFE_ROLLBACK="$CFG_SAFE_ROLLBACK"
ROLLBACK_SECS="$CFG_ROLLBACK_SECS"
TRUSTED_IFS="$CFG_TRUSTED_IFS"
NEXT_ID="$CFG_NEXT_ID"
SSH_PORT="$CFG_SSH_PORT"
SSH_MODE="$CFG_SSH_MODE"
SSH_BLOCK="$CFG_SSH_BLOCK"
SSH_SOURCES="$CFG_SSH_SOURCES"
EOF
  [[ $? == 0 ]] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$(conf_file "$dir")"
}

# ---------- 网络与系统环境探测 ----------
detect_os_name() {
  if [[ -r /etc/os-release ]]; then
    local name=""
    name="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
    [[ -n "$name" ]] && { printf '%s' "$name"; return; }
  fi
  uname -sr
}

detect_wan_if() {
  local dev=""
  if command -v ip >/dev/null 2>&1; then
    dev="$(ip -o -4 route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$dev" ]]; then
      dev="$(ip -o -6 route show to default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
  fi
  if [[ -z "$dev" && -d /sys/class/net ]]; then
    local p b
    for p in /sys/class/net/*; do
      b="${p##*/}"
      case "$b" in
        lo|docker*|br-*|veth*|virbr*|wg*|wt*|tailscale*|tun*|tap*|podman*|cni*) continue ;;
        *) dev="$b"; break ;;
      esac
    done
  fi
  if [[ -z "$dev" ]] && command -v route >/dev/null 2>&1; then
    dev="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  fi
  printf '%s' "${dev:-eth0}"
}

detect_wan_ips() {
  local wan="${1:-$CFG_WAN_IF}" ips=""
  if command -v ip >/dev/null 2>&1; then
    ips="$(ip -o -4 addr show dev "$wan" scope global 2>/dev/null | awk '{split($4,a,"/"); printf "%s ",a[1]}')"
    local ip6
    ip6="$(ip -o -6 addr show dev "$wan" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    [[ -n "$ip6" ]] && ips="${ips}${ip6}"
  fi
  ips="$(trim "$ips")"
  printf '%s' "${ips:-未检测到}"
}

detect_ssh_port() {
  local p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      printf '%s' "$p"
      return
    fi
  fi
  if command -v ss >/dev/null 2>&1; then
    p="$(ss -tlnp 2>/dev/null | awk '/sshd|ssh\.socket/{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      printf '%s' "$p"
      return
    fi
  fi
  if [[ -r /etc/ssh/sshd_config ]]; then
    p="$(awk 'BEGIN{IGNORECASE=1} /^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      printf '%s' "$p"
      return
    fi
  fi
  printf '22'
}

detect_ssh_client_ip() {
  local ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="$(awk '{print $1}' <<< "$SSH_CONNECTION")"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="$(awk '{print $1}' <<< "$SSH_CLIENT")"
  fi
  printf '%s' "$ip"
}

# ---------- 参数合法性校验 ----------
validate_iface() {
  local x="$1"
  [[ "$x" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]]
}

# normalize_* 把结果写入全局 NORM_OUT 且不产生任何子进程：
# 守护审计每 5 秒校验整个规则库，逐条 fork 会在规则多时拖垮 CPU 并触发审计超时隔离。
NORM_OUT=""
normalize_ports() {
  local raw="$1" out="" tok a b
  local -a parts=()
  NORM_OUT=""
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "$raw" in
    [aA][nN][yY]|\*|[aA][lL][lL]) NORM_OUT="any"; return 0 ;;
  esac
  raw="${raw//，/,}"
  raw="${raw// /,}"
  IFS=',' read -r -a parts <<< "$raw"
  local seen=","
  for tok in "${parts[@]}"; do
    [[ -z "$tok" ]] && continue
    if [[ "$tok" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      a="${BASH_REMATCH[1]}"
      b="${BASH_REMATCH[2]}"
      (( 10#$a >= 1 && 10#$b <= 65535 && 10#$a <= 10#$b )) || return 1
      tok="$((10#$a))-$((10#$b))"
      (( 10#$a == 10#$b )) && tok="$((10#$a))"
    elif [[ "$tok" =~ ^[0-9]{1,5}$ ]]; then
      a="$tok"
      (( 10#$a >= 1 && 10#$a <= 65535 )) || return 1
      tok="$((10#$a))"
    else
      return 1
    fi
    if [[ "$seen" != *",$tok,"* ]]; then
      seen+="$tok,"
      out+="${out:+,}$tok"
    fi
  done
  [[ -n "$out" ]] || return 1
  NORM_OUT="$out"
}

validate_ports() {
  normalize_ports "$1" || return 1
  printf '%s' "$NORM_OUT"
}

validate_ipv4_cidr() {
  local s="$1" ip mask=32
  if [[ "$s" == */* ]]; then
    ip="${s%%/*}"
    mask="${s#*/}"
    # 不接受前导零：nft 按 C 语言规则解析数字，/010 会被当作八进制
    [[ "$mask" =~ ^(0|[1-9][0-9]?)$ ]] && (( mask <= 32 )) || return 1
  else
    ip="$s"
  fi
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
  local oct
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$oct" == 0 || "$oct" != 0* ]] || return 1
  done
  (( 10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255 ))
}

normalize_cidrs() {
  local raw="$1" tok out="" seen=","
  local -a parts=()
  NORM_OUT=""
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  raw="${raw//，/,}"
  raw="${raw//[[:space:]]/,}"
  [[ -z "$raw" ]] && return 1
  IFS=',' read -r -a parts <<< "$raw"
  for tok in "${parts[@]}"; do
    [[ -z "$tok" ]] && continue
    case "$tok" in
      [aA][nN][yY]|\*|[aA][lL][lL])
        if (( ${#parts[@]} > 1 )); then
          return 1
        fi
        NORM_OUT="any"
        return 0
        ;;
    esac
    if validate_ipv4_cidr "$tok" || validate_ipv6_cidr "$tok"; then
      if [[ "$seen" != *",$tok,"* ]]; then
        seen+="$tok,"
        out+="${out:+,}$tok"
      fi
    else
      return 1
    fi
  done
  [[ -n "$out" ]] || return 1
  NORM_OUT="$out"
}

validate_cidrs() {
  normalize_cidrs "$1" || return 1
  printf '%s' "$NORM_OUT"
}

sanitize_comment() {
  local c
  c="$(trim "$1")"
  c="${c//|//}"
  c="$(printf '%s' "$c" | tr -d '\r\n\t')"
  printf '%s' "${c:-未命名}"
}

# ---------- 规则数据库操作 (ID|ENABLED|ACTION|DIR|SCOPE|PROTO|PORTS|CIDR|COMMENT) ----------
add_rule_to_dir() {
  local dir="$1" enabled="$2" action="$3" rdir="$4" scope="$5" proto="$6" ports="$7" cidr="$8" comment="$9"
  load_conf "$dir" >/dev/null 2>&1 || return 1
  [[ "$CFG_NEXT_ID" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  local rid="$CFG_NEXT_ID"
  CFG_NEXT_ID=$(( CFG_NEXT_ID + 1 ))
  save_conf "$dir" || return 1
  local rf
  rf="$(rules_file "$dir")"
  touch "$rf" || return 1
  chmod 600 "$rf" || return 1
  # Imported databases may have a valid final row without LF. Separate the next row.
  if [[ -s "$rf" && -n "$(tail -c 1 "$rf")" ]]; then
    printf '\n' >> "$rf" || return 1
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$rid" "$enabled" "$action" "$rdir" "$scope" "$proto" "$ports" "$cidr" "$(sanitize_comment "$comment")" >> "$rf" || return 1
  printf '%s' "$rid"
}

rule_exists_in_dir() {
  local dir="$1" rid="$2" rf
  rf="$(rules_file "$dir")"
  [[ "$rid" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  [[ -f "$rf" ]] && grep -qE "^${rid}\|" "$rf"
}

# ---------- nftables 规则编译器 ----------
emit_rule_lines() {
  local out_file="$1" indent="$2" prefix="$3" dir="$4" scope="$5" action="$6" proto="$7" ports="$8" cidr="$9" rid="${10}" is_dnat="${11}"
  local -a cidrs=() protos=() port_list=()
  if [[ "$cidr" == "any" ]]; then
    cidrs=("any")
  else
    IFS=',' read -r -a cidrs <<< "$cidr"
  fi
  if [[ "$proto" == "both" ]]; then
    protos=("tcp" "udp")
  else
    protos=("$proto")
  fi
  if [[ "$ports" == "any" ]]; then
    port_list=("any")
  else
    IFS=',' read -r -a port_list <<< "$ports"
  fi

  local addr_key="saddr"
  [[ "$dir" == "out" ]] && addr_key="daddr"

  local c ip_pred ip_ver p pt port_pred
  for c in "${cidrs[@]}"; do
    ip_pred=""
    ip_ver="both"
    if [[ "$c" != "any" ]]; then
      if [[ "$c" == *:* ]]; then
        ip_pred="ip6 $addr_key $c"
        ip_ver="6"
      else
        ip_pred="ip $addr_key $c"
        ip_ver="4"
      fi
    fi

    for p in "${protos[@]}"; do
      if [[ "$p" == "icmp" ]]; then
        if [[ "$ip_ver" == "both" || "$ip_ver" == "4" ]]; then
          printf '%s%s%smeta nfproto ipv4 icmp type echo-request ct state new counter %s comment "rule-%s"\n' \
            "$indent" "${prefix:+$prefix }" "${ip_pred:+$ip_pred }" "$action" "$rid" >> "$out_file" || return 1
        fi
        if [[ "$ip_ver" == "both" || "$ip_ver" == "6" ]]; then
          printf '%s%s%smeta nfproto ipv6 icmpv6 type echo-request ct state new counter %s comment "rule-%s"\n' \
            "$indent" "${prefix:+$prefix }" "${ip_pred:+$ip_pred }" "$action" "$rid" >> "$out_file" || return 1
        fi
        continue
      fi

      if [[ "$p" == "any" ]]; then
        printf '%s%s%sct state new counter %s comment "rule-%s"\n' \
          "$indent" "${prefix:+$prefix }" "${ip_pred:+$ip_pred }" "$action" "$rid" >> "$out_file" || return 1
        continue
      fi

      for pt in "${port_list[@]}"; do
        if [[ "$pt" == "any" ]]; then
          port_pred="meta l4proto $p"
        elif [[ "$is_dnat" == "1" ]]; then
          # Docker -p 端口映射时包已被 DNAT，需通过 conntrack 原始目的端口匹配公网暴露端口
          port_pred="meta l4proto $p ct original proto-dst $pt"
        else
          port_pred="$p dport $pt"
        fi
        printf '%s%s%s%s ct state new counter %s comment "rule-%s"\n' \
          "$indent" "${prefix:+$prefix }" "${ip_pred:+$ip_pred }" "$port_pred" "$action" "$rid" >> "$out_file" || return 1
      done
    done
  done
}

validate_network_roles() {
  local wan="$1" trusted="$2" tif
  [[ "$wan" != lo ]] || { err "公网接口不能是 lo"; return 1; }
  validate_iface "$wan" || { err "非法公网接口"; return 1; }
  local -a roles=()
  if [[ -n "$trusted" ]]; then
    IFS=',' read -r -a roles <<< "$trusted"
    for tif in "${roles[@]}"; do
      tif="$(trim "$tif")"
      validate_iface "$tif" || { err "非法信任接口"; return 1; }
      [[ "$tif" != "$wan" ]] || { err "公网接口不能同时是信任接口: $wan"; return 1; }
    done
  fi
}

validate_render_config() {
  validate_network_roles "$CFG_WAN_IF" "$CFG_TRUSTED_IFS" || return 1
  if [[ -n "$CFG_SSH_BLOCK" ]]; then
    local b
    b="$(validate_cidrs "$CFG_SSH_BLOCK")" && [[ "$b" != any ]] || { err "SSH 黑名单必须指定地址"; return 1; }
  fi
  [[ "$CFG_OUTBOUND_POLICY" == accept || "$CFG_OUTBOUND_POLICY" == drop ]] || return 1
  [[ "$CFG_DOCKER_TO_HOST" == accept || "$CFG_DOCKER_TO_HOST" == drop ]] || return 1
  [[ "$CFG_PING_ALLOW" == 0 || "$CFG_PING_ALLOW" == 1 ]] || return 1
  [[ "$CFG_DOCKER_HOST_DNS" == 0 || "$CFG_DOCKER_HOST_DNS" == 1 ]] || return 1
  [[ "$CFG_ROLLBACK_SECS" =~ ^[1-9][0-9]{0,3}$ ]] && (( CFG_ROLLBACK_SECS <= 3600 )) || return 1
  [[ "$CFG_NEXT_ID" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
  [[ "$CFG_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( CFG_SSH_PORT<=65535 )) || return 1
  case "$CFG_SSH_MODE" in
    none) ;;
    hidden|whitelist)
      [[ "$CFG_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( CFG_SSH_PORT <= 65535 )) || { err "SSH 端口必须是单个有效端口"; return 1; }
      if [[ "$CFG_SSH_MODE" == whitelist ]]; then
        local normalized
        normalized="$(validate_cidrs "$CFG_SSH_SOURCES")" && [[ "$normalized" != any ]] || { err "SSH 白名单配置无效"; return 1; }
      fi
      ;;
    *) err "SSH 模式无效"; return 1 ;;
  esac
}

render_nft_ruleset() {
  local dir="$1" target="$2" tmp
  load_conf "$dir" || { err "无法读取配置"; return 1; }
  validate_render_config && validate_rule_database "$dir" || return 1
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  if ! ( set -e; render_nft_body "$dir" "$tmp" ); then
    rm -f -- "$tmp"; err "规则生成失败"; return 1
  fi
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
}

render_nft_body() {
  local dir="$1" out_file="$2"
  load_conf "$dir" >/dev/null 2>&1 || return 1
  local rf wan="$CFG_WAN_IF"
  rf="$(rules_file "$dir")"

  cat > "$out_file" <<EOF
#!/usr/sbin/nft -f
# VPS-FW 自动生成规则表，请勿手动编辑
# 仅管理独立表 inet ${TABLE_NAME}，绝不执行 flush ruleset，绝不破坏 Docker/VPN 原有表
table inet $TABLE_NAME
delete table inet $TABLE_NAME

table inet $TABLE_NAME {
  chain host_input {
    type filter hook input priority -150; policy drop;
    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    iifname "$wan" meta nfproto ipv4 udp sport 67 udp dport 68 accept
    iifname "$wan" meta nfproto ipv6 udp sport 547 udp dport 546 accept
    iifname "$wan" meta nfproto ipv6 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    iifname "$wan" ip6 saddr fe80::/10 icmpv6 type mld-listener-query accept
    iifname "$wan" meta nfproto ipv4 icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
EOF
  [[ $? == 0 ]] || return 1

  # 信任内网管理网卡 (Tailscale / WireGuard / 私有 VPC)
  if [[ -n "$CFG_TRUSTED_IFS" ]]; then
    local -a tifs=()
    local tif
    IFS=',' read -r -a tifs <<< "$CFG_TRUSTED_IFS"
    for tif in "${tifs[@]}"; do
      tif="$(trim "$tif")"
      [[ -n "$tif" ]] && printf '    iifname "%s" accept comment "trusted-if"\n' "$tif" >> "$out_file" || return 1
    done
  fi

  # 容器访问宿主机策略
  if [[ "$CFG_DOCKER_TO_HOST" == "accept" ]]; then
    cat >> "$out_file" <<EOF
    iifname != "$wan" iifname "docker0" accept comment "docker-to-host"
    iifname != "$wan" iifname "br-*" accept comment "docker-to-host"
    iifname != "$wan" iifname "podman*" accept comment "docker-to-host"
EOF
  [[ $? == 0 ]] || return 1
  elif [[ "$CFG_DOCKER_HOST_DNS" == "1" ]]; then
    cat >> "$out_file" <<EOF
    iifname != "$wan" iifname "docker0" udp dport 53 accept comment "docker-host-dns"
    iifname != "$wan" iifname "docker0" tcp dport 53 accept comment "docker-host-dns"
    iifname != "$wan" iifname "br-*" udp dport 53 accept comment "docker-host-dns"
    iifname != "$wan" iifname "br-*" tcp dport 53 accept comment "docker-host-dns"
    iifname != "$wan" iifname "podman*" udp dport 53 accept comment "docker-host-dns"
    iifname != "$wan" iifname "podman*" tcp dport 53 accept comment "docker-host-dns"
EOF
  [[ $? == 0 ]] || return 1
  fi

  for bridge_pattern in docker0 'br-*' 'podman*'; do
    printf '    iifname != "%s" iifname "%s" ip6 hoplimit 255 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept\n' "$wan" "$bridge_pattern" >> "$out_file" || return 1
  done

  # Explicit blacklist and whitelist gate. Generic rules retain their original order.
  if [[ "$CFG_SSH_MODE" != none ]]; then
    if [[ -n "$CFG_SSH_BLOCK" ]]; then
      emit_rule_lines "$out_file" "    " "iifname \"$wan\"" in host drop tcp "$CFG_SSH_PORT" "$CFG_SSH_BLOCK" ssh-blacklist 0 || return 1
    fi
    printf '    iifname "%s" tcp dport %s ct state new jump ssh_gate\n' "$wan" "$CFG_SSH_PORT" >> "$out_file" || return 1
  fi

  # 用户入站规则 (宿主机)
  if [[ -f "$rf" ]]; then
    local rid enabled action rdir scope proto ports cidr comment
    while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
      [[ -z "$rid" || "$rid" == \#* ]] && continue
      [[ "$enabled" != "1" ]] && continue
      [[ "$rdir" != "in" ]] && continue
      [[ "$scope" == "all" || "$scope" == "host" ]] || continue
      emit_rule_lines "$out_file" "    " "iifname \"$wan\"" "$rdir" "$scope" "$action" "$proto" "$ports" "$cidr" "$rid" "0" || return 1
    done < "$rf"
  fi

  # A whitelist grants SSH only after ordinary ordered user rules were consulted.
  if [[ "$CFG_SSH_MODE" == whitelist ]]; then
    emit_rule_lines "$out_file" "    " "iifname \"$wan\"" in host accept tcp "$CFG_SSH_PORT" "$CFG_SSH_SOURCES" ssh-allow 0 || return 1
  fi

  # 公网 Ping 默认控制 (放在用户规则之后，便于先执行针对性封禁 IP 规则)
  if [[ "$CFG_PING_ALLOW" == "1" ]]; then
    cat >> "$out_file" <<EOF
    iifname "$wan" meta nfproto ipv4 icmp type echo-request limit rate 10/second burst 20 packets accept comment "ping-allow"
    iifname "$wan" meta nfproto ipv6 icmpv6 type echo-request limit rate 10/second burst 20 packets accept comment "ping-allow"
EOF
  [[ $? == 0 ]] || return 1
  fi

  cat >> "$out_file" <<EOF
    counter drop comment "default-host-drop"
  }

  chain ssh_gate {
EOF
  [[ $? == 0 ]] || return 1
  if [[ "$CFG_SSH_MODE" == whitelist ]]; then
    emit_rule_lines "$out_file" "    " "" in host return tcp "$CFG_SSH_PORT" "$CFG_SSH_SOURCES" ssh-gate-return 0 || return 1
  fi
  cat >> "$out_file" <<'EOF'
    counter drop comment "ssh-gate-deny"
  }

  # Docker / 容器 DNAT 入站（匹配原始公网映射端口，防止容器 -p 端口绕过）
  chain forward_dnat_in {
EOF
  [[ $? == 0 ]] || return 1
  if [[ -f "$rf" ]]; then
    while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
      [[ -z "$rid" || "$rid" == \#* ]] && continue
      [[ "$enabled" != "1" ]] && continue
      [[ "$rdir" != "in" ]] && continue
      [[ "$scope" == "all" || "$scope" == "docker" ]] || continue
      emit_rule_lines "$out_file" "    " "" "$rdir" "$scope" "$action" "$proto" "$ports" "$cidr" "$rid" "1" || return 1
    done < "$rf"
  fi
  cat >> "$out_file" <<'EOF'
    counter drop comment "default-docker-dnat-drop"
  }

  # 非 DNAT 路由容器入站（例如 IPv6 直通容器）
  chain forward_routed_in {
EOF
  [[ $? == 0 ]] || return 1
  if [[ -f "$rf" ]]; then
    while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
      [[ -z "$rid" || "$rid" == \#* ]] && continue
      [[ "$enabled" != "1" ]] && continue
      [[ "$rdir" != "in" ]] && continue
      [[ "$scope" == "all" || "$scope" == "docker" ]] || continue
      emit_rule_lines "$out_file" "    " "" "$rdir" "$scope" "$action" "$proto" "$ports" "$cidr" "$rid" "0" || return 1
    done < "$rf"
  fi
  cat >> "$out_file" <<EOF
    counter drop comment "default-docker-routed-drop"
  }

  # 容器出站到公网
  chain forward_out {
    meta nfproto ipv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    meta nfproto ipv4 icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
EOF
  [[ $? == 0 ]] || return 1
  if [[ -f "$rf" ]]; then
    while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
      [[ -z "$rid" || "$rid" == \#* ]] && continue
      [[ "$enabled" != "1" ]] && continue
      [[ "$rdir" != "out" ]] && continue
      [[ "$scope" == "all" || "$scope" == "docker" ]] || continue
      emit_rule_lines "$out_file" "    " "" "$rdir" "$scope" "$action" "$proto" "$ports" "$cidr" "$rid" "0" || return 1
    done < "$rf"
  fi
  cat >> "$out_file" <<EOF
    counter $CFG_OUTBOUND_POLICY comment "default-docker-out"
  }

  chain routed_forward {
    type filter hook forward priority -150; policy drop;
    ct state established,related accept
    ct state invalid drop
    # 放行容器网桥内部互访（独立通配符规则，避免在匿名集合 {} 中使用通配符导致旧版 nft 报错或匹配失败）
    iifname != "$wan" iifname "docker0" oifname != "$wan" oifname "docker0" accept comment "container-mesh"
    iifname != "$wan" iifname "br-*" oifname != "$wan" oifname "br-*" accept comment "container-mesh"
    iifname != "$wan" iifname "podman*" oifname != "$wan" oifname "podman*" accept comment "container-mesh"
    # 来自公网的流量：DNAT 映射走 forward_dnat_in，其余直通走 forward_routed_in
    iifname "$wan" ct status dnat goto forward_dnat_in
    iifname "$wan" goto forward_routed_in
    # 容器发往公网的出站流量
    iifname != "$wan" iifname "docker0" oifname "$wan" goto forward_out
    iifname != "$wan" iifname "br-*" oifname "$wan" goto forward_out
    iifname != "$wan" iifname "podman*" oifname "$wan" goto forward_out
    counter drop comment "default-forward-drop"
  }

  chain host_output {
    type filter hook output priority -150; policy $CFG_OUTBOUND_POLICY;
    oifname "lo" accept
    ct state established,related accept
    ct state invalid drop
    oifname "$wan" meta nfproto ipv4 udp sport 68 udp dport 67 accept
    oifname "$wan" meta nfproto ipv6 udp sport 546 udp dport 547 accept
    oifname "$wan" meta nfproto ipv6 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
    oifname "$wan" meta nfproto ipv6 icmpv6 type { mld-listener-report, mld-listener-done, mld2-listener-report } accept
    oifname "$wan" meta nfproto ipv4 icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
EOF
  [[ $? == 0 ]] || return 1
  for bridge_pattern in docker0 'br-*' 'podman*'; do
    printf '    oifname != "%s" oifname "%s" ip6 hoplimit 255 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept\n' "$wan" "$bridge_pattern" >> "$out_file" || return 1
  done
  # 信任接口不隐式豁免出站；仅保留 IPv6 邻居发现控制报文。
  local out_tif
  local -a out_tifs=()
  IFS=',' read -r -a out_tifs <<< "$CFG_TRUSTED_IFS"
  for out_tif in ${out_tifs[@]+"${out_tifs[@]}"}; do
    out_tif="$(trim "$out_tif")"
    [[ -n "$out_tif" ]] || continue
    printf '    oifname "%s" ip6 hoplimit 255 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept\n' "$out_tif" >> "$out_file" || return 1
  done
  if [[ -f "$rf" ]]; then
    while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
      [[ -z "$rid" || "$rid" == \#* ]] && continue
      [[ "$enabled" != "1" ]] && continue
      [[ "$rdir" != "out" ]] && continue
      [[ "$scope" == "all" || "$scope" == "host" ]] || continue
      emit_rule_lines "$out_file" "    " "" "$rdir" "$scope" "$action" "$proto" "$ports" "$cidr" "$rid" "0" || return 1
    done < "$rf"
  fi
  cat >> "$out_file" <<EOF
    counter $CFG_OUTBOUND_POLICY comment "default-host-out"
  }
}
EOF
  [[ $? == 0 ]] || return 1
  chmod 600 "$out_file" || return 1
}

# ---------- 内核指纹、应用、回滚与 systemd 守护 ----------
live_table_hash() {
  command -v nft >/dev/null 2>&1 || return 1
  local out
  out="$(nft list table inet "$TABLE_NAME" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  # 归一化动态包计数后再算 sha256，用于检测规则篡改/丢失
  printf '%s\n' "$out" | sed -E 's/packets [0-9]+ bytes [0-9]+/packets 0 bytes 0/g' | hash_stdin
}

drop_packet_counts() {
  if (( DEMO_MODE == 1 )); then
    printf '1284 492'
    return
  fi
  command -v nft >/dev/null 2>&1 || { printf '0 0'; return; }
  local out host_drops fwd_drops
  out="$(nft list table inet "$TABLE_NAME" 2>/dev/null)" || { printf '0 0'; return; }
  host_drops="$(printf '%s\n' "$out" | awk '/default-host-drop/{for(i=1;i<=NF;i++) if($i=="packets"){s+=$(i+1)}} END{printf "%d", s+0}')"
  fwd_drops="$(printf '%s\n' "$out" | awk '/default-(docker-dnat|docker-routed|forward)-drop/{for(i=1;i<=NF;i++) if($i=="packets"){s+=$(i+1)}} END{printf "%d", s+0}')"
  printf '%s %s' "$host_drops" "$fwd_drops"
}

port_in_spec() {
  local spec="$1" target="$2" tok a b
  [[ "$spec" == "any" ]] && return 0
  IFS=',' read -r -a parts <<< "$spec"
  for tok in "${parts[@]}"; do
    if [[ "$tok" == *-* ]]; then
      a="${tok%%-*}"; b="${tok#*-}"
      (( target >= a && target <= b )) && return 0
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( target == tok )) && return 0
    fi
  done
  return 1
}

# 检查规则列表中给定方向、作用域、协议、端口的最终策略 (accept / drop / default-drop)
evaluate_port_decision() {
  local dir_check="$1" scope_need="$2" proto_need="$3" port_num="$4"
  local rf
  rf="$(rules_file "$dir_check")"
  [[ -f "$rf" ]] || { printf 'default-drop||'; return; }
  local rid enabled action rdir scope proto ports cidr comment
  while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
    [[ -z "$rid" || "$rid" == \#* || "$enabled" != "1" ]] && continue
    [[ "$rdir" != "in" ]] && continue
    if [[ "$scope" != "all" && "$scope" != "$scope_need" ]]; then
      continue
    fi
    if [[ "$proto" != "any" && "$proto" != "both" && "$proto" != "$proto_need" ]]; then
      continue
    fi
    if port_in_spec "$ports" "$port_num"; then
      printf '%s|%s|%s' "$action" "$rid" "$cidr"
      return
    fi
  done < "$rf"
  printf 'default-drop||'
}

# ---------- 冲突防火墙检测 ----------
check_conflicting_firewalls() {
  local found=() svc
  for svc in ufw firewalld netfilter-persistent; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      found+=("$svc")
    fi
  done
  if (( ${#found[@]} > 0 )); then
    warn "检测到系统正在运行其他防火墙服务: ${found[*]}"
    echo "  注意: Linux Netfilter 会同时执行多个防火墙表，若 ufw/firewalld 仍在拦截，"
    echo "        你在本面板放行的端口仍可能被 ufw 拦住。"
    if ask_yesno "是否停用并禁用冲突服务 (${found[*]})，交由 VPS-FW 统一管理？" "n"; then
      for svc in "${found[@]}"; do
        if [[ "$svc" == "ufw" ]] && command -v ufw >/dev/null 2>&1; then
          ufw --force disable >/dev/null 2>&1 || true
        fi
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
      done
      ok "已停用冲突服务: ${found[*]}"
    fi
  fi
}

# ---------- 草稿管理 ----------
init_draft_from_conf() {
  [[ -n "${OWNED_DRAFT_DIR:-}" && "$OWNED_DRAFT_DIR" != "$CONF_DIR" ]] && rm -rf -- "$OWNED_DRAFT_DIR"
  DRAFT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vps-fw-draft.XXXXXX")" || return 1
  OWNED_DRAFT_DIR="$DRAFT_DIR"
  if [[ -f "$(conf_file "$CONF_DIR")" ]]; then
    cp -f "$(conf_file "$CONF_DIR")" "$(conf_file "$DRAFT_DIR")" && cp -f "$(rules_file "$CONF_DIR")" "$(rules_file "$DRAFT_DIR")" || { err "保存配置不完整；请从 VNC 检查历史版本"; return 1; }
  else
    load_conf "$DRAFT_DIR" >/dev/null 2>&1 || true
    save_conf "$DRAFT_DIR" && touch "$(rules_file "$DRAFT_DIR")" || return 1
  fi
  CHANGES_PENDING=0
}

check_draft_dirty() {
  if [[ ! -f "$(conf_file "$CONF_DIR")" ]]; then
    CHANGES_PENDING=1
    return
  fi
  if ! cmp -s "$(conf_file "$DRAFT_DIR")" "$(conf_file "$CONF_DIR")" || \
     ! cmp -s "$(rules_file "$DRAFT_DIR")" "$(rules_file "$CONF_DIR")"; then
    CHANGES_PENDING=1
  else
    CHANGES_PENDING=0
  fi
}

# ---------- TUI 渲染组件 ----------
scope_label() {
  case "$1" in
    all)    printf '宿主机+容器' ;;
    host)   printf '仅宿主机' ;;
    docker) printf '仅Docker' ;;
    *)      printf '%s' "$1" ;;
  esac
}

dir_action_label() {
  local d="$1" a="$2"
  if [[ "$d" == "in" && "$a" == "accept" ]]; then
    printf '%s入站允许%s' "$C_GREEN" "$C_RESET"
  elif [[ "$d" == "in" && "$a" == "drop" ]]; then
    printf '%s入站拒绝%s' "$C_RED" "$C_RESET"
  elif [[ "$d" == "out" && "$a" == "accept" ]]; then
    printf '%s出站允许%s' "$C_CYAN" "$C_RESET"
  else
    printf '%s出站拒绝%s' "$C_YELLOW" "$C_RESET"
  fi
}

render_dashboard() {
  load_conf "$DRAFT_DIR" >/dev/null 2>&1 || true
  local os_name wan_ips live_h exp_h status_txt boot_txt watch_txt ping_txt out_txt d2h_txt trust_txt
  os_name="$(truncate_str "$(detect_os_name)" 30)"
  local max_ip_w=$(( 29 - ${#CFG_WAN_IF} ))
  (( max_ip_w < 8 )) && max_ip_w=8
  wan_ips="$(truncate_str "$(detect_wan_ips "$CFG_WAN_IF")" "$max_ip_w")"

  if (( DEMO_MODE == 1 )); then
    status_txt="${C_CYAN}● 演示沙箱模式 (不修改宿主机)${C_RESET}"
    boot_txt="${C_GREEN}● ON${C_RESET}"
    watch_txt="${C_GREEN}● ON (5s)${C_RESET}"
  else
    live_h="$(live_table_hash || true)"
    exp_h="$(cat "$(fprint_file "$CONF_DIR")" 2>/dev/null || true)"
    if [[ -f "$CONF_DIR/locked.state" ]]; then
      status_txt="${C_RED}✗ 已隔离：使用 VNC 恢复${C_RESET}"
    elif [[ ! -f "$(conf_file "$CONF_DIR")" ]]; then
      status_txt="${C_YELLOW}○ 未初始化 (仅草稿中)${C_RESET}"
    elif [[ -z "$live_h" ]]; then
      status_txt="${C_RED}✗ 危险: 内核规则缺失${C_RESET}"
    elif [[ "$live_h" != "$exp_h" ]]; then
      status_txt="${C_YELLOW}! 警告: 内核规则不一致${C_RESET}"
    else
      status_txt="${C_GREEN}● 运行中 (指纹已校验)${C_RESET}"
    fi
    if systemctl is-enabled --quiet vps-fw.service 2>/dev/null; then
      boot_txt="${C_GREEN}● ON${C_RESET}"
    else
      boot_txt="${C_RED}○ OFF${C_RESET}"
    fi
    if systemctl is-active --quiet vps-fw-watch.timer 2>/dev/null; then
      watch_txt="${C_GREEN}● ON (5s)${C_RESET}"
    else
      watch_txt="${C_YELLOW}○ OFF${C_RESET}"
    fi
  fi

  [[ "$CFG_PING_ALLOW" == "1" ]] && ping_txt="${C_GREEN}允许 (限速)${C_RESET}" || ping_txt="${C_YELLOW}静默禁Ping${C_RESET}"
  [[ "$CFG_OUTBOUND_POLICY" == "accept" ]] && out_txt="${C_GREEN}ACCEPT (默认允许)${C_RESET}" || out_txt="${C_RED}DROP (严格白名单)${C_RESET}"
  [[ "$CFG_DOCKER_TO_HOST" == "drop" ]] && d2h_txt="${C_GREEN}隔离 (仅DNS)${C_RESET}" || d2h_txt="${C_YELLOW}允许互访${C_RESET}"
  trust_txt="${CFG_TRUSTED_IFS:-无}"

  local drops host_drops fwd_drops
  drops="$(drop_packet_counts)"
  host_drops="${drops%% *}"
  fwd_drops="${drops##* }"

  local W=92
  local dline
  dline="$(repeat_char '═' "$W")"
  local top="╔${dline}╗"
  local mid="╠${dline}╣"
  local bot="╚${dline}╝"

  printf '%s%s%s\n' "$C_CYAN" "$top" "$C_RESET"
  local title_line="  ${C_BOLD}VPS-FW 严格模式防火墙面板 v${VERSION}${C_RESET}   ${C_DIM}[Debian 13 · nftables · 严格隔离]${C_RESET}"
  printf '%s║%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$title_line" "$W")" "$C_CYAN" "$C_RESET"
  printf '%s%s%s\n' "$C_CYAN" "$mid" "$C_RESET"

  local c1 c2
  c1="  系统环境 : ${C_WHITE}${os_name}${C_RESET}"
  c2="│ 公网网卡 : ${C_WHITE}${CFG_WAN_IF}${C_RESET} ${C_DIM}(${wan_ips})${C_RESET}"
  printf '%s║%s%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$c1" 46)" "$(pad_right "$c2" 46)" "$C_CYAN" "$C_RESET"

  c1="  防护状态 : $status_txt"
  c2="│ 开机自启 : $boot_txt   守护审计: $watch_txt"
  printf '%s║%s%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$c1" 46)" "$(pad_right "$c2" 46)" "$C_CYAN" "$C_RESET"

  c1="  入站策略 : ${C_GREEN}默认 DROP${C_RESET} │ 容器转发: ${C_GREEN}DROP${C_RESET}"
  c2="│ 出站策略 : $out_txt"
  printf '%s║%s%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$c1" 46)" "$(pad_right "$c2" 46)" "$C_CYAN" "$C_RESET"

  c1="  容器隔离 : $d2h_txt │ Ping: $ping_txt"
  c2="│ 信任内网 : ${C_CYAN}$(truncate_str "$trust_txt" 28)${C_RESET}"
  printf '%s║%s%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$c1" 46)" "$(pad_right "$c2" 46)" "$C_CYAN" "$C_RESET"

  c1="  拦截计数 : 宿主机已拦截 ${C_YELLOW}${host_drops}${C_RESET} 包"
  c2="│ 容器转发已拦截 ${C_YELLOW}${fwd_drops}${C_RESET} 包"
  printf '%s║%s%s%s%s║%s\n' "$C_CYAN" "$C_RESET" "$(pad_right "$c1" 46)" "$(pad_right "$c2" 46)" "$C_CYAN" "$C_RESET"

  printf '%s%s%s\n' "$C_CYAN" "$bot" "$C_RESET"

  # 提示条
  if (( DEMO_MODE == 0 )) && [[ -f "$CONF_DIR/locked.state" ]]; then
    local lock_reason
    lock_reason="$(head -n1 "$CONF_DIR/locked.state" 2>/dev/null || true)"
    printf '  %s[!] 隔离原因: %s -> VNC 中执行 fw restore；有未确认修改时用 [6] 重新应用或 fw recover 版本ID%s\n' "$C_RED$C_BOLD" "${lock_reason:-未记录（systemd 应急隔离）}" "$C_RESET"
  fi
  if [[ -f "$(pend_file "$CONF_DIR")" ]]; then
    local start_ep secs_tot elapsed rem
    start_ep="$(awk -F= '/^START_EPOCH=/{print $2; exit}' "$(pend_file "$CONF_DIR")")"
    secs_tot="$(awk -F= '/^SECS=/{print $2; exit}' "$(pend_file "$CONF_DIR")")"
    [[ "$start_ep" =~ ^[1-9][0-9]{0,11}$ && "$secs_tot" =~ ^[1-9][0-9]{0,3}$ ]] || { err "待确认状态损坏；审计将隔离网络"; return 1; }
    elapsed=$(( $(date +%s) - start_ep ))
    rem=$(( ${secs_tot:-300} - elapsed ))
    (( rem < 0 )) && rem=0
    printf '  %s[!] 已应用规则并等待确认（剩余 %s 秒将超时隔离） -> 请按 [6] 确认保存或执行 fw confirm%s\n' "$C_YELLOW$C_BOLD" "$rem" "$C_RESET"
  fi
  if (( CHANGES_PENDING == 1 )); then
    printf '  %s[*] 检测到未应用的草稿改动 -> 请按 [6] 应用规则使其在内核生效%s\n' "$C_MAGENTA$C_BOLD" "$C_RESET"
  fi
}

# Read-only synthetic display rows. SSH identifiers never enter rules.db.
ui_policy_rows() (
  local dir="$1" rf
  if load_conf "$dir" >/dev/null 2>&1; then
    case "$CFG_SSH_MODE" in
      whitelist) printf 'SSH|1|白名单|in|host|tcp|%s|%s|其他来源拒绝\n' "$CFG_SSH_PORT" "$CFG_SSH_SOURCES" ;;
      hidden) printf 'SSH|1|drop|in|host|tcp|%s|any|公网隐身；信任接口: %s；[4]管理\n' "$CFG_SSH_PORT" "${CFG_TRUSTED_IFS:-无}" ;;
      none) printf 'SSH|0|按规则|in|host|tcp|%s|—|按普通规则\n' "$CFG_SSH_PORT" ;;
    esac
    if [[ -n "$CFG_SSH_BLOCK" ]]; then
      printf 'SSH-B|%s|drop|in|host|tcp|%s|%s|SSH优先黑名单\n' "$( [[ "$CFG_SSH_MODE" == none ]] && echo 0 || echo 1 )" "$CFG_SSH_PORT" "$CFG_SSH_BLOCK"
    fi
  fi
  rf="$(rules_file "$dir")"
  [[ ! -f "$rf" ]] || cat "$rf"
  printf '\n'
)

render_rules_table() {
  local dir="${1:-$DRAFT_DIR}" base="$CONF_DIR" state="已保存"
  [[ ! -f "$(pend_file "$CONF_DIR")" ]] || state="待确认"
  [[ "$dir" != "$CONF_DIR" ]] || base="$dir"
  {
    awk -F'|' -v state="$state" '
      !NF || $0=="" || /^#/ {next}
      FILENAME==ARGV[1] {old[$1]=$0; ids[++n]=$1; next}
      {new[$1]=$0; order[++m]=$1}
      END {
        for(i=1;i<=n;i++) if(ids[i] in new) prev[++p]=ids[i]
        for(i=1;i<=m;i++) if(order[i] in old) rank[order[i]]=++q
        for(i=1;i<=p;i++) if(rank[prev[i]]!=i) moved[prev[i]]=1
        for(i=1;i<=m;i++) {
          id=order[i]
          if(!(id in old)) print "待新增|" new[id]
          else if(old[id]!=new[id]) {print "修改前|" old[id]; print "待修改|" new[id]}
          else print (moved[id]?"待排序":state) "|" new[id]
        }
        for(i=1;i<=n;i++) if(!(ids[i] in new)) print "待删除|" old[ids[i]]
      }' <(ui_policy_rows "$base") <(ui_policy_rows "$dir")
    local oldconf newconf
    oldconf="$(conf_file "$base")"; newconf="$(conf_file "$dir")"
    [[ -f "$oldconf" ]] || oldconf=/dev/null
    [[ -f "$newconf" ]] || newconf=/dev/null
    awk -F= '
      /^#/ || !NF || $1=="NEXT_ID" || /^SSH_/ {next}
      FILENAME==ARGV[1] {old[$1]=$2;next}
      {if(old[$1]!=$2) print "待设置|设置|1|配置|—|—|—|—|—|" $1 ": " old[$1] " → " $2}
    ' "$oldconf" "$newconf"
  } | ui_render_grid
}

# Wrap UTF-8 cells without hiding addresses, comments or removed rule details.
ui_render_grid() {
  LC_ALL=C awk -F'|' -v blue="$C_BLUE" -v reset="$C_RESET" -v yellow="$C_YELLOW" -v red="$C_RED" '
    function parts(s,w,a, i,b,step,cp,cw,line,k,ch) {
      for(k in a) delete a[k]
      line="";cw=0;k=1
      for(i=1;i<=length(s);i+=step) {
        b=ord[substr(s,i,1)];step=1;cp=1
        if(b>=240){step=4;cp=2} else if(b>=224){step=3;cp=2} else if(b>=192){step=2}
        ch=substr(s,i,step)
        if(ch=="—" || ch=="→") cp=1
        if(cw+cp>w){a[k++]=line;line="";cw=0}
        line=line ch;cw+=cp
      }
      a[k]=line;return k
    }
    function width(s, i,b,w) {
      for(i=1;i<=length(s);) {b=ord[substr(s,i,1)]; if(substr(s,i,3)=="—" || substr(s,i,3)=="→"){w++;i+=3} else if(b>=240){w+=2;i+=4} else if(b>=224){w+=2;i+=3} else if(b>=192){w++;i+=2} else {w++;i++}}
      return w
    }
    function row( color, i,j,k,n,max,cell,lines,key) {
      max=1;for(key in lines)delete lines[key]
      for(i=1;i<=9;i++){n=parts(v[i],w[i],cell);if(n>max)max=n;for(j=1;j<=n;j++)lines[i SUBSEP j]=cell[j]}
      for(j=1;j<=max;j++){printf "%s│%s",blue,color;for(i=1;i<=9;i++){key=i SUBSEP j;celltxt=lines[key];printf " %s%*s",celltxt,w[i]-width(celltxt),""}printf " %s│%s\n",blue,reset}
    }
    BEGIN {
      for(i=0;i<256;i++)ord[sprintf("%c",i)]=i
      split("6 4 10 10 8 12 22 12 18",w," ");total=10;for(i=1;i<=9;i++)total+=w[i]
      for(i=0;i<total;i++)bar=bar "─"
      printf "%s┌%s┐%s\n",blue,bar,reset
      split("ID 状态 变更 方向/策略 协议 端口 来源/目标IP 作用范围 备注",v," ");row(blue)
      printf "%s├%s┤%s\n",blue,bar,reset
    }
    NF>=10 {
      v[1]=($2~/^[0-9]+$/?"#" $2:$2);v[2]=($3==1?"启用":"停用");v[3]=$1
      v[4]=($5=="in"?"入站":($5=="out"?"出站":"")) ($4=="accept"?"允许":($4=="drop"?"拒绝":$4))
      v[5]=($7=="both"?"TCP+UDP":toupper($7));v[6]=toupper($8)
      v[7]=($9=="any"?"ANY (IPv4+IPv6)":$9)
      v[8]=($6=="host"?"宿主机":($6=="all"?"宿主机+容器":($6=="docker"?"Docker":$6)));v[9]=$10
      row($1=="待删除"?red:($1~/^待/?yellow:reset))
    }
    END {
      note="SSH/SSH-B 在 [4] 管理，白名单范围内仍受普通规则约束；数字 ID 在 [3] 管理。"
      printf "%s│%s %s%*s %s│%s\n",blue,reset,note,total-2-width(note),"",blue,reset
      printf "%s└%s┘%s\n",blue,bar,reset
    }
  '
}

# ---------- 首次向导 ----------
# 隔离后唯一的恢复入口是 VNC 控制台，而控制台登录需要密码；仅密钥登录的云镜像 root 密码通常是锁定的。
warn_if_no_console_login() {
  command -v passwd >/dev/null 2>&1 || return 0
  local pw_state
  pw_state="$(passwd -S root 2>/dev/null | awk '{print $2}')" || return 0
  case "$pw_state" in
    L*) warn "root 密码处于锁定状态。超时或异常隔离后只能从 VNC 控制台恢复，请先确认至少有一个账号能在控制台用密码登录（例如先执行 passwd root）。" ;;
  esac
  return 0
}

# 草稿中是否仍有 SSH 入口；没有则输出原因并返回 0（应用后只能走 VNC）
draft_ssh_lockout_reason() {
  load_conf "$DRAFT_DIR" >/dev/null 2>&1 || { printf '无法读取草稿，不能判断 SSH 策略'; return 0; }
  local rid enabled action rdir scope proto ports cidr comment allow=0
  if [[ "$CFG_SSH_MODE" != none && -n "$CFG_SSH_BLOCK" ]]; then
    printf '存在 SSH 独立黑名单，需核对它是否覆盖管理来源'; return 0
  fi
  while IFS='|' read -r rid enabled action rdir scope proto ports cidr comment || [[ -n "$rid" ]]; do
    [[ -n "$rid" && "$rid" != \#* && "$enabled" == 1 && "$rdir" == in ]] || continue
    [[ "$scope" == host || "$scope" == all ]] || continue
    [[ "$proto" == tcp || "$proto" == both || "$proto" == any ]] || continue
    port_in_spec "$ports" "$CFG_SSH_PORT" || continue
    if [[ "$action" == drop ]]; then
      printf '规则 #%s 拒绝 SSH 端口，需要核对来源与规则顺序（此处为保守告警）' "$rid"; return 0
    fi
    [[ "$action" != accept ]] || allow=1
  done < "$(rules_file "$DRAFT_DIR")"
  [[ -z "$CFG_TRUSTED_IFS" ]] || return 1
  [[ "$CFG_SSH_MODE" != whitelist ]] || return 1
  if [[ "$CFG_SSH_MODE" == hidden ]]; then
    printf 'SSH 隐身模式已开启，但没有信任内网网卡'; return 0
  fi
  (( allow == 0 )) || return 1
  printf '没有放行 SSH 端口 %s/TCP 的规则，也没有信任内网网卡' "$CFG_SSH_PORT"
}
confirm_ssh_lockout_risk() {
  local why
  why="$(draft_ssh_lockout_reason)" || { info "配置检查不能证明 SSH 可达；应用后仍需新连接验证。"; return 0; }
  warn "${why}。可能阻断新的 SSH 连接；请准备可登录的商家控制台。"
  ask_yesno "仍然继续应用？" "n"
}

first_time_setup() {
  clear_screen
  printf '%s━━ 首次配置向导 (失败封闭初始化) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$C_CYAN$C_BOLD" "$C_RESET"
  local def_wan ssh_port client_ip
  def_wan="$(detect_wan_if)"
  ssh_port="$(detect_ssh_port)"
  local chosen_port=""
  while true; do
    printf '  SSH TCP 端口 [探测建议 %s，请核对，尤其是 VNC/socket activation]: ' "$ssh_port"
    read -r chosen_port || return 1
    chosen_port="$(trim "$chosen_port")"
    chosen_port="${chosen_port:-$ssh_port}"
    if [[ "$chosen_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( chosen_port<=65535 )); then
      break
    fi
    err "端口无效，请输入 1-65535 之间的数字"
  done
  ssh_port="$chosen_port"; CFG_SSH_PORT="$ssh_port"
  client_ip="$(detect_ssh_client_ip)"

  info "自动探测到当前环境："
  printf '    • 公网网卡 : %s%s%s\n' "$C_GREEN" "$def_wan" "$C_RESET"
  printf '    • SSH 端口 : %s%s%s\n' "$C_GREEN" "$ssh_port" "$C_RESET"
  printf '    • 你的来源 : %s%s%s\n\n' "$C_GREEN" "${client_ip:-未知 (如为 VNC 可留空放行 ANY)}" "$C_RESET"

  printf '  确认公网网卡名称 [直接回车使用 %s]: ' "$def_wan"
  local in_wan=""
  read -r in_wan || true
  in_wan="$(trim "$in_wan")"
  CFG_WAN_IF="${in_wan:-$def_wan}"
  validate_iface "$CFG_WAN_IF" || die "非法网卡名: $CFG_WAN_IF"

  local ssh_cidr="any"
  if [[ -n "$client_ip" ]]; then
    printf '  SSH 访问方式: [1] 仅限当前 IP (%s；地址变化后须用 VPN/控制台恢复)   [2] 允许 ANY (方便多地登录) [默认 1]: ' "$client_ip"
    local ssh_mode=""
    read -r ssh_mode || true
    if [[ "$(trim "$ssh_mode")" != "2" ]]; then
      ssh_cidr="$(validate_cidrs "$client_ip")" || { err "来源地址无效"; return 1; }
    fi
  fi

  save_conf "$DRAFT_DIR" || return 1
  : > "$(rules_file "$DRAFT_DIR")" || return 1
  if [[ "$ssh_cidr" == any ]]; then
    add_rule_to_dir "$DRAFT_DIR" 1 accept in host tcp "$ssh_port" any "SSH 管理入口（任意来源）" >/dev/null || return 1
  else
    CFG_SSH_MODE="whitelist"
    CFG_SSH_SOURCES="$ssh_cidr"
    save_conf "$DRAFT_DIR" || return 1
  fi
  CHANGES_PENDING=1

  echo
  ok "已生成初始安全草稿（默认拦截所有其他公网入站及 Docker 端口映射）。"
  if (( DEMO_MODE == 0 )); then
    warn_if_no_console_login
    if ask_yesno "是否现在立即应用基础防火墙保护（含 300 秒超时隔离保护）？" "y"; then
      with_lock apply_draft_to_system 1 || { err "应用失败，未确认成功"; pause_prompt; return 1; }
      # with_lock 在子 shell 中执行，草稿状态需在此处同步
      CHANGES_PENDING=0
      ok "基础防护已上线！请新开 SSH 窗口验证可正常登录后，在主菜单 [6] 确认保存。"
      pause_prompt
    fi
  fi
}

# ---------- 交互功能菜单动作 ----------
action_quick_allow_port() {
  printf '\n%s── [1] 快速放行端口 (入站允许) ──────────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  输入端口 (如 443 或 80,443 或 8000-8010, 输入 q 返回): '
  local raw_p="" ports=""
  read -r raw_p || return
  raw_p="$(trim "$raw_p")"
  [[ -z "$raw_p" || "$raw_p" == "q" || "$raw_p" == "0" ]] && return
  ports="$(validate_ports "$raw_p")" || { err "端口格式错误，支持 443 / 80,443 / 8000-8010"; pause_prompt; return; }

  printf '  协议选择: [1] TCP+UDP (默认)  [2] 仅 TCP  [3] 仅 UDP : '
  local pr_c="" proto="both"
  read -r pr_c || true
  case "$(trim "$pr_c")" in
    2) proto="tcp" ;;
    3) proto="udp" ;;
    *) proto="both" ;;
  esac

  printf '  来源 IP 白名单 (直接回车默认 ANY 任意公网 IP; 支持多个用逗号隔开): '
  local raw_ip="" cidr="any"
  read -r raw_ip || true
  raw_ip="$(trim "$raw_ip")"
  if [[ -n "$raw_ip" ]]; then
    cidr="$(validate_cidrs "$raw_ip")" || { err "IP/CIDR 格式错误"; pause_prompt; return; }
  fi

  printf '  作用范围: [1] 宿主机 + Docker容器 (默认推荐)  [2] 仅宿主机  [3] 仅Docker容器 : '
  local sc_c="" scope="all"
  read -r sc_c || true
  case "$(trim "$sc_c")" in
    2) scope="host" ;;
    3) scope="docker" ;;
    *) scope="all" ;;
  esac

  printf '  备注名称 [默认 端口放行]: '
  local note=""
  read -r note || true
  note="${note:-端口放行}"

  local rid
  rid="$(add_rule_to_dir "$DRAFT_DIR" "1" "accept" "in" "$scope" "$proto" "$ports" "$cidr" "$note")"
  check_draft_dirty
  ok "已添加到草稿 (#${rid}): 放行 ${proto} ${ports} (${cidr}, $(scope_label "$scope"))"
  pause_prompt
}

action_advanced_rule() {
  printf '\n%s── [2] 添加高级规则 (白名单 / 封禁 IP / 出站限制) ───────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  方向: [1] 入站 (默认)  [2] 出站  [0] 返回: '
  local d_c="" rdir="in"
  read -r d_c || return
  case "$(trim "$d_c")" in
    0|q) return ;;
    2) rdir="out" ;;
    *) rdir="in" ;;
  esac

  printf '  动作: [1] 允许 ALLOW (默认)  [2] 拒绝 DROP (封禁): '
  local a_c="" action="accept"
  read -r a_c || return
  [[ "$(trim "$a_c")" == "2" ]] && action="drop"

  printf '  作用范围: [1] 宿主机+Docker (默认)  [2] 仅宿主机  [3] 仅Docker容器: '
  local sc_c="" scope="all"
  read -r sc_c || return
  case "$(trim "$sc_c")" in
    2) scope="host" ;;
    3) scope="docker" ;;
    *) scope="all" ;;
  esac

  printf '  协议: [1] TCP  [2] UDP  [3] TCP+UDP (默认)  [4] 全部协议 ANY  [5] ICMP Ping: '
  local p_c="" proto="both"
  read -r p_c || return
  case "$(trim "$p_c")" in
    1) proto="tcp" ;;
    2) proto="udp" ;;
    4) proto="any" ;;
    5) proto="icmp" ;;
    *) proto="both" ;;
  esac

  local ports="any"
  if [[ "$proto" != "any" && "$proto" != "icmp" ]]; then
    printf '  端口 (如 22 / 80,443 / 8000-8010 / any) [默认 any]: '
    local raw_p=""
    read -r raw_p || return
    raw_p="$(trim "$raw_p")"
    raw_p="${raw_p:-any}"
    ports="$(validate_ports "$raw_p")" || { err "端口格式无效"; pause_prompt; return; }
  fi

  local dir_label="来源"
  [[ "$rdir" == "out" ]] && dir_label="目标"
  printf '  %s IP / CIDR (多个逗号隔开, 或填 any) [默认 any]: ' "$dir_label"
  local raw_c="" cidr="any"
  read -r raw_c || return
  raw_c="$(trim "$raw_c")"
  raw_c="${raw_c:-any}"
  cidr="$(validate_cidrs "$raw_c")" || { err "IP / CIDR 格式无效"; pause_prompt; return; }

  printf '  备注名 [默认 自定义规则]: '
  local note=""
  read -r note || true
  note="${note:-自定义规则}"

  local rid
  rid="$(add_rule_to_dir "$DRAFT_DIR" "1" "$action" "$rdir" "$scope" "$proto" "$ports" "$cidr" "$note")"
  check_draft_dirty
  ok "已加入草稿 (#${rid})"
  pause_prompt
}

action_manage_rules() {
  local rf
  rf="$(rules_file "$DRAFT_DIR")"
  [[ -s "$rf" ]] || { warn "当前没有任何规则"; pause_prompt; return; }
  printf '\n%s── [3] 编辑 / 启停 / 删除 / 排序规则 ────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  [1] 启用 / 停用指定规则\n'
  printf '  [2] 删除规则 (支持多个如 2,3)\n'
  printf '  [3] 调整规则优先级 (上移 / 下移)\n'
  printf '  [0] 返回\n'
  printf '  请选择: '
  local opt=""
  read -r opt || return
  case "$(trim "$opt")" in
    1)
      printf '  输入要切换启停的规则 ID: '
      local rid=""
      read -r rid || return
      rid="$(trim "$rid")"
      rule_exists_in_dir "$DRAFT_DIR" "$rid" || { err "找不到规则 #$rid"; pause_prompt; return; }
      local tmp
      tmp="$(mktemp "$DRAFT_DIR/.rules.XXXXXX")" || return 1
      awk -F'|' -v OFS='|' -v id="$rid" '{if($1==id){$2=($2=="1"?"0":"1")} print}' "$rf" > "$tmp" || { rm -f "$tmp"; return 1; }
      mv -f "$tmp" "$rf" || return 1
      check_draft_dirty
      ok "已切换规则 #$rid 状态"
      ;;
    2)
      printf '  输入要删除的规则 ID (多个用逗号隔开): '
      local rids=""
      read -r rids || return
      rids="${rids//，/,}"
      rids="${rids//[[:space:]]/}"
      [[ -n "$rids" ]] || return
      local -a del_want=()
      local del_id del_ok="" del_miss=""
      IFS=',' read -r -a del_want <<< "$rids"
      for del_id in "${del_want[@]}"; do
        del_id="${del_id#\#}"
        [[ -z "$del_id" ]] && continue
        if rule_exists_in_dir "$DRAFT_DIR" "$del_id"; then
          [[ ",$del_ok," == *",$del_id,"* ]] || del_ok+="${del_ok:+,}$del_id"
        else
          del_miss+="${del_miss:+,}$del_id"
        fi
      done
      [[ -z "$del_miss" ]] || warn "未找到规则，已忽略: $del_miss"
      if [[ -z "$del_ok" ]]; then
        pause_prompt
        return
      fi
      local tmp
      tmp="$(mktemp "$DRAFT_DIR/.rules.XXXXXX")" || return 1
      awk -F'|' -v ids=",$del_ok," 'index(ids, "," $1 ",") == 0 {print}' "$rf" > "$tmp" || { rm -f "$tmp"; return 1; }
      mv -f "$tmp" "$rf" || return 1
      check_draft_dirty
      ok "已从草稿删除规则: $del_ok"
      ;;
    3)
      printf '  输入要移动的规则 ID: '
      local rid="" dir_mv=""
      read -r rid || return
      rid="$(trim "$rid")"
      rule_exists_in_dir "$DRAFT_DIR" "$rid" || { err "找不到规则 #$rid"; pause_prompt; return; }
      printf '  方向: [u] 上移一位  [d] 下移一位: '
      read -r dir_mv || return
      dir_mv="$(to_lower "$(trim "$dir_mv")")"
      local -a lines=()
      local idx=0 found_idx=-1 line_txt
      while IFS= read -r line_txt || [[ -n "$line_txt" ]]; do
        [[ -z "$line_txt" ]] && continue
        lines+=("$line_txt")
        [[ "${line_txt%%|*}" == "$rid" ]] && found_idx=$idx
        idx=$(( idx + 1 ))
      done < "$rf"
      if (( found_idx == -1 )); then
        err "未找到规则"
      elif [[ "$dir_mv" == "u" ]] && (( found_idx > 0 )); then
        local swap="${lines[found_idx-1]}"
        lines[found_idx-1]="${lines[found_idx]}"
        lines[found_idx]="$swap"
        printf '%s\n' "${lines[@]}" | atomic_write "$rf" || return 1
        check_draft_dirty
        ok "规则 #$rid 已上移"
      elif [[ "$dir_mv" == "d" ]] && (( found_idx >= 0 && found_idx < ${#lines[@]} - 1 )); then
        local swap="${lines[found_idx+1]}"
        lines[found_idx+1]="${lines[found_idx]}"
        lines[found_idx]="$swap"
        printf '%s\n' "${lines[@]}" | atomic_write "$rf" || return 1
        check_draft_dirty
        ok "规则 #$rid 已下移"
      else
        warn "已在边界位置或输入无效"
      fi
      ;;
    *) return ;;
  esac
  pause_prompt
}

action_presets_menu() {
  load_conf "$DRAFT_DIR" >/dev/null 2>&1 || true
  local ssh_port client_ip
  ssh_port="$CFG_SSH_PORT"
  client_ip="$(detect_ssh_client_ip)"

  printf '\n%s── [4] 自动交易 / 常用安全预设 ──────────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  [1] 锁定 SSH 仅允许指定 IP / 当前登录 IP (%s)\n' "${client_ip:-未检测到}"
  printf '  [2] SSH 隐身模式 (关闭公网 SSH，仅允许 Tailscale/WireGuard 等内网网卡登录)\n'
  printf '  [3] 一键放行 Web 服务端口 (80, 443 TCP -> 宿主机+Docker)\n'
  printf '  [4] 切换公网 Ping 状态 (当前: %s)\n' "$( [[ "$CFG_PING_ALLOW" == "1" ]] && printf '允许限速Ping' || printf '静默禁Ping' )"
  printf '  [5] 管理信任内网网卡 (当前: %s)\n' "${CFG_TRUSTED_IFS:-无}"
  printf '  [6] 切换容器访问宿主机策略 (当前: %s)\n' "$( [[ "$CFG_DOCKER_TO_HOST" == "drop" ]] && printf '禁止反连宿主机(仅DNS)' || printf '允许反连宿主机' )"
  printf '  [7] 切换出站默认策略 (当前: %s)\n' "$( [[ "$CFG_OUTBOUND_POLICY" == "accept" ]] && printf 'ACCEPT 默认允许' || printf 'DROP 严格出站白名单' )"
  printf '  [8] 修改公网网卡 (当前: %s)\n' "$CFG_WAN_IF"
  printf '  [9] 检测并处理冲突防火墙服务 (ufw / firewalld)\n'
  printf '  [10] 关闭公网 SSH 专用策略（恢复按普通规则判断）\n'
  printf '  [11] 修改 SSH 优先黑名单 (当前: %s)\n' "${CFG_SSH_BLOCK:-无}"
  printf '  [12] 明确修改保存的 SSH 端口 (当前: %s)\n' "$CFG_SSH_PORT"
  warn "信任接口仅控制访问宿主机，不开放 VPN 出口、子网路由或访问容器的转发。"
  printf '  [0] 返回\n'
  printf '  请选择: '
  local c=""
  read -r c || return
  case "$(trim "$c")" in
    1)
      printf '  输入允许连 SSH (%s/TCP) 的白名单 IP/CIDR [回车使用 %s]: ' "$ssh_port" "${client_ip:-取消}"
      local wip=""
      read -r wip || return
      wip="$(trim "$wip")"
      wip="${wip:-$client_ip}"
      [[ -n "$wip" ]] || { err "未提供 IP"; pause_prompt; return; }
      wip="$(validate_cidrs "$wip")" || { err "IP 格式错误"; pause_prompt; return; }
      [[ "$wip" != "any" ]] || { err "白名单必须指定 IP/CIDR"; pause_prompt; return; }
      CFG_SSH_MODE="whitelist"
      CFG_SSH_SOURCES="$wip"
      save_conf "$DRAFT_DIR" || return 1
      check_draft_dirty
      ok "公网 SSH 专用策略已更新：仅允许 ${wip}；覆盖普通规则中的 SSH 放行，不修改 Docker 规则。"
      ;;
    2)
      printf '  输入内网 VPN 网卡名 (如 tailscale0 或 wg0 或 wt0): '
      local tif=""
      read -r tif || return
      tif="$(trim "$tif")"
      validate_iface "$tif" || { err "非法网卡名"; pause_prompt; return; }
      [[ "$tif" != "$CFG_WAN_IF" ]] || { err "不能将公网接口设为信任接口"; pause_prompt; return; }
      warn "将拒绝公网 SSH，并完全信任 $tif 的宿主机入站访问（不限 SSH）。"
      if ask_yesno "已验证 VPN 可用，确认启用？" "n"; then
        if [[ ",$CFG_TRUSTED_IFS," != *",$tif,"* ]]; then
          CFG_TRUSTED_IFS="${CFG_TRUSTED_IFS:+$CFG_TRUSTED_IFS,}$tif"
        fi
        CFG_SSH_MODE="hidden"
        CFG_SSH_SOURCES=""
        save_conf "$DRAFT_DIR" || return 1
        check_draft_dirty
        ok "已更新公网 SSH 专用策略，普通放行规则不能绕过；请应用后新建连接验证。"
      fi
      ;;
    3)
      add_rule_to_dir "$DRAFT_DIR" "1" "accept" "in" "all" "tcp" "80,443" "any" "Web HTTP/HTTPS" >/dev/null || { err "规则写入失败"; return 1; }
      check_draft_dirty
      ok "已添加 80,443 TCP 入站放行规则到草稿"
      ;;
    4)
      CFG_PING_ALLOW="$( [[ "$CFG_PING_ALLOW" == "1" ]] && printf '0' || printf '1' )"
      save_conf "$DRAFT_DIR" || { err "草稿配置写入失败"; return 1; }
      check_draft_dirty
      ok "已切换公网 Ping 状态"
      ;;
    5)
      printf '  当前信任内网网卡: %s\n' "${CFG_TRUSTED_IFS:-无}"
      printf '  输入新的逗号分隔网卡列表 (如 tailscale0,wg0; 留空则清空): '
      local raw_t="" tok new_t=""
      read -r raw_t || return
      raw_t="$(trim "${raw_t//，/,}")"
      if [[ -n "$raw_t" ]]; then
        IFS=',' read -r -a tarr <<< "$raw_t"
        for tok in "${tarr[@]}"; do
          tok="$(trim "$tok")"
          [[ -z "$tok" ]] && continue
          validate_iface "$tok" || { err "非法网卡名: $tok"; pause_prompt; return; }
          new_t+="${new_t:+,}$tok"
        done
      fi
      validate_network_roles "$CFG_WAN_IF" "$new_t" || { pause_prompt; return 1; }
      CFG_TRUSTED_IFS="$new_t"
      save_conf "$DRAFT_DIR" || { err "草稿配置写入失败"; return 1; }
      check_draft_dirty
      ok "信任内网网卡已更新为: ${CFG_TRUSTED_IFS:-无}"
      ;;
    6)
      CFG_DOCKER_TO_HOST="$( [[ "$CFG_DOCKER_TO_HOST" == "drop" ]] && printf 'accept' || printf 'drop' )"
      save_conf "$DRAFT_DIR" || { err "草稿配置写入失败"; return 1; }
      check_draft_dirty
      ok "容器反连宿主机策略已切换为: $CFG_DOCKER_TO_HOST"
      ;;
    7)
      if [[ "$CFG_OUTBOUND_POLICY" == "accept" ]]; then
        warn "切换到严格出站白名单 (DROP) 后，系统无法 apt 更新、解析 DNS 或请求交易所 API，除非添加出站放行规则！"
        if ask_yesno "是否自动为你预先添加基础出站放行 (DNS 53, NTP 123, HTTP/HTTPS 80/443)？" "y"; then
          add_rule_to_dir "$DRAFT_DIR" "1" "accept" "out" "all" "both" "53" "any" "出站 DNS 解析" >/dev/null || { err "规则写入失败"; return 1; }
          add_rule_to_dir "$DRAFT_DIR" "1" "accept" "out" "all" "udp" "123" "any" "出站 NTP 对时" >/dev/null || { err "规则写入失败"; return 1; }
          add_rule_to_dir "$DRAFT_DIR" "1" "accept" "out" "all" "tcp" "80,443" "any" "出站 HTTP/HTTPS API" >/dev/null || { err "规则写入失败"; return 1; }
        fi
        CFG_OUTBOUND_POLICY="drop"
      else
        CFG_OUTBOUND_POLICY="accept"
      fi
      save_conf "$DRAFT_DIR" || { err "草稿配置写入失败"; return 1; }
      check_draft_dirty
      ok "默认出站策略已切换为: $CFG_OUTBOUND_POLICY"
      ;;
    8)
      local dwan
      dwan="$(detect_wan_if)"
      printf '  输入新的公网网卡名 [自动探测: %s]: ' "$dwan"
      local nw=""
      read -r nw || return
      nw="$(trim "$nw")"
      nw="${nw:-$dwan}"
      validate_iface "$nw" || { err "非法网卡名"; pause_prompt; return; }
      validate_network_roles "$nw" "$CFG_TRUSTED_IFS" || { pause_prompt; return 1; }
      CFG_WAN_IF="$nw"
      save_conf "$DRAFT_DIR" || { err "草稿配置写入失败"; return 1; }
      check_draft_dirty
      ok "公网网卡已设置为: $CFG_WAN_IF"
      ;;
    11)
      warn "仅此处设置的地址优先拒绝 SSH；普通规则不自动重排。包含自己的地址将阻断登录。"
      printf '  输入黑名单 IP/CIDR（空白清除）: '
      local blocked=""
      read -r blocked || return 1
      if [[ -n "$blocked" ]]; then
        blocked="$(validate_cidrs "$blocked")" && [[ "$blocked" != any ]] || { err "请指定地址"; return 1; }
      fi
      if ask_yesno "确认保存 SSH 黑名单？" n; then
        CFG_SSH_BLOCK="$blocked"; save_conf "$DRAFT_DIR" || return 1; check_draft_dirty
      fi
      ;;
    12)
      printf '  输入实际 SSH TCP 端口（不会修改 sshd，仅修改防火墙）: '
      local new_port=""
      read -r new_port || return 1
      [[ "$new_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( new_port<=65535 )) || { err "端口无效"; return 1; }
      if ask_yesno "已通过 VNC/ss 确认服务监听此端口？" n; then
        CFG_SSH_PORT="$new_port"; save_conf "$DRAFT_DIR" || return 1
        if [[ "$CFG_SSH_MODE" == none ]]; then
          # 未启用专用策略时 SSH 由普通规则放行，仅改保存的端口不会打开新端口
          warn "当前未启用 SSH 专用策略：保存的端口不会自动改动普通放行规则，旧端口的规则请自行在 [3] 中处理。"
          if ask_yesno "是否为新端口 ${new_port}/TCP 新增指定来源放行规则？" "n"; then
            local new_sources=""
            printf '  输入允许来源 IP/CIDR（必须明确输入；any 表示任意来源，留空取消）: '
            read -r new_sources || return 1
            if [[ -n "$new_sources" ]]; then
              new_sources="$(validate_cidrs "$new_sources")" || { err "来源无效，未添加规则"; return 1; }
              if [[ "$new_sources" == any ]] && ! ask_yesno "确认向任意来源开放新 SSH 端口？" "n"; then
                info "未添加任意来源规则"
              else
                add_rule_to_dir "$DRAFT_DIR" 1 accept in host tcp "$new_port" "$new_sources" "SSH 新端口（明确来源）" >/dev/null || return 1
              fi
            fi
          fi
        fi
        check_draft_dirty
      fi
      ;;
    10)
      warn "关闭后，已有普通规则可能重新向任意来源开放 SSH。信任接口配置不变。"
      if ask_yesno "确认关闭专用 SSH 限制？" "n"; then
        CFG_SSH_MODE="none"
        CFG_SSH_SOURCES=""
        save_conf "$DRAFT_DIR" || return 1
        check_draft_dirty
      fi
      ;;
    9)
      (( DEMO_MODE == 1 )) && { info "演示模式无需检测冲突服务"; pause_prompt; return; }
      check_conflicting_firewalls
      ;;
    *) return ;;
  esac
  pause_prompt
}

action_docker_audit() {
  info "Docker 配置审计：显示端口映射、网络及候选策略，不推断外网连通性。"
  if (( DEMO_MODE == 1 )); then
    printf '  [模拟] web: 0.0.0.0:443->443/tcp，bridge 网络\n'
    printf '  [模拟] 来源条件、规则顺序及实际内核链均需共同评估。\n'
  else
    if ! command -v docker >/dev/null 2>&1; then
      warn "未安装 Docker"; pause_prompt; return 0
    fi
    docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Networks}}' || { pause_prompt; return 1; }
    docker network ls || { pause_prompt; return 1; }
    local h expected
    h="$(live_table_hash || true)"
    expected="$(cat "$(fprint_file "$CONF_DIR")" 2>/dev/null || true)"
    if [[ -n "$h" && "$h" == "$expected" ]]; then
      info "本程序内核表指纹匹配；这不代表整个网络路径已验证。"
    else
      warn "本程序内核表缺失或不一致，不能据配置判断实际策略。"
    fi
  fi
  printf '\n  已保存的 Docker 入站规则（按顺序；包含来源条件；不是最终可达性结论）：\n'
  if [[ -f "$(rules_file "$CONF_DIR")" ]]; then
    awk -F'|' '$2==1 && $4=="in" && ($5=="all" || $5=="docker") {printf "  #%s %s %s 端口=%s 来源=%s\n",$1,$3,$6,$7,$8}' "$(rules_file "$CONF_DIR")"
  fi
  warn "无端口映射不等于安全；host/macvlan/ipvlan、端口范围及 IPv4/IPv6 必须分别检查。"
  info "请从外部允许与拒绝来源测试新连接。"
  pause_prompt
}

action_apply_confirm_menu() {
  printf '\n%s── [6] 应用规则 / 确认保存 / 隔离 ───────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  if [[ -f "$(pend_file "$CONF_DIR")" ]]; then
    printf '  [1] 确认保存当前已生效的新规则 (取消 300 秒超时隔离)\n'
    printf '  [2] 立即隔离网络\n'
    printf '  [3] 重新应用当前草稿（新一轮待确认，用于 VNC 恢复）\n'
    printf '  [0] 返回\n'
    printf '  请选择: '
    local c=""
    read -r c || return
    case "$(trim "$c")" in
      1) with_lock cmd_confirm ;;
      2) with_lock quarantine "用户取消待确认配置" ;;
      3) confirm_ssh_lockout_risk || return
         with_lock apply_draft_to_system 1 && CHANGES_PENDING=0 ;;
      *) return ;;
    esac
    pause_prompt
    return
  fi

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  printf '  当前 SSH 端口检测为: %s/TCP。请确保已在规则列表中放行或已配置信任内网网卡！\n' "$ssh_port"
  printf '  [1] 安全应用 (推荐: 开启 300 秒失败封闭倒计时，未确认自动隔离)\n'
  printf '  [2] 直接永久应用 (立即生效并设为永久，不设倒计时)\n'
  printf '  [0] 取消返回\n'
  printf '  请选择: '
  local c=""
  read -r c || return
  case "$(trim "$c")" in
    1)
      confirm_ssh_lockout_risk || return
      if with_lock apply_draft_to_system 1; then
        CHANGES_PENDING=0
        ok "新防火墙规则已生效！请在 300 秒内新开 SSH 窗口验证可正常登录后，选 [6] -> [1] 确认保存。"
      else
        err "应用失败，未确认成功"
      fi
      ;;
    2)
      confirm_ssh_lockout_risk || return
      if ask_yesno "确定不设确认倒计时、直接永久应用吗？" "n"; then
        if with_lock apply_draft_to_system 0; then
          CHANGES_PENDING=0
          ok "新防火墙规则已永久生效！"
        else
          err "应用失败"
        fi
      fi
      ;;
    *) return ;;
  esac
  pause_prompt
}

action_diagnostics() {
  printf '\n%s── [7] 底层 nftables 规则 & 监听端口诊断 ────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  [1] 预览草稿将生成的 nftables 完整规则\n'
  printf '  [2] 查看当前内核实际生效的 inet %s 表\n' "$TABLE_NAME"
  printf '  [3] 查看当前本机监听端口 (ss -lntup) 与其他 nft 表\n'
  printf '  [4] 查看守护审计日志 (journalctl -t vps-fw)\n'
  printf '  [0] 返回\n'
  printf '  请选择: '
  local c=""
  read -r c || return
  case "$(trim "$c")" in
    1)
      local tmp_nft
      tmp_nft="$(mktemp "${TMPDIR:-/tmp}/vps-fw-preview.XXXXXX")"
      if ! render_nft_ruleset "$DRAFT_DIR" "$tmp_nft"; then
        rm -f "$tmp_nft"; err "预览失败，未显示残缺规则"; pause_prompt; return 1
      fi
      cat "$tmp_nft"
      rm -f "$tmp_nft"
      ;;
    2)
      if (( DEMO_MODE == 1 )); then
        warn "演示模式无内核规则，请选 [1] 预览生成规则"
      else
        nft list table inet "$TABLE_NAME" 2>&1 || true
      fi
      ;;
    3)
      if command -v ss >/dev/null 2>&1; then
        printf '%s-- 监听端口 --%s\n' "$C_BOLD" "$C_RESET"
        ss -lntup 2>/dev/null | head -n 30
      fi
      if command -v nft >/dev/null 2>&1 && (( DEMO_MODE == 0 )); then
        printf '\n%s-- 内核所有 nftables 表 --%s\n' "$C_BOLD" "$C_RESET"
        nft list tables 2>/dev/null || true
      fi
      ;;
    4)
      if command -v journalctl >/dev/null 2>&1 && (( DEMO_MODE == 0 )); then
        journalctl -t vps-fw -n 30 --no-pager 2>/dev/null || true
      fi
      ;;
    *) return ;;
  esac
  pause_prompt
}

action_backup_rescue() {
  printf '\n%s── [8] 版本恢复 / 紧急隔离 ───────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  printf '  [1] 从历史版本导入配置到草稿\n'
  printf '  [2] 校验当前版本与内核规则（异常则隔离）\n'
  printf '  [3] 紧急隔离网络（inet %s + 独立隔离表；SSH 也会中断）\n' "$TABLE_NAME"
  printf '  [4] 彻底卸载 VPS-FW 面板与守护服务\n'
  printf '  [0] 返回\n'
  printf '  请选择: '
  local c=""
  read -r c || return
  case "$(trim "$c")" in
    1)
      local bdir
      bdir="$CONF_DIR/generations"
      if [[ ! -d "$bdir" ]] || [[ -z "$(ls -A "$bdir" 2>/dev/null)" ]]; then
        warn "暂无历史备份"
        pause_prompt
        return
      fi
      local -a baks=()
      local b idx=1
      while IFS= read -r b; do
        baks+=("$b")
        printf '    [%d] %s\n' "$idx" "$(basename "$b")"
        idx=$(( idx + 1 ))
      done < <(ls -1dt "$bdir"/*/ 2>/dev/null | head -n 15)
      printf '  输入要导入草稿的备份序号 (0 返回): '
      local sel=""
      read -r sel || return
      [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#baks[@]} )) || return
      local chosen="${baks[sel-1]}"
      valid_generation "${chosen%/}" || { err "历史版本完整性验证失败"; return 1; }
      cp -f "$chosen/fw.conf" "$(conf_file "$DRAFT_DIR")" && cp -f "$chosen/rules.db" "$(rules_file "$DRAFT_DIR")" || { err "导入失败"; return 1; }
      check_draft_dirty
      ok "已将备份 $(basename "$chosen") 导入草稿，按 [6] 应用后生效。"
      ;;
    2)
      (( DEMO_MODE == 1 )) && { warn "演示模式不支持"; pause_prompt; return; }
      with_lock cmd_audit
      ;;
    3)
      (( DEMO_MODE == 1 )) && { warn "演示模式不支持"; pause_prompt; return; }
      printf '  %s警告: 将隔离所有非回环流量，包括已有 SSH。请准备 VNC！输入 YES 确认: %s' "$C_RED" "$C_RESET"
      local ack=""
      read -r ack || return
      if [[ "$ack" == "YES" ]]; then
        with_lock cmd_emergency_off
      else
        info "已取消"
      fi
      ;;
    4)
      (( DEMO_MODE == 1 )) && { warn "演示模式不支持"; pause_prompt; return; }
      printf '  %s确认彻底卸载 VPS-FW (输入 UNINSTALL 确认): %s' "$C_RED" "$C_RESET"
      local ack=""
      read -r ack || return
      if [[ "$ack" == "UNINSTALL" ]]; then
        cmd_uninstall
      fi
      ;;
    *) return ;;
  esac
  pause_prompt
}

# Explicit user-triggered updater. Metadata is parsed as data, never sourced.
fetch_update_file() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
    --connect-timeout 10 --max-time 60 --max-filesize 8388608 "$1" -o "$2"
}
version_is_newer() {
  local next="$1" current="$2" i
  local -a nv cv
  [[ "$next" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]] || return 1
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a nv <<< "$next"; IFS=. read -r -a cv <<< "$current"
  for i in 0 1 2; do
    (( 10#${nv[$i]} > 10#${cv[$i]} )) && return 0
    (( 10#${nv[$i]} < 10#${cv[$i]} )) && return 1
  done
  return 1
}
install_checked_update() {
  [[ ! -f "$CONF_DIR/locked.state" && ! -f "$CONF_DIR/fault.state" ]] || { err "当前处于隔离/故障状态，请先从控制台恢复后再更新"; return 1; }
  install_payload "$1"
}
check_and_install_update() (
  # Subshell confines download cleanup and temporary variables to this action.
  local tmp key value seen="," release="" commit="" digest="" actual payload_version
  [[ "$DEMO_MODE" != 1 ]] || { info "演示模式不联网、不安装更新"; return 0; }
  check_draft_dirty
  (( CHANGES_PENDING == 0 )) || { warn "有未应用草稿，请先应用并确认，或退出放弃草稿后再检查更新"; return 1; }
  [[ ! -f "$(pend_file "$CONF_DIR")" ]] || { warn "有待确认配置，请先验证连接并确认，再更新脚本"; return 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vps-fw-update.XXXXXX")" || return 1
  # Freeze the quoted path now: function locals disappear before the subshell EXIT trap.
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$tmp")" EXIT
  info "正在检查官方仓库更新（当前 v${VERSION}）..."
  fetch_update_file 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/main/update.manifest' "$tmp/manifest" || { err "更新信息下载失败，原程序未更改"; return 1; }
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -n "$key" && "$seen" != *",$key,"* ]] || { err "更新信息格式错误"; return 1; }
    seen+="$key,"
    case "$key" in VERSION) release="$value" ;; COMMIT) commit="$value" ;; SHA256) digest="$value" ;; *) err "未知更新字段"; return 1 ;; esac
  done < "$tmp/manifest"
  [[ "$release" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ && "$commit" =~ ^[0-9a-f]{40}$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || { err "更新信息校验失败"; return 1; }
  if ! version_is_newer "$release" "$VERSION"; then info "当前 v${VERSION}，仓库发布 v${release}，无需升级（不会降级）。"; return 0; fi
  info "发现 v${release}。更新只替换程序，不自动应用规则；请先阅读仓库更新说明。"
  ask_yesno "下载、校验并安装 v${release}？" n || return 0
  fetch_update_file "https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/$commit/vps-fw.sh" "$tmp/payload" || { err "脚本下载失败，原程序未更改"; return 1; }
  actual="$(hash_stdin < "$tmp/payload")" || return 1
  [[ "$actual" == "$digest" ]] || { err "SHA256 不匹配，原程序未更改"; return 1; }
  bash -n "$tmp/payload" || { err "脚本语法检查失败，原程序未更改"; return 1; }
  payload_version="$(sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' "$tmp/payload")"
  [[ "$payload_version" == "$release" ]] || { err "脚本版本与发布信息不一致"; return 1; }
  with_lock install_checked_update "$tmp/payload" || { err "安装更新失败，请检查上方原因"; return 1; }
  ok "已安装 v${release}。当前面板即将退出，请重新运行 fw（非 root 使用 sudo fw）。"
  return 10
)
action_script_update() {
  local rc=0
  check_and_install_update || rc=$?
  pause_prompt
  return "$rc"
}

interactive_loop() {
  if [[ ! -f "$(conf_file "$CONF_DIR")" ]]; then
    init_draft_from_conf || return 1
    first_time_setup
  else
    init_draft_from_conf || return 1
  fi

  while true; do
    # 若后台发生过超时隔离且当前草稿未改动，则同步刷新显示
    if (( CHANGES_PENDING == 0 )) && [[ -f "$(conf_file "$CONF_DIR")" ]]; then
      if ! cmp -s "$(conf_file "$DRAFT_DIR")" "$(conf_file "$CONF_DIR")" 2>/dev/null || \
         ! cmp -s "$(rules_file "$DRAFT_DIR")" "$(rules_file "$CONF_DIR")" 2>/dev/null; then
        init_draft_from_conf || return 1
      fi
    fi

    clear_screen
    render_dashboard
    render_rules_table "$DRAFT_DIR"
    echo
    printf '  %s[1]%s 快速放行端口 (入站允许)            %s[5]%s Docker 容器端口暴露审计\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '  %s[2]%s 添加高级规则 (白名单/封禁IP/出站)  %s[6]%s 应用规则 / 确认 / 隔离\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '  %s[3]%s 编辑 / 启停 / 删除 / 排序规则      %s[7]%s 查看底层 nft 规则 & 端口诊断\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '  %s[4]%s 自动交易 / 常用安全预设            %s[8]%s 版本恢复 / 紧急隔离\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '  %s[9]%s 检查脚本更新\n' "$C_CYAN" "$C_RESET"
    printf '  %s[0]%s 退出面板 (已应用的防火墙持续在后台守护)\n' "$C_DIM" "$C_RESET"
    printf '\n  请输入操作编号: '
    local choice=""
    if ! read -r choice; then
      echo
      break
    fi
    case "$(to_lower "$(trim "$choice")")" in
      1) action_quick_allow_port ;;
      2) action_advanced_rule ;;
      3) action_manage_rules ;;
      4) action_presets_menu ;;
      5) action_docker_audit ;;
      6) action_apply_confirm_menu ;;
      7) action_diagnostics ;;
      8) action_backup_rescue ;;
      9)
        local update_rc=0
        action_script_update || update_rc=$?
        [[ "$update_rc" != 10 ]] || break
        ;;
      0|q|quit|exit)
        if (( CHANGES_PENDING == 1 )); then
          if ! ask_yesno "有尚未应用的草稿改动，确定丢弃并退出吗？" "n"; then
            continue
          fi
        fi
        info "已退出面板，已生效的防火墙规则继续在后台保护服务器。"
        break
        ;;
      *) warn "无效选项: $choice"; sleep 1 ;;
    esac
  done
}

# ---------- 自动安装与 curl 一键运行自举 ----------
ensure_root_and_deps() {
  (( $(id -u) == 0 )) || die "请使用 root 权限运行 (sudo -i 或 sudo bash ...)"
  if ! command -v nft >/dev/null 2>&1; then
    info "未检测到 nftables，正在通过 apt 自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update 失败"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables iproute2 || die "安装 nftables 失败"
      ok "nftables 安装完成"
    else
      die "请手动安装 nftables"
    fi
  fi
}

install_payload() {
  local payload="$1" temp_install
  if [[ -x "$EXEC_PATH" ]] && cmp -s "$payload" "$EXEC_PATH"; then
    return 0  # 在安装锁内确认内容相同，无升级，允许待确认期间重开面板。
  fi
  bash -n "$payload" || { err "脚本语法检查失败"; return 1; }
  if [[ -f "$(pend_file "$CONF_DIR")" ]]; then
    err "存在待确认防火墙修改，先在 VNC 核对并重新应用/确认，再升级程序"; return 1
  fi
  if [[ -L "$CONF_DIR/current" ]]; then
    local saved_gen
    saved_gen="$(active_dir)" && valid_generation "$saved_gen" || { err "保存配置不兼容或损坏，拒绝升级。请先用旧版核对 CIDR 前导零等问题并重新应用。"; return 1; }
  fi
  if [[ -e "$BIN_LINK" && ! -L "$BIN_LINK" ]]; then
    err "快捷命令路径被普通文件占用: $BIN_LINK"; return 1
  fi
  mkdir -p "$(dirname "$EXEC_PATH")" "$(dirname "$BIN_LINK")" || return 1
  temp_install="$(mktemp "$(dirname "$EXEC_PATH")/.vps-fw-install.XXXXXX")" || return 1
  if ! cp -- "$payload" "$temp_install" || ! chmod 755 "$temp_install" || ! mv -f -- "$temp_install" "$EXEC_PATH"; then
    rm -f -- "$temp_install"; return 1
  fi
  ln -sf "$EXEC_PATH" "$BIN_LINK" || return 1
}

self_install_if_needed() {
  local self="$SCRIPT_SELF" abs_self payload expected actual
  if [[ -n "$self" && -f "$self" && "$self" != /dev/fd/* && "$self" != /proc/self/fd/* ]]; then
    abs_self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
    # 包含 fw 符号链接调用：已执行安装文件时无需重新安装。
    [[ "$self" -ef "$EXEC_PATH" ]] && return 0
    with_lock install_payload "$abs_self" || die "安装失败"
  else
    # 管道模式必须指定固定 GitHub commit 和独立取得的 SHA256。
    expected="${VPS_FW_SHA256:-}"
    [[ "$RAW_URL" =~ ^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-fA-F]{40}/.+$ ]] || die "管道启动需要 VPS_FW_RAW_URL 指向固定 40 位 commit 的 GitHub Raw URL"
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "管道启动需要 VPS_FW_SHA256（从可信发布信息取得）"
    payload="$(mktemp "${TMPDIR:-/tmp}/vps-fw-download.XXXXXX")" || die "临时文件创建失败"
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$RAW_URL" -o "$payload"; then
      rm -f "$payload"; die "下载失败"
    fi
    actual="$(hash_stdin < "$payload")"
    if [[ "$(to_lower "$actual")" != "$(to_lower "$expected")" ]]; then
      rm -f "$payload"; die "SHA256 不匹配，保留原安装"
    fi
    if ! with_lock install_payload "$payload"; then
      rm -f "$payload"; die "安装失败"
    fi
    rm -f "$payload"
  fi
  # 总是执行刚刚持久化的同一个文件，避免菜单与后台服务版本不同。
  exec "$EXEC_PATH" "$@"
}

cleanup_exit() {
  [[ -n "${OWNED_DRAFT_DIR:-}" && "$OWNED_DRAFT_DIR" != "$CONF_DIR" && -d "$OWNED_DRAFT_DIR" ]] && rm -rf -- "$OWNED_DRAFT_DIR"
  [[ -n "$DEMO_TMP"  && -d "$DEMO_TMP" ]]  && rm -rf "$DEMO_TMP"
  return 0
}
trap cleanup_exit EXIT

# ---------- 演示模式 ----------
run_demo() {
  DEMO_MODE=1
  DEMO_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vps-fw-demo.XXXXXX")" && [[ -n "$DEMO_TMP" && -d "$DEMO_TMP" ]] || { DEMO_TMP=""; err "无法创建演示临时目录"; return 1; }
  CONF_DIR="$DEMO_TMP"
  DRAFT_DIR="$DEMO_TMP/draft"
  mkdir -p "$DRAFT_DIR"

  CFG_WAN_IF="$(detect_wan_if)"
  CFG_PING_ALLOW="1"
  CFG_OUTBOUND_POLICY="accept"
  CFG_DOCKER_TO_HOST="drop"
  CFG_DOCKER_HOST_DNS="1"
  CFG_SAFE_ROLLBACK="1"
  CFG_ROLLBACK_SECS="300"
  CFG_TRUSTED_IFS="tailscale0"
  CFG_NEXT_ID="1"
  save_conf "$CONF_DIR"
  : > "$(rules_file "$CONF_DIR")"
  add_rule_to_dir "$CONF_DIR" "1" "accept" "in" "host"   "tcp"  "22"     "any"              "SSH 管理入口" >/dev/null || { err "规则写入失败"; return 1; }
  add_rule_to_dir "$CONF_DIR" "1" "accept" "in" "all"    "tcp"  "80,443" "any"              "Web 服务端口" >/dev/null || { err "规则写入失败"; return 1; }
  add_rule_to_dir "$CONF_DIR" "1" "accept" "in" "docker" "tcp"  "8443"   "203.0.113.10/32"  "交易面板白名单" >/dev/null || { err "规则写入失败"; return 1; }
  add_rule_to_dir "$CONF_DIR" "1" "drop"   "in" "all"    "any"  "any"    "198.51.100.0/24"  "恶意扫描IP封禁" >/dev/null || { err "规则写入失败"; return 1; }
  render_nft_ruleset "$CONF_DIR" "$(nft_file "$CONF_DIR")" || return 1
  init_draft_from_conf || return 1

  if [[ -t 0 && "${1:-}" != "--no-tty" ]]; then
    interactive_loop
    return
  fi

  # 非 TTY 环境下直接展示面板截图与生成的 nft 规则预览
  render_dashboard
  render_rules_table "$DRAFT_DIR"
  printf '\n%s── 生成的 /etc/vps-fw/rules.nft 预览 ────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
  cat "$(nft_file "$CONF_DIR")"
}

show_help() {
  cat <<EOF
VPS-FW v${VERSION} -- Debian / Ubuntu 主机防火墙面板

用法:
  fw | vps-fw             打开交互式防火墙终端面板
  fw status               只读查看当前防护状态与规则列表
  fw rules                查看内核实际加载的 nftables 规则
  fw docker-audit         列出 Docker 映射和有来源条件的候选规则（需外部验证）
  fw confirm              确认最新修改 (取消 300 秒超时隔离)
  fw rollback             旧命令别名：立即隔离网络（不会撤掉保护；终端下需输入 YES）
  fw audit                校验保存版本与内核；异常则隔离并返回失败（未初始化时不做任何操作）
  fw restore              VNC 中人工恢复完整版本（无待确认修改时）
  fw boot-restore         由启动服务调用；未确认或损坏时持续隔离
  fw lockdown [--yes]     隔离全部非回环网络，包括已有 SSH（终端下需输入 YES，--yes 跳过）
  fw emergency-off        lockdown 的兼容别名
  fw bind-service NAME.service  为业务添加防火墙启动依赖
  fw health               业务启动前检查；未确认、损坏或隔离时失败
  fw generations          列出历史版本 ID 与创建时间（新的在前，标出 current / previous）
  fw recover VERSION_ID   VNC 中校验历史版本并重新应用（需再次 confirm）
  fw uninstall            严格模式拒绝自动卸载，请在 VNC 人工退役
  fw --demo               无需 root/nftables 安全预览面板界面与生成规则
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    --demo|demo)
      shift || true
      run_demo "$@" || return 1
      return 0
      ;;
    --version|-V)
      printf '%s\n' "$VERSION"
      return 0
      ;;
    --help|-h|help)
      show_help
      return 0
      ;;
  esac

  if [[ -z "$cmd" ]]; then
    ensure_root_and_deps
  else
    (( $(id -u) == 0 )) || die "需要 root"
  fi

  # 仅在交互命令或无参数启动时自动安装与重绑 TTY
  case "$cmd" in
    boot-restore) with_lock boot_restore; return $? ;;
    restore) with_lock explicit_restore; return $? ;;
    recover) [[ $# == 2 ]] || { err "用法: fw recover 24位版本ID"; return 1; }; with_lock cmd_recover "$2"; return $? ;;
    generations) list_generations; return $? ;;
    audit) with_lock cmd_audit; return $? ;;
    watch) watch_audit; return $? ;;
    health) with_lock health_check; return $? ;;
    lockdown) confirm_cli_lockdown "${2:-}" || return 1; with_lock quarantine "用户请求隔离"; return $? ;;
    bind-service) [[ $# == 2 ]] || return 1; with_lock bind_service "$2"; return $? ;;
    auto-rollback) shift; with_lock cmd_auto_rollback "${1:-}" 0; return $? ;;
    confirm) with_lock cmd_confirm; return $? ;;
    rollback) confirm_cli_lockdown "${2:-}" || return 1; with_lock quarantine "用户取消待确认修改"; return $? ;;
    rules)
      nft list table inet "$TABLE_NAME"
      return $?
      ;;
    status)
      if [[ ! -f "$(conf_file "$CONF_DIR")" ]]; then
        warn "VPS-FW 尚未初始化，请运行 fw 进行向导初始化。"
        return 0
      fi
      DRAFT_DIR="$CONF_DIR"
      render_dashboard
      render_rules_table "$CONF_DIR"
      return 0
      ;;
    docker-audit)
      DRAFT_DIR="$CONF_DIR"
      action_docker_audit
      return $?
      ;;
    emergency-off)
      confirm_cli_lockdown "${2:-}" || return 1
      with_lock cmd_emergency_off
      return $?
      ;;
    uninstall)
      cmd_uninstall
      return $?
      ;;
    "") ;;
    *) err "未知命令: $cmd"; return 1 ;;
  esac

  self_install_if_needed "$@"

  # 若从 curl | bash 管道启动，将标准输入重定向回真实终端 /dev/tty 以打开交互菜单
  if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec </dev/tty
  fi
  [[ -t 0 ]] || die "交互式菜单需要终端环境 (TTY)，非交互环境请使用 fw status / fw audit"

  interactive_loop
}

# v3.1: immutable generations + persistent quarantine. No automatic fail-open rollback.
active_dir() {
  local target
  target="$(readlink "$CONF_DIR/current")" || return 1
  [[ "$target" =~ ^generations/[0-9a-f]{24}$ ]] || return 1
  printf '%s/%s' "$CONF_DIR" "$target"
}
state_path() {
  local dir="$1" file="$2"
  if [[ "$dir" == "$CONF_DIR" && -L "$CONF_DIR/current" ]]; then
    printf '%s/current/%s' "$CONF_DIR" "$file"
  else
    printf '%s/%s' "$dir" "$file"
  fi
}
conf_file() { state_path "$1" fw.conf; }
rules_file() { state_path "$1" rules.db; }
nft_file() { state_path "$1" rules.nft; }
atomic_write() {
  local dest="$1" mode="${2:-600}" temp
  mkdir -p "$(dirname "$dest")" || return 1
  temp="$(mktemp "${dest}.XXXXXX")" || return 1
  if ! cat > "$temp" || ! chmod "$mode" "$temp" || ! mv -f -- "$temp" "$dest"; then
    rm -f -- "$temp"; return 1
  fi
}
with_lock() {
  if (( DEMO_MODE == 1 )); then "$@"; return $?; fi
  command -v flock >/dev/null || { err "缺少 flock，拒绝无锁操作"; return 1; }
  ( flock -x 9 || exit 1; "$@" ) 9>"$LOCK_FILE"
}
with_guard() {
  ( flock -x -w 5 8 || exit 1; "$@" ) 8>"$GUARD_LOCK_FILE"
}
# Busy is not an audit failure. A bounded busy period prevents a stuck owner hiding audits indefinitely.
watch_audit() {
  local rc
  ( flock -n -E 75 9 || exit $?; rm -f "$WATCH_BUSY_FILE" || exit 1; cmd_audit ) 9>"$LOCK_FILE"
  rc=$?
  if [[ "$rc" == 75 ]]; then
    local start now
    now="$(date +%s)" || return 1
    if [[ ! -e "$WATCH_BUSY_FILE" ]]; then
      printf '%s\n' "$now" | atomic_write "$WATCH_BUSY_FILE" || return 1
    fi
    start="$(cat "$WATCH_BUSY_FILE")" || return 1
    [[ "$start" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
    if (( now < start || now - start >= 120 )); then
      err "应用锁持续占用达到 120 秒或计时异常，交由独立守护隔离"; return 1
    fi
  fi
  return "$rc"
}
lockdown_rules() {
  cat <<'EOF'
table inet vps_fw_lockdown
delete table inet vps_fw_lockdown
table inet vps_fw_lockdown {
 chain lock_input { type filter hook input priority -310; policy drop; iifname "lo" accept; }
 chain lock_output { type filter hook output priority -310; policy drop; oifname "lo" accept; }
 chain lock_forward { type filter hook forward priority -310; policy drop; }
}
EOF
}
quarantine() { with_guard quarantine_locked "$@"; }
quarantine_locked() {
  local reason="${1:-未知故障}" marked=0
  mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR" && printf '%s\n' "$reason" | atomic_write "$CONF_DIR/locked.state" && marked=1
  if ! lockdown_rules | nft -f -; then
    err "严重故障：无法装载隔离规则！请通过 VNC 停止业务并检查内核/nft。"
    return 1
  fi
  logger -t vps-fw -- "QUARANTINE: $reason" 2>/dev/null || true
  if [[ "${2:-0}" == 1 ]]; then
    info "正在更新防火墙，已临时隔离网络（可能中断 SSH）；完成后自动恢复所选策略。"
  else
    err "已进入网络隔离（包括已有 SSH）；请通过 VNC 恢复。原因: $reason"
  fi
  if [[ "${2:-0}" == 1 ]]; then
    if systemctl is-failed --quiet "$GUARD_UNIT"; then
      systemctl reset-failed "$GUARD_UNIT" || return 1
    fi
    [[ "$marked" == 1 ]] && rm -f "$CONF_DIR/fault.state" || return 1
  fi
  [[ "$marked" == 1 ]] && sync -f "$CONF_DIR"
}
fail_closed() { quarantine "$*"; return 1; }
# 已处于隔离时由审计/启动反复调用：只重新装载隔离表，不改写 locked.state，
# 否则 5 秒后最初的隔离原因就会被覆盖，VNC 恢复时无从判断。
reassert_quarantine() { with_guard reassert_quarantine_locked; }
reassert_quarantine_locked() {
  local reason
  reason="$(head -n1 "$CONF_DIR/locked.state" 2>/dev/null || true)"
  if ! lockdown_rules | nft -f -; then
    err "严重故障：无法装载隔离规则！请通过 VNC 停止业务并检查内核/nft。"
    return 1
  fi
  err "隔离状态持续中；请通过 VNC 恢复。最初原因: ${reason:-未记录（systemd 应急隔离）}"
  return 1
}
release_quarantine() { with_guard release_quarantine_locked; }
release_quarantine_locked() {
  # Even if a full/read-only filesystem prevents fault.state, a failed or running
  # independent guard must never be cleared by an overlapping restore.
  local guard_state
  guard_state="$(systemctl show -p ActiveState --value "$GUARD_UNIT")" || return 1
  [[ "$guard_state" == inactive ]] || { err "独立隔离服务尚未结束或已失败，拒绝解除隔离"; return 1; }
  [[ ! -e "$CONF_DIR/fault.state" ]] || { err "本次事务中发生独立守护故障，拒绝解除隔离；请从 VNC 重新核对并恢复。"; return 1; }
  # 先建后删：隔离表本就不存在时（如人工执行 boot-restore）也算成功，仅 nft 真正故障才失败
  printf 'table inet vps_fw_lockdown\ndelete table inet vps_fw_lockdown\n' | nft -f - || return 1
  rm -f "$CONF_DIR/locked.state" && sync -f "$CONF_DIR" || return 1
}
# 是否曾经初始化/启用过保护。未初始化的主机上，人工执行 audit/health/restore 不应触发隔离。
is_initialized() {
  # 启动服务单元存在即视为启用过保护：此后即使配置被整体删除，审计仍会直接隔离
  [[ -L "$CONF_DIR/current" || -f "$CONF_DIR/fw.conf" || -f "$CONF_DIR/locked.state" || -f "$CONF_DIR/fault.state" || -e /etc/systemd/system/vps-fw.service ]]
}
confirm_cli_lockdown() {
  # 交互终端下要求显式确认（与面板一致）；脚本/管道调用或 --yes 直接执行
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && return 0
  [[ -t 0 ]] || return 0
  printf '  %s警告: 将隔离所有非回环流量，包括当前 SSH，只能通过 VNC 恢复。输入 YES 确认: %s' "$C_RED" "$C_RESET"
  local ack=""
  read -r ack || return 1
  [[ "$ack" == "YES" ]] || { info "已取消"; return 1; }
}
valid_generation() {
  local gen="${1:-}" f
  [[ -n "$gen" && -d "$gen" && ! -L "$gen" ]] || return 1
  for f in fw.conf rules.db rules.nft manifest.sha256; do
    [[ -f "$gen/$f" && ! -L "$gen/$f" ]] || return 1
  done
  [[ -s "$gen/fw.conf" && -s "$gen/rules.nft" ]] || return 1
  [[ "$(wc -l < "$gen/manifest.sha256" | tr -d ' ')" == 3 ]] || return 1
  # The manifest must name exactly these three files; never follow an arbitrary path.
  [[ "$(awk '{print $2}' "$gen/manifest.sha256" | tr '\n' ' ')" == 'fw.conf rules.db rules.nft ' ]] || return 1
  ( cd "$gen" && sha256sum --status -c manifest.sha256 ) || return 1
  load_conf "$gen" && validate_render_config && validate_rule_database "$gen" || return 1
  nft -c -f "$gen/rules.nft" || return 1
}
install_live_nft() {
  local gen h
  gen="$(active_dir)" && valid_generation "$gen" || { fail_closed "已保存版本缺失或校验失败"; return 1; }
  nft -f "$gen/rules.nft" || { fail_closed "内核规则加载失败"; return 1; }
  h="$(live_table_hash)" && [[ -n "$h" ]] || { fail_closed "内核指纹读取失败"; return 1; }
  printf '%s\n' "$h" | atomic_write "$(fprint_file "$CONF_DIR")" || { fail_closed "指纹持久化失败"; return 1; }
}
explicit_restore() {
  is_initialized || { err "VPS-FW 尚未初始化，未执行任何操作；请先运行 fw 完成向导"; return 1; }
  [[ ! -f "$(pend_file "$CONF_DIR")" ]] || { err "存在未确认配置；请在面板 [6] 重新应用已核对的草稿，或执行 fw generations 后用 fw recover 版本ID 恢复，而非直接 restore"; return 1; }
  quarantine "人工恢复前隔离" 1 || return 1
  install_live_nft || return 1
  release_quarantine || { fail_closed "解除隔离失败"; return 1; }
  ok "完整性校验通过，已恢复保存的策略"
}
list_generations() {
  # 首列仍是版本 ID；按时间倒序并附创建时间。标记用 ASCII，VNC 文本控制台无法显示中文。
  local gen id cur prev mark
  [[ -d "$CONF_DIR/generations" ]] || return 1
  cur="$(readlink "$CONF_DIR/current" 2>/dev/null || true)"; cur="${cur##*/}"
  prev="$(cat "$CONF_DIR/previous" 2>/dev/null || true)"; prev="${prev##*/}"
  while IFS= read -r gen; do
    gen="${gen%/}"
    [[ -d "$gen" && ! -L "$gen" ]] || continue
    id="${gen##*/}"; mark=""
    [[ -n "$prev" && "$id" == "$prev" ]] && mark="  <- previous"
    [[ -n "$cur" && "$id" == "$cur" ]] && mark="  <- current"
    printf '%s  %s%s\n' "$id" "$(date -r "$gen" '+%F %T' 2>/dev/null || printf '?')" "$mark"
  done < <(ls -1dt "$CONF_DIR"/generations/*/ 2>/dev/null)
}
cmd_recover() {
  local version="$1" gen temp rc
  [[ "$version" =~ ^[0-9a-f]{24}$ ]] || { err "版本 ID 无效"; return 1; }
  gen="$CONF_DIR/generations/$version"
  # 选错/输错版本只报错，不隔离：此时尚未改动任何状态
  valid_generation "$gen" || { err "所选历史版本不存在或校验失败，未做任何更改；可用 fw generations 查看版本 ID"; return 1; }
  temp="$(mktemp -d "${TMPDIR:-/tmp}/vps-fw-recover.XXXXXX")" || return 1
  if ! cp "$gen/fw.conf" "$temp/fw.conf" || ! cp "$gen/rules.db" "$temp/rules.db"; then
    rm -rf -- "$temp"; return 1
  fi
  DRAFT_DIR="$temp"
  apply_draft_to_system 1; rc=$?
  rm -rf -- "$temp"
  return "$rc"
}
boot_restore() {
  is_initialized || { err "VPS-FW 尚未初始化，未执行任何操作；请先运行 fw 完成向导"; return 1; }
  if [[ -f "$CONF_DIR/locked.state" || -f "$CONF_DIR/fault.state" ]]; then
    reassert_quarantine; return 1
  fi
  if [[ -f "$(pend_file "$CONF_DIR")" ]]; then
    fail_closed "重启时存在未确认修改"; return 1
  fi
  # ExecStartPre has already installed independent lockdown rules.
  install_live_nft || return 1
  release_quarantine || { fail_closed "启动时解除隔离失败"; return 1; }
}
stop_rollback_timer_if_any() {
  # Only cancels old v3.0 timers during migration. Never stop our own service.
  local unit
  unit="$(awk -F= '/^UNIT=/{print $2; exit}' "$(pend_file "$CONF_DIR")" 2>/dev/null || true)"
  if [[ "$unit" =~ ^vps-fw-rollback-[0-9a-f]+$ ]]; then
    systemctl stop "$unit.timer" || return 1
  fi
}
cmd_auto_rollback() {
  # Legacy scheduled callback must fail closed too.
  local token="${1:-}" force="${2:-0}" cur
  [[ -f "$(pend_file "$CONF_DIR")" ]] || return 0
  cur="$(awk -F= '/^TOKEN=/{print $2}' "$(pend_file "$CONF_DIR")")"
  [[ "$force" == 1 || "$token" == "$cur" ]] || return 0
  fail_closed "未确认修改到期（旧版回调）"
}
do_rollback_unsafe() { fail_closed "已取消自动放宽式回滚；请使用 VNC 重新应用规则"; }
cmd_confirm() {
  local gen h expected
  [[ -f "$(pend_file "$CONF_DIR")" ]] || { err "没有待确认修改"; return 1; }
  [[ ! -f "$CONF_DIR/locked.state" && ! -f "$CONF_DIR/fault.state" ]] || { err "已隔离，必须从 VNC 重新应用规则"; return 1; }
  pending_expired && { fail_closed "确认已超时"; return 1; }
  systemctl is-active --quiet vps-fw-watch.timer && systemctl is-enabled --quiet vps-fw.service || { fail_closed "确认时启动保护或审计计时器不可用"; return 1; }
  gen="$(active_dir)" && valid_generation "$gen" || { fail_closed "确认时版本校验失败"; return 1; }
  h="$(live_table_hash)"; expected="$(cat "$(fprint_file "$CONF_DIR")" 2>/dev/null)"
  [[ -n "$h" && "$h" == "$expected" ]] || { fail_closed "确认时内核规则不一致"; return 1; }
  stop_rollback_timer_if_any && rm -f "$(pend_file "$CONF_DIR")" || { fail_closed "确认状态写入失败"; return 1; }
  sync -f "$CONF_DIR" || { fail_closed "确认状态落盘失败"; return 1; }
  ok "已确认当前完整版本，启动时将验证后恢复"
}
pending_expired() {
  local start secs
  [[ -f "$(pend_file "$CONF_DIR")" ]] || return 1
  start="$(awk -F= '/^START_EPOCH=/{print $2}' "$(pend_file "$CONF_DIR")")"
  secs="$(awk -F= '/^SECS=/{print $2}' "$(pend_file "$CONF_DIR")")"
  [[ "$start" =~ ^[1-9][0-9]{0,11}$ && "$secs" =~ ^[1-9][0-9]{0,3}$ ]] || return 0
  (( $(date +%s) < start || $(date +%s) >= start + secs ))
}
cmd_audit() {
  local gen h expected
  # 定时审计遇到此情况仍会失败，由 vps-fw-watch 的 OnFailure 应急隔离兜底
  is_initialized || { err "VPS-FW 尚未初始化，未执行任何操作；请先运行 fw 完成向导"; return 1; }
  if [[ -f "$CONF_DIR/locked.state" || -f "$CONF_DIR/fault.state" ]]; then
    reassert_quarantine; return 1
  fi
  pending_expired && { fail_closed "未在期限内确认"; return 1; }
  gen="$(active_dir)" && valid_generation "$gen" || { fail_closed "审计发现保存版本损坏或缺失"; return 1; }
  h="$(live_table_hash || true)"; expected="$(cat "$(fprint_file "$CONF_DIR")" 2>/dev/null || true)"
  [[ -n "$h" && "$h" == "$expected" ]] || { fail_closed "审计发现内核规则缺失或变化"; return 1; }
  printf 'PASS\n'
}
write_systemd_units() {
  mkdir -p /etc/systemd/system || return 1
  atomic_write /etc/systemd/system/vps-fw.service 644 <<EOF
[Unit]
Description=VPS-FW verified firewall (fail closed)
DefaultDependencies=no
Wants=network-pre.target
After=local-fs.target nftables.service
Requires=local-fs.target
Before=network-pre.target docker.service containerd.service shutdown.target
Conflicts=shutdown.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/nft 'add table inet vps_fw_lockdown; delete table inet vps_fw_lockdown; add table inet vps_fw_lockdown; add chain inet vps_fw_lockdown lock_input { type filter hook input priority -310; policy drop; }; add rule inet vps_fw_lockdown lock_input iifname lo accept; add chain inet vps_fw_lockdown lock_output { type filter hook output priority -310; policy drop; }; add rule inet vps_fw_lockdown lock_output oifname lo accept; add chain inet vps_fw_lockdown lock_forward { type filter hook forward priority -310; policy drop; }'
ExecStart=$EXEC_PATH boot-restore
ExecReload=$EXEC_PATH audit
[Install]
WantedBy=sysinit.target
EOF
  [[ $? == 0 ]] || return 1
  atomic_write /etc/systemd/system/vps-fw-watch.service 644 <<EOF
[Unit]
Description=VPS-FW integrity and pending deadline check
After=vps-fw.service
OnFailure=vps-fw-quarantine.service
[Service]
Type=oneshot
TimeoutStartSec=20s
SuccessExitStatus=75
ExecStart=$EXEC_PATH watch
EOF
  [[ $? == 0 ]] || return 1
  atomic_write /etc/systemd/system/vps-fw-watch.timer 644 <<'EOF'
[Unit]
Description=VPS-FW continuous integrity check
[Timer]
OnBootSec=5s
OnUnitActiveSec=5s
AccuracySec=1s
Unit=vps-fw-watch.service
[Install]
WantedBy=timers.target
EOF
  [[ $? == 0 ]] || return 1
  atomic_write /etc/systemd/system/vps-fw-quarantine.service 644 <<'EOF'
[Unit]
Description=VPS-FW independent emergency quarantine
DefaultDependencies=no
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/bin/flock -w 5 /run/vps-fw-guard.lock /bin/sh -ec 'umask 077; mkdir -p /etc/vps-fw || :; touch /etc/vps-fw/fault.state || :; /usr/sbin/nft "add table inet vps_fw_lockdown; delete table inet vps_fw_lockdown; add table inet vps_fw_lockdown; add chain inet vps_fw_lockdown lock_input { type filter hook input priority -310; policy drop; }; add rule inet vps_fw_lockdown lock_input iifname lo accept; add chain inet vps_fw_lockdown lock_output { type filter hook output priority -310; policy drop; }; add rule inet vps_fw_lockdown lock_output oifname lo accept; add chain inet vps_fw_lockdown lock_forward { type filter hook forward priority -310; policy drop; }"; test -f /etc/vps-fw/locked.state || echo systemd-guard-failure > /etc/vps-fw/locked.state; sync -f /etc/vps-fw'
TimeoutStartSec=20s
EOF
  [[ $? == 0 ]] || return 1
  systemctl daemon-reload || return 1
  systemctl enable vps-fw.service || return 1
  local unit
  for unit in docker.service containerd.service; do
    if [[ "$(systemctl show -p LoadState --value "$unit")" == loaded ]]; then
      bind_service "$unit" || return 1
    fi
  done
}
bind_service() {
  local unit="$1"
  [[ "$unit" =~ ^[a-zA-Z0-9_@.-]+\.service$ && "$unit" != vps-fw* ]] || { err "无效业务 service 名称"; return 1; }
  mkdir -p "/etc/systemd/system/$unit.d" || return 1
  atomic_write "/etc/systemd/system/$unit.d/50-vps-fw.conf" 644 <<'EOF'
[Unit]
Requires=vps-fw.service
After=vps-fw.service
[Service]
ExecStartPre=+/usr/local/sbin/vps-fw health
EOF
  [[ $? == 0 ]] || return 1
  systemctl daemon-reload
}
health_check() {
  [[ ! -f "$CONF_DIR/locked.state" && ! -f "$CONF_DIR/fault.state" && ! -f "$(pend_file "$CONF_DIR")" ]] || return 1
  cmd_audit
}
apply_draft_to_system() {
  local trial="${1:-1}" stage gen token old
  load_conf "$DRAFT_DIR" && validate_render_config && validate_rule_database "$DRAFT_DIR" || return 1
  if (( DEMO_MODE == 1 )); then
    render_nft_ruleset "$DRAFT_DIR" "$DRAFT_DIR/rules.nft" || return 1
    ok "[演示] 已校验并生成草稿，不修改正式配置"; return 0
  fi
  mkdir -p "$CONF_DIR/generations" && chmod 700 "$CONF_DIR" "$CONF_DIR/generations" || return 1
  token="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [[ "$token" =~ ^[0-9a-f]{24}$ ]] || return 1
  stage="$CONF_DIR/generations/$token"
  mkdir -m700 "$stage" || return 1
  # 此阶段失败尚未触碰线上状态：清掉半成品版本目录，避免历史列表里堆积无效版本
  if ! { cp "$(conf_file "$DRAFT_DIR")" "$stage/fw.conf" && cp "$(rules_file "$DRAFT_DIR")" "$stage/rules.db" \
      && render_nft_ruleset "$stage" "$stage/rules.nft" \
      && ( cd "$stage" && sha256sum fw.conf rules.db rules.nft > manifest.sha256 ) \
      && chmod 600 "$stage/"* && valid_generation "$stage"; }; then
    rm -rf -- "$stage"
    return 1
  fi
  # From this point any failure leaves a persistent quarantine, never a deleted table.
  quarantine "应用事务进行中" 1 || return 1
  write_systemd_units || { fail_closed "启动保护配置写入失败"; return 1; }
  stop_rollback_timer_if_any || return 1
  old="$(readlink "$CONF_DIR/current" 2>/dev/null || true)"
  [[ -z "$old" ]] || printf '%s\n' "$old" | atomic_write "$CONF_DIR/previous" || return 1
  # 试用应用先写待确认标记再切换 current：两步之间崩溃时，新版本不会被当作已确认版本恢复
  if [[ "$trial" == 1 ]]; then
    printf 'TOKEN=%s\nSTART_EPOCH=%s\nSECS=%s\n' "$token" "$(date +%s)" "$CFG_ROLLBACK_SECS" | atomic_write "$(pend_file "$CONF_DIR")" || return 1
  fi
  ln -s "generations/$token" "$CONF_DIR/.current-$token" && mv -Tf "$CONF_DIR/.current-$token" "$CONF_DIR/current" || return 1
  if [[ "$trial" != 1 ]]; then
    rm -f "$(pend_file "$CONF_DIR")" || return 1
  fi
  sync -f "$CONF_DIR" || return 1
  install_live_nft || return 1
  systemctl enable --now vps-fw-watch.timer && systemctl is-active --quiet vps-fw-watch.timer || { fail_closed "审计定时器未启动"; return 1; }
  release_quarantine || { fail_closed "解除隔离失败"; return 1; }
  CHANGES_PENDING=0
  ok "规则已应用；未确认到期或异常时将隔离，不会自动开放公网"
}
cmd_emergency_off() { quarantine "用户请求隔离"; }
cmd_uninstall() { err "严格模式不自动卸载保护。请在 VNC 中按文档执行人工退役流程。"; return 1; }

validate_ipv6_cidr() {
  local value="$1" addr mask part count=0 compressed=0 rest
  addr="${value%%/*}"
  if [[ "$value" == */* ]]; then
    mask="${value#*/}"
    [[ "$mask" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( mask<=128 )) || return 1
  fi
  [[ "$addr" == *:* && "$addr" =~ ^[0-9a-fA-F:]+$ && "$addr" != *:::* ]] || return 1
  [[ "$addr" != :* || "$addr" == ::* ]] || return 1
  [[ "$addr" != *: || "$addr" == *:: ]] || return 1
  if [[ "$addr" == *::* ]]; then
    compressed=1; rest="${addr#*::}"; [[ "$rest" != *::* ]] || return 1
  else
    [[ "$addr" != :* && "$addr" != *: ]] || return 1
  fi
  local -a chunks=()
  IFS=: read -r -a chunks <<< "$addr"
  for part in "${chunks[@]}"; do
    [[ -n "$part" ]] || continue
    [[ "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    count=$((count+1))
  done
  if (( compressed )); then (( count<8 )); else (( count==8 )); fi
}
validate_rule_database() {
  local dir="$1" f rid enabled action direction scope proto ports cidr comment ids=, total=0
  f="$(rules_file "$dir")"
  [[ -f "$f" ]] || { err "规则数据库缺失"; return 1; }
  while IFS='|' read -r rid enabled action direction scope proto ports cidr comment || [[ -n "$rid" ]]; do
    [[ -n "$rid" && "$rid" != \#* ]] || continue
    [[ "$rid" =~ ^[1-9][0-9]{0,8}$ && "$ids" != *",$rid,"* ]] || return 1
    ids+="$rid,"; total=$((total+1)); (( total<=256 )) || { err "规则数量超过上限 256 条"; return 1; }
    [[ "$enabled" == 0 || "$enabled" == 1 ]] || return 1
    [[ "$action" == accept || "$action" == drop ]] || return 1
    [[ "$direction" == in || "$direction" == out ]] || return 1
    [[ "$scope" == host || "$scope" == docker || "$scope" == all ]] || return 1
    case "$proto" in tcp|udp|both) ;; any|icmp) [[ "$ports" == any ]] || return 1 ;; *) return 1 ;; esac
    normalize_ports "$ports" && [[ "$NORM_OUT" == "$ports" ]] || return 1
    normalize_cidrs "$cidr" && [[ "$NORM_OUT" == "$cidr" ]] || return 1
    [[ "$comment" != *'|'* ]] || return 1
  done < "$f"
}

main "$@"
