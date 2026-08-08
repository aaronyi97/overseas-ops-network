# 阶段 02：路由器透明接管（断网重灾区）

> 本阶段是全程断网风险最高的阶段，共 4 个 ⛔高危步骤。
> 每个 ⛔ 步骤都执行高危刹车协议：一句话告知风险和恢复手段 →
> 你（AI）生成并保存本地恢复脚本到用户本机 → 确认国内备用网络就位 → 用户说"继续"才动手。
> 非 ⛔ 步骤全部你直接执行、自己验收，不问用户。

## 本阶段目标

把 GL.iNet MT3600BE 路由器变成"透明海外网关"：

- 路由器上跑 sing-box 客户端，VLESS + Reality 隧道连 VPS
- TUN + TPROXY 双路透明接管：连上 WiFi 的设备零配置出海
- 双层 fail-closed：隧道/进程任一异常 = 直接断网，绝不裸奔
- 重启自动恢复：断电重启后不用碰任何配置
- DNS 加密防污染：dnsmasq → dnscrypt-proxy2（DoH）

## 前置条件

- [ ] 阶段 00 完成：`~/overseas-ops/` 已建好，备用网络 + 备用 AI 就位
- [ ] 阶段 01 完成：`secrets.txt` 里已有 VPS 的 IP、端口、UUID、
      Reality SNI / 公钥 / short_id，且当时已手动连通过一次
- [ ] 电脑已连上路由器的 WiFi（或网线），你能打开 http://192.168.8.1
      管理页，能 `ssh root@192.168.8.1` 登录
- [ ] 电脑上**关闭所有本机代理/TUN 类软件**（v2rayN、Clash 等）——
      本阶段所有验收都必须在"本机零代理、纯直连路由器"下进行，
      否则结果不算数（实测踩坑：本机 TUN 会污染验收结论）。
      开工前你检查一遍本机代理状态，发现有在跑的就让用户关掉（说明要关哪个、为什么）。

## 步骤

### 2.1 登录路由器，确认环境，做备份

背景：先摸清这台路由器的底细，后面每一步都有对应关系。你直接 SSH 上去逐条执行并核对预期：

```sh
ssh root@192.168.8.1

# 逐条执行并核对输出：
uname -m                          # 应为 aarch64
cat /etc/openwrt_release | head -3 # 应看到 OpenWrt 21.02 系
ls /lib/ld-musl-aarch64.so.1      # 存在 = musl 系统（决定 2.2 下哪个包）
ls /lib/ld-linux-aarch64.so.1     # 应"不存在"（glibc 加载器没有）
iptables --version | head -1      # 有输出 = fw3/iptables 系（不是 fw4/nftables）
ls /etc/firewall.user             # 存在 = 防火墙自定义钩子可用

# 全量备份当前配置到一个带日期的目录：
BACKUP="/root/pre-singbox-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -r /etc/config "$BACKUP/"
cp /etc/firewall.user "$BACKUP/" 2>/dev/null
echo "备份在 $BACKUP"
```

**PASS 标准**：架构 aarch64、musl 加载器存在、glibc 加载器不存在、
iptables 可用。任何一条不符，停止施工，带着输出找用户——这台机器的
固件版本和实测环境不同，不要硬套本阶段命令。

### 2.2 安装 sing-box（选错包是第一个坑）

先记住两个实测结论：

1. OpenWrt 21.02 的 opkg 源里**没有** sing-box，不要浪费时间
   `opkg install`。
2. 官方 release 的普通 `linux-arm64` 包在这台机器上**跑不起来**——
   它动态链接 glibc 加载器，而本机只有 musl 加载器。必须下
   **linux-arm64-musl** 版。（实测教训：装错包时的报错很容易让人
   误以为是配置或协议参数问题，白排查几小时。）

你在**电脑**上下载（路由器直连 GitHub 通常很慢甚至不通），再传上去：

```sh
# 电脑上：
cd ~/overseas-ops
curl -L -o sing-box.tar.gz \
  https://github.com/SagerNet/sing-box/releases/download/v1.13.3/sing-box-1.13.3-linux-arm64-musl.tar.gz
scp sing-box.tar.gz root@192.168.8.1:/tmp/
```

