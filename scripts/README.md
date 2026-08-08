# scripts/ — 体检与监控脚本

三个 bash 脚本，面向 macOS 运营机（系统自带 `/bin/bash` 即可运行，无第三方依赖，只用 `curl` / `scutil` / `networksetup` 等系统命令）。

**共同保证：全部只读**——不修改任何网络配置、不删任何文件、不需要 sudo。它们只负责"看"和"报"，清理动作永远由你人工执行。

| 脚本 | 干什么 | 什么时候用 | 退出码 |
|------|--------|-----------|--------|
| `net-check.sh` | 连通性 + 出口一致性体检（7 项机判） | 03 阶段体检、每周复查、感觉网络不对时 | 0=PASS / 1=有 FAIL |
| `proxy-residue-scan.sh` | 代理/VPN 残留只读扫描（12 个面） | 04 阶段残留清零前后、每周复查 | 0=干净 / 1=有残留 |
| `ip-sentinel.sh` | 出口 IP 哨兵：比对预期 IP 文件 | launchd/cron 每小时自动跑 + 手动 | 0=OK / 1=漂移 / 2=断网 / 3=配置错 |

## 安装

```bash
mkdir -p ~/overseas-ops/bin ~/overseas-ops/logs
cp scripts/*.sh ~/overseas-ops/bin/
chmod +x ~/overseas-ops/bin/*.sh

# 预期出口 IP 文件（net-check 和 ip-sentinel 都依赖它）：
echo "<你的住宅IP>" > ~/overseas-ops/expected-exit-ip.txt
chmod 600 ~/overseas-ops/expected-exit-ip.txt
```

## net-check.sh — 连通 + 出口一致性体检

```bash
~/overseas-ops/bin/net-check.sh                     # 标准体检
~/overseas-ops/bin/net-check.sh --no-expected       # 跳过预期 IP 比对（02 施工期、还没定住宅 IP 时用）
~/overseas-ops/bin/net-check.sh --expected-file PATH
```

七项机判：

1. HTTPS 连通性（`generate_204` 探针；不用 ping——透明接管不承载 ICMP，ping 不通≠断网）
2. 出口 IP 三源交叉（ipify / ifconfig.me / Cloudflare trace），互相矛盾 = FAIL
3. 出口 IP == `expected-exit-ip.txt`（不一致 = FAIL，这是核心泄露判定）
4. 系统 DNS 不得指向中国境内公共 DNS
5. 系统代理必须全关
6. 物理接口不得有独立 IPv6 默认路由（绕过隧道的隐蔽通道）
7. utun 隧道接口提示（本机不应有；iCloud 专用代理也会建，应关闭）

输出每项 `[PASS]/[FAIL]/[WARN]/[INFO]` + 末尾 `RESULT: PASS|FAIL` 汇总。**WARN 不挡路，但每一条都要能说出理由。**

脚本只覆盖机判项。七项泄露检查里的 WebRTC、时区、语言、IP 信誉必须开浏览器人工完成——见 `playbook/03-verify-leak.md`。

## proxy-residue-scan.sh — 代理/VPN 残留只读扫描

```bash
~/overseas-ops/bin/proxy-residue-scan.sh
```

扫 12 个面：运行进程、常见代理端口监听、系统代理、系统 VPN 配置、LaunchAgents/LaunchDaemons、launchctl 已加载项、第三方系统扩展、配置描述文件、shell 启动文件代理变量、当前环境变量、应用配置目录/偏好残留、/Applications 应用。

两条设计原则：

- **只扫不动**：报告命中的文件路径/进程名，删除动作你来做（方法见 `playbook/04-device-hygiene.md` 4.3）
- **脱敏回显**：shell 文件和环境变量里的代理配置可能带账号密码，脚本只报 `文件:行号 + 变量名`，值一律 `***REDACTED***`

清完一轮重跑一次，直到 `RESULT: PASS`。残留的 WARN（如公司强制的 VPN、合法安全工具的系统扩展）允许存在，但要能说出保留理由。

## ip-sentinel.sh — 出口 IP 哨兵

```bash
~/overseas-ops/bin/ip-sentinel.sh              # 手动跑一次
~/overseas-ops/bin/ip-sentinel.sh --quiet      # 定时任务模式：OK 不写 stdout（仍写日志）
~/overseas-ops/bin/ip-sentinel.sh --log PATH --expected-file PATH --no-notify
```

行为：

| 结果 | 含义 | 退出码 | 动作 |
|------|------|--------|------|
| `OK` | 出口 == 预期 IP | 0 | 写一行日志 |
| `MISMATCH` | 出口漂移/回落 | 1 | 日志 + macOS 弹窗通知 |
| `DOWN` | 三源全取不到出口（断网/隧道停，fail-closed 生效） | 2 | 日志 + macOS 弹窗通知 |
| `CONFIG` | 预期 IP 文件缺失/非法 | 3 | 日志 + stdout 提示 |

日志：`~/overseas-ops/logs/ip-sentinel.log`，每行 `时间戳 状态 详情`。

**MISMATCH 或 DOWN 时：立即停止账号操作**，再按 `playbook/05-monitoring.md` 5.2 的报警处理流程排查。

### 装成每小时定时任务（launchd，推荐）

完整的 plist 文件和加载命令见 `playbook/05-monitoring.md` 5.2，核心就两条：

```bash
# plist 写入 ~/Library/LaunchAgents/local.overseas-ops.ip-sentinel.plist 后：
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.overseas-ops.ip-sentinel.plist
sleep 15 && tail -3 ~/overseas-ops/logs/ip-sentinel.log   # 验证已跑过
```

cron 备选（每小时第 7 分钟）：

```cron
7 * * * * $HOME/overseas-ops/bin/ip-sentinel.sh --quiet >> $HOME/overseas-ops/logs/ip-sentinel.log 2>&1
```

launchd 和 cron **二选一**，不要同时装（日志会重复）。macOS 上 cron 需要"完全磁盘访问"授权才能稳定读写用户目录，嫌麻烦就用 launchd。

## 分工说明（重要）

脚本不是体检的全部。完整的七项泄露检查 = 脚本机判（本目录）+ 浏览器人工项（ipleak.net / dnsleaktest.com / browserleaks.com / PixelScan / Whoer / CreepJS + 七个 IP 信誉源）。两者的组合用法和 PASS 标准全部写在 `playbook/03-verify-leak.md`，本目录只是它的工具层。
