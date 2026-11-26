#!/bin/sh
set -eu

PORT="${PORT:-}"
SNI="${SNI:-www.apple.com}"
MEM_LIMIT="${MEM_LIMIT:-65MiB}"
MAX_CONN="${MAX_CONN:-4}"
HOST_IP_OVERRIDE="${HOST_IP:-}"
OUT_FILE="${OUT_FILE:-/root/reality-node.txt}"
SILENT=0
INTERACTIVE=0
REMOVE_MODE=0

usage() {
  cat << 'USAGE'
用法: sb-reality.sh [选项]
  -s, --silent              静默模式（自动随机端口与密钥，最终输出结果）
  -i, --interactive         交互模式（提示输入端口、伪装 SNI、单 IP 连接上限）
  -p, --port <10000-65000>  指定监听端口（默认 10000-65000 随机空闲端口）
  --sni <域名>              伪装目标 SNI（默认 www.apple.com）
  --ip <地址>               指定客户端连接使用的 IP（默认自动检测公网 IP）
  --mem <如 65MiB>          Go 运行时内存上限（默认 65MiB）
  --max-conn <数字>         单 IP 并发 TCP 连接上限（默认 4，设 0 跳过）
  -o, --output <文件路径>   结果保存路径（默认 /root/reality-node.txt）
  --remove                  卸载 sing-box 与相关配置/规则
  -h, --help                显示帮助
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--silent) SILENT=1; shift ;;
    -i|--interactive) INTERACTIVE=1; shift ;;
    -p|--port) PORT="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --ip) HOST_IP_OVERRIDE="$2"; shift 2 ;;
    --mem) MEM_LIMIT="$2"; shift 2 ;;
    --max-conn) MAX_CONN="$2"; shift 2 ;;
    -o|--output) OUT_FILE="$2"; shift 2 ;;
    --remove) REMOVE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

cleanup_nokey() {
  if [ -x /usr/local/bin/nokey ]; then
    /usr/local/bin/nokey --remove >/dev/null 2>&1 || true
  fi
  rm -rf /usr/local/bin/nokey /usr/local/etc/nokey
}

if [ "$REMOVE_MODE" -eq 1 ]; then
  rc-service sing-box stop >/dev/null 2>&1 || true
  rc-update del sing-box default >/dev/null 2>&1 || true
  cleanup_nokey
  rm -f /etc/sing-box/config.json /etc/conf.d/sing-box "$OUT_FILE"
  echo "已清理 sing-box 配置与节点输出文件。"
  exit 0
fi

if [ "$INTERACTIVE" -eq 1 ] && [ "$SILENT" -eq 0 ]; then
  printf "监听端口 [10000-65000，留空自动随机]: "
  read -r in_port || true
  [ -n "${in_port:-}" ] && PORT="$in_port"

  printf "伪装 SNI [默认 %s]: " "$SNI"
  read -r in_sni || true
  [ -n "${in_sni:-}" ] && SNI="$in_sni"

  printf "单 IP 最大并发连接数 [默认 %s，0 为不设防火墙限制]: " "$MAX_CONN"
  read -r in_conn || true
  [ -n "${in_conn:-}" ] && MAX_CONN="$in_conn"
fi

is_port_in_use() {
  target_port="$1"
  hex_port=$(printf '%04X' "$target_port")
  for tbl in /proc/net/tcp /proc/net/tcp6; do
    if [ -r "$tbl" ]; then
      if awk -v hp="$hex_port" 'NR>1 {split($2, a, ":"); if (toupper(a[2]) == hp) {found=1; exit}} END {exit !found}' "$tbl"; then
        return 0
      fi
    fi
  done
  return 1
}

pick_random_port() {
  seed=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ' || echo "$$")
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    r=$(( (seed + attempt * 7919) % 55001 ))
    cand=$((10000 + r))
    if ! is_port_in_use "$cand"; then
      echo "$cand"
      return 0
    fi
    attempt=$((attempt + 1))
  done
  echo "24433"
}

