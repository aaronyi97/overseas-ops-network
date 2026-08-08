# 阶段 03：泄露体检（七项全绿，才能注册账号）

> 网络搭好了不等于安全。这一阶段只做一件事：**用证据回答"平台看到的到底是谁"**。
> 七项检查全部 PASS 之前，不许用户注册、登录任何高价值账号。没体检就开户，前面两个阶段等于白搭。
> 执行模式：机检脚本和 curl 类检查你（AI）直接跑、自己判；浏览器类检查你打开页面核对
> （没法自己读取的页面，让用户看一眼并告诉你结果）；只有 3.7 是 ⛔高危闸门。

## 本阶段目标

完成七项泄露检查，全部拿到绿：

| # | 检查项 | 回答的问题 | 主要工具 |
|---|--------|-----------|---------|
| 1 | 出口 IP | 平台看到的是我的住宅 IP，不是真实宽带 IP，也不是 VPS 机房 IP | `scripts/net-check.sh` + ipleak.net |
| 2 | DNS 泄露 | DNS 查询全部走隧道，不经过本地运营商 | dnsleaktest.com + browserleaks.com/dns |
| 3 | WebRTC 泄露 | 浏览器不会绕过代理暴露本地/真实 IP | browserleaks.com/webrtc + ipleak.net |
| 4 | 时区 | 浏览器报告的时区与 IP 所在地区一致 | browserleaks.com/javascript |
| 5 | 语言 | 浏览器只报 `en-US`，不带 `zh-CN` | browserleaks.com/javascript |
| 6 | fail-closed 复测 | 隧道断 = 彻底断网，绝不回落到真实 IP | 手动故障注入 |
| 7 | IP 信誉 | 这个 IP 没有被各风控库标记成代理/滥用 | 七个查询源交叉 |

外加一项建议项：指纹一致性加分检查（PixelScan / Whoer / CreepJS）。

## 前置条件

- [ ] 阶段 02 验收全绿：连路由器 WiFi 能出海、隧道停 = 断网、重启自恢复
- [ ] 当前用的是**建议的 macOS 运营机**，已连上路由器 WiFi（不是手机热点、不是家宽直连）
- [ ] 预期出口 IP 以 secrets.txt 里 01 阶段记录的"住宅 IP"为准；如果缺失或不确定，
      让用户去住宅 IP 供应商后台确认**他分到的那一个固定 IP**（不是网关地址，是出口 IP）后发给你
- [ ] 你把预期出口 IP 写入本地文件（一行一个 IP，别的什么都不要写）：

```bash
mkdir -p ~/overseas-ops/logs
chmod 700 ~/overseas-ops
echo "<你的住宅IP>" > ~/overseas-ops/expected-exit-ip.txt
chmod 600 ~/overseas-ops/expected-exit-ip.txt
```

- [ ] 你把本仓库的脚本复制到本地并赋可执行权限：

```bash
mkdir -p ~/overseas-ops/bin
cp scripts/*.sh ~/overseas-ops/bin/
chmod +x ~/overseas-ops/bin/*.sh
```

> 注意：本阶段几乎所有操作是只读的（访问网站、跑体检脚本），唯一例外是第 6 项 fail-closed 复测（⛔高危，会短暂断网）。

## 步骤

### 3.1 先跑机检：连通 + 出口一致性

**做什么**：体检脚本会一次性检查：HTTPS 是否连通、三个不同来源测出的出口 IP 是否一致、出口 IP 是否等于预期 IP、DNS 有没有指向中国境内服务器、系统代理有没有被意外打开、有没有 IPv6 旁路。你直接跑：

```bash
~/overseas-ops/bin/net-check.sh
```

**PASS 标准**：脚本末尾输出 `RESULT: PASS`（退出码 0）。任何 FAIL 项先停下来修，不要继续——脚本报 FAIL 说明网络层就有问题，后面浏览器检查做了也白做。

> 常见 FAIL：预期 IP 文件没建或写错（重新执行前置条件）；出口 IP ≠ 预期 IP（回 02 检查 VPS 上的住宅 IP 链路是否生效）；出现中国境内 DNS（回 02 检查路由器 DNS 配置）。

### 3.2 第 1 项：出口 IP 检查

**做什么**：确认"平台看到的脸"。

你打开 `https://ipleak.net`（走当前网络），核对页面顶部：

- IP 地址 = 住宅 IP（与 `expected-exit-ip.txt` 一致）
- 地理位置 = 目标国家/城市
- ISP/组织名 = 一个普通家庭宽带运营商的名字，**不是**阿里云/腾讯云/AWS/DigitalOcean 这类机房名字，也**不是** VPS 商家

**PASS 标准**：三条全中。如果显示的 IP 是 VPS 的 IP → 住宅 IP 链路没生效，回 02 阶段排查；如果显示的是用户家的真实宽带 IP → 透明接管根本没生效，**立即停止**，回 02 阶段。