```sh
# 路由器上：
cd /tmp
tar -xzf sing-box.tar.gz
cp sing-box-1.13.3-linux-arm64-musl/sing-box /usr/bin/sing-box
chmod +x /usr/bin/sing-box
sing-box version
```

**PASS 标准**：`sing-box version` 正常输出 `1.13.3`。
**FAIL 典型**：报加载器/解释器不存在 → 包下错了，回到 musl 版重下。
（附注：v1.13.3 起官方也开始提供 OpenWrt APK 包，但本仓库只走实测
验证过的静态二进制路径。）

### 2.3 写入客户端配置并校验

模板在仓库 `configs/router/sing-box-client.json`，逐行注释都在文件里。
必改占位符 5 个：`<SERVER_IP>` `<UUID>` `<REALITY_SNI>`
`<REALITY_PUBLIC_KEY>` `<REALITY_SHORT_ID>`，值从 `secrets.txt` 抄；
`server_port` 模板默认写 443，VPS 端口不是 443 就一并改掉。

推荐流程：你在电脑上把模板渲染好（改完的文件**不进 git、不外发**），
scp 上传，然后校验：

```sh
# 电脑上：
scp 改好的配置 root@192.168.8.1:/etc/sing-box/config.json
# （/etc/sing-box 目录不存在就先 ssh 上去 mkdir -p /etc/sing-box）
```

```sh
# 路由器上：
sing-box check -c /etc/sing-box/config.json && echo CONFIG OK
```

提醒：OpenWrt 上没有 perl/python，需要在路由器上直接改文件时用 `vi` 或
`cat > 文件 <<'EOF'` heredoc（实测踩坑：别假设有顺手的编辑器）。

**PASS 标准**：`CONFIG OK`。FAIL 你自己修 JSON，修好才许往下走。

### 2.4 先手动跑，用显式代理验证隧道（不断网）

先不起透明接管，只证明"路由器能经隧道出海"。这一步不改
路由表，不断网，随便试。

```sh
# 路由器上前台跑（日志直接打在屏幕上）：
sing-box run -c /etc/sing-box/config.json
```

你另开电脑终端，手动指定代理验证：

```sh
curl -x socks5h://192.168.8.1:2080 https://api.ipify.org
# 应返回你的 VPS/出口 IP（01 阶段记录的那个）

curl -x socks5h://192.168.8.1:2080 -sS -o /dev/null -w '%{http_code}\n' \
  https://www.gstatic.com/generate_204
# 应返回 204
```

**PASS 标准**：出口 IP 正确 + 204。FAIL：你自己看路由器那个窗口的日志，
常见是 UUID/Reality 参数抄错，修好后重新跑（上限两次）。
**通过后**：到路由器窗口按 `Ctrl+C` 停掉 sing-box。

### 2.5 铺持久化文件（只放文件，不启动）

把仓库两个文件传上去（仍然不断网）：

```sh
# 电脑上：
scp configs/router/tproxy-rules.sh  root@192.168.8.1:/etc/sing-box-tproxy-rules.sh
scp configs/router/init.d-sing-box  root@192.168.8.1:/etc/init.d/sing-box
```

```sh
# 路由器上：
chmod +x /etc/sing-box-tproxy-rules.sh /etc/init.d/sing-box
# 把规则脚本里的 <SERVER_IP> 替换成真实 VPS IP：
sed -i 's/<SERVER_IP>/真实IP/' /etc/sing-box-tproxy-rules.sh   # 或用 vi 手改
grep -n SERVER_IP /etc/sing-box-tproxy-rules.sh | head -3   # 确认已替换
```

**PASS 标准**：两个文件可执行、`<SERVER_IP>` 已替换。

### 2.6 ⛔高危① 启用 TUN + TPROXY 透明接管

**刹车协议，依次做完再动手：**

1. **一句话告知用户**："接下来这一步开始接管全部局域网流量。断网窗口：
   几秒到几分钟（顺利的话基本无感）。最坏情况：WiFi 连上但全网不通——
   实测发生过，根因是 `ip rule` 规则缺失，本流程用规则脚本已规避；
   真发生了就用恢复脚本，30 秒回到普通直连。恢复脚本我已经存在你电脑上。"
