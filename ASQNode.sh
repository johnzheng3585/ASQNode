#!/usr/bin/env bash
set -euo pipefail

# 默认参数
DEVICE="/dev/sdb"
MOUNT_POINT="/mnt/data"
SKIP_DOCKER=false
USE_IPV6=false
DOCKER_ONLY=false
DOCKER_ALIYUN_ONLY=false
ENABLE_MOUNT=true
MOUNT_ONLY=false
ALLOW_FORMAT=true
RUN_UID=""
RUN_CH=""
RUN_TYPE="asqdnode"

usage() {
  echo "用法: $0 [--device 设备路径] [--mountpoint 挂载目录] [--mount-only] [--skip-mount] [--skip-docker] [--docker-only] [--format|--no-format] [--ipv6] [--uid 值] [--ch 值] [--type 值]" 1>&2
  echo "参数说明:" 1>&2
  echo "  --device         指定要挂载的设备路径（默认: /dev/sdb）" 1>&2
  echo "  --mountpoint     指定挂载目录（默认: /mnt/data）" 1>&2
  echo "  --mount-only     仅执行磁盘挂载动作，完成后退出" 1>&2
  echo "  --skip-mount     跳过磁盘挂载流程（跳过后 ttrun.sh 不追加 -c 参数）" 1>&2
  echo "  --skip-docker    跳过 Docker 安装和配置，仅执行磁盘挂载和 ttmanager 部署" 1>&2
  echo "  --docker-only    仅安装和配置 Docker" 1>&2
  echo "  --format         允许脚本在需要时格式化磁盘（默认）" 1>&2
  echo "  --no-format      禁止格式化磁盘" 1>&2
  echo "  --ipv6           使用 IPv6 进行网络下载" 1>&2
  echo "  --uid/-uid       传递给 ttrun.sh 的 uid 参数值" 1>&2
  echo "  --ch/-ch         传递给 ttrun.sh 的 ch 参数值" 1>&2
  echo "  --type/-t        传递给 ttrun.sh 的业务类型参数（默认: asqdnode）" 1>&2
}

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "缺少 --device 的值" 1>&2; usage; exit 2; }
      DEVICE="$2"; shift 2;;
    --mountpoint)
      [[ $# -ge 2 ]] || { echo "缺少 --mountpoint 的值" 1>&2; usage; exit 2; }
      MOUNT_POINT="$2"; shift 2;;
    --mount-only|--only-mount)
      MOUNT_ONLY=true; ENABLE_MOUNT=true; shift;;
    --skip-mount|--no-mount)
      ENABLE_MOUNT=false; shift;;
    --skip-docker)
      SKIP_DOCKER=true; shift;;
    --docker-only)
      DOCKER_ONLY=true; DOCKER_ALIYUN_ONLY=true; shift;;
    --format)
      ALLOW_FORMAT=true; shift;;
    --no-format|--skip-format)
      ALLOW_FORMAT=false; shift;;
    --uid|--uid\b|-uid)
      [[ $# -ge 2 ]] || { echo "缺少 --uid 的值" 1>&2; usage; exit 2; }
      RUN_UID="$2"; shift 2;;
    --ch|-ch)
      [[ $# -ge 2 ]] || { echo "缺少 --ch 的值" 1>&2; usage; exit 2; }
      RUN_CH="$2"; shift 2;;
    --type/-t)
      [[ $# -ge 2 ]] || { echo "缺少 --type 的值" 1>&2; usage; exit 2; }
      RUN_TYPE="$2"; shift 2;;
    --ipv6)
      USE_IPV6=true; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "未知参数: $1" 1>&2; usage; exit 2;;
  esac
done

if $DOCKER_ONLY && $SKIP_DOCKER; then echo "[ERROR] --docker-only 与 --skip-docker 不能同时使用" 1>&2; exit 2; fi
if $DOCKER_ONLY && $MOUNT_ONLY; then echo "[ERROR] --docker-only 与 --mount-only 不能同时使用" 1>&2; exit 2; fi
if $MOUNT_ONLY && ! $ENABLE_MOUNT; then echo "[ERROR] --mount-only 与 --skip-mount 不能同时使用" 1>&2; exit 2; fi

# 设置 IP 协议标志
if $USE_IPV6; then
  CURL_IP_FLAG="-6"; WGET_IP_FLAG="-6"
  echo "[INFO] 网络模式: IPv6"
else
  CURL_IP_FLAG="-4"; WGET_IP_FLAG="-4"
  echo "[INFO] 网络模式: IPv4"
fi

# 必须 root 权限
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行此脚本" 1>&2
  exit 1
fi

# 优化基础网络请求解析优先 IPv4
ensure_ipv4_default() {
  if [[ -f /etc/gai.conf ]]; then
    if ! grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
      echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
    fi
  fi
  mkdir -p /etc && echo 'ipv4' > /etc/curlrc
  echo 'prefer-family = IPv4' > /etc/wgetrc
}
ensure_ipv4_default

# 确保 DNS 正常
ensure_dns() {
  local test_host="mirrors.aliyun.com"
  if ! getent hosts "$test_host" >/dev/null 2>&1; then
    printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n" > /etc/resolv.conf || true
  fi
}
ensure_dns

detect_data_device() {
  local root_source root_disk
  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_disk=""
  if [[ -n "$root_source" && -b "$root_source" ]]; then
    root_disk="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
  fi

  local dev
  for dev in /dev/vdb /dev/xvdb /dev/sdb /dev/nvme1n1; do
    if [[ -b "$dev" ]]; then
      if [[ -n "$root_disk" && "$(basename "$dev")" == "$root_disk" ]]; then continue; fi
      echo "$dev"; return 0
    fi
  done
  return 1
}

# ==================== 磁盘挂载流程 (针对 Debian 12 适配) ====================
if ! $DOCKER_ONLY && $ENABLE_MOUNT; then
  command -v lsblk >/dev/null 2>&1 || { apt-get update && apt-get install -y util-linux; }
  command -v blkid >/dev/null 2>&1 || { apt-get update && apt-get install -y e2fsprogs; }

  if [[ ! -b "$DEVICE" ]]; then
    AUTO_DEVICE="$(detect_data_device || true)"
    if [[ -n "$AUTO_DEVICE" && -b "$AUTO_DEVICE" ]]; then DEVICE="$AUTO_DEVICE"; fi
  fi

  if [[ -b "$DEVICE" ]]; then
    # 检查并清理 LVM
    if lsblk -ln -o NAME,TYPE "$DEVICE" 2>/dev/null | awk '$2=="lvm"{found=1} END {exit found ? 0 : 1}'; then
      if $ALLOW_FORMAT; then
        apt-get update && apt-get install -y lvm2 || true
        local lvm_volumes=$(lsblk -ln -o NAME,TYPE "$DEVICE" 2>/dev/null | awk '$2=="lvm"{print $1}' || true)
        while IFS= read -r lv_name; do
          if [[ -n "$lv_name" ]]; then umount -f "/dev/mapper/${lv_name}" 2>/dev/null || true; fi
        done <<< "$lvm_volumes"
        wipefs -a "$DEVICE" 2>/dev/null || dd if=/dev/zero of="$DEVICE" bs=1M count=50 2>/dev/null || true
      fi
    fi

    TARGET_BLOCK="$DEVICE"
    child_parts=$(lsblk -ln -o NAME,TYPE "$DEVICE" | awk '$2=="part"{print $1}') || true
    if [[ -n "${child_parts}" ]]; then
      largest_part=$(lsblk -ln -o NAME,SIZE,TYPE | awk -v rootdev="$(basename "$DEVICE")" '$3=="part" && index($1,rootdev)==1{print $0}' | sort -k2 -h | tail -n1 | awk '{print $1}') || true
      if [[ -n "${largest_part:-}" ]]; then TARGET_BLOCK="/dev/${largest_part}"; fi
    fi

    if ! findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
      FSTYPE=$(lsblk -no FSTYPE "$TARGET_BLOCK" | head -n1 || true)
      if [[ -z "${FSTYPE:-}" ] && $ALLOW_FORMAT; then
        mkfs.ext4 -F "$TARGET_BLOCK"
        FSTYPE="ext4"
      fi

      if [[ -n "${FSTYPE:-}" ]]; then
        mkdir -p "$MOUNT_POINT"
        UUID=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
        if [[ -n "$UUID" ]]; then
          cp /etc/fstab /etc/fstab.bak
          tmpfstab=$(mktemp)
          grep -Ev "(^UUID=${UUID}[[:space:]]|^[^#].*[[:space:]]$MOUNT_POINT[[:space:]])" /etc/fstab > "$tmpfstab" || true
          printf "UUID=%s %s %s defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" "$FSTYPE" >> "$tmpfstab"
          mv "$tmpfstab" /etc/fstab
          mount -a || true
          echo "[OK] 磁盘挂载成功: $MOUNT_POINT"
        fi
      fi
    fi
  fi
fi

if $MOUNT_ONLY; then echo "[INFO] 仅挂载模式完成"; exit 0; fi

# ==================== Debian 12 Docker CE 安装 ====================
if $SKIP_DOCKER; then
  echo "[INFO] 跳过 Docker 安装"
else
  if ! command -v docker >/dev/null 2>&1; then
    echo "[INFO] 正在为 Debian 12 安装官方 Docker CE 环境..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 写入特定 cgroup 驱动配置
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON
    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker
    echo "[OK] Docker 部署成功"
  fi
fi

if $DOCKER_ONLY; then echo "[INFO] Docker 安装完毕"; exit 0; fi

# ==================== 统一业务部署阶段 ====================
echo "[INFO] 开始拉取业务组件并后台运行..."
cd /root

if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 $WGET_IP_FLAG -O ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  wget --tries=2 --timeout=8 $WGET_IP_FLAG -O ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
else
  curl $CURL_IP_FLAG --retry 2 -fsSL -o ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
fi
chmod +x ttmanager || true

curl $CURL_IP_FLAG --retry 2 -fsSL -o config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || true
./ttmanager -g || true

# 精确动态构筑启动参数
TT_RUN_ARGS=()
[[ -n "${RUN_CH:-}" ]] && TT_RUN_ARGS+=(-ch "$RUN_CH")
[[ -n "${RUN_TYPE:-}" ]] && TT_RUN_ARGS+=(-t "$RUN_TYPE")
$ENABLE_MOUNT && TT_RUN_ARGS+=(-c "$MOUNT_POINT")
[[ -n "${RUN_UID:-}" ]] && TT_RUN_ARGS+=(-uid "$RUN_UID")

echo "[INFO] 后台运行命令: ./ttrun.sh ${TT_RUN_ARGS[*]}"
nohup ./ttrun.sh "${TT_RUN_ARGS[@]}" >/dev/null 2>&1 &

# 构建持久化开机自启字符串
TT_RUN_CMD="./ttrun.sh"
[[ -n "${RUN_CH:-}" ]] && TT_RUN_CMD+=" -ch $(printf '%q' "$RUN_CH")"
[[ -n "${RUN_TYPE:-}" ]] && TT_RUN_CMD+=" -t $(printf '%q' "$RUN_TYPE")"
$ENABLE_MOUNT && TT_RUN_CMD+=" -c $(printf '%q' "$MOUNT_POINT")"
[[ -n "${RUN_UID:-}" ]] && TT_RUN_CMD+=" -uid $(printf '%q' "$RUN_UID")"
TT_RUN_REMOVE_REGEX='ttrun\.sh.*-t[[:space:]]+[^[:space:]]+'

# 第一重：写入 crontab 定时开机自启任务
if command -v crontab >/dev/null 2>&1 || apt-get install -y cron; then
  systemctl enable cron || true; systemctl start cron || true
  CRON_LINE="@reboot cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &"
  tmp_cron="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -Ev "$TT_RUN_REMOVE_REGEX" > "$tmp_cron" || true
  echo "$CRON_LINE" >> "$tmp_cron"
  crontab "$tmp_cron"; rm -f "$tmp_cron"
fi

# 第二重：兼容补充传统的 rc.local 运行方式
RC_LOCAL="/etc/rc.local"
if [[ ! -f "$RC_LOCAL" ]]; then
  echo '#!/bin/sh -e' > "$RC_LOCAL"
  echo 'exit 0' >> "$RC_LOCAL"
fi
tmp_rc_local="$(mktemp)"
grep -Ev "exit 0|$TT_RUN_REMOVE_REGEX" "$RC_LOCAL" > "$tmp_rc_local" || true
echo "cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &" >> "$tmp_rc_local"
echo "exit 0" >> "$tmp_rc_local"
mv "$tmp_rc_local" "$RC_LOCAL"; chmod +x "$RC_LOCAL"

if [[ -f /lib/systemd/system/rc-local.service ]]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable rc-local >/dev/null 2>&1 || true
  systemctl start rc-local >/dev/null 2>&1 || true
fi

echo "[OK] Debian 12 节点统一部署顺利完成！"
