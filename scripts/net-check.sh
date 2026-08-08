#!/bin/bash
# =============================================================================
# net-check.sh — 海外运营网络体检：连通性 + 出口一致性（macOS，只读）
#
# 检查项：
#   1. HTTPS 连通性（不用 ICMP ping——透明接管不一定承载 ICMP，ping 不通 ≠ 断网）
#   2. 出口 IP 多源一致性（ipify / ifconfig.me / Cloudflare trace 三源交叉）
#   3. 出口 IP == 预期住宅 IP（读本地 expected-exit-ip.txt）
#   4. DNS 粗查：系统解析器不得指向中国境内公共 DNS
#   5. 系统代理必须为全关（透明接管方案下本机不应开任何系统代理）
#   6. IPv6 旁路：物理接口不得有独立 IPv6 默认路由（绕过隧道的隐蔽通道）
#   7. utun 隧道接口提示（本机不应有；iCloud Private Relay 也会建，应关闭）
#
# 用法：
#   net-check.sh                          # 标准体检
#   net-check.sh --expected-file PATH     # 指定预期 IP 文件
#   net-check.sh --no-expected            # 跳过预期 IP 比对（02 施工期用）
#
# 退出码：0 = 全部 PASS（允许 WARN）；1 = 存在 FAIL
# 本脚本只读，不修改任何系统状态。
# =============================================================================

EXPECTED_FILE="${HOME}/overseas-ops/expected-exit-ip.txt"
CHECK_EXPECTED=1

while [ $# -gt 0 ]; do
  case "$1" in
    --expected-file) EXPECTED_FILE="${2:-}"; shift 2 ;;
    --no-expected)   CHECK_EXPECTED=0; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
      exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 64 ;;
  esac
done

PASS_N=0; FAIL_N=0; WARN_N=0

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''
fi

pass() { PASS_N=$((PASS_N+1)); echo "${C_G}[PASS]${C_0} $1"; }
fail() { FAIL_N=$((FAIL_N+1)); echo "${C_R}[FAIL]${C_0} $1"; }
warn() { WARN_N=$((WARN_N+1)); echo "${C_Y}[WARN]${C_0} $1"; }
info() { echo "${C_B}[INFO]${C_0} $1"; }

is_ipv4() { echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

echo "===== net-check $(date '+%Y-%m-%d %H:%M:%S %z') ====="
echo

# --- 动态发现活跃接口（不写死 en0/Wi-Fi）---
ACTIVE_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
info "活跃接口: ${ACTIVE_IF:-未发现}"
echo

# ---------- 1. HTTPS 连通性 ----------
echo "--- 1. HTTPS 连通性 ---"
CODE=$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 10 https://www.gstatic.com/generate_204 2>/dev/null || true)
if [ "$CODE" = "204" ]; then
  pass "HTTPS 探针正常（generate_204 返回 204）"
else
  fail "HTTPS 探针异常（generate_204 返回 '${CODE:-无响应}'）——先确认是否处于 fail-closed 断网状态"
fi
echo

# ---------- 2. 出口 IP 多源一致性 ----------
echo "--- 2. 出口 IP 多源一致性 ---"
IP1=$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
IP2=$(curl -4 -sS --max-time 10 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]' || true)
IP3=$(curl -4 -sS --max-time 10 'https://1.1.1.1/cdn-cgi/trace' 2>/dev/null | sed -n 's/^ip=//p' | tr -d '[:space:]' || true)

SEEN=""
N_OK=0
for src_ip in "ipify:$IP1" "ifconfig.me:$IP2" "cloudflare:$IP3"; do
  src="${src_ip%%:*}"; ip="${src_ip#*:}"
  if is_ipv4 "$ip"; then
    info "${src} 出口: ${ip}"
    N_OK=$((N_OK+1))
    case " $SEEN " in
      *" $ip "*) : ;;
      *) SEEN="$SEEN $ip" ;;
    esac
  else
    info "${src} 出口: 未取到"
  fi
done

N_DISTINCT=$(echo $SEEN | wc -w | tr -d ' ')
if [ "$N_OK" -ge 2 ] && [ "$N_DISTINCT" -eq 1 ]; then
  EXIT_IP=$(echo $SEEN | awk '{print $1}')
  pass "三源出口一致: ${EXIT_IP}"
elif [ "$N_OK" -ge 2 ]; then
  fail "多源出口互相矛盾（$(echo $SEEN | tr ' ' '/') ）——链路存在分流或泄露"
  EXIT_IP=""
elif [ "$N_OK" -eq 1 ]; then
  EXIT_IP=$(echo $SEEN | awk '{print $1}')
  warn "只有一个来源可用（${EXIT_IP}），无法交叉验证，建议网络恢复后重跑"
else
  fail "三个来源全部取不到出口 IP"
  EXIT_IP=""
fi
echo

# ---------- 3. 预期出口 IP 比对 ----------
echo "--- 3. 预期出口 IP 比对 ---"
if [ "$CHECK_EXPECTED" -eq 0 ]; then
  info "按 --no-expected 跳过本项"
