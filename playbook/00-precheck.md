# 阶段 00：准备与兜底

> 本阶段不碰任何设备配置。目标：料备齐、凭证入库、断网兜底就位。
> 执行模式：能自动的你（AI）自动做；只有采购、凭证、兜底确认需要用户出手。

## 本阶段目标

- 硬件、账号、采购确认
- 本地工作目录与凭证文件就位（你自动创建）
- 断网兜底就位（**本阶段唯一的硬闸门**）

## 步骤

### 0.1 自动初始化本地工作目录

你直接执行：

```bash
mkdir -p ~/overseas-ops/recovery && touch ~/overseas-ops/secrets.txt && chmod 600 ~/overseas-ops/secrets.txt
```

把本仓库的 `docs/recovery.md` 复制一份到 `~/overseas-ops/recovery/README.md`（断网时本地也能读）。

验收：`ls -la ~/overseas-ops/` 看到 `secrets.txt`（权限 600）和 `recovery/`。

### 0.2 采购清点（需要用户出手）

对照 `docs/shopping.md`，问用户一次（合并成一条，不要逐项轰炸）：

- [ ] GL.iNet MT3600BE 路由器（在手？）
- [ ] 美西 VPS（已买？需要 IP、root 密码或密钥）
- [ ] 住宅 IP 代理（已买？需要地址、端口、用户名、密码）

缺什么，打开 `docs/shopping.md` 给选型标准让他下单。**不替他选套餐。**

### 0.3 凭证入库（需要用户出手）

引导用户把 VPS 和住宅代理的凭证填入 `~/overseas-ops/secrets.txt`（或者贴给你，由你写入该文件）。提醒：这个文件不进 git、不外发。

验收：你读一遍 secrets.txt，四要素齐全（VPS IP/登录方式、代理 host/port/user/pass）。

### 0.4 断网兜底确认 ⭐（硬闸门，必须用户明确确认）

用一段话跟用户确认（这是本阶段唯一必须等回复的地方）：

> 后面改路由器的过程中**断网是大概率事件**。请确认三件事：
> 1. 你的手机热点现在能连（或者家里有第二个国内 WiFi）
> 2. 你有一个国内能用的 AI（Kimi / DeepSeek 都行），能正常对话
> 3. 断网时你会这样做：连热点 → 打开备用 AI → 把这句话发给它：
>
> "我在按 overseas-ops-network 仓库搭网络，执行到第 X 阶段断网了。请读我电脑上的 `~/overseas-ops/recovery/README.md`，按里面的场景树帮我修复。"
>
> 确认好了回我"兜底已就位"。

用户确认后才进 01。用户如果这时候没有热点/备用 AI，停下来让他先解决，不要侥幸开工。

## 本阶段验收（全绿才进 01）

- [ ] 路由器、VPS、住宅 IP 三样齐（或已下单在途，在途就等）
- [ ] `~/overseas-ops/secrets.txt` 凭证齐全，权限 600
- [ ] `~/overseas-ops/recovery/README.md` 已存本机
- [ ] 用户明确回复"兜底已就位"

## 回滚

本阶段无副作用，无需回滚。
