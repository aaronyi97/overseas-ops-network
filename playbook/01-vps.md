# 阶段 01：VPS 搭建（隧道服务端）

> 本阶段只碰 VPS，不碰路由器和任何用户设备，最坏情况是把 VPS 搞坏重装——不会断用户家里的网。
> 唯一的高危点是 1.6 的防火墙，按高危刹车协议处理。
> 执行模式：所有命令你（AI）直接执行（本机终端或 SSH 到 VPS），验收自己跑、自己判；只有 1.6 的 ⛔ 闸门和个别必须用户出手的事才停下来。

## 本阶段目标

- VPS 上装好 sing-box 服务端（VLESS + Reality 加密隧道的一头）
- VPS 的出口指向用户买的独享住宅 IP（目标网站看到的是住宅 IP，不是机房 IP）
- 施工电脑上的本地客户端能手动连上隧道并出海（**这是进 02 阶段的门票**）

完成后链路长这样（02 阶段再把"本地客户端"换成路由器）：

```
施工电脑（手动开的测试客户端）
   │  VLESS + Reality 加密隧道
   ▼
VPS（sing-box 服务端）
   │  HTTP 代理
   ▼
独享住宅 IP  →  互联网
```

## 前置条件

- [ ] 阶段 00 验收全绿（硬件、账号、兜底就位）
- [ ] VPS 已买好：**Ubuntu 系统**（22.04 / 24.04 均可），root 密码或密钥、公网 IP 已在 `~/overseas-ops/secrets.txt` 里
- [ ] 住宅 IP 代理已买好：secrets.txt 里有**代理地址、端口、用户名、密码**四样（HTTP 协议）
- [ ] 用户知道怎么登录 VPS 商家的**网页后台**（1.6 万一把自己锁在门外，要从网页终端救命；1.6 执行前会让用户现场确认一次）
- [ ] 本阶段你要往 secrets.txt 里写入 4 个新值（1.4 生成的密钥材料）

占位符约定（全仓库统一）：`<SERVER_IP>` = VPS 公网 IP；`<UUID>` `<REALITY_PRIVATE_KEY>` `<REALITY_PUBLIC_KEY>` `<REALITY_SHORT_ID>` = 1.4 生成的密钥；`<PROXY_HOST>` `<PROXY_PORT>` `<PROXY_USER>` `<PROXY_PASS>` = 住宅代理四要素。

## 步骤

### 1.1 第一次 SSH 登录 VPS

**为什么**：后面所有操作都在 VPS 上执行，SSH 是唯一的管理通道。先确认这条通道好用——1.6 高危步骤的成败标准就是"SSH 还能不能连上"。

**做什么**：你从施工电脑直接登录（IP 和凭证从 secrets.txt 读）：

```bash
ssh root@<SERVER_IP>
```

第一次连接会问 `Are you sure you want to continue connecting?`，输入 `yes` 回车，然后输入 root 密码（输入时屏幕不显示，是正常的）。

**验收**：登录成功后，命令行开头变成类似 `root@xxxx:~#` 的样子。

PASS 标准：看到 VPS 的命令行提示符，能在里面执行 `hostname` 并返回 VPS 的主机名。连不上先核对 IP 和凭证是否抄错；两次仍不通，带报错找用户。

---

### 1.2 系统更新与基础工具

**为什么**：新 VPS 的软件包索引是旧的，先更新再装工具，避免后面莫名其妙装不上东西。

**做什么**（你在 VPS 的 SSH 会话里直接执行；后面未特别说明的命令都在 VPS 上执行）：

```bash
apt update && apt upgrade -y
apt install -y curl openssl ufw
```

**验收**：

```bash
curl --version | head -1
openssl version
```

PASS 标准：两条命令都正常输出版本号，不报错。

---

### 1.3 安装 sing-box v1.13.3

**为什么**：sing-box 是隧道的核心软件。锁定 1.13.3 这个版本——它和 02 阶段路由器上装的版本一致，版本对齐能少踩很多坑。从官方 GitHub Release 下载，不用来路不明的第三方源。

**做什么**：

先确认 CPU 架构：

```bash
uname -m
```

- 输出 `x86_64` → 用下面的 `linux-amd64` 包（绝大多数 VPS 是这个）
- 输出 `aarch64` → 把下面两条命令里的 `amd64` 都换成 `arm64`

下载并安装：

```bash
cd /tmp
curl -LO https://github.com/SagerNet/sing-box/releases/download/v1.13.3/sing-box-1.13.3-linux-amd64.tar.gz
tar -xzf sing-box-1.13.3-linux-amd64.tar.gz
install -m 0755 sing-box-1.13.3-linux-amd64/sing-box /usr/local/bin/sing-box
mkdir -p /etc/sing-box
```

