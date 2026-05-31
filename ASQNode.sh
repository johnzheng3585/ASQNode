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
  echo "      $0 --mount-only --device /dev/vdb --no-format  # 仅挂载，不安装/不部署，且禁止格式化" 1>&2
  echo "      $0 --skip-mount --uid 111         # 跳过挂载，仅启动 ttrun 并传 -uid 111" 1>&2
  echo "      $0 --ch 251202                    # 启动 ttrun 时追加 -ch 251202（默认不传 -ch）" 1>&2
  echo "      $0 -t bynode                      # 启动 ttrun 时传 -t bynode（默认 asqdnode）" 1>&2
  echo "      $0 --device /dev/vdb --skip-docker  # 跳过 Docker 安装，仅挂载磁盘和部署 ttmanager" 1>&2
  echo "      $0 --docker-only                     # 仅安装/配置 Docker（使用阿里源）" 1>&2
  echo "      $0 --ipv6                           # 使用 IPv6 下载" 1>&2
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
  echo "[ERROR] --docker-only 与 --skip-docker 不能同时使用" 1>&2; usage; exit 2
fi

if $DOCKER_ONLY && $MOUNT_ONLY; then
  echo "[ERROR] --docker-only 与 --mount-only 不能同时使用" 1>&2; usage; exit 2
fi

if $MOUNT_ONLY && ! $ENABLE_MOUNT; then
  echo "[ERROR] --mount-only 与 --skip-mount 不能同时使用" 1>&2; usage; exit 2
fi

# 设置 IP 协议标志（用于 curl/wget）
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

# 需要 root 权限
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行此脚本" 1>&2
  exit 1
fi

# 全局优先使用 IPv4
ensure_ipv4_default() {
  if [[ -f /etc/gai.conf ]]; then
    if ! grep -Eq '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf; then
      echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
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

  # APT 强制 IPv4
  if command -v apt-get >/dev/null 2>&1; then
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
  fi
}

if ! $MOUNT_ONLY; then
  ensure_ipv4_default
fi

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
      if [[ -n "$root_disk" && "$base" == "$root_disk" ]]; then continue; fi
      echo "$dev"
      return 0
    fi
  done

  local best_dev="" best_size=0 name size type
  while read -r name size type; do
    [[ "$type" == "disk" ]] || continue
    [[ -n "$name" ]] || continue
    if [[ -n "$root_disk" && "$name" == "$root_disk" ]]; then continue; fi
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > best_size )); then
      best_size="$size"
      best_dev="/dev/$name"
    fi
  done < <(lsblk -b -dn -o NAME,SIZE,TYPE 2>/dev/null || true)

  if [[ -n "$best_dev" ]]; then echo "$best_dev"; return 0; fi
  return 1
}

if ! $DOCKER_ONLY && $ENABLE_MOUNT; then

# 基本检查
command -v lsblk >/dev/null 2>&1 || { echo "[ERROR] 缺少 lsblk 命令" 1>&2; exit 1; }
command -v blkid >/dev/null 2>&1 || { echo "[ERROR] 缺少 blkid 命令" 1>&2; exit 1; }

if [[ ! -b "$DEVICE" ]]; then
  echo "[WARN] 指定设备不存在或不是块设备: $DEVICE"
  AUTO_DEVICE="$(detect_data_device || true)"
  if [[ -n "$AUTO_DEVICE" && -b "$AUTO_DEVICE" ]]; then
    DEVICE="$AUTO_DEVICE"
    echo "[INFO] 自动识别到数据盘设备: $DEVICE"
  else
    echo "[ERROR] 未找到可用数据盘，请通过 --device 指定" 1>&2; exit 1
  fi
fi

# 检测并清理 LVM 结构
cleanup_lvm_on_device() {
  local dev="$1"
  local lvm_volumes=$(lsblk -ln -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="lvm"{print $1}' || true)
  if [[ -z "$lvm_volumes" ]]; then return 1; fi

  echo "[WARN] 检测到 LVM 结构，开始清理..."
  command -v vgs >/dev/null 2>&1 || { 
    echo "[ERROR] 缺少 LVM 工具，尝试安装 lvm2..." 1>&2
    if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y lvm2; else exit 1; fi
  }
  
  while IFS= read -r lv_name; do
    if [[ -n "$lv_name" ]]; then
      local lv_dev="/dev/mapper/${lv_name}"
      if findmnt "$lv_dev" >/dev/null 2>&1; then umount -f "$lv_dev" 2>/dev/null || true; fi
    fi
  done <<< "$lvm_volumes"
  
  local vg_list=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | sort -u | tr -d ' ' || true)
  if [[ -n "$vg_list" ]]; then
    while IFS= read -r vg_name; do
      if [[ -n "$vg_name" && "$vg_name" != "" ]]; then
        local lv_paths=$(lvs --noheadings -o lv_path "$vg_name" 2>/dev/null || true)
        while IFS= read -r lv_path; do
          if [[ -n "$lv_path" ]]; then lvremove -f "$(echo "$lv_path" | tr -d ' ')" 2>/dev/null || true; fi
        done <<< "$lv_paths"
        vgremove -f "$vg_name" 2>/dev/null || true
      fi
    done <<< "$vg_list"
  fi
  
  if pvs "$dev" >/dev/null 2>&1; then pvremove -f "$dev" 2>/dev/null || true; fi
  wipefs -a "$dev" 2>/dev/null || dd if=/dev/zero of="$dev" bs=1M count=100 2>/dev/null || true
  partprobe "$dev" 2>/dev/null || true; sleep 2
}

