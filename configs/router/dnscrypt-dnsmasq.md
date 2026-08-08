# 路由器 DNS 方案：dnsmasq + dnscrypt-proxy2（DoH 加密）

> 本文是配置参考。改 DNS 上游属于 ⛔高危操作（可能断网），执行顺序、
> 恢复脚本和刹车流程以 `playbook/02-router.md` 2.8 步为准，本文只解释
> "为什么这么配"和"每个片段是什么"。

## 一、要解决的问题

路由器固件默认把上游网络（家宽/酒店）下发的 DNS 塞给 dnsmasq。这条链路
上的明文 UDP 53 查询会被 GFW 注入虚假应答，实测过的污染案例：

| 域名 | 污染解析结果（指向了别家的 IP 段） | 真实归属 |
|------|----------------------------------|----------|
| chatgpt.com | 指向 Facebook/Meta 的 IP 段 | Cloudflare |
| api.openai.com | 指向 Twitter/X 的 IP 段 | Cloudflare |

电脑手动改 DNS 可以躲一时，但 iPhone 等走 DHCP 拿 DNS 的设备全部中招。
而且光靠"换干净 IP 的上游"不够：GFW 不只看目标，还能在链路上劫持明文
UDP 53。唯一可靠的防御是 **DNS 查询加密后再出门**。

## 二、最终 DNS 链路

```
手机/电脑 ──DNS──> dnsmasq（路由器 :53，DHCP 默认下发）
                     └──唯一上游──> dnscrypt-proxy2（127.0.0.1:5335）
                                      └──DoH 加密──> 公共 DoH 服务器
```

- 对设备完全透明：DHCP 发什么就用什么，不用改任何设备设置
- 出路由器的 DNS 是 HTTPS 加密的，链路上看不到也改不了
- 再叠加 sing-box TPROXY 入口的 SNI 嗅探兜底（见 sing-box-client.json
  里 `sniff_override_destination` 的注释），双保险

## 三、配置片段

### 3.1 dnscrypt-proxy2：让进程真正跑起来（GL 固件有坑）

GL.iNet 固件 ≠ 标准 OpenWrt。它的 `/etc/init.d/dnscrypt-proxy` 里有
一个 UCI 守卫：只有 `gl-dns` 模式是 `secure` 时才真正启动，否则脚本
**静默退出——不报错、不写日志、不起进程**（实测 P0 事故：按端口问题
排查了两轮，最后读 init.d 源码才发现守卫）。

```sh
# 关键两行：解开 GL 固件的守卫，声明走 DoH
uci set gl-dns.@dns[0].mode='secure'
uci set gl-dns.@dns[0].proto='DoH'
uci commit gl-dns

/etc/init.d/dnscrypt-proxy start
/etc/init.d/dnscrypt-proxy enable
```

监听端口约定为 **5335**：

- 不要用 5353——实测会被 avahi-daemon 占用
- 监听地址的配置位置随固件版本不同（常见于
  `/etc/dnscrypt-proxy2/dnscrypt-proxy.toml` 的 `listen_addresses`，
  或由 `gl-dns` 设置驱动）。以你机器上 `ls` 到的实际文件为准，
  改完后用下面的验证命令确认

```sh
# 验证：进程在跑 + 端口在听（TCP 和 UDP 都要有）
pidof dnscrypt-proxy
netstat -lnp | grep 5335
```

**排错纪律（血泪教训）**：`pidof` 为空且 `logread` 里没有任何该服务
日志 = 进程根本没启动过。此时立刻 `cat /etc/init.d/dnscrypt-proxy`
读守卫条件、查 `uci show gl-dns`，禁止继续盲目换端口、调参数。

### 3.2 dnsmasq：唯一上游指向本地加密 DNS

```sh
# 备份先
cp /etc/config/dhcp /etc/config/dhcp.bak.$(date +%s)

# 忽略上游下发的 DNS，只走 127.0.0.1#5335（dnscrypt）
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 3.3 路由器本机 resolv.conf 收口（建议一并做）

LAN 设备干净了，但**路由器自己的 shell**（以后排查时 `nslookup` 用）
默认还在用上级下发的 DNS。把 wwan/wwan6 的 peer DNS 关掉、指向本机
dnsmasq：

```sh
uci set network.wwan.peerdns='0'
uci delete network.wwan.dns 2>/dev/null
uci add_list network.wwan.dns='127.0.0.1'

uci set network.wwan6.peerdns='0'
uci delete network.wwan6.dns 2>/dev/null
uci add_list network.wwan6.dns='::1'

uci commit network
/etc/init.d/dnsmasq restart
sleep 3
/etc/init.d/network reload
```

说明：`network reload` 时若出现 `killall: mapd|p1905_managerd...` 的
提示是无害的（那些进程本来就没在跑）。

> 注：`wwan`/`wwan6` 是 GL 固件里"上游网络"接口的常见名字。如果你的
> 固件里叫别的（如 `wan`），先 `uci show network | grep -m5 peerdns`
> 找到实际接口名再替换。

## 四、验证

在路由器 SSH 里：

```sh
nslookup chatgpt.com
nslookup api.openai.com
nslookup google.com
```

PASS 标准：解析结果落在正确的服务商机房段（如 chatgpt.com /
api.openai.com 应返回 Cloudflare 段地址）。如果返回的是毫不相干的
大公司 IP 段（Facebook、Twitter 那种），说明仍被污染——停下来回滚，
不要继续。

再用一台连 WiFi 的设备实测（iPhone 也要测，它是 DHCP DNS 的重灾区）：
浏览器能正常打开此前被污染的站点。

## 五、回滚

```sh
# dnsmasq 回滚：恢复"用上游下发的 DNS"
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci set dhcp.@dnsmasq[0].noresolv='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# wwan 本机 DNS 回滚（如做过 3.3）
uci delete network.wwan.dns 2>/dev/null
uci set network.wwan.peerdns='1'
uci delete network.wwan6.dns 2>/dev/null
uci set network.wwan6.peerdns='1'
uci commit network
/etc/init.d/network reload
```

dnscrypt 本身不需要卸：dnsmasq 不再指向它之后它就是闲置进程。

## 六、过渡方案（不推荐长期使用）

也可以跳过 dnscrypt，把 dnsmasq 上游直接指 `1.1.1.1` / `8.8.8.8`：
这两个地址不在 TUN 的 `route_exclude_address` 里，查询会被 TUN 抓进
隧道再出海，绕开本链路的污染。但这依赖 sing-box 时刻健康，且明文 DNS
在隧道入口前仍暴露一跳。**最终形态请以上面第二节的加密链路为准。**