**验收**：

```bash
sing-box version
```

PASS 标准：第一行输出 `sing-box version 1.13.3`。

---

### 1.4 生成三份密钥材料

**为什么**：隧道要认"自己人"。UUID 相当于用户账号；Reality 密钥对相当于锁和钥匙（私钥留在 VPS，公钥将来给路由器）；short_id 是第二层暗号。这三样都是随机生成的，全网独一份。

**做什么**：依次执行三条命令，每条会输出一串字符：

```bash
sing-box generate uuid
sing-box generate reality-keypair
openssl rand -hex 8
```

你把输出**全部写入施工电脑本地的 `~/overseas-ops/secrets.txt`**，格式：

```
UUID = （第一条的输出）
REALITY_PRIVATE_KEY = （第二条输出的 PrivateKey 那行）
REALITY_PUBLIC_KEY  = （第二条输出的 PublicKey 那行）
SHORT_ID = （第三条的输出）
```

纪律：私钥（PrivateKey）永远只出现在 VPS 配置和 secrets.txt 里；公钥（PublicKey）02 阶段才用得到。

**验收**：你读回 secrets.txt 核对——四个值都在、没有截断、没有抄串行。

PASS 标准：secrets.txt 里四行齐全，且 PrivateKey 和 PublicKey 是**不同**的两串（如果一样说明抄错了，重新生成）。

---

### 1.5 写入服务端配置

**为什么**：这一步告诉 sing-box"怎么工作"：443 端口收隧道连接（VLESS+Reality，伪装成访问 www.cloudflare.com）、所有流量转给住宅代理、顺手掐掉走不了住宅代理的 QUIC（UDP 443）流量、管理接口只许 VPS 本机访问。这些都已经写在仓库的模板里，只需要替换占位符。

**做什么**：

1. 你读仓库里的 `configs/vps/sing-box-server.json`，用 secrets.txt 里的真实值把 6 个占位符逐个替换掉：
   - `<UUID>`、`<REALITY_PRIVATE_KEY>`、`<REALITY_SHORT_ID>`：1.4 生成的
   - `<PROXY_HOST>`、`<PROXY_PORT>`、`<PROXY_USER>`、`<PROXY_PASS>`：住宅代理四要素
   - 注意：`<PROXY_PORT>` 替换成**纯数字**，不带引号（例如 `8080`）
2. 把渲染好的配置直接写入 VPS 的 `/etc/sing-box/config.json`（heredoc 经 SSH 写入或本地渲染后 scp 均可）

模板里的 `//` 注释不用删，sing-box 认这种写法。

**验收**：

```bash
sing-box check -c /etc/sing-box/config.json
echo $?
```

PASS 标准：`sing-box check` **没有任何输出**，且 `echo $?` 输出 `0`。有报错你自己定位——通常是占位符没替换干净或标点抄坏了，修复后重试（上限两次）。（万一报错指向某一行注释，就把模板里的 `//` 注释行删掉再校验——极少见，但旧版本 sing-box 不认注释。）

---

### 1.6 ⛔高危 启用防火墙（放行 SSH 和 443，其余入站全关）

**为什么**：VPS 暴露在公网上，全世界都有扫描器在扫它。防火墙只留两个门：SSH（管理通道）和 443（隧道入口），其余全部关上。**风险在于：如果 SSH 那扇门没开对，会把自己锁在门外**，连管理通道都断掉。

**执行前，按高危刹车协议依次完成四件事（少一件都不许动手）**：

1. **一句话告知用户**："接下来启用 VPS 防火墙，只放行 SSH 端口和 443 端口。最坏情况是 SSH 端口放行错了，SSH 再也连不上 VPS，只能从商家网页后台的网页终端救；恢复方法我已经写好存在你电脑上。"
2. **生成本地恢复脚本**：你把下面这段**完整保存**为用户本机的 `~/overseas-ops/recovery/01-vps-ufw-recovery.md`，并告诉用户：万一 SSH 连不上了，照这个文件操作。

   ```text
   # VPS 防火墙锁外恢复（01 阶段 1.6 备用）
   1. 打开 VPS 商家的网页后台并登录（用商家账号，不是 root）
   2. 找到这台 VPS 的「网页终端 / Console / VNC / 救援终端」（各家叫法不同）
   3. 在网页终端里用 root + root 密码登录（密码在 secrets.txt）
   4. 执行：ufw disable
   5. 回到施工电脑，重新 ssh root@<SERVER_IP>，应该能连上了
   6. 连上后把当时执行的命令和报错发给 AI，排查是哪一步放行错了
   ```

