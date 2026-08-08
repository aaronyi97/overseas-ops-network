# 断网恢复手册（给国内备用 AI 的接手文档）

> **这份文件是写给"国内备用 AI"读的**（Kimi / DeepSeek / 豆包等，国内网络直接可用的 AI）。

## 使用方式（用户必读，断网前就该知道）

这套方案是 **fail-closed** 设计：隧道异常 = 直接断网，绝不裸奔。所以施工中或施工中改配置时，**断网是大概率事件，不是意外**。断网后：

1. 电脑/手机切到**国内备用网络**（手机热点即可）
2. 打开国内备用 AI，把**本文件全文**发给它，再附上这句话：

> "我在按 overseas-ops-network 仓库搭网络，执行到第 __ 阶段第 __ 步后断网了。我的本机是 __（Mac/Windows）。请按这份恢复手册的场景树帮我定位问题并修复。"

3. 按备用 AI 的指引逐步操作，**每步只执行一条命令，把输出贴回去**，不要批量执行

## 给接手 AI 的说明

- 用户的路由器是 GL.iNet MT3600BE（OpenWrt），管理地址固定为 `192.168.8.1`
- 几乎所有修复都通过 `ssh root@192.168.8.1` 完成；路由器上**只有 BusyBox ash**，没有 bash / perl / python / nohup，编辑文件用 `vi` 或 `cat heredoc`
- 文中 `<SERVER_IP>` `<UUID>` `<PASSWORD>` `<PROXY_HOST>` 等是占位符；真实值在**用户本机**的 `~/overseas-ops/secrets.txt`，让用户自己查、自己替换，贴回输出前提醒他抹掉敏感值
- 断网分两种：**设计性断网**（fail-closed 生效，隧道断但路由器管理面一定活着）和**真故障**。先分清是哪种
- 修复目标不是"恢复成某个完美状态"，而是**恢复到断网前那个施工阶段的已知良好状态**，然后让用户回到主仓库的 playbook 从该阶段验收点继续

## 场景快速定位

| 现象 | 去场景 |
|------|--------|
| `ping 192.168.8.1` 不通，管理页也打不开 | A |
| 能上路由器管理面 / 能 SSH，但没外网 | B |
| 有外网，但出口 IP 不对 / 网站打开的是错的东西 | C |
| 路由器重启之后网络不自己恢复 | D |
| 不想折腾了，要整体回滚成普通路由器 | E |

先跑这个 30 秒定位脚本（Mac/Linux 终端；Windows 用 PowerShell 逐条等价执行）：

```bash
ping -c 3 192.168.8.1                                  # 路由器活着吗
curl -s --max-time 8 https://api.ipify.org; echo       # 有外网吗？出口 IP 是多少
nslookup google.com 192.168.8.1                        # 路由器 DNS 正常吗
```

---

## 场景 A：完全连不上路由器管理面

**症状**：`ping 192.168.8.1` 全丢包，浏览器打不开 `http://192.168.8.1`，SSH 也连不上。

**诊断与修复路径（按顺序）**：

1. **确认 WiFi 没连错**：电脑当前连的必须是 MT3600BE 的 WiFi，不是家里主路由或手机热点。连错 WiFi 是本场景最常见原因
2. **换有线**：找根网线插路由器 LAN 口，再 `ping 192.168.8.1`。有线通 = 只是 WiFi 侧问题
3. **物理重启**：拔电源，等 30 秒，插回，**等足 2 分钟**让它完全启动，再 ping
4. 重启后能 ping 通 → 转场景 B 继续诊断（外网大概率还没有，属正常）
5. 重启后仍不通 → 大概率固件/配置损坏。用 GL.iNet 官方的 Uboot 刷机流程重刷固件（按住 reset 键通电进刷机页，具体步骤搜"GL-MT3600BE uboot 刷机"，官方文档有图文）。刷完路由器回到出厂态，按主仓库 playbook 02 重新施工
6. **施工期间所有设备先切手机热点上网**，别干等

---

## 场景 B：能上路由器，但没外网

**症状**：`ping 192.168.8.1` 通、SSH 能进，但浏览器打不开任何网站。

先记住：**如果 fail-closed 已配好，隧道断 = 外网断是设计行为**，说明防火墙在保护你。修复 = 把隧道修起来，不是关防火墙。

**第 1 步：SSH 进路由器**

