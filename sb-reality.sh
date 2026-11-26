#!/bin/sh
set -eu

# 默认参数
PORT="${PORT:-}"
SNI="${SNI:-www.amd.com}"
MEM_LIMIT="${MEM_LIMIT:-65MiB}"
MAX_CONN="${MAX_CONN:-4}"
HOST_IP_OVERRIDE="${HOST_IP:-}"
OUT_FILE="${OUT_FILE:-/root/reality-node.txt}"
SILENT=0
INTERACTIVE=0
REMOVE_MODE=0

# 端口范围常量
MIN_VALID_PORT=10000
MAX_VALID_PORT=65000
RAND_PORT_MIN=30000
RAND_PORT_MAX=50000

log_info() {
  if [ "$SILENT" -eq 0 ]; then
    echo "[信息] $*" >&2
  fi
}

log_warn() {
  echo "[警告] $*" >&2
}

log_err() {
  echo "[错误] $*" >&2
}

usage() {
  cat << 'USAGE'
用法: sb-reality.sh [选项]
  -s, --silent              静默模式（自动在 30000-50000 随机空闲端口并输出结果）
  -i, --interactive         交互模式（提示输入端口、伪装 SNI、单 IP 连接上限）
  -p, --port <10000-65000>  指定监听端口（安装前强制检测占用，冲突时告警）
  --sni <域名>              伪装目标 SNI（默认 www.amd.com）
  --ip <地址>               指定客户端连接使用的 IP（默认自动检测公网 IP）
  --mem <如 65MiB>          Go 运行时内存上限（默认 65MiB）
  --max-conn <数字>         单 IP 并发 TCP 连接上限（默认 4，设 0 跳过）
  -o, --output <文件路径>   结果保存路径（默认 /root/reality-node.txt）
  --remove                  彻底清理 sing-box 配置、状态与防火墙规则
  -h, --help                显示帮助
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--silent) SILENT=1; shift ;;
    -i|--interactive) INTERACTIVE=1; shift ;;
    -p|--port)
      [ "$#" -lt 2 ] && { log_err "-p 需要指定端口号"; exit 1; }
      PORT="$2"; shift 2 ;;
    --sni)
      [ "$#" -lt 2 ] && { log_err "--sni 需要指定域名"; exit 1; }
      SNI="$2"; shift 2 ;;
    --ip)
      [ "$#" -lt 2 ] && { log_err "--ip 需要指定地址"; exit 1; }
      HOST_IP_OVERRIDE="$2"; shift 2 ;;
    --mem)
      [ "$#" -lt 2 ] && { log_err "--mem 需要指定内存上限"; exit 1; }
      MEM_LIMIT="$2"; shift 2 ;;
    --max-conn)
      [ "$#" -lt 2 ] && { log_err "--max-conn 需要指定数字"; exit 1; }
      MAX_CONN="$2"; shift 2 ;;
    -o|--output)
      [ "$#" -lt 2 ] && { log_err "-o 需要指定路径"; exit 1; }
      OUT_FILE="$2"; shift 2 ;;
    --remove) REMOVE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "未知参数: $1"; usage; exit 1 ;;
  esac
done

# 精准清理旧端口的 iptables connlimit 规则
cleanup_old_iptables() {
  command -v iptables >/dev/null 2>&1 || return 0
  old_port=""
  if [ -r /etc/sing-box/config.json ]; then
    old_port=$(awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}' /etc/sing-box/config.json 2>/dev/null || true)
  fi
  if [ -n "${old_port:-}" ]; then
    iptables -S INPUT 2>/dev/null | grep -- "--dport ${old_port} " | grep 'connlimit' | while IFS= read -r rule; do
      del_rule="${rule#-A }"
      # shellcheck disable=SC2086
      iptables -D $del_rule >/dev/null 2>&1 || true
    done
  fi
}