3. **确认兜底**：让用户现在就去登录一次 VPS 商家网页后台，确认能打开、找得到网页终端入口。
4. **等待确认**：用户明确回复"继续"之后，再执行下面的命令。

**做什么**（用户回复"继续"之后，你直接执行）：

先确认 SSH 端口（绝大多数是 22，但有些商家会改）：

```bash
ss -tlnp | grep sshd
```

看输出里 `0.0.0.0:后面那个数字`，那就是 SSH 端口。下面命令里的 `<SSH_PORT>` 换成它（是 22 就写 22）：

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow <SSH_PORT>/tcp
ufw allow 443/tcp
ufw enable
```

`ufw enable` 会警告"可能中断现有连接"，输入 `y` 回车（已放行 SSH，现有会话不会断）。

**验收**（三样全过才算 PASS）：

```bash
ufw status verbose
```

① 输出里能看到 `<SSH_PORT>/tcp` 和 `443/tcp` 两条 `ALLOW`，且 `Status: active`。

② 你从施工电脑**新起一条 SSH 会话**，重新执行 `ssh root@<SERVER_IP>`——能登录成功。这一步是救命验收：旧会话不断不代表新会话能建，必须实测。

③ 旧的 SSH 会话还活着（没掉线）。

PASS 标准：①②③ 全过。任何一条不过：**不要继续**，先按本地恢复脚本里的流程恢复，再自己排查是哪一步放行错了；两次修不好，带现场信息找用户。

补充：如果 VPS 商家后台还有一层"安全组/防火墙"（在网页后台里设置的那种），也要在里面放行 443 端口——那是云平台的门，ufw 是系统里的门，两道都要开。网页后台操作必须用户出手，给他清单式指引：登录后台 → 找到安全组/防火墙 → 添加入站放行 443/tcp → 回你"已放行"。

---

### 1.7 设置开机自启并启动 sing-box

**为什么**：手动跑的程序一关 SSH 就没了。交给 systemd（Ubuntu 的服务管家）之后：开机自动起、崩溃自动拉、重启不用管。

**做什么**：

你直接在 VPS 上创建服务文件（heredoc 写入 `/etc/systemd/system/sing-box.service`），内容整段如下：

```ini
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/etc/sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
```

然后启用并启动：

```bash
systemctl daemon-reload
systemctl enable --now sing-box
```

**验收**：

```bash
systemctl status sing-box --no-pager
ss -tlnp | grep 443
```

PASS 标准：第一条输出里有 `active (running)`；第二条能看到 sing-box 在监听 443 端口。

---

### 1.8 VPS 上自测住宅代理出口

**为什么**：在动用客户端之前，先在 VPS 上确认两件事：① 买的住宅代理本身是通的；② sing-box 的出口确实指向它。把问题按层切开，出了错才知道该怪谁。

**做什么**：

① 直接测试住宅代理（这条命令不经过 sing-box，是 VPS 直接连代理）：

```bash
curl -x http://<PROXY_USER>:<PROXY_PASS>@<PROXY_HOST>:<PROXY_PORT> -s --max-time 20 https://api.ipify.org; echo
```

② 查看 sing-box 的出口选择器指向：

```bash
curl -s http://127.0.0.1:9090/proxies/exit-select
```

**验收**：

PASS 标准：

- ① 返回一个 IP 地址，且**不等于** VPS IP。你把这个 IP 写入 secrets.txt，标注"住宅 IP"——它就是将来在所有平台上的"网络身份"，1.9 还要用它对答案
- ② 输出里包含 `"now":"residential-isp"`

如果 ① 超时或报错：你先核对代理四要素有没有抄错；确认无误还不通，多半是代理本身的连通性问题——修复重试上限两次，仍不通带报错停下来找用户（可能需要用户去供应商后台确认订阅状态）。

---

### 1.9 本地客户端手动连接测试（本阶段出口标准）

**为什么**：前面验的都是 VPS 自己。这一步从施工电脑真连一次隧道，验证"客户端 → VPS → 住宅代理 → 互联网"整条链全通。02 阶段要把路由器接到这条隧道上，现在不验通，到时候路由器一接管连排查的网都没有。

**做什么**：

① 你在施工电脑上装 sing-box 客户端（和 VPS 同一个软件，只是角色不同）：

- macOS（有 Homebrew）：`brew install sing-box`
- macOS / Windows 手动装：从 `https://github.com/SagerNet/sing-box/releases/tag/v1.13.3` 下载对应压缩包（Mac 苹果芯片：`darwin-arm64`；Windows：`windows-amd64`），解压