```bash
ssh root@192.168.8.1
```

**第 2 步：逐项诊断（在路由器上执行）**

```bash
pidof sing-box                       # 隧道客户端活着吗？无输出 = 挂了
logread -e sing-box | tail -20       # 看它最后的报错
ping -c 3 <SERVER_IP>                # 路由器到 VPS 通吗？
ip rule show | grep fwmark           # TPROXY 引流规则在吗？应有 fwmark 0x1 lookup 100
ip route show table 100              # 应有 local default dev lo
```

**第 3 步：按诊断结果修复**

- **sing-box 没在跑** → 重启并观察：

  ```bash
  /etc/init.d/sing-box restart
  sleep 3 && pidof sing-box && logread -e sing-box | tail -10
  ```

  起不来且日志报配置错 → 配置被改坏。用备份恢复：

  ```bash
  ls -t /etc/sing-box/config.json.bak.* | head -1    # 找到最近备份
  cp <最近备份路径> /etc/sing-box/config.json
  sing-box check -c /etc/sing-box/config.json && /etc/init.d/sing-box restart
  ```

- **fwmark 规则或 table 100 缺失**（重启后规则丢失的典型症状，见场景 D）→ 手动补 4 条：

  ```bash
  ip rule add fwmark 0x1/0x1 lookup 100 pref 100 2>/dev/null
  ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
  ip -6 rule add fwmark 0x1/0x1 lookup 100 pref 100 2>/dev/null
  ip -6 route add local ::/0 dev lo table 100 2>/dev/null
  ```

  补完在电脑上 `curl -s https://api.ipify.org` 验证。

- **`ping <SERVER_IP>` 不通** → 问题在路由器上行或 VPS：
  1. 先确认路由器自己有没有网：`ping -c 3 223.5.5.5`。不通 = 上行（家宽/上级路由）断了，检查上级网络
  2. 上行通但 VPS 不通 → 换手机热点当上行试试；热点能通 = VPS 的 IP 被墙了，去 VPS 商家后台换 IP（并把新 IP 同步进路由器配置）
  3. VPS 能 ping 通但隧道还是断 → SSH 上 VPS 查服务端：

     ```bash
     ssh root@<SERVER_IP>
     systemctl is-active sing-box
     sing-box check -c /etc/sing-box/config.json
     journalctl -u sing-box --since "10 min ago" | tail -20
     ```

     挂了重启：`systemctl restart sing-box`；配置错就用 VPS 上的 `config.json.bak.*` 备份恢复。

- **隧道活着但出口是 VPS 机房 IP 而不是住宅 IP** → VPS 侧转发住宅 IP 的 outbound 出问题。在 VPS 上直测住宅代理：

  ```bash
  curl -x http://<PROXY_USER>:<PROXY_PASS>@<PROXY_HOST>:<PROXY_PORT> --max-time 15 https://api.ipify.org
  ```

  不通/认证失败 = 代理凭证错或订阅过期（检查是否忘续费！）；通的话检查 sing-box 配置里 selector 指向是否被改。

---

## 场景 C：有外网，但出口不对

**症状**：能上网，但出口 IP 不是预期的住宅 IP；或者网站内容异常、某些 App 打不开、账号突然被要求验证。

**诊断**：

```bash
curl -s --max-time 8 https://api.ipify.org; echo      # 实际出口
nslookup chatgpt.com 192.168.8.1                       # 解析结果是否合理
```

**出口 IP = VPS 机房 IP** → VPS 侧 selector 指错了或住宅 IP 出站挂了，按场景 B 最后一条处理。**注意：此时流量在裸奔机房 IP，别登录任何运营账号，先修好再用。**

**解析结果离谱**（比如 chatgpt.com 解析到明显无关的 IP）→ **DNS 被污染**。SSH 上路由器：

```bash
pidof dnscrypt-proxy; pidof dnsmasq          # DNS 链两个进程都要在
cat /tmp/resolv.conf                          # 不应出现运营商/上级路由 DNS
uci show dhcp.@dnsmasq[0].server              # 上游应指向加密 DNS（如 127.0.0.1#5335）
```

修复（按主仓库 `configs/router/` 的模板口径，把上游改回加密 DNS 链）：

```bash
uci set dhcp.@dnsmasq[0].noresolv='1'
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci commit dhcp
/etc/init.d/dnsmasq restart
/etc/init.d/dnscrypt-proxy restart 2>/dev/null
```