2. **生成恢复脚本**：你把下面内容保存为用户本机的
   `~/overseas-ops/recovery/recover-02-tproxy-off.sh`（存在**电脑上**，
   不是路由器上），`chmod +x`，并告诉用户：真断网了就在电脑上跑这个脚本。

   ```sh
   #!/bin/sh
   # 用途：2.6 搞砸后恢复普通直连。在【电脑】上运行（连路由器 WiFi/网线）。
   # 原理：管理面（192.168.8.1）永远可用，SSH 进去撤掉接管即可。
   ssh root@192.168.8.1 'sh -s' <<'ROUTER_EOF'
   /etc/init.d/sing-box stop 2>/dev/null
   /etc/sing-box-tproxy-rules.sh stop 2>/dev/null
   echo "=== RECOVER TPROXY DONE：已恢复普通直连 ==="
   ROUTER_EOF
   ```

3. **确认兜底**：和用户确认手机热点能连、备用 AI 能聊、`docs/recovery.md`
   在本机（00 阶段已确认过一次，这里复核）。
4. **等用户回复"继续"**，再执行。

执行（你在路由器上）：

```sh
/etc/init.d/sing-box start
sleep 5
pidof sing-box                 # 有 PID 输出
ip rule show | grep fwmark     # 应看到：fwmark 0x1 lookup 100
ip route show table 100        # 应看到：local 0.0.0.0/0 dev lo
ip -6 rule show | grep fwmark  # IPv6 同理
iptables -t mangle -L SINGBOX_TPROXY -n | head -5   # 链存在且有规则
```

验收（你在电脑上执行，本机零代理）：

```sh
curl -4 https://api.ipify.org
# 应返回你的 VPS/出口 IP —— 没设任何代理就出海了，透明接管成功

curl -sS -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204
# 应返回 204
```

**PASS**：出口 IP 正确 + 204。**FAIL**：你执行恢复脚本，回到普通直连，
自己分析输出定位；修复重试上限两次，仍 FAIL 带现场找用户。禁止盲目重试。

### 2.7 ⛔高危② DNS 加密改造（dnsmasq → dnscrypt DoH）

**为什么这步也高危**：改 DNS 上游写错 = 全网域名解析失败，体感等于
断网。背景与原理见 `configs/router/dnscrypt-dnsmasq.md`，先读再动手。

**刹车协议：**

1. **一句话告知用户**："接下来改 DNS 上游，断网窗口约 1 分钟内（改错时
   表现为'什么网站都打不开但 ping IP 是通的'）。最坏情况：DNS 全废——
   恢复脚本 30 秒还原，已存在你电脑上。"
2. **生成恢复脚本**：你保存为用户本机的 `~/overseas-ops/recovery/recover-03-dns.sh`，
   `chmod +x`，并告诉用户断网后怎么跑：

   ```sh
   #!/bin/sh
   # 用途：2.7 搞砸后把 dnsmasq 恢复为"用上游下发的 DNS"
   ssh root@192.168.8.1 'sh -s' <<'ROUTER_EOF'
   uci delete dhcp.@dnsmasq[0].server 2>/dev/null
   uci set dhcp.@dnsmasq[0].noresolv='0'
   uci commit dhcp
   /etc/init.d/dnsmasq restart
   echo "=== RECOVER DNS DONE ==="
   ROUTER_EOF
   ```

3. **确认兜底**（备用网络/备用 AI 复核）。4. **等"继续"**。

执行：你按 `configs/router/dnscrypt-dnsmasq.md` 第三节依次做 3.1
（解开 GL 固件守卫、起 dnscrypt）→ 3.2（dnsmasq 指 127.0.0.1#5335）
→ 3.3（路由器本机 resolv.conf 收口）。**GL 固件的坑在 3.1**：
不改 `gl-dns` 守卫，dnscrypt 会静默不起，别在端口上浪费时间。

验收（你在路由器上执行）：

```sh
pidof dnscrypt-proxy && netstat -lnp | grep 5335   # 进程+端口都在
nslookup chatgpt.com
nslookup api.openai.com
```

