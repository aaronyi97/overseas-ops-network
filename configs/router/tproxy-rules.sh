#!/bin/sh
# ============================================================================
# tproxy-rules.sh — sing-box TPROXY 透明接管的 iptables / 策略路由规则
#
# 目标设备：GL.iNet MT3600BE（OpenWrt 21.02，fw3 + iptables/ip6tables）
# 存放位置：路由器 /etc/sing-box-tproxy-rules.sh（chmod +x）
# 调用方式：
#   /etc/sing-box-tproxy-rules.sh start   # sing-box 启动后调用（init.d 已挂钩）
#   /etc/sing-box-tproxy-rules.sh stop    # sing-box 停止前调用 / 手动恢复用
#
# 为什么不能省这个脚本（实测踩过的坑）：
#   iptables 规则有 fw3 的持久化机制，重启不丢；但 `ip rule` / `ip route`
#   是内核运行时状态，路由器一重启就没。缺了下面那 4 条 ip 规则时，
#   症状是"sing-box 在跑、iptables 规则也在，但 WiFi 连上就是上不了网"。
#   所以必须由 init.d 在每次启动 sing-box 后重新下发。
#
# 注意：OpenWrt 默认 shell 是 BusyBox ash，没有 bash、没有 nohup。
#       本脚本只用 POSIX sh 语法，不要用 bash 特性改写。
# ============================================================================

# 你的 VPS IP：启用前把 <SERVER_IP> 替换成真实值（与 sing-box 配置一致）
SERVER_IP="<SERVER_IP>"

MARK="0x1/0x1"
TABLE="100"
PREF="100"
CHAIN4="SINGBOX_TPROXY"
CHAIN6="SINGBOX_TPROXY6"
PORT4="60080"
PORT6="60081"

do_start() {
    # ---- 1. 策略路由：被打上 fwmark 0x1 的包查路由表 100，投递到本机 ----
    # 幂等：先查再加，重复执行不会重复添加
    ip rule | grep -q "fwmark 0x1 lookup $TABLE" || \
        ip rule add fwmark $MARK lookup $TABLE pref $PREF
    ip route show table $TABLE 2>/dev/null | grep -q "^local 0.0.0.0/0" || \
        ip route add local 0.0.0.0/0 dev lo table $TABLE

    # IPv6 同理（IPv6 默认路由在 GL 固件上已存在，不能忽略不管）
    ip -6 rule | grep -q "fwmark 0x1 lookup $TABLE" || \
        ip -6 rule add fwmark $MARK lookup $TABLE pref $PREF
    ip -6 route show table $TABLE 2>/dev/null | grep -q "^local ::/0" || \
        ip -6 route add local ::/0 dev lo table $TABLE

    # ---- 2. IPv4 TPROXY 链：局域网进来的 TCP/UDP 转交 sing-box :60080 ----
    iptables -t mangle -N $CHAIN4 2>/dev/null
    iptables -t mangle -F $CHAIN4

    # 私网 / 保留网段直接放行：访问路由器管理面、局域网互访不进隧道
    for net in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
               172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t mangle -A $CHAIN4 -d "$net" -j RETURN
    done

    # VPS 自身放行：防止任何指向 VPS 的包被拦回来形成环路
    iptables -t mangle -A $CHAIN4 -d "$SERVER_IP" -j RETURN

    # TCP/UDP 打上标记并 TPROXY 到 sing-box；其余协议（如 ICMP）放行，
    # 交给 TUN 的 auto_route 处理
    iptables -t mangle -A $CHAIN4 -p tcp -j TPROXY \
        --on-ip 127.0.0.1 --on-port $PORT4 --tproxy-mark $MARK
    iptables -t mangle -A $CHAIN4 -p udp -j TPROXY \
        --on-ip 127.0.0.1 --on-port $PORT4 --tproxy-mark $MARK
    iptables -t mangle -A $CHAIN4 -j RETURN

    # 挂到 PREROUTING（幂等：先查再挂）
    iptables -t mangle -C PREROUTING -j $CHAIN4 2>/dev/null || \
        iptables -t mangle -A PREROUTING -j $CHAIN4

    # ---- 3. IPv6 TPROXY 链：同理，端口 60081 ----
    ip6tables -t mangle -N $CHAIN6 2>/dev/null
    ip6tables -t mangle -F $CHAIN6

    for net in ::1/128 fc00::/7 fe80::/10 ff00::/8; do
        ip6tables -t mangle -A $CHAIN6 -d "$net" -j RETURN
    done

    ip6tables -t mangle -A $CHAIN6 -p tcp -j TPROXY \
        --on-ip ::1 --on-port $PORT6 --tproxy-mark $MARK
    ip6tables -t mangle -A $CHAIN6 -p udp -j TPROXY \
        --on-ip ::1 --on-port $PORT6 --tproxy-mark $MARK
    ip6tables -t mangle -A $CHAIN6 -j RETURN

    ip6tables -t mangle -C PREROUTING -j $CHAIN6 2>/dev/null || \
        ip6tables -t mangle -A PREROUTING -j $CHAIN6

    echo "tproxy-rules: start done"
}

do_stop() {
    # 摘掉 PREROUTING 挂载点并清空自定义链
    iptables -t mangle -D PREROUTING -j $CHAIN4 2>/dev/null
    iptables -t mangle -F $CHAIN4 2>/dev/null
    iptables -t mangle -X $CHAIN4 2>/dev/null

    ip6tables -t mangle -D PREROUTING -j $CHAIN6 2>/dev/null
    ip6tables -t mangle -F $CHAIN6 2>/dev/null
    ip6tables -t mangle -X $CHAIN6 2>/dev/null

    # 删策略路由（v4 + v6）
    ip rule del fwmark $MARK lookup $TABLE pref $PREF 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table $TABLE 2>/dev/null
    ip -6 rule del fwmark $MARK lookup $TABLE pref $PREF 2>/dev/null
    ip -6 route del local ::/0 dev lo table $TABLE 2>/dev/null

    echo "tproxy-rules: stop done"
}

case "$1" in
    start) do_start ;;
    stop)  do_stop ;;
    *)
        echo "用法: $0 {start|stop}"
        exit 1
        ;;
esac