# 彻底清理旧配置、状态文件、残留进程与规则（不卸载软件包）
cleanup_old_state() {
  cleanup_old_iptables

  rc-service sing-box stop >/dev/null 2>&1 || true
  wait_cnt=0
  while [ "$wait_cnt" -lt 3 ]; do
    if ! pidof sing-box >/dev/null 2>&1 && ! pgrep -x sing-box >/dev/null 2>&1; then
      break
    fi
    sleep 1
    wait_cnt=$((wait_cnt + 1))
  done

  if [ -x /usr/local/bin/nokey ]; then
    /usr/local/bin/nokey --remove >/dev/null 2>&1 || true
  fi
  rm -rf /usr/local/bin/nokey /usr/local/etc/nokey
  rm -f /etc/sing-box/*.json /etc/conf.d/sing-box "$OUT_FILE"
  rm -rf /var/lib/sing-box/*
}

# 前置环境体检
preflight_check() {
  if [ "$(id -u)" -ne 0 ]; then
    log_err "请使用 root 权限运行此脚本。"
    exit 1
  fi

  if ! command -v apk >/dev/null 2>&1 || ! command -v rc-service >/dev/null 2>&1; then
    log_err "当前系统不是 Alpine Linux (OpenRC)，脚本不兼容。"
    exit 1
  fi

  avail_disk=$(df -m /etc 2>/dev/null | awk 'NR==2 {print $4}' || echo "100")
  case "$avail_disk" in
    ''|*[!0-9]*) avail_disk=100 ;;
  esac
  if [ "$avail_disk" -lt 30 ]; then
    log_err "根分区可用磁盘空间不足 (${avail_disk}MB < 30MB)，无法安全安装。"
    exit 1
  fi

  avail_mem=$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "128")
  case "$avail_mem" in
    ''|*[!0-9]*) avail_mem=128 ;;
  esac
  if [ "$avail_mem" -lt 64 ]; then
    log_warn "当前系统可用内存较低 (${avail_mem}MB)，已启用 GOMEMLIMIT=${MEM_LIMIT} 防 OOM。"
  fi
}

# 精准检查端口是否处于 LISTEN 状态 (状态码 0A)
is_port_in_use() {
  target_port="$1"
  hex_port=$(printf '%04X' "$target_port")
  for tbl in /proc/net/tcp /proc/net/tcp6; do
    if [ -r "$tbl" ]; then
      if awk -v hp="$hex_port" 'NR>1 && toupper($4)=="0A" {split($2, a, ":"); if (toupper(a[2]) == hp) {found=1; exit}} END {exit !found}' "$tbl"; then
        return 0
      fi
    fi
  done
  return 1
}

# 校验端口格式与范围
validate_port_format() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$p" -lt "$MIN_VALID_PORT" ] || [ "$p" -gt "$MAX_VALID_PORT" ]; then
    return 1
  fi
  return 0
}

# 在 30000-50000 之间生成随机空闲端口
pick_random_port() {
  span=$((RAND_PORT_MAX - RAND_PORT_MIN + 1))
  seed=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \t\r\n' || echo "$$")
  case "$seed" in
    ''|*[!0-9]*) seed="$$" ;;
  esac

  attempt=0
  while [ "$attempt" -lt 50 ]; do
    r=$(( (seed + attempt * 7919) % span ))
    cand=$((RAND_PORT_MIN + r))
    if ! is_port_in_use "$cand"; then
      echo "$cand"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  log_err "在 ${RAND_PORT_MIN}-${RAND_PORT_MAX} 范围内尝试 50 次均未找到空闲端口，请手动排查端口占用。"
  exit 1
}

# 校验 SNI 域名格式
validate_sni() {
  case "$1" in
    ''|*[!A-Za-z0-9.-]*|*..*|.*|*.)
      return 1 ;;
    *.*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

preflight_check

# 卸载模式
if [ "$REMOVE_MODE" -eq 1 ]; then
  cleanup_old_state
  rc-update del sing-box default >/dev/null 2>&1 || true
  echo "[✓] 已彻底清理 sing-box 配置、状态文件与防火墙规则。"
  exit 0
fi

# 交互模式输入
if [ "$INTERACTIVE" -eq 1 ] && [ "$SILENT" -eq 0 ]; then
  if [ -z "${PORT:-}" ]; then
    printf "监听端口 [%s-%s，留空自动在 %s-%s 随机]: " "$MIN_VALID_PORT" "$MAX_VALID_PORT" "$RAND_PORT_MIN" "$RAND_PORT_MAX"
    read -r in_port || true
    [ -n "${in_port:-}" ] && PORT="$in_port"
  fi

  printf "伪装 SNI [默认 %s]: " "$SNI"
  read -r in_sni || true
  [ -n "${in_sni:-}" ] && SNI="$in_sni"

  printf "单 IP 最大并发连接数 [默认 %s，0 为不设防火墙限制]: " "$MAX_CONN"
  read -r in_conn || true
  [ -n "${in_conn:-}" ] && MAX_CONN="$in_conn"
fi

# 校验 SNI
if ! validate_sni "$SNI"; then
  log_err "伪装 SNI 域名格式不合法: $SNI"
  exit 1
fi

# 先彻底清场（停旧服务、删旧配置与旧规则），再做端口检查，避免旧服务自身占用导致冲突
log_info "正在清理旧配置与残留状态..."
cleanup_old_state

# 端口校验与冲突处理
while :; do
  if [ -z "${PORT:-}" ]; then
    PORT=$(pick_random_port)
    log_info "已自动选择空闲随机端口: ${PORT}"
    break
  fi

  if ! validate_port_format "$PORT"; then
    log_warn "端口 [${PORT}] 无效，必须为 ${MIN_VALID_PORT}-${MAX_VALID_PORT} 之间的纯数字。"
    if [ "$SILENT" -eq 0 ] && [ -t 0 ]; then
      printf "请重新输入端口 [%s-%s，留空自动在 %s-%s 随机]: " "$MIN_VALID_PORT" "$MAX_VALID_PORT" "$RAND_PORT_MIN" "$RAND_PORT_MAX"
      read -r PORT || true
      continue
    else
      log_err "非交互/静默模式下端口无效，已终止。"
      exit 1
    fi
  fi

  if is_port_in_use "$PORT"; then
    log_warn "端口 [${PORT}] 已被其他进程占用！"
    if [ "$SILENT" -eq 0 ] && [ -t 0 ]; then
      printf "请重新输入其他可用端口 [%s-%s，留空自动在 %s-%s 随机]: " "$MIN_VALID_PORT" "$MAX_VALID_PORT" "$RAND_PORT_MIN" "$RAND_PORT_MAX"
      read -r PORT || true
      continue
    else
      log_err "非交互/静默模式下指定端口 [${PORT}] 已被占用，请更换端口后重试。"
      exit 1
    fi
  fi

  break
done

# 安装依赖（已安装则跳过）
if ! command -v sing-box >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log_info "正在安装 sing-box 与基础依赖..."
  apk update >/dev/null
  apk add --no-cache sing-box ca-certificates curl >/dev/null
fi

# 生成并校验密钥
UUID=$(sing-box generate uuid)
KEYPAIR_OUT=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR_OUT" | awk '/PrivateKey:/ {print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR_OUT" | awk '/PublicKey:/ {print $2}')
SHORT_ID=$(sing-box generate rand --hex 8)

if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ]; then
  log_err "sing-box 密钥生成异常，请检查 sing-box 版本或运行环境。"
  exit 1
fi

# 探测公网 IP
IPV4=$(curl -fsSL4 --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null \
  || curl -fsSL4 --connect-timeout 2 --max-time 3 https://ifconfig.me/ip 2>/dev/null \
  || true)
IPV6=$(curl -fsSL6 --connect-timeout 2 --max-time 3 https://api64.ipify.org 2>/dev/null \
  || true)

if [ -n "${HOST_IP_OVERRIDE:-}" ]; then
  RAW_IP="$HOST_IP_OVERRIDE"
  case "$RAW_IP" in
    *:*) HOST_IP="[$RAW_IP]" ;;
    *)   HOST_IP="$RAW_IP" ;;
  esac
elif [ -n "${IPV4:-}" ]; then
  RAW_IP="$IPV4"
  HOST_IP="$IPV4"
elif [ -n "${IPV6:-}" ]; then
  RAW_IP="$IPV6"
  HOST_IP="[$IPV6]"
else
  RAW_IP="127.0.0.1"
  HOST_IP="127.0.0.1"
  log_warn "未能自动探测到公网 IP，输出配置中暂用 127.0.0.1，请手动替换。"
fi

# 兼容判断监听地址：开启 bindv6only=1 或无 IPv6 时切为 0.0.0.0
LISTEN_ADDR="::"
if [ ! -r /proc/net/if_inet6 ]; then
  LISTEN_ADDR="0.0.0.0"
elif [ -r /proc/sys/net/ipv6/bindv6only ] && [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" = "1" ]; then
  LISTEN_ADDR="0.0.0.0"
fi

NODE_NAME="Reality-${RAW_IP}-${PORT}"
VLESS_LINK="vless://${UUID}@${HOST_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"

mkdir -p /etc/sing-box /var/lib/sing-box
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
      "listen": "${LISTEN_ADDR}",
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
chmod 600 /etc/sing-box/config.json

cat << EOF > /etc/conf.d/sing-box
export GOMEMLIMIT=${MEM_LIMIT}
export GOGC=50
EOF

sing-box check -c /etc/sing-box/config.json >/dev/null
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box start >/dev/null 2>&1 || true

# 启动后轮询校验（最多 5 秒）：进程存活 + 端口真正进入 LISTEN 状态
started=0
retry=0
while [ "$retry" -lt 5 ]; do
  if (pidof sing-box >/dev/null 2>&1 || pgrep -x sing-box >/dev/null 2>&1) && is_port_in_use "$PORT"; then
    started=1
    break
  fi
  sleep 1
  retry=$((retry + 1))
done

if [ "$started" -ne 1 ]; then
  log_err "sing-box 启动失败或端口 ${PORT} 未进入 LISTEN 状态，请检查配置与内存。"
  exit 1
fi

# 可选：单 IP 并发限制
case "$MAX_CONN" in
  ''|*[!0-9]*) MAX_CONN=0 ;;
esac

if [ "$MAX_CONN" -gt 0 ] && command -v iptables >/dev/null 2>&1; then
  if ! iptables -C INPUT -p tcp --syn --dport "$PORT" -m connlimit --connlimit-above "$MAX_CONN" --connlimit-mask 32 -j DROP >/dev/null 2>&1; then
    iptables -A INPUT -p tcp --syn --dport "$PORT" -m connlimit --connlimit-above "$MAX_CONN" --connlimit-mask 32 -j DROP >/dev/null 2>&1 || true
  fi
fi

# 检测本机防火墙拦截策略
FW_NOTE=""
if command -v iptables >/dev/null 2>&1; then
  if iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
    FW_NOTE="  [!] 检测到本机 iptables INPUT 默认拦截，请放行 TCP ${PORT} 端口。"
  fi
fi

{
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [✓] sing-box VLESS-Reality 节点部署成功"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "▸ 节点基础参数"
  echo "  节点名称  : ${NODE_NAME}"
  echo "  IPv4 地址 : ${IPV4:-无}"
  echo "  IPv6 地址 : ${IPV6:-无}"
  echo "  监听地址  : ${LISTEN_ADDR}:${PORT}"
  echo "  伪装 SNI  : ${SNI}"
  echo "  内存上限  : ${MEM_LIMIT}"
  echo "  用户 UUID : ${UUID}"
  echo "  PublicKey : ${PUBLIC_KEY}"
  echo "  ShortId   : ${SHORT_ID}"
  echo ""
  echo "──────────────────────────────────────────────────"
  echo "▸ VLESS 分享链接（可直接复制导入）"
  echo "  ${VLESS_LINK}"
  echo ""
  echo "──────────────────────────────────────────────────"
  echo "▸ Clash / Mihomo 节点配置"
  echo "proxies:"
  echo "  - name: \"${NODE_NAME}\""
  echo "    type: vless"
  echo "    server: ${RAW_IP}"
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
  echo ""
  echo "──────────────────────────────────────────────────"
  echo "▸ 维护提示"
  echo "  • 结果已保存至 ${OUT_FILE}，随时可用 cat ${OUT_FILE} 查看。"
  echo "  • 服务端已启用 multiplex，建议客户端开启 smux 降低并发数。"
  [ -n "$FW_NOTE" ] && echo "$FW_NOTE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"
cat "$OUT_FILE"