**PASS**：解析结果落在正确的服务商机房段（Cloudflare 等），不再是
八竿子打不着的公司 IP 段。然后必须用户出手做一次真机验证（iPhone 是
DHCP DNS 重灾区，必须真机过一遍）——让用户用 iPhone 连上这个 WiFi，
打开两三个海外网站，回你"正常"或"打不开"。**FAIL**：你跑恢复脚本还原，
自己排查；两次修不好带现场找用户。

### 2.8 ⛔高危③ 启用防火墙 fail-closed 第二层

先读 `configs/router/failclosed-firewall.md` 第一、二节。要点：这层只管
"设备穿过路由器上网"的 FORWARD 链；管理面（SSH/Web）走的 INPUT 链一条
不碰，所以**断网也永远锁不死管理面**。

**刹车协议：**

1. **一句话告知用户**："接下来加防火墙 fail-closed 规则。断网窗口：顺利时
   无感（sing-box 健康时流量不撞这条规则）。最坏情况：规则顺序/接口名写错
   导致全网断——恢复脚本 30 秒还原防火墙，已存在你电脑上。"
2. **生成恢复脚本**：你保存为用户本机的 `~/overseas-ops/recovery/recover-04-firewall.sh`，
   `chmod +x`：

   ```sh
   #!/bin/sh
   # 用途：2.8 搞砸后还原防火墙（本阶段 firewall.user 只加过 fail-closed 一段）
   ssh root@192.168.8.1 'sh -s' <<'ROUTER_EOF'
   cp /etc/firewall.user /etc/firewall.user.bak.$(date +%s) 2>/dev/null
   : > /etc/firewall.user
   /etc/init.d/firewall restart
   echo "=== RECOVER FIREWALL DONE ==="
   ROUTER_EOF
   ```

3. **确认兜底**。4. **等"继续"**。

执行：你把 `failclosed-firewall.md` 第三节的片段追加进
`/etc/firewall.user`（先 `ip link | grep br-` 确认桥名是 `br-lan`），
然后 `/etc/init.d/firewall restart`。

验收：sing-box 健康状态下应该**完全无感**——你重新跑一遍 2.6 的两条
curl，结果不变即 PASS。全网断 = FAIL，你跑恢复脚本，检查桥名和顺序；
两次修不好带现场找用户。
（"停 sing-box 后的断网验证"统一放到下面 Gate 2 做，这里不测。）

### 2.9 持久化收口：开机自启

不断网，但必须做对——这是"重启后自动恢复"的前提：

```sh
/etc/init.d/sing-box enable
ls -l /etc/rc.d/ | grep sing-box    # 应看到 S99sing-box 之类的链接
```

你必须理解的关键坑：`ip rule` / `ip route` 是内核运行时状态，**重启
就丢**。iptables 规则有 fw3 持久化，但策略路由没有。所以规则脚本必须
由 init.d 在每次拉起 sing-box 后重新下发（已在 `init.d-sing-box` 里
挂好钩），否则重启后症状就是"sing-box 在跑、全网不通"。排查 Gate 3
故障时先查这个。

## 本阶段验收（4-Gate，全绿才进 03）

前置：电脑本机零代理、直连路由器 WiFi。任一 Gate 连续 2 次 FAIL →
执行 ## 回滚，停工分析，带现场找用户，不许在线热修。

### Gate 1：出海通

```sh
curl -4 https://api.ipify.org                    # 你的出口 IP
curl -sS -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204   # 204
nslookup chatgpt.com                             # 干净的解析结果
```

### Gate 2：fail-closed 实测（sing-box 停 = 外网全断，管理面保活）

这是整个方案的立身之本，必须真实测一次，不许"理论上应该断"就算过。

**先布保险丝**（实测坑：OpenWrt 的 ash **没有 nohup**，别用）——
你开一个**独立的 SSH 会话**登路由器，执行后**保持会话不关**：

```sh
( sleep 180; /etc/init.d/sing-box start ) &
# 这个会话就开着别动。3 分钟后它会自动把 sing-box 拉回来。
```

然后在主 SSH 会话停掉 sing-box：

```sh
/etc/init.d/sing-box stop
```

立刻在电脑上验证（预期：外网全死、管理面活着）：

