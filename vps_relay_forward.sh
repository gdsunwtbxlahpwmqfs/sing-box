#!/usr/bin/env bash
# =======================================================
# 按端口分门别类的全端口/部分端口中转脚本（iptables）
# 规则格式举例（放在 RULES 数组里）:
#   "tcp:80,443->1.2.3.4"      单个协议、多个端口
#   "udp:53->2.2.2.2"         单个协议、单端口
#   "both:1000-2000->3.3.3.3" 协议 both 表示 tcp+udp，端口范围
#   "tcp:->4.4.4.4"           不指定端口表示该协议的全部端口
# =======================================================

set -euo pipefail

# -------------------------
# 配置区：在这里添加你的规则
# 格式: proto:port_spec->target_ip
# proto = tcp | udp | both
# port_spec = empty | single | comma-separated | range (start-end)
# Examples:
#   "tcp:80,443->1.1.1.1"
#   "udp:53->2.2.2.2"
#   "both:1000-2000->3.3.3.3"
#   "tcp:->5.5.5.5"   # ALL TCP -> 5.5.5.5
# -------------------------
RULES=(
  "tcp:6661-6671->144.202.119.34"
  "udp:50000-51000->144.202.119.34"
)

# -------------------------
# 以下无需改动（除非你知道自己在做什么）
# -------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 权限运行此脚本"
    exit 1
  fi
}

ensure_tools() {
  if ! command -v iptables >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y iptables
  fi
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    apt-get install -y iptables-persistent netfilter-persistent
  fi
}

enable_ip_forward() {
  echo "开启 IPv4 转发..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -Eq "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    sed -i '/^#*net.ipv4.ip_forward=/d' /etc/sysctl.conf || true
    printf "net.ipv4.ip_forward=1\n" >> /etc/sysctl.conf
  fi
  sysctl -p >/dev/null
}

# helper: add PREROUTING DNAT rule for given proto, port_param, target
# port_param can be:
#   ""           -> all ports (no --dport)
#   "80"         -> single port
#   "80,443,22"  -> multiport list (use -m multiport --dports)
#   "1000-2000"  -> range (use --dport 1000:2000)
add_prerouting_rule() {
  local proto=$1
  local port_param=$2
  local target=$3

  if [[ -z "$port_param" ]]; then
    # all ports
    iptables -t nat -A PREROUTING -p "${proto}" -j DNAT --to-destination "${target}"
  else
    # detect comma list
    if [[ "$port_param" == *","* ]]; then
      iptables -t nat -A PREROUTING -p "${proto}" -m multiport --dports "${port_param}" -j DNAT --to-destination "${target}"
    elif [[ "$port_param" == *"-"* ]]; then
      # range like start-end -> iptables expects start: end
      local rstart=${port_param%-*}
      local rend=${port_param#*-}
      iptables -t nat -A PREROUTING -p "${proto}" --dport "${rstart}:${rend}" -j DNAT --to-destination "${target}"
    else
      # single port
      iptables -t nat -A PREROUTING -p "${proto}" --dport "${port_param}" -j DNAT --to-destination "${target}"
    fi
  fi
}

# apply rules
apply_rules() {
  echo "清空 nat 表 PREROUTING 和 POSTROUTING（谨慎）..."
  iptables -t nat -F PREROUTING || true
  iptables -t nat -F POSTROUTING || true

  local added_masq_tcp=0
  local added_masq_udp=0

  for r in "${RULES[@]}"; do
    # strip spaces
    r="${r//[[:space:]]/}"
    # parse proto:ports->target
    if ! [[ "$r" =~ ^(tcp|udp|both):([0-9]+(-[0-9]+)?)-\>([0-9\.]+)$ ]]; then
      echo "⚠️ 忽略非法规则: $r"
      continue
    fi
    proto="${BASH_REMATCH[1],,}"    # lowercase
    ports="${BASH_REMATCH[2]}"
    target="${BASH_REMATCH[4]}"

    # normalize empty ports to ""
    if [[ -z "$ports" ]]; then
      port_param=""
    else
      port_param="$ports"
    fi

    case "$proto" in
      tcp)
        echo "添加 TCP 规则: ports='${port_param:-ALL}' -> ${target}"
        add_prerouting_rule tcp "$port_param" "$target"
        added_masq_tcp=1
        ;;
      udp)
        echo "添加 UDP 规则: ports='${port_param:-ALL}' -> ${target}"
        add_prerouting_rule udp "$port_param" "$target"
        added_masq_udp=1
        ;;
      both)
        echo "添加 TCP 规则: ports='${port_param:-ALL}' -> ${target}"
        add_prerouting_rule tcp "$port_param" "$target"
        echo "添加 UDP 规则: ports='${port_param:-ALL}' -> ${target}"
        add_prerouting_rule udp "$port_param" "$target"
        added_masq_tcp=1
        added_masq_udp=1
        ;;
      *)
        echo "⚠️ 未知协议 '$proto' ，跳过规则: $r"
        ;;
    esac
  done

  # 添加 POSTROUTING MASQUERADE（只需一次/协议）
  if [[ $added_masq_tcp -eq 1 ]]; then
    iptables -t nat -A POSTROUTING -p tcp -j MASQUERADE
  fi
  if [[ $added_masq_udp -eq 1 ]]; then
    iptables -t nat -A POSTROUTING -p udp -j MASQUERADE
  fi

  echo "保存并 reload iptables 规则（netfilter-persistent）..."
  netfilter-persistent save
  netfilter-persistent reload
}

create_systemd_service() {
  cat >/etc/systemd/system/relay-by-port.service <<EOF
[Unit]
Description=Relay by Port (iptables) Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/netfilter-persistent start
ExecReload=/usr/sbin/netfilter-persistent reload
ExecStop=/usr/sbin/netfilter-persistent stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable relay-by-port
  systemctl restart relay-by-port || true
}

main() {
  require_root
  ensure_tools
  enable_ip_forward
  apply_rules
  create_systemd_service
  echo "✅ 按端口分门别类转发已启用！"
  echo "已加载规则："
  for r in "${RULES[@]}"; do
    echo "  - $r"
  done
  echo "提示：查看 nat 表规则： iptables -t nat -L -n --line-numbers"
}

main "$@"