elif [ ! -f "$EXPECTED_FILE" ]; then
  fail "预期 IP 文件不存在: ${EXPECTED_FILE}
      先执行: echo \"<你的住宅IP>\" > ${EXPECTED_FILE} && chmod 600 ${EXPECTED_FILE}"
else
  EXPECTED_IP=$(head -n 1 "$EXPECTED_FILE" | tr -d '[:space:]')
  if ! is_ipv4 "$EXPECTED_IP"; then
    fail "预期 IP 文件内容不是合法 IPv4: '${EXPECTED_IP}'（文件里只写一行 IP，别的都不要写）"
  elif [ -z "$EXIT_IP" ]; then
    warn "出口 IP 未取到，无法与预期 ${EXPECTED_IP} 比对"
  elif [ "$EXIT_IP" = "$EXPECTED_IP" ]; then
    pass "出口 IP == 预期住宅 IP（${EXPECTED_IP}）"
  else
    fail "出口 IP（${EXIT_IP}）!= 预期住宅 IP（${EXPECTED_IP}）——发生漂移或回落，立即停止账号操作"
  fi
fi
echo

# ---------- 4. DNS 粗查（中国境内公共 DNS） ----------
echo "--- 4. DNS 粗查 ---"
RESOLVERS=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\] : /{print $3}' | sort -u)
if [ -z "$RESOLVERS" ]; then
  warn "scutil --dns 未列出任何解析器"
else
  info "当前解析器: $(echo $RESOLVERS | tr '\n' ' ')"
  CN_DNS=$(echo "$RESOLVERS" | grep -xE '114\.114\.(114|115)\.11[45]|223\.(5|6)\.[56]\.[56]|119\.29\.29\.29|182\.254\.116\.116|180\.76\.76\.76|210\.2\.4\.8|1\.2\.4\.8|117\.50\.1[01]\.1[01]|101\.226\.4\.6|218\.30\.118\.6' || true)
  if [ -n "$CN_DNS" ]; then
    fail "系统 DNS 指向中国境内公共 DNS: $(echo $CN_DNS | tr '\n' ' ')——回 02 检查路由器 DNS 链路"
  else
    pass "未发现中国境内公共 DNS（192.168.8.1 = 路由器本地转发，属正常）"
  fi
fi
echo

# ---------- 5. 系统代理必须为全关 ----------
echo "--- 5. 系统代理状态 ---"
PROXY_ON=$(scutil --proxy 2>/dev/null | awk '/Enable : 1/{print $1}')
if [ -n "$PROXY_ON" ]; then
  fail "系统代理被打开: $(echo $PROXY_ON | tr '\n' ' ')——透明接管方案下应全关，去 系统设置→Wi-Fi→详细信息→代理 关闭"
else
  pass "系统代理全关（HTTP/HTTPS/SOCKS/自动发现均未启用）"
fi
echo

# ---------- 6. IPv6 旁路 ----------
echo "--- 6. IPv6 旁路 ---"
V6_DEF_IF=$(netstat -rn -f inet6 2>/dev/null | awk '$1=="default"{print $4; exit}')
if [ -z "$V6_DEF_IF" ]; then
  pass "无 IPv6 默认路由——不存在绕过隧道的 IPv6 路径"
else
  case "$V6_DEF_IF" in
    utun*)
      warn "IPv6 默认路由在隧道接口 ${V6_DEF_IF}——确认隧道本身接管 IPv6，否则存在旁路" ;;
    *)
      fail "物理接口 ${V6_DEF_IF} 存在 IPv6 默认路由——IPv6 流量可能绕过隧道直连，去路由器关闭 IPv6 或确认其被接管" ;;
  esac
fi
V6_PUBLIC=$(curl -6 -sS --max-time 8 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)
case "$V6_PUBLIC" in
  *:*) info "curl -6 实测返回公网 IPv6（${V6_PUBLIC}）——结合上一条判定" ;;
  *)   : ;;
esac
echo

# ---------- 7. utun 隧道接口提示 ----------
echo "--- 7. 本机隧道接口 ---"
UTUN_N=$(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -c '^utun' || true)
if [ "${UTUN_N:-0}" -gt 0 ]; then
  warn "本机存在 ${UTUN_N} 个 utun 隧道接口——透明接管方案下通常不应有；常见来源：iCloud 专用代理（应关闭）、残留 VPN 客户端"
else
  pass "无 utun 隧道接口"
fi
echo

# ---------- 汇总 ----------
echo "===== 汇总: PASS=${PASS_N} FAIL=${FAIL_N} WARN=${WARN_N} ====="
if [ "$FAIL_N" -gt 0 ]; then
  echo "${C_R}RESULT: FAIL${C_0} —— 先修 FAIL 项再继续（对照 playbook/03-verify-leak.md）"
  exit 1
fi
echo "${C_G}RESULT: PASS${C_0}（WARN 项需人工确认理由）"
echo "提示：脚本只覆盖机判项；WebRTC/时区/语言/IP 信誉必须按 playbook 03 在浏览器人工完成"
exit 0
