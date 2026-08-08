#!/bin/bash
# =============================================================================
# ip-sentinel.sh — 出口 IP 哨兵：当前出口 vs 预期住宅 IP 文件（macOS）
#
# 设计用途：由 launchd 每小时（或 cron）定时运行，也支持手动跑。
# 三种结局：
#   OK       出口 == 预期 IP            退出码 0
#   MISMATCH 出口 != 预期 IP（漂移/回落）退出码 1  + 系统通知
#   DOWN     三源全部取不到出口（断网/隧道停，fail-closed 生效中）退出码 2 + 系统通知
#   CONFIG   预期 IP 文件缺失或非法      退出码 3
#
# 用法：
#   ip-sentinel.sh                          # 标准运行
#   ip-sentinel.sh --quiet                  # OK 时不输出 stdout（仍写日志），适合定时任务
#   ip-sentinel.sh --expected-file PATH     # 覆盖默认预期文件
#   ip-sentinel.sh --log PATH               # 覆盖默认日志路径
#   ip-sentinel.sh --no-notify              # 禁用 macOS 弹窗通知
#
# 默认路径：
#   预期 IP 文件: ~/overseas-ops/expected-exit-ip.txt（一行一个 IPv4）
#   日志:         ~/overseas-ops/logs/ip-sentinel.log（追加，每行一条）
#
# 本脚本只读：不修改任何网络/系统配置。
# =============================================================================

EXPECTED_FILE="${HOME}/overseas-ops/expected-exit-ip.txt"
LOG_FILE="${HOME}/overseas-ops/logs/ip-sentinel.log"
QUIET=0
NOTIFY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --expected-file) EXPECTED_FILE="${2:-}"; shift 2 ;;
    --log)           LOG_FILE="${2:-}"; shift 2 ;;
    --quiet)         QUIET=1; shift ;;
    --no-notify)     NOTIFY=0; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32
      exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 64 ;;
  esac
done

TS() { date '+%Y-%m-%dT%H:%M:%S%z'; }

is_ipv4() { echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

notify() {
  [ "$NOTIFY" -eq 1 ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$1\" with title \"出口IP哨兵\" sound name \"Basso\"" >/dev/null 2>&1 || true
}

emit() {
  # $1=状态 $2=正文；写日志 + 按 quiet 规则输出 stdout
  local line="$(TS) $1 $2"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
  if [ "$1" = "OK" ] && [ "$QUIET" -eq 1 ]; then
    return 0
  fi
  echo "$line"
}

# --- 读取预期 IP ---
if [ ! -f "$EXPECTED_FILE" ]; then
  emit CONFIG "预期 IP 文件不存在: ${EXPECTED_FILE}（先 echo \"<你的住宅IP>\" 写入该文件）"
  exit 3
fi
EXPECTED_IP=$(head -n 1 "$EXPECTED_FILE" | tr -d '[:space:]')
if ! is_ipv4 "$EXPECTED_IP"; then
  emit CONFIG "预期 IP 文件内容非法: '${EXPECTED_IP}'（只写一行 IPv4）"
  exit 3
fi

# --- 多源取当前出口（任一源取到即停） ---
ACTUAL_IP=""
SRC=""
ip=$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
if is_ipv4 "$ip"; then ACTUAL_IP="$ip"; SRC="ipify"; fi
if [ -z "$ACTUAL_IP" ]; then
  ip=$(curl -4 -sS --max-time 10 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]' || true)
  if is_ipv4 "$ip"; then ACTUAL_IP="$ip"; SRC="ifconfig.me"; fi
fi
if [ -z "$ACTUAL_IP" ]; then
  ip=$(curl -4 -sS --max-time 10 'https://1.1.1.1/cdn-cgi/trace' 2>/dev/null | sed -n 's/^ip=//p' | tr -d '[:space:]' || true)
  if is_ipv4 "$ip"; then ACTUAL_IP="$ip"; SRC="cloudflare"; fi
fi

# --- 判定 ---
if [ -z "$ACTUAL_IP" ]; then
  emit DOWN "三源全部取不到出口 IP——断网或隧道停止（fail-closed 生效属预期），按 docs/recovery.md 排查"
  notify "取不到出口 IP：断网或隧道已停止（fail-closed）。立即停止账号操作。"
  exit 2
fi

if [ "$ACTUAL_IP" = "$EXPECTED_IP" ]; then
  emit OK "出口一致 (${ACTUAL_IP} via ${SRC})"
  exit 0
fi

emit MISMATCH "预期 ${EXPECTED_IP} 实际 ${ACTUAL_IP} (via ${SRC})——IP 漂移或回落，立即停止账号操作"
notify "出口 IP 漂移：预期 ${EXPECTED_IP}，实际 ${ACTUAL_IP}。立即停止账号操作！"
exit 1