如果 `/tmp/resolv.conf` 里又冒出了运营商 DNS，检查上行接口的 peerdns 没收口：

```bash
uci show network | grep peerdns
# 对实际活跃的上行接口（wwan / tethering 等，以 uci show network 实际名为准）：
uci set network.<上行接口名>.peerdns='0'
uci commit network && /etc/init.d/network restart
```

⚠️ `network restart` 会瞬断几秒，属正常。

**出口对、解析对，但特定平台表现异常**（降智、频繁验证）→ 不是断网问题，是 IP 信誉问题。去查 IPQS 分数，并按 `docs/pitfalls.md` 里"IP 段被平台专有标记"一节做 A/B 验证。

---

## 场景 D：路由器重启后不自恢复

**症状**：重启前一切正常，重启后 sing-box 在跑、iptables 规则也在，但就是没网。

**根因（真实踩过）**：`ip rule` / `ip route` 是内核运行时状态，重启即丢；init.d 只拉了 sing-box 进程，没人补 TPROXY 引流规则。

**诊断**：

```bash
ssh root@192.168.8.1
pidof sing-box                       # 在跑
ip rule show | grep fwmark           # 空 = 规则丢了
ls /etc/rc.d/ | grep sing-box        # 空 = 没设开机自启
```

**修复**：

```bash
# 1. 立即补规则（恢复上网）
ip rule add fwmark 0x1/0x1 lookup 100 pref 100
ip route add local 0.0.0.0/0 dev lo table 100
ip -6 rule add fwmark 0x1/0x1 lookup 100 pref 100
ip -6 route add local ::/0 dev lo table 100

# 2. 确认开机自启
/etc/init.d/sing-box enable

# 3. 把补规则脚本挂进启动链（按主仓库 configs/router/ 模板）
#    确认 /etc/sing-box-tproxy-rules.sh 存在且被 init.d 调用
cat /etc/sing-box-tproxy-rules.sh
grep tproxy /etc/init.d/sing-box
```

修完**必须重启验证一次**：`reboot`，等 2 分钟，电脑端 `curl -s https://api.ipify.org` 出住宅 IP 才算闭环。

---

## 场景 E：整体回滚到普通路由器状态

**适用**：不想继续这套方案了，或要回滚到一个干净的起点重新施工。

**路径（SSH 上路由器，按顺序）**：

```bash
# 1. 停掉并禁用隧道客户端
/etc/init.d/sing-box stop
/etc/init.d/sing-box disable

# 2. 清掉 TPROXY 引流规则
ip rule del fwmark 0x1/0x1 lookup 100 pref 100 2>/dev/null
ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
ip -6 rule del fwmark 0x1/0x1 lookup 100 pref 100 2>/dev/null
ip -6 route del local ::/0 dev lo table 100 2>/dev/null

# 3. 清掉透明接管的防火墙规则（链名以 configs/router/ 模板为准）
iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null
ip6tables -t mangle -F SINGBOX_TPROXY6 2>/dev/null
ip6tables -t mangle -X SINGBOX_TPROXY6 2>/dev/null

# 4. DNS 恢复普通口径（用上级路由分配的 DNS）
uci set dhcp.@dnsmasq[0].noresolv='0'
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci commit dhcp
/etc/init.d/dnsmasq restart

# 5. 重启
reboot
```

重启后这就是一台普通路由器：设备直连家宽出海，没有隧道、没有 fail-closed。

**验证回滚成功**：`curl -s https://api.ipify.org` 返回的是你家宽的真实 IP（即"裸奔"状态——回滚后不要再登录运营账号）。

想重新施工：从主仓库 playbook 02 阶段的验收点重新开始即可，VPS 侧的东西都没动。

---

## 修复完成后的交接

备用 AI 请提醒用户：

1. 把本次事故现象、根因、修复动作简单记下来（回本仓库 `docs/pitfalls.md` 看格式）
2. 切回 MT3600BE 的 WiFi，跑一次 `curl -s https://api.ipify.org` 确认出口 = 住宅 IP
3. 回到主仓库，让引导 AI **从断网那个阶段的验收点继续**，不要从头再来
4. 断网期间在备用网络（手机热点直连）下，**不要登录任何运营账号**——热点出口是国内 IP，登了就污染账号环境
