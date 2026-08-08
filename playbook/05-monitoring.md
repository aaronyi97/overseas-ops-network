# 阶段 05：监控与长期维护

> 搭好只是开始。出口 IP 会漂移、供应商会出故障、订阅会到期——这一阶段把"靠脑子记"变成"靠机器盯"。
> 本阶段全部操作只读或仅新增定时任务，无高危步骤。
> 执行模式：安装和验证你（AI）直接做；续费、日历提醒这类账号侧操作必须用户出手，给清单式请求。

## 本阶段目标

- 出口 IP 哨兵上线：每小时自动比对一次出口 IP，不一致立刻报警
- 每周体检成为固定习惯（机器 + 人工结合）
- 续费纪律落地：**固定 IP 断供 = IP 被回收 = 永远失去这个身份**，这是用真金白银踩过的坑

## 前置条件

- [ ] 阶段 03 七项全绿、阶段 04 验收通过
- [ ] `~/overseas-ops/expected-exit-ip.txt` 已写入当前住宅 IP（03 前置条件）
- [ ] 脚本已在 `~/overseas-ops/bin/` 且有可执行权限

## 步骤

### 5.1 手动先跑一次哨兵

**做什么**：`ip-sentinel.sh` 干一件事——取当前出口 IP，和预期文件比对。三种结局：一致（OK）、不一致（MISMATCH，IP 漂移或回落）、取不到出口（DOWN，隧道断了，fail-closed 生效中）。你直接跑：

```bash
~/overseas-ops/bin/ip-sentinel.sh
```

**PASS 标准**：输出 `OK`，退出码 0（`echo $?` 查看）。同时确认日志已追加：`tail -3 ~/overseas-ops/logs/ip-sentinel.log`。

> 退出码约定：`0`=正常，`1`=出口 IP 与预期不符，`2`=取不到出口（断网/隧道停），`3`=配置错误（预期文件缺失等）。定时报警和排障都靠它。

### 5.2 装定时哨兵（launchd，每小时）

**为什么**：IP 漂移、供应商悄悄换出口、隧道半夜挂掉——这些事不会挑人盯着屏幕的时候发生。每小时一次自动比对，异常时写日志 + 弹 macOS 通知。

macOS 推荐 launchd。你直接创建 plist 文件：

```bash
cat > ~/Library/LaunchAgents/local.overseas-ops.ip-sentinel.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.overseas-ops.ip-sentinel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>$HOME/overseas-ops/bin/ip-sentinel.sh --quiet</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
```

