#!/bin/bash
# =============================================================================
# proxy-residue-scan.sh — 代理/VPN 残留只读扫描（macOS）
#
# 用途：路由器透明接管方案下，运营机本机不该有任何代理/VPN 残留。
#       本脚本把常见残留全部扫出来给你看，但【只读】——不删任何东西，
#       清理动作由你按 playbook/04-device-hygiene.md 人工执行。
#
# 扫描面：
#   1. 运行中的代理/VPN 进程
#   2. 常见代理端口监听
#   3. 系统代理设置
#   4. 系统 VPN 配置
#   5. LaunchAgents / LaunchDaemons 文件名命中
#   6. launchctl 已加载项命中
#   7. 第三方系统扩展（网络扩展）
#   8. 配置描述文件（需人工确认项）
#   9. shell 启动文件里的代理环境变量（只报 文件:行号 + 变量名，不回显值）
#  10. 当前环境变量里的代理设置（同上脱敏）
#  11. 应用配置目录 / 偏好文件残留
#  12. /Applications 里的 VPN/代理类 App
#
# 退出码：0 = 未发现残留（允许 WARN）；1 = 发现残留（FAIL）
# =============================================================================

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

# 代理/VPN 关键词表（进程、plist、App 共用）
# 注意：stash/loon 这类短词必须带分隔符匹配，避免误伤系统服务
# （如 com.apple.security.KeychainStasher 含 "stash"，com.apple.balloond 含 "loon"）
KW='clash|v2ray|xray|sing-box|singbox|shadowsocks|trojan|hysteria|naiveproxy|tuic|wireguard|openvpn|tailscale|zerotier|cloudflare-warp|cloudflared|warp-svc|surge|loon\.|\.loon|stash\.|\.stash|quantumult|shadowrocket|proxifier|charles|mitmproxy|fiddler|tunnelblick|anyconnect|globalprotect|forticlient|openconnect|outline|expressvpn|nordvpn|surfshark|mullvad|protonvpn|windscribe|astrill|letsvpn|quickq|v2box'

echo "===== proxy-residue-scan $(date '+%Y-%m-%d %H:%M:%S %z') ====="
echo "（只读扫描，不修改任何系统状态）"
echo

# ---------- 1. 进程 ----------
echo "--- 1. 运行中的代理/VPN 进程 ---"
HITS=$(ps -axo user,pid,comm,args 2>/dev/null | grep -iE "$KW" | grep -v 'grep' || true)
if [ -n "$HITS" ]; then
  fail "发现运行中的相关进程："
  echo "$HITS" | sed 's/^/      /'
else
  pass "无相关进程"
fi
echo

# ---------- 2. 常见代理端口监听 ----------
echo "--- 2. 常见代理端口监听 ---"
PORTS=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ':(1080|1086|1087|10808|10809|7890|7891|7897|9090|9091|8080|8118|3128|6152|6153|8889) ' || true)
if [ -n "$PORTS" ]; then
  fail "发现常见代理端口在监听（确认进程身份后清理）："
  echo "$PORTS" | sed 's/^/      /'
else
  pass "常见代理端口均无监听"
fi
echo

# ---------- 3. 系统代理设置 ----------
echo "--- 3. 系统代理设置 ---"
PROXY_ON=$(scutil --proxy 2>/dev/null | awk '/Enable : 1/{print $1}')
if [ -n "$PROXY_ON" ]; then
  fail "系统代理处于开启状态: $(echo $PROXY_ON | tr '\n' ' ')——去 系统设置→Wi-Fi→详细信息→代理 全部关闭"
else
  pass "系统代理全关"
fi
echo

# ---------- 4. 系统 VPN 配置 ----------
echo "--- 4. 系统 VPN 配置 ---"
VPN_LIST=$(scutil --nc list 2>/dev/null | grep -E '^\* \(' || true)
if [ -n "$VPN_LIST" ]; then
  fail "系统里存在 VPN 配置——去 系统设置→VPN 删除："
  echo "$VPN_LIST" | sed 's/^/      /'
else
  pass "无系统 VPN 配置"
fi
echo

# ---------- 5. LaunchAgents / LaunchDaemons 文件名 ----------
echo "--- 5. LaunchAgents / LaunchDaemons 残留 ---"
LD_HITS=""
for d in "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons; do
  [ -d "$d" ] || continue
  H=$(ls "$d" 2>/dev/null | grep -iE "$KW" || true)
  [ -n "$H" ] && LD_HITS="${LD_HITS}${H}
"
done
if [ -n "$LD_HITS" ]; then
  fail "发现开机自启 plist 残留（bootout 后删除，方法见 playbook 04）："
  echo "$LD_HITS" | sed '/^$/d; s/^/      /'
else
  pass "三个自启目录均无文件名命中"
fi
echo

# ---------- 6. launchctl 已加载项 ----------
echo "--- 6. launchctl 已加载项 ---"
LC_HITS=$(launchctl list 2>/dev/null | grep -iE "$KW" || true)
if [ -n "$LC_HITS" ]; then
  fail "launchctl 中仍有已加载的相关服务："
  echo "$LC_HITS" | sed 's/^/      /'
else
  pass "launchctl 无命中"
fi
echo