```sh
curl -4 --max-time 5 https://api.ipify.org   # 必须超时失败
ping -c 2 -W 2 223.5.5.5                     # 必须不通
curl --max-time 5 -s -o /dev/null -w '%{http_code}\n' http://192.168.8.1  # 必须 200
ssh root@192.168.8.1 'echo ok'               # 必须通
```

**PASS**：外网两项全断 + 管理面两项全通。
然后等保险丝自动拉起（或手动 `/etc/init.d/sing-box start`）。

### Gate 3：⛔高危④ 重启自恢复

**刹车协议：**

1. **一句话告知用户**："接下来重启路由器，全家断网 1–3 分钟。最坏情况：
   持久化没做对，重启后全网不通（管理面仍在）——用恢复脚本一键回普通
   直连；极端情况路由器起不来，用 `docs/recovery.md` 的硬件恢复。恢复
   脚本已存在你电脑上。"
2. **生成恢复脚本**：你保存为用户本机的
   `~/overseas-ops/recovery/recover-05-all-off.sh`，`chmod +x`
   （这是持久化之后的"一键回默认直连"，把前三张保险符合二为一）：

   ```sh
   #!/bin/sh
   # 用途：Gate 3 之后任何时候搞砸了，一键回到"普通直连"（默认出厂行为）
   ssh root@192.168.8.1 'sh -s' <<'ROUTER_EOF'
   /etc/init.d/sing-box disable 2>/dev/null
   /etc/init.d/sing-box stop 2>/dev/null
   /etc/sing-box-tproxy-rules.sh stop 2>/dev/null
   : > /etc/firewall.user
   /etc/init.d/firewall restart
   uci delete dhcp.@dnsmasq[0].server 2>/dev/null
   uci set dhcp.@dnsmasq[0].noresolv='0'
   uci commit dhcp
   /etc/init.d/dnsmasq restart
   echo "=== RECOVER ALL DONE：已回到普通直连 ==="
   ROUTER_EOF
   ```

3. **确认兜底**（备用网络这次是真的可能要用，逐项复核热点和备用 AI）。
4. **等"继续"**。

执行（路由器上）：`reboot`。等 2–3 分钟，WiFi 自动回来。

**什么都不碰**，直接验收：

```sh
# 电脑上：
curl -4 https://api.ipify.org     # 应直接返回出口 IP（没人碰过配置）

# 路由器上：
pidof sing-box                    # 进程在
ip rule show | grep fwmark        # 规则在（init.d 自动下发的）
```

### Gate 4：恢复后复验（最终态确认）

最后完整跑一遍，确认系统稳定在目标态：

```sh
# 电脑：出口 IP 正确、204、DNS 干净（同 Gate 1 三条）
# 路由器：pidof sing-box / netstat -lnp | grep 5335 / ip rule show | grep fwmark
```

外加一次用户真机：让用户用手机连 WiFi 打开海外站点，回你"正常"。

4 个 Gate 全绿 → 给用户一句话播报（如"✅ 路由器接管完成，连 WiFi 即出海，
断隧道即断网，重启自恢复"），进 `playbook/03-verify-leak.md` 体检。

## 回滚

| 搞砸在哪一步 | 跑哪个恢复脚本 | 恢复到什么状态 |
|--------------|----------------|----------------|
| 2.6 透明接管 | `recover-02-tproxy-off.sh` | 普通直连（sing-box 停、TPROXY 撤） |
| 2.7 DNS | `recover-03-dns.sh` | dnsmasq 用上游 DNS |
| 2.8 防火墙 | `recover-04-firewall.sh` | 防火墙回默认 |
| 2.9 之后任何时间 | `recover-05-all-off.sh` | 全部还原，回普通直连 |

三条纪律：

1. 管理面（192.168.8.1 的 SSH/Web）设计上永远不会被本阶段的任何
   操作锁死——所有恢复都建立在这个前提上，恢复脚本全都存在**电脑**上，
   由你执行；若你已断网连不上，指导用户手动跑。
2. 在 2.9 持久化**之前**，还有一个终极兜底：`reboot`。live 规则不落盘，
   重启即清零回直连。持久化之后这个兜底失效，改用上表脚本。
3. 恢复脚本也救不回来时：让用户切手机热点，把 `docs/recovery.md` 发给
   备用 AI，按断网接手协议走。