is_mountable_fstype() {
  local fstype="${1:-}"
  case "$fstype" in ""|LVM2_member|linux_raid_member|crypto_LUKS|swap) return 1 ;; *) return 0 ;; esac
}

detect_block_fstype() {
  local block="$1" mount_point="${2:-}" fstype=""
  fstype=$(lsblk -no FSTYPE "$block" | head -n1 || true)
  if [[ -z "${fstype:-}" ]]; then fstype=$(blkid -s TYPE -o value "$block" 2>/dev/null || true); fi
  if [[ -z "${fstype:-}" && -n "${mount_point:-}" ]]; then fstype=$(findmnt -rn -o FSTYPE --target "$mount_point" 2>/dev/null || true); fi
  echo "$fstype"
}

ensure_fstab_entry_if_missing() {
  local target_block="$1" mount_point="$2" uuid="$3" fstype="$4" timestamp tmpfstab
  if [[ -z "${uuid:-}" ]]; then echo "[ERROR] 无法获取 UUID" 1>&2; exit 1; fi
  if grep -Eq "^UUID=${uuid}[[:space:]]+${mount_point}[[:space:]]+" /etc/fstab || grep -Eq "^[[:space:]]*${target_block//\//\\/}[[:space:]]+${mount_point}[[:space:]]+" /etc/fstab; then return 0; fi
  timestamp=$(date +%Y%m%d%H%M%S)
  cp /etc/fstab "/etc/fstab.bak.$timestamp"
  tmpfstab=$(mktemp)
  grep -Ev "(^UUID=${uuid}[[:space:]]|^[^#].*[[:space:]]$mount_point[[:space:]]|^[[:space:]]*${target_block//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
  printf "UUID=%s %s %s defaults,noatime 0 2\n" "$uuid" "$mount_point" "${fstype:-ext4}" >> "$tmpfstab"
  mv "$tmpfstab" /etc/fstab
}

if lsblk -ln -o NAME,TYPE "$DEVICE" 2>/dev/null | awk '$2=="lvm"{found=1} END {exit found ? 0 : 1}'; then
  if ! $ALLOW_FORMAT; then exit 1; fi
  cleanup_lvm_on_device "$DEVICE"
fi

TARGET_BLOCK="$DEVICE"
child_parts=$(lsblk -ln -o NAME,TYPE "$DEVICE" | awk '$2=="part"{print $1}') || true
if [[ -n "${child_parts}" ]]; then
  largest_part=$(lsblk -ln -o NAME,SIZE,TYPE | awk -v rootdev="$(basename "$DEVICE")" '$3=="part" && index($1,rootdev)==1{print $0}' | sort -k2 -h | tail -n1 | awk '{print $1}') || true
  if [[ -n "${largest_part:-}" ]]; then TARGET_BLOCK="/dev/${largest_part}"; fi
fi

SKIP_MOUNT=false
if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  src=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
  if [[ -n "${src:-}" ]]; then
    tgt_uuid=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
    if [[ "$src" == "$TARGET_BLOCK" ]] || [[ -n "${tgt_uuid:-}" && "$src" == *"UUID=$tgt_uuid"* ]]; then
      SKIP_MOUNT=true
    else
      echo "[ERROR] 挂载点已被占用" 1>&2; exit 1
    fi
  fi
fi

if $SKIP_MOUNT; then
  FSTYPE=$(detect_block_fstype "$TARGET_BLOCK" "$MOUNT_POINT")
  UUID=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
  ensure_fstab_entry_if_missing "$TARGET_BLOCK" "$MOUNT_POINT" "$UUID" "$FSTYPE"
fi