cleanup_nokey

apk update >/dev/null
apk add --no-cache sing-box ca-certificates curl >/dev/null

if [ -z "${PORT:-}" ]; then
  PORT=$(pick_random_port)
fi

case "$PORT" in
  ''|*[!0-9]*)
    echo "端口必须为数字，当前: $PORT" >&2
    exit 1
    ;;
esac

if [ "$PORT" -lt 10000 ] || [ "$PORT" -gt 65000 ]; then
  echo "端口必须在 10000-65000 之间，当前: $PORT" >&2
  exit 1
fi

UUID=$(sing-box generate uuid)
KEYPAIR_OUT=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR_OUT" | awk '/PrivateKey:/ {print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR_OUT" | awk '/PublicKey:/ {print $2}')
SHORT_ID=$(sing-box generate rand --hex 8)

IPV4=$(curl -fsSL4 --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null \
  || curl -fsSL4 --connect-timeout 2 --max-time 3 https://ifconfig.me/ip 2>/dev/null \
  || true)
IPV6=$(curl -fsSL6 --connect-timeout 2 --max-time 3 https://api64.ipify.org 2>/dev/null \
  || true)

if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
  HOST_IP="$HOST_IP_OVERRIDE"
elif [ -n "${IPV4:-}" ]; then
  HOST_IP="$IPV4"
elif [ -n "${IPV6:-}" ]; then
  HOST_IP="[$IPV6]"
else
  HOST_IP="127.0.0.1"
fi

mkdir -p /etc/sing-box
cat << EOF > /etc/sing-box/config.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

cat << EOF > /etc/conf.d/sing-box
export GOMEMLIMIT=${MEM_LIMIT}
export GOGC=50
EOF

sing-box check -c /etc/sing-box/config.json >/dev/null
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart >/dev/null 2>&1 || true

sleep 1
if ! pidof sing-box >/dev/null 2>&1 && ! pgrep -x sing-box >/dev/null 2>&1; then
  echo "sing-box 启动失败，请检查 /etc/sing-box/config.json 与内存状态" >&2
  exit 1
fi

case "$MAX_CONN" in
  ''|*[!0-9]*) MAX_CONN=0 ;;
esac

if [ "$MAX_CONN" -gt 0 ] && command -v iptables >/dev/null 2>&1; then
  while iptables -D INPUT -p tcp --syn -m connlimit --connlimit-mask 32 -j DROP >/dev/null 2>&1; do
    :
  done
  iptables -A INPUT -p tcp --syn --dport "$PORT" -m connlimit --connlimit-above "$MAX_CONN" --connlimit-mask 32 -j DROP >/dev/null 2>&1 || true
fi

{
  echo "IPv4: ${IPV4:-无}"
  echo "IPv6: ${IPV6:-无}"
  echo "端口: ${PORT}"
  echo "UUID: ${UUID}"
  echo "PublicKey: ${PUBLIC_KEY}"
  echo "ShortId: ${SHORT_ID}"
  echo "SNI: ${SNI}"
  echo ""
  echo "--- Clash / Mihomo 节点配置 ---"
  echo "proxies:"
  echo "  - name: \"Reality-${HOST_IP}-${PORT}\""
  echo "    type: vless"
  echo "    server: ${HOST_IP}"
  echo "    port: ${PORT}"
  echo "    uuid: ${UUID}"
  echo "    network: tcp"
  echo "    tls: true"
  echo "    udp: true"
  echo "    servername: ${SNI}"
  echo "    reality-opts:"
  echo "      public-key: ${PUBLIC_KEY}"
  echo "      short-id: ${SHORT_ID}"
  echo "    client-fingerprint: chrome"
  echo "    smux:"
  echo "      enabled: true"
  echo "      protocol: smux"
  echo "      max-connections: 2"
  echo "      min-streams: 4"
  echo "      padding: true"
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"
cat "$OUT_FILE"
