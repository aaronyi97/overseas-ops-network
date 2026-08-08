# 防火墙 fail-closed：FORWARD default-deny（fw3 + iptables）

> 本文是配置参考。启用防火墙属于 ⛔高危操作（可能断网），执行顺序、
> 恢复脚本和刹车流程以 `playbook/02-router.md` 2.9 步为准。

## 一、这是什么：双层 fail-closed 的第二层

这套方案承诺"隧道异常 = 直接断网，真实 IP 一秒都不暴露"。靠两层实现：

| 层 | 机制 | 管什么 |
|----|------|--------|
| 第 1 层 | sing-box TUN `strict_route` | 隧道断了但 sing-box 进程还在：禁止流量从普通路由溜走 |
| 第 2 层 | **路由器防火墙 FORWARD default-deny（本文）** | sing-box 整个崩了/停了：局域网设备依然什么都发不出去 |

两层都在才算 fail-closed。只做第 1 层，sing-box 进程一死就裸奔。

**先确认防火墙后端**：MT3600BE 的 GL 固件（OpenWrt 21.02）实测是
**fw3 + iptables/ip6tables**，不是新版 OpenWrt 的 fw4/nftables。
本文规则只适用于 fw3。确认方法：

```sh
iptables --version        # 有输出 = iptables 系
ls /etc/firewall.user     # 存在 = fw3 的自定义规则入口可用
which fw4 nft             # 应该都没有输出
```

## 二、设计思路（说人话）

- 局域网设备访问路由器自己（SSH / Web 管理面 192.168.8.1）走的是
  **INPUT 链**——本文一条都不碰，所以"断网"永远不会把你锁在管理面外。
- 路由器自己出网（sing-box 连 VPS、dnscrypt 发 DoH）走 **OUTPUT 链**
  ——也不碰，隧道自己能建、能重连。
- 我们只管 **FORWARD 链**（设备穿过路由器上网的那条路）：
  - 去 `tun0`（sing-box 活着时透明流量走的路）→ 放行
  - 去其他任何地方（上游家宽/酒店网络）→ **丢弃**

效果：sing-box 健康时一切照常（流量本来就走 tun0/TPROXY，不经过这条
DROP）；sing-box 一停，tun0 消失、TPROXY 撤销，设备的包只剩"去上游"
一条路——正好撞上 DROP，于是全网静默，而不是悄悄直连出去。

## 三、配置片段（写入 /etc/firewall.user）

`/etc/firewall.user` 是 fw3 留给用户的自定义钩子，每次防火墙
reload/restart/开机都会执行，天然持久化。把下面这段追加进去：

```sh
# >>> fail-closed >>>
# 双层 fail-closed 第 2 层：LAN 转发 default-deny
# 幂等写法：-C 检查存在才 -I 插入，reload 多少次都不会堆叠

# 1) tun0 → LAN 的回程流量放行
iptables  -C FORWARD -i tun0   -o br-lan -j ACCEPT 2>/dev/null || iptables  -I FORWARD 1 -i tun0   -o br-lan -j ACCEPT
ip6tables -C FORWARD -i tun0   -o br-lan -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i tun0   -o br-lan -j ACCEPT

# 2) LAN → tun0 放行（sing-box 健康时透明流量的路）
iptables  -C FORWARD -i br-lan -o tun0   -j ACCEPT 2>/dev/null || iptables  -I FORWARD 2 -i br-lan -o tun0   -j ACCEPT
ip6tables -C FORWARD -i br-lan -o tun0   -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 2 -i br-lan -o tun0   -j ACCEPT

# 3) 其余所有 LAN 转发一律丢弃（fail-closed 本体）
iptables  -C FORWARD -i br-lan -j DROP 2>/dev/null || iptables  -I FORWARD 3 -i br-lan -j DROP
ip6tables -C FORWARD -i br-lan -j DROP 2>/dev/null || ip6tables -I FORWARD 3 -i br-lan -j DROP
# <<< fail-closed <<<
```

改完执行：

```sh
/etc/init.d/firewall restart
```

三个注意点：

1. **顺序不能乱**。1、2 在 3 之前，去 tun0 的包永远先命中放行。
   用 `-I FORWARD <固定位置>` 插入就是为保证这个顺序。
2. **确认 LAN 桥名**。上面假设桥叫 `br-lan`（GL 固件默认）。先跑
   `ip link | grep -E 'br-|tun'` 确认；如果你开了访客 Wi-Fi，访客
   桥（常见 `br-guest`）要照样加一组 1/2/3。
3. **启用时机**。必须在 sing-box + TUN + TPROXY 全部验收通过之后再
   启用（playbook 2.9），否则你会在隧道还没搭好时就把自己断网。

## 四、验证

启用后分两种状态验证：

**sing-box 健康时（应该无感）**——连 WiFi 的设备：

```sh
curl -4 https://api.ipify.org     # 返回你的 VPS/出口 IP
ping -c 3 223.5.5.5               # 通（ICMP 走 tun0）
```

**sing-box 停止时（fail-closed 本体）**：

```sh
# 在路由器上：/etc/init.d/sing-box stop
curl -4 --max-time 5 https://api.ipify.org   # 必须超时/失败
ping -c 2 -W 2 223.5.5.5                     # 必须不通
curl --max-time 5 http://192.168.8.1         # 必须通（管理面保活）
ssh root@192.168.8.1 'echo ok'               # 必须通（管理面保活）
```

外网全断 + 管理面保活 = PASS。任何一项反过来都是 FAIL，立即回滚。

## 五、回滚

```sh
# 删掉 firewall.user 里 >>> fail-closed >>> 标记包住的整段，然后：
/etc/init.d/firewall restart
```

防火墙 restart 会按 fw3 默认策略重建规则，自定义 DROP 消失，设备恢复
普通直连（前提是 TPROXY 规则也已按 playbook 撤掉）。

## 六、可选加固（了解即可，默认不做）

更严格的写法是白名单制：FORWARD 只放行"到 VPS IP / 到上游网关 /
established-related"，其余全 DROP。本文的"tun0 以外全 DROP"在实际
效果上等价且更简单（设备本来就不需要直连 VPS，隧道是路由器自己建的）。
没有特殊需求不要叠加，规则越复杂，断网时越难排查。