加载并立即验证：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.overseas-ops.ip-sentinel.plist
sleep 15
tail -3 ~/overseas-ops/logs/ip-sentinel.log
```

**PASS 标准**：日志里出现一条刚才时间戳的 `OK` 记录（RunAtLoad 会让它加载后立刻跑一次）。一小时后可再看一眼，确认又多了一条。

**哨兵报警了怎么办**（MISMATCH 或 DOWN）——把第 1 条讲给用户，其余你带着处理：

1. **让用户立即停止一切账号操作**——漂移期间每一秒操作都在给账号档案叠加矛盾信号
2. 打开 ipleak.net 看当前实际出口是谁
3. DOWN（断网）：大概率是隧道挂了，fail-closed 正常工作中，按 `docs/recovery.md` 修复
4. MISMATCH（IP 变了）：检查供应商侧是否变更了分配（必要时让用户去后台看）；确认新 IP 是预期变更后，更新 `expected-exit-ip.txt` 并重跑 03 全项体检

### 5.3 （备选）用 cron 跑哨兵

launchd 不适用时（比如用户就是习惯 cron），改用：

```bash
crontab -l 2>/dev/null | grep -v ip-sentinel | crontab -
( crontab -l 2>/dev/null; echo '7 * * * * $HOME/overseas-ops/bin/ip-sentinel.sh --quiet >> $HOME/overseas-ops/logs/ip-sentinel.log 2>&1' ) | crontab -
crontab -l | grep ip-sentinel   # 确认已写入
```

注意：macOS 上 cron 需要给 cron 授予"完全磁盘访问权限"才能稳定读写用户目录，弹不出授权框就老实回 5.2 用 launchd。二选一，不要两个都装（日志会重复）。

### 5.4 每周体检

**为什么**：小时级哨兵只盯"出口 IP 变没变"，盯不了 DNS 配置漂移、浏览器更新后 WebRTC 开关失效、IP 信誉悄悄恶化这些慢性问题。

和用户约定每周固定一个时间（比如周一早上），做三件事：

1. 脚本两项（你可以代跑，或照下面的方法自动化）：

```bash
~/overseas-ops/bin/net-check.sh
~/overseas-ops/bin/proxy-residue-scan.sh
```

2. 浏览器人工抽查 03 的关键项（必须用户做，给他固定清单）：ipleak.net（出口）、dnsleaktest.com Extended test（DNS）、browserleaks.com/webrtc（WebRTC）——每个运营浏览器都要过一遍
3. 抽查 IP 信誉：至少 Scamalytics + IPQualityScore 两源，和上周记录对比有没有变差

**PASS 标准**：脚本全 PASS、浏览器项全绿、信誉无恶化。任何一项掉了，按 03/04 对应步骤修。

> 想更进一步自动化：可以照 5.2 的方法给 `net-check.sh` 也加一个每周 launchd 任务（`StartInterval 604800`），日志落盘，每周只看一眼日志。但浏览器项永远需要人工，别省。

### 5.5 续费纪律（长期义务，最重要的一节）

**真实踩过的坑**：住宅 IP 是订阅制。有一次忘记续费，订阅过期，**供应商直接回收了那个固定 IP，再花钱也买不回同一个**——只能换一个新 IP，而这个新 IP 对平台来说是"一个全新的人"，之前养了几个月的账号环境信任度部分作废，一切从头再来。

以下全部必须用户出手，合并成一条清单式请求（不要逐项轰炸）：

- [ ] 住宅 IP 订阅：打开自动续费；同时在日历里设**到期前 7 天 + 前 3 天**两个提醒（自动续费也会失败：卡过期、余额不足）
- [ ] VPS 订阅：同样处理。VPS 断了至少 IP 还在（住宅 IP 在供应商侧），但断太久一样麻烦
- [ ] 把两个到期日记进 `~/overseas-ops/secrets.txt` 旁边的备忘录
- [ ] 每次续费后，确认供应商后台里固定 IP 槽位仍然绑定着、没被释放
- [ ] 做完回你"续费纪律已设"

**换 IP 的正当理由**（只有这些，别手痒）：信誉七源里 3+ 源标记且持续恶化；平台风控明显加剧；供应商释放了 IP。前 2-3 个月保持同一个 IP 不动，是账号信任积累的关键期。

### 5.6 换 IP 标准流程（SOP）

真到了必须换 IP 的时候，按顺序走，别乱：

1. 用户在供应商侧获取/绑定新 IP；你改 VPS 隧道配置（02 阶段的方法）
2. 你更新 `~/overseas-ops/expected-exit-ip.txt` 为新 IP
3. 你手动跑一次哨兵确认 OK
4. 完整重跑 03 阶段七项体检（新 IP 的信誉必须重新查）
5. 观察哨兵日志 48-72 小时，确认稳定无漂移
6. 然后用户才恢复账号操作；已注册的老账号尽量降低操作频率过渡几天

## 本阶段验收

- [ ] 手动跑 `ip-sentinel.sh` 返回 OK、退出码 0
- [ ] launchd（或 cron）定时任务已加载，日志在持续追加新记录
- [ ] 用户已知晓：哨兵报警（两种）各自该怎么处理（你用一两句话讲清，确认他听懂了）
- [ ] 住宅 IP 和 VPS 的自动续费已开 + 日历双提醒已设
- [ ] 用户已知晓：断供的后果是什么（不是"断网"，是"永久失去这个 IP 身份"）

全部通过 = 六个阶段全部收口，环境进入长期运营态。给用户一句话收尾播报。

## 回滚

- 卸载 launchd 哨兵：

```bash
launchctl bootout gui/$(id -u)/local.overseas-ops.ip-sentinel
rm ~/Library/LaunchAgents/local.overseas-ops.ip-sentinel.plist
```

- 卸载 cron 哨兵：`crontab -l | grep -v ip-sentinel | crontab -`
- 日志、`expected-exit-ip.txt`、`~/overseas-ops/` 整个目录删除即可
- 本阶段不改动任何网络配置，回滚不影响 01-04 的成果