### 3.3 第 2 项：DNS 泄露检查

**为什么**：DNS 查询比网页请求更容易泄露——很多配置里网页走隧道、DNS 却直接问本地运营商，平台一对比就穿帮。

两个工具都要测：

1. `https://www.dnsleaktest.com` → 点 **Extended test**（标准测试样本太少）
2. `https://browserleaks.com/dns`

**PASS 标准**：两个工具列出的所有 DNS 服务器：

- 不出现任何中国境内运营商的 DNS（各省电信/联通/移动的 DNS，或 114.114.114.114、223.5.5.5、119.29.29.29 等公共 DNS）
- 不出现用户本地宽带运营商的名字
- 显示的是隧道/VPS 侧或住宅 IP 侧的 DNS，地理位置与出口 IP 同国

任何一个工具里冒出中国 DNS = FAIL，回 02 检查路由器 DNS 链路（DNS 必须走隧道或被加密接管）。

### 3.4 第 3 项：WebRTC 泄露检查

**为什么**：WebRTC 是浏览器视频/语音通话的底层技术，它会用特殊方式枚举本机网络接口，是历史上最常见的"代理挂得好好的、浏览器却报了真实 IP"的通道。

打开 `https://browserleaks.com/webrtc`（ipleak.net 页面下方的 WebRTC 区也一起看）。

**PASS 标准**：

- Local IP Address 一栏不出现局域网里的真实内网网段地址
- Public IP Address 一栏只出现住宅 IP，**绝不出现真实宽带 IP 或 VPS IP**

如果泄露了：说明浏览器 WebRTC 没关，记入待办，04 阶段关掉后再回来复测。这不算施工失败，04 就是干这个的。

### 3.5 第 4 项：时区检查

**为什么**：IP 在洛杉矶、浏览器报北京时间，是风控眼里最典型的矛盾信号之一。

打开 `https://browserleaks.com/javascript`，看 `Timezone` / `Intl.DateTimeFormat` 相关行。

**PASS 标准**：浏览器报告的时区 = 住宅 IP 所在地区的时区（例如美国西部 IP 对应 `America/Los_Angeles`）。不一致 → 记入待办，04 阶段改**系统时区**（浏览器时区来自操作系统），改完重启浏览器回来复测。

### 3.6 第 5 项：语言检查

**做什么**：同一个 javascript 页面，看 `Accept-Language` 和 `navigator.language` / `navigator.languages`。

**PASS 标准**：`Accept-Language` 以 `en-US` 开头且不含 `zh-CN`；`navigator.language` = `en-US`。

不一致 → 记入待办，04 阶段改**浏览器语言**（注意：改的是浏览器设置，不是必须改系统语言——系统语言不强改，理由见 04）。

### 3.7 第 6 项：fail-closed 复测 ⛔高危

**做什么**：02 阶段已经验证过一次"隧道停 = 断网"，这里在做完所有上层配置后**复测一次**，确认没有漂移。这一步会主动把隧道停掉，**外网会断 1-2 分钟**。

⛔ **按高危刹车协议，执行前依次完成四件事**：

1. **一句话告知用户**："接下来我会主动停掉路由器上的隧道做 fail-closed
   复测，外网会断 1-2 分钟。最坏情况是隧道起不回来、外网持续中断——
   恢复脚本已存在你电脑上，30 秒可拉起；再不行就用手机热点走 recovery 流程。"
2. **生成本地恢复脚本**：你把下面内容保存为用户本机的
   `~/overseas-ops/recovery/recover-06-failclosed-retest.sh`，`chmod +x`，
   并告诉用户：外网没恢复就跑这个脚本。

   ```sh
   #!/bin/sh
   # 用途：3.7 fail-closed 复测后隧道没恢复时，手动拉起隧道。在【电脑】上运行。
   ssh root@192.168.8.1 "/etc/init.d/sing-box start"
   sleep 10
   curl -4 -sS --max-time 15 https://api.ipify.org; echo
   # 出口 IP 回不来就按 docs/recovery.md 处理
   ```

3. **确认兜底**：断网期间用户没有进行中的重要事务；手机热点备用网络在手边；备用 AI 能聊。
4. **等用户回复"继续"**，再动手。

操作（用户回"继续"后你执行）：

1. SSH 到路由器停掉隧道进程（以 02 阶段实际用的停服命令为准，例如）：

```bash
ssh root@192.168.8.1 "/etc/init.d/sing-box stop"
```

2. Mac 上立刻验证外网彻底断开（两条都要试）：

```bash
curl -4 -sS --max-time 15 https://api.ipify.org ; echo "exit=$?"
ping -c 2 192.168.8.1
```

再打开 ipleak.net，应当加载失败。

3. **PASS 标准（三条同时成立）**：
   - `curl` 超时或报错（**exit 非 0**）——外网断
   - `ping 192.168.8.1` 通——LAN 管理面活着，还能管路由器
   - 任何时刻 curl 都**不能**返回 VPS 原始 IP 或真实宽带 IP（返回了 = fail-open 漏洞，CRITICAL FAIL，整套方案要回 02 重修）