if ! $SKIP_MOUNT; then
  FSTYPE=$(lsblk -no FSTYPE "$TARGET_BLOCK" | head -n1 || true)
  if [[ -z "${FSTYPE:-}" ]] || ! is_mountable_fstype "$FSTYPE"; then
    if ! $ALLOW_FORMAT; then echo "[ERROR] 需格式化但 --no-format 启用" 1>&2; exit 1; fi
    command -v mkfs.ext4 >/dev/null 2>&1 || { apt-get update && apt-get install -y e2fsprogs; }
    mkfs.ext4 -F "$TARGET_BLOCK"
    FSTYPE="ext4"
  fi

  mkdir -p "$MOUNT_POINT"
  UUID=$(blkid -s UUID -o value "$TARGET_BLOCK")
  timestamp=$(date +%Y%m%d%H%M%S)
  cp /etc/fstab "/etc/fstab.bak.$timestamp"
  tmpfstab=$(mktemp)
  grep -Ev "(^UUID=${UUID}[[:space:]]|^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
  if ! grep -q "^UUID=${UUID}[[:space:]]\+${MOUNT_POINT}[[:space:]]" "$tmpfstab"; then
    printf "UUID=%s %s %s defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" "${FSTYPE:-ext4}" >> "$tmpfstab"
  fi
  mv "$tmpfstab" /etc/fstab
  mount -a || true
  
  src_after=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
  if [[ -n "${src_after:-}" ]]; then
    echo "[OK] 挂载成功"
  else
    if ! $ALLOW_FORMAT; then exit 1; fi
    umount -f "$MOUNT_POINT" >/dev/null 2>&1 || true
    mkfs.ext4 -F "$TARGET_BLOCK"
    UUID=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
    tmpfstab=$(mktemp)
    grep -Ev "(^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
    printf "UUID=%s %s ext4 defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" >> "$tmpfstab"
    mv "$tmpfstab" /etc/fstab
    mount -a || true
  fi
fi

fi

if $MOUNT_ONLY; then
  echo "[INFO] 已完成仅挂载模式"
  exit 0
fi

# ================= Debian 12 软件源与 Docker 安装逻辑 =================

is_debian12=false
if [[ -f /etc/os-release ]]; then
  if grep -q 'ID=debian' /etc/os-release && grep -q 'VERSION_ID="12"' /etc/os-release; then
    is_debian12=true
  fi
fi

if $is_debian12; then
  if $SKIP_DOCKER; then
    echo "[INFO] 检测到 Debian 12，已设置 --skip-docker，跳过 Docker 安装"
  else
    echo "[INFO] 检测到 Debian 12，开始配置阿里云 APT 源并安装 Docker"

    # 配置阿里云 Debian 12 镜像源
    echo "[INFO] 写入 Debian 12 阿里云镜像源..."
    cp -a /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S) || true
    cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb-src https://mirrors.aliyun.com/debian-security/ bookworm-security main
deb https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-updates main non-free non-free-firmware contrib
deb https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
deb-src https://mirrors.aliyun.com/debian/ bookworm-backports main non-free non-free-firmware contrib
EOF
    
    apt-get update || true
    apt-get install -y ca-certificates curl gnupg lsb-release

    # 配置阿里云 Docker CE 源
    echo "[INFO] 配置阿里云 Docker CE 仓库..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL $CURL_IP_FLAG https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/debian \
      bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update || true

    # 如果没有 Docker，安装 Docker
    if ! command -v docker >/dev/null 2>&1; then
      echo "[INFO] 安装 Docker CE..."
      # 尝试寻找指定版本(26.1.3)，找不到则安装最新版
      if apt-cache madison docker-ce | grep -q "26.1.3"; then
        desired_ver=$(apt-cache madison docker-ce | grep "26.1.3" | awk '{print $3}' | head -n 1)
        apt-get install -y docker-ce=${desired_ver} docker-ce-cli=${desired_ver} containerd.io docker-buildx-plugin docker-compose-plugin || \
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      else
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
    else
      echo "[INFO] Docker 已安装，跳过安装"
    fi

    # 统一 cgroup 设置
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON
    systemctl enable docker || true
    systemctl daemon-reload || true
    systemctl restart docker || true

    # 检查 cgroup v2 降级 v1 (Debian 默认使用 cgroup v2)
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
      echo "[WARN] 检测到系统使用 cgroup v2，写入 GRUB 参数以切换到 v1（需重启生效）"
      if [[ -f /etc/default/grub ]]; then
        if ! grep -q 'systemd.unified_cgroup_hierarchy=0' /etc/default/grub; then
          sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub || true
          update-grub || true
          echo "[INFO] 已更新 GRUB (cgroup v1)，如果您的应用强依赖 v1 请重启服务器。"
        fi
      fi
    else
      echo "[INFO] 系统已使用 cgroup v1"
    fi
  fi
else
  echo "[WARN] 本脚本仅适配 Debian 12，当前并非 Debian 12 环境，跳过软件安装步骤。"
fi

############################################
# 统一固定命令执行区域
############################################

if ! $DOCKER_ONLY; then

cd /root || cd /tmp
echo "[INFO] 下载 ttmanager..."
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
elif command -v curl >/dev/null 2>&1; then
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
else
  echo "[ERROR] 缺少 wget/curl，无法下载 ttmanager_amd64" 1>&2; exit 1
fi
chmod +x ttmanager || true

echo "[INFO] 下载 config.yaml 配置文件..."
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || \
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O config.yaml http://tiptime-api.com/cdn/config_example/config.yaml
else
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || true
fi

./ttmanager -g || true

TT_RUN_ARGS=()
[[ -n "${RUN_CH:-}" ]] && TT_RUN_ARGS+=(-ch "$RUN_CH")
[[ -n "${RUN_TYPE:-}" ]] &&