② 你在施工电脑上新建文件 `~/overseas-ops/client-test.json`（这个目录本来就放凭证，安全），写入下面内容并替换 5 个占位符（值都在 secrets.txt 里）：

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vps",
      "server": "<SERVER_IP>",
      "server_port": 443,
      "uuid": "<UUID>",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "<REALITY_PUBLIC_KEY>",
          "short_id": "<REALITY_SHORT_ID>"
        }
      }
    }
  ]
}
```

注意：客户端用的是**公钥**（`<REALITY_PUBLIC_KEY>`），和服务端的私钥是一对，别抄错。

③ 启动本地客户端（在 `~/overseas-ops/` 目录下，前台跑着，这个窗口不要关）：

```bash
# macOS
sing-box run -c client-test.json

# Windows PowerShell（在解压出来的目录里）
.\sing-box.exe run -c client-test.json
```

④ **另开一个终端**，走本地代理发两个请求：

```bash
curl --proxy socks5h://127.0.0.1:1080 -s --max-time 20 https://api.ipify.org; echo
curl --proxy socks5h://127.0.0.1:1080 -sI --max-time 20 https://www.google.com | head -1
```

**验收**：

PASS 标准（两条全过）：

- 第一条返回的 IP **等于 1.8 写进 secrets.txt 的那个"住宅 IP"**——既不是用户的宽带 IP，也不是 VPS 的机房 IP
- 第二条返回 `HTTP/2 200` 或 `HTTP/1.1 200`

测完回到 ③ 的窗口按 `Ctrl+C` 停掉本地客户端。`client-test.json` 别删，留在 `~/overseas-ops/` 里，以后排障还会用到。

如果 FAIL：你自己读 ③ 窗口里 sing-box 的日志最后 20 行定位，修复重试上限两次；仍 FAIL 就带着现场信息（日志、已尝试的修复）停下来找用户。**无论何种结果都不要直接进 02 阶段**，PASS 是唯一门票。

---

### 1.10 以后改配置的纪律（现在不学命令，先记住规矩）

**为什么**：VPS 是整条链路的控制面，乱改配置 = 运营环境猝死。两条铁律，来自真实踩坑：

1. **改配置永远三步走**：改文件 → `sing-box check -c /etc/sing-box/config.json` 校验通过 → `systemctl reload sing-box`（平滑重载，不断现有连接）。**禁止 `systemctl restart`**——那会把所有在跑的连接掐断
2. **出口选择器里禁止出现直连**：`exit-select` 里永远只有住宅代理。住宅代理挂了宁可断网，也绝不允许自动回落成 VPS 直出——平台看到机房 IP，前面的功夫全废

补充一个已知现象，免得以后慌：如果将来通过这条隧道 SSH 到 VPS 上执行 `reload`，SSH 会话可能会闪断一下——这是隧道自己在重载，属正常现象，重新连上即可。

**验收**：无操作。这两条是你后续所有阶段改 VPS 配置时必须遵守的纪律，违反任意一条都按事故处理。

## 本阶段验收（全绿才进 02）

- [ ] `sing-box version` 输出 1.13.3
- [ ] `sing-box check` 通过（无输出、退出码 0）
- [ ] ufw 已启用：SSH 端口和 443/tcp 放行，**新起的 SSH 会话实测能登录**
- [ ] `systemctl status sing-box` 显示 active (running)，443 端口在监听
- [ ] VPS 直测住宅代理返回住宅 IP（≠ VPS IP）
- [ ] Clash API 显示出口选择器 `now: residential-isp`
- [ ] 本地客户端测试：出口 IP = 住宅 IP，且 google.com 返回 200
- [ ] secrets.txt 已记录：UUID、Reality 公私钥、SHORT_ID、住宅 IP（02 阶段要用公钥）

全部 PASS 后给用户一句话播报（如"✅ VPS 隧道已通，出口 IP 正确"），然后进 02。

## 回滚

本阶段只动过 VPS，回滚就是把 VPS 恢复成一台干净机器，不影响用户家里/公司的任何设备。

在 VPS 上执行：

```bash
systemctl disable --now sing-box
ufw disable
rm -f /etc/systemd/system/sing-box.service /usr/local/bin/sing-box
rm -rf /etc/sing-box
systemctl daemon-reload
```

再删除施工电脑上的 `~/overseas-ops/client-test.json`。

回滚后：VPS 防火墙关闭、sing-box 删除干净，可以从 1.1 重新开始。secrets.txt 里的密钥材料保留即可——重新搭建时可以直接复用，也可以重新生成一套（重新生成更安全）。