# ---------- 7. 第三方系统扩展 ----------
echo "--- 7. 系统扩展（网络扩展） ---"
SEXT=$(systemextensionsctl list 2>/dev/null | awk '/^---/{cat=$0; next} /^\*/{print}' || true)
if [ -n "$SEXT" ]; then
  warn "存在已激活的第三方系统扩展（VPN 类必须卸载；确认每一项是什么）："
  echo "$SEXT" | sed 's/^/      /'
  info  "卸载方法: 系统设置→通用→登录项与扩展→网络扩展，或 systemextensionsctl uninstall <TeamID> <bundleID>"
else
  pass "无第三方系统扩展"
fi
echo

# ---------- 8. 配置描述文件 ----------
echo "--- 8. 配置描述文件 ---"
PROFILES_OUT=$(profiles list 2>&1 | head -5 || true)
case "$PROFILES_OUT" in
  *"There are no"*)
    pass "无配置描述文件" ;;
  *error*|*Error*|*"requires root"*)
    info "无法自动列出描述文件（需要权限）——请人工确认：系统设置→通用→VPN与设备管理，应无任何含 VPN/代理/内容过滤的描述文件" ;;
  *)
    warn "检测到配置描述文件，请人工确认其 payload 不含 VPN/代理/内容过滤："
    echo "$PROFILES_OUT" | sed 's/^/      /' ;;
esac
echo

# ---------- 9. shell 启动文件代理变量（脱敏：只报 文件:行号 + 变量名） ----------
echo "--- 9. shell 启动文件代理变量 ---"
RC_HITS=""
for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bash_profile" "$HOME/.bashrc"; do
  [ -f "$f" ] || continue
  H=$(grep -nEi '(http_proxy|https_proxy|all_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)' "$f" 2>/dev/null | sed -E 's/=.*/=***REDACTED***/' || true)
  [ -n "$H" ] && RC_HITS="${RC_HITS}${f}:
${H}
"
done
if [ -n "$RC_HITS" ]; then
  fail "shell 启动文件含代理变量（值已脱敏；手动编辑删除后重开终端）："
  echo "$RC_HITS" | sed 's/^/      /'
else
  pass "shell 启动文件无代理变量"
fi
echo

# ---------- 10. 当前环境变量（脱敏） ----------
echo "--- 10. 当前 shell 环境变量 ---"
ENV_HITS=$(env 2>/dev/null | grep -iE '^(http_proxy|https_proxy|all_proxy)=' | sed -E 's/=.*/=***REDACTED***/' || true)
if [ -n "$ENV_HITS" ]; then
  fail "当前环境变量含代理设置："
  echo "$ENV_HITS" | sed 's/^/      /'
else
  pass "环境变量无代理设置"
fi
echo

# ---------- 11. 配置目录 / 偏好残留 ----------
echo "--- 11. 配置目录与偏好残留 ---"
DIR_HITS=""
for p in \
  "$HOME/.config/clash" "$HOME/.config/clash.meta" "$HOME/.config/sing-box" \
  "$HOME/.config/v2ray" "$HOME/.config/wireguard" \
  "$HOME/Library/Application Support/ClashX" "$HOME/Library/Application Support/ClashX Pro" \
  "$HOME/Library/Application Support/V2rayU" "$HOME/Library/Application Support/Surge" \
  "$HOME/Library/Application Support/Tailscale" "$HOME/Library/Application Support/Stash" \
  "$HOME/Library/Application Support/loon" \
  ; do
  [ -e "$p" ] && DIR_HITS="${DIR_HITS}${p}
"
done
PREF_HITS=$(ls "$HOME/Library/Preferences" 2>/dev/null | grep -iE 'clash|v2ray|xray|sing-box|singbox|surge|stash|wireguard|tunnelblick' || true)
if [ -n "$DIR_HITS$PREF_HITS" ]; then
  fail "发现配置目录/偏好残留（删除对应目录或 plist）："
  [ -n "$DIR_HITS" ] && echo "$DIR_HITS" | sed '/^$/d; s/^/      /'
  [ -n "$PREF_HITS" ] && echo "$PREF_HITS" | sed "s|^|      $HOME/Library/Preferences/|"
else
  pass "无配置目录/偏好残留"
fi
echo

# ---------- 12. /Applications VPN/代理类 App ----------
echo "--- 12. 应用目录 ---"
APP_HITS=$( (ls /Applications 2>/dev/null; ls "$HOME/Applications" 2>/dev/null) | grep -iE "$KW" || true)
if [ -n "$APP_HITS" ]; then
  fail "发现 VPN/代理类 App（用官方卸载器卸载，勿只拖废纸篓）："
  echo "$APP_HITS" | sed 's/^/      /'
else
  pass "应用目录无 VPN/代理类 App"
fi
echo

# ---------- 汇总 ----------
echo "===== 汇总: PASS=${PASS_N} FAIL=${FAIL_N} WARN=${WARN_N} ====="
if [ "$FAIL_N" -gt 0 ]; then
  echo "${C_R}RESULT: FAIL${C_0} —— 按 playbook/04-device-hygiene.md 4.3 逐项清理后复扫"
  exit 1
fi
echo "${C_G}RESULT: PASS${C_0}（WARN 项需能说清保留理由，如公司强制 VPN）"
exit 0
