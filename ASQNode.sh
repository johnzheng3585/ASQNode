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
  echo "示例: $0 --device /dev/vdb --mountpoint /mnt/data" 1>&2
  echo "" 1>&2
  echo "参数说明:" 1>&2
  echo "  --device         指定要挂载的设备路径（默认: /dev/sdb）" 1>&2
  echo "  --mountpoint     指定挂载目录（默认: /mnt/data）" 1>&2
  echo "  --mount-only     仅执行磁盘挂载动作，完成后退出，不安装 Docker、不部署 ttmanager" 1>&2
  echo "  --skip-mount     跳过磁盘挂载流程（跳过后 ttrun.sh 不追加 -c 参数）" 1>&2
  echo "  --skip-docker    跳过 Docker 安装和配置，仅执行磁盘挂载和 ttmanager 部署" 1>&2
  echo "  --docker-only    仅安装和配置 Docker（使用阿里源），跳过磁盘挂载和 ttmanager 部署" 1>&2
  echo "  --format         允许脚本在需要时格式化磁盘（默认）" 1>&2
  echo "  --no-format      禁止格式化磁盘；无文件系统或挂载失败时直接退出" 1>&2
  echo "  --ipv6           使用 IPv6 进行网络下载（默认使用 IPv4）" 1>&2
  echo "  --uid/-uid       传递给 ttrun.sh 的 uid 参数值" 1>&2
  echo "  --ch/-ch         传递给 ttrun.sh 的 ch 参数值" 1>&2
  echo "  --type/-t        传递给 ttrun.sh 的业务类型参数（默认: asqdnode）" 1>&2
}

# 【彻底修复位置】去除了原脚本中 case 匹配里的空格错位
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "缺少 --device 的值" 1>&2; usage; exit 2; }
      DEVICE="$2"; shift 2;;
    --mountpoint)
      [[ $# -ge 2 ]] || { echo "缺少 --mountpoint 的值" 1>&2; usage; exit 2; }
      MOUNT_POINT="$2"; shift 2;;
    --mount-only|--only-mount)
      MOUNT_ONLY=true
      ENABLE_MOUNT=true
      shift;;
    --skip-mount|--no-mount)
      ENABLE_MOUNT=false; shift;;
    --skip-docker)
      SKIP_DOCKER=true; shift;;
    --docker-only)
      DOCKER_ONLY=true
      DOCKER_ALIYUN_ONLY=true
      shift;;
    --format)
      ALLOW_FORMAT=true; shift;;
    --no-format|--skip-format)
      ALLOW_FORMAT=false; shift;;
    --uid|-uid)
      [[ $# -ge 2 ]] || { echo "缺少 --uid 的值" 1>&2; usage; exit 2; }
      RUN_UID="$2"; shift 2;;
    --ch|-ch)
      [[ $# -ge 2 ]] || { echo "缺少 --ch 的值" 1>&2; usage; exit 2; }
      RUN_CH="$2"; shift 2;;
    --type|-t)
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

if $DOCKER_ONLY && $SKIP_DOCKER; then
  echo "[ERROR] --docker-only 与 --skip-docker 不能同时使用" 1>&2
  usage; exit 2
fi

if $DOCKER_ONLY && $MOUNT_ONLY; then
  echo "[ERROR] --docker-only 与 --mount-only 不能同时使用" 1>&2
  usage; exit 2
fi

if $MOUNT_ONLY && ! $ENABLE_MOUNT; then
  echo "[ERROR] --mount-only 与 --skip-mount 不能同时使用" 1>&2
  usage; exit 2
fi

# 设置 IP 协议标志
if $USE_IPV6; then
  CURL_IP_FLAG="-6"
  WGET_IP_FLAG="-6"
  echo "[INFO] 网络模式: IPv6"
else
  CURL_IP_FLAG="-4"
  WGET_IP_FLAG="-4"
  echo "[INFO] 网络模式: IPv4"
fi

echo "[INFO] 设备: $DEVICE"
echo "[INFO] 挂载点: $MOUNT_POINT"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行此脚本" 1>&2
  exit 1
fi

# 全局优先使用 IPv4（适配 Debian 12）
ensure_ipv4_default() {
  if [[ -f /etc/gai.conf ]]; then
    if ! grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
      if grep -Eq '^[#;][[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
        sed -i -E 's/^[#;][[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf || true
      else
        echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
      fi
    fi
  else
    echo 'precedence ::ffff:0:0/96  100' > /etc/gai.conf || true
  fi

  if [[ -f /etc/curlrc ]]; then
    grep -q '^ipv4\b' /etc/curlrc || echo 'ipv4' >> /etc/curlrc
  else
    echo 'ipv4' > /etc/curlrc
  fi

  if [[ -f /etc/wgetrc ]]; then
    if grep -Eq '^#?\s*prefer-family' /etc/wgetrc; then
      sed -i -E 's/^#?\s*prefer-family.*/prefer-family = IPv4/' /etc/wgetrc || true
    else
      echo 'prefer-family = IPv4' >> /etc/wgetrc
    fi
  else
    echo 'prefer-family = IPv4' > /etc/wgetrc
  fi
}

if ! $MOUNT_ONLY; then
  ensure_ipv4_default
fi

# 确保 DNS 正常
ensure_dns() {
  local test_host="mirrors.aliyun.com"
  if ! getent hosts "$test_host" >/dev/null 2>&1; then
    echo "[WARN] DNS 解析失败，写入公共 DNS"
    printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf || true
    grep -q '^nameserver 8.8.8.8' /etc/resolv.conf || echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
  fi
}
ensure_dns

detect_data_device() {
  local root_source root_disk root_pkname root_type
  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_disk=""
  if [[ -n "$root_source" && -b "$root_source" ]]; then
    root_pkname="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
    if [[ -n "$root_pkname" ]]; then
      root_disk="$root_pkname"
    else
      root_type="$(lsblk -no TYPE "$root_source" 2>/dev/null | head -n1 || true)"
      if [[ "$root_type" == "disk" ]]; then
        root_disk="$(basename "$root_source")"
      fi
    fi
  fi

  local dev base
  for dev in /dev/vdb /dev/xvdb /dev/sdb /dev/nvme1n1; do
    if [[ -b "$dev" ]]; then
      base="$(basename "$dev")"
      if [[ -n "$root_disk" && "$base" == "$root_disk" ]]; then
        continue
      fi
      echo "$dev"
      return 0
    fi
  done

  local best_dev="" best_size=0 name size type
  while read -r name size type; do
    [[ "$type" == "disk" ]] || continue
    [[ -n "$name" ]] || continue
    if [[ -n "$root_disk" && "$name" == "$root_disk" ]]; then
      continue
    fi
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > best_size )); then
      best_size="$size"
      best_dev="/dev/$name"
    fi
  done < <(lsblk -b -dn -o NAME,SIZE,TYPE 2>/dev/null || true)

  if [[ -n "$best_dev" ]]; then
    echo "$best_dev"
    return 0
  fi
  return 1
}

# ==================== 磁盘处理逻辑 ====================
if ! $DOCKER_ONLY && $ENABLE_MOUNT; then
  # 统一适配为 Debian 的 apt 安装组件
  command -v lsblk >/dev/null 2>&1 || { apt-get update && apt-get install -y util-linux; }
  command -v blkid >/dev/null 2>&1 || { apt-get update && apt-get install -y e2fsprogs; }

  if [[ ! -b "$DEVICE" ]]; then
    echo "[WARN] 指定设备不存在或不是块设备: $DEVICE"
    AUTO_DEVICE="$(detect_data_device || true)"