4. 恢复并验证：

```bash
ssh root@192.168.8.1 "/etc/init.d/sing-box start"
sleep 10
curl -4 -sS --max-time 15 https://api.ipify.org ; echo
```

恢复后 curl 必须重新返回**住宅 IP**。回不来就按 `docs/recovery.md` 处理。

### 3.8 第 7 项：IP 信誉七源交叉

**做什么**：住宅 IP 也可能"脏"（前用户滥用、被风控库收录）。你用七个独立来源交叉查一遍出口 IP，把结果记录到 `~/overseas-ops/`。把下面 URL 里的 `<IP>` 换成住宅 IP：

| # | 来源 | 地址 | 看什么 |
|---|------|------|--------|
| 1 | Scamalytics | `scamalytics.com/ip/<IP>` | Fraud Score / risk / ISP |
| 2 | IPQualityScore | `ipqualityscore.com` | fraud score、proxy/VPN 标记 |
| 3 | IP2Location | `ip2location.io` | 代理类型判定 |
| 4 | IPinfo | `ipinfo.io/<IP>` | type（应为 isp/住宅类，不是 hosting） |
| 5 | ipdata | `ipdata.co` | VPN/Proxy/数据中心/Tor 标记 |
| 6 | RIPEstat | `stat.ripe.net/app/launchpad/<IP>` | ASN 注册信息（**权威源**：确认 ASN 属于居民宽带运营商） |
| 7 | AbuseIPDB | `abuseipdb.com/check/<IP>` | 被举报次数 |

**PASS 标准**：

- 0-1 个源有标记 → 绿，记录后通过
- 2 个源标记 → 黄：可以使用但要观察，注册新账号时尤其注意前几天的风控反应
- 3 个及以上源标记，或 RIPEstat 显示 ASN 属于机房/IDC → 红：**这个 IP 不能用于高价值账号**，让用户联系供应商换 IP，换完从 3.1 重跑

> 说明：住宅代理 IP 被个别库标成 proxy 是常态（这些库更新滞后），看的是**多数源的综合结论**和 RIPEstat 的权威 ASN 归属，不要被单一来源的标记吓到，也不要无视多个来源的同时报警。

### 3.9 建议项：指纹一致性加分检查

**做什么**（非七项硬门槛，但强烈建议做一次）：

- `pixelscan.net` — 全维度指纹 + 一致性评分
- `whoer.net` — 匿名度评分（顺带复核时区/语言）
- `abrahamjuliot.github.io/creepjs` — 深层指纹与"说谎检测"（浏览器自己报告的信息互相矛盾会被抓）

**怎么看结果**：这些工具对完全正常的家庭用户也常常不给满分，**别追求满分，看"矛盾项"**——IP 国家与时区矛盾、语言与 IP 矛盾、系统字体暴露中文环境这类才需要处理。矛盾项大多指向 04 阶段要修的东西。

## 本阶段验收（七项全绿，才能去注册账号）

逐项打勾，缺一不许开户：

- [ ] 1. 出口 IP：ipleak.net 显示住宅 IP + 目标地区 + 家庭宽带 ISP；`net-check.sh` 全 PASS
- [ ] 2. DNS：dnsleaktest Extended test + browserleaks.com/dns 均无中国境内 DNS
- [ ] 3. WebRTC：两个工具均不泄露本地/真实公网 IP
- [ ] 4. 时区：浏览器时区 = IP 所在地区时区
- [ ] 5. 语言：Accept-Language 只有 en-US，无 zh-CN
- [ ] 6. fail-closed：停隧道 = 外网全断 + LAN 保活 + 恢复后出口仍是住宅 IP
- [ ] 7. IP 信誉：七源交叉结果 ≤1 源标记（或按 3.8 标准判定为绿）

你把检查结果（含页面存档/截图）存到 `~/overseas-ops/` 下留档，以后每周复查时对照。

**七项全绿之后，用户才被允许开始注册/登录账号。** 没全绿就明确告诉用户"现在不能注册/登录账号"——不许为了让他高兴而跳过。任何一项 FAIL：先去 04 阶段（时区/语言/WebRTC/残留问题）或回 02 阶段（网络链路问题）修好，再回来重跑全项。

## 回滚

- 本阶段除 3.7 外全部只读，无系统状态改变，无需回滚
- 3.7 的回滚 = 启动隧道：`ssh root@192.168.8.1 "/etc/init.d/sing-box start"`（即恢复脚本
  `recover-06-failclosed-retest.sh` 的内容），然后用 curl 验证出口恢复为住宅 IP；启动失败按 `docs/recovery.md` 处理
- 如果体检暴露的是 02 阶段的链路问题（出口不对、DNS 泄露、fail-open）：停止前进，回 02 对应步骤修复，修好后从 3.1 重跑，**不要跳项**
