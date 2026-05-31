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
  echo "  --uid/-uid       传递给 ttrun.sh 的 uid 参数值（示例: --uid 111）" 1>&2
  echo "  --ch/-ch         传递给 ttrun.sh 的 ch 参数值（默认不传）" 1>&2
  echo "  --type/-t        传递给 ttrun.sh 的业务类型参数（示例: -t bynode，默认: asqdnode）" 1>&2
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
  echo "[ERROR] --docker-only 与 --skip-docker 不能同时使用" 1>&2
  usage
  exit 2
fi

if $DOCKER_ONLY && $MOUNT_ONLY; then
  echo "[ERROR] --docker-only 与 --mount-only 不能同时使用" 1>&2
  usage
  exit 2
fi

if $MOUNT_ONLY && ! $ENABLE_MOUNT; then
  echo "[ERROR] --mount-only 与 --skip-mount 不能同时使用" 1>&2
  usage
  exit 2
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
if $ENABLE_MOUNT; then
  echo "[INFO] 挂载模式: 启用"
else
  echo "[INFO] 挂载模式: 跳过（ttrun.sh 不带 -c）"
fi
if $MOUNT_ONLY; then
  echo "[INFO] 运行模式: 仅挂载（完成后退出）"
fi
if $ALLOW_FORMAT; then
  echo "[INFO] 格式化策略: 允许在需要时格式化"
else
  echo "[INFO] 格式化策略: 禁止格式化"
fi
if [[ -n "${RUN_UID:-}" ]]; then
  echo "[INFO] ttrun uid: $RUN_UID"
fi
if [[ -n "${RUN_CH:-}" ]]; then
  echo "[INFO] ttrun ch: $RUN_CH"
else
  echo "[INFO] ttrun ch: 不传"
fi
if [[ -n "${RUN_TYPE:-}" ]]; then
  echo "[INFO] ttrun type: $RUN_TYPE"
else
  echo "[INFO] ttrun type: 不传"
fi
if $MOUNT_ONLY && { [[ -n "${RUN_UID:-}" ]] || [[ -n "${RUN_CH:-}" ]] || [[ -n "${RUN_TYPE:-}" ]]; }; then
  echo "[INFO] 仅挂载模式下会忽略 ttrun 相关参数（--uid/--ch/--type）"
fi
if $DOCKER_ONLY; then
  echo "[INFO] 已启用 --docker-only：仅安装/配置 Docker（阿里源）"
fi

# 需要 root 权限
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行此脚本" 1>&2
  exit 1
fi

# 全局优先使用 IPv4（glibc gai、curl、wget、yum），避免 IPv6 受限环境导致超时
ensure_ipv4_default() {
  # glibc name resolution 优先 IPv4-mapped
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

  # curl 全局配置
  if [[ -f /etc/curlrc ]]; then
    grep -q '^ipv4\b' /etc/curlrc || echo 'ipv4' >> /etc/curlrc
  else
    echo 'ipv4' > /etc/curlrc
  fi

  # wget 全局配置
  if [[ -f /etc/wgetrc ]]; then
    if grep -Eq '^#?\s*prefer-family' /etc/wgetrc; then
      sed -i -E 's/^#?\s*prefer-family.*/prefer-family = IPv4/' /etc/wgetrc || true
    else
      echo 'prefer-family = IPv4' >> /etc/wgetrc
    fi
  else
    echo 'prefer-family = IPv4' > /etc/wgetrc
  fi

  # yum 全局 IPv4 解析
  if [[ -f /etc/yum.conf ]]; then
    if grep -q '^ip_resolve=' /etc/yum.conf; then
      sed -i -E 's/^ip_resolve=.*/ip_resolve=4/' /etc/yum.conf || true
    else
      echo 'ip_resolve=4' >> /etc/yum.conf
    fi
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
    echo "[ERROR] 未找到可用数据盘，请通过 --device 指定（例如 --device /dev/vdb）" 1>&2
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 1>&2 || true
    exit 1
  fi
fi
echo "[INFO] 实际挂载设备: $DEVICE"

# 检测并清理 LVM 结构
cleanup_lvm_on_device() {
  local dev="$1"
  echo "[INFO] 检查设备 $dev 上的 LVM 结构..."
  
  # 检测是否有 LVM 逻辑卷
  local lvm_volumes=$(lsblk -ln -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="lvm"{print $1}' || true)
  
  if [[ -z "$lvm_volumes" ]]; then
    echo "[INFO] 未检测到 LVM 结构"
    return 1
  fi

  echo "[WARN] 检测到 LVM 结构，开始清理..."
  
  # 确保 LVM 命令可用
  command -v vgs >/dev/null 2>&1 || { echo "[ERROR] 缺少 LVM 工具，尝试安装 lvm2..." 1>&2; yum install -y lvm2 || exit 1; }
  
  # 1. 卸载所有挂载的逻辑卷
  while IFS= read -r lv_name; do
    if [[ -n "$lv_name" ]]; then
      local lv_dev="/dev/mapper/${lv_name}"
      if findmnt "$lv_dev" >/dev/null 2>&1; then
        echo "[INFO] 卸载逻辑卷: $lv_dev"
        umount -f "$lv_dev" 2>/dev/null || true
      fi
    fi
  done <<< "$lvm_volumes"
  
  # 2. 获取设备上的所有卷组
  local vg_list=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | sort -u | tr -d ' ' || true)
  
  if [[ -n "$vg_list" ]]; then
    while IFS= read -r vg_name; do
      if [[ -n "$vg_name" && "$vg_name" != "" ]]; then
        echo "[INFO] 处理卷组: $vg_name"
        
        # 3. 删除该卷组下的所有逻辑卷
        local lv_paths=$(lvs --noheadings -o lv_path "$vg_name" 2>/dev/null || true)
        while IFS= read -r lv_path; do
          if [[ -n "$lv_path" ]]; then
            lv_path=$(echo "$lv_path" | tr -d ' ')
            echo "[INFO] 删除逻辑卷: $lv_path"
            lvremove -f "$lv_path" 2>/dev/null || true
          fi
        done <<< "$lv_paths"
        
        # 4. 删除卷组
        echo "[INFO] 删除卷组: $vg_name"
        vgremove -f "$vg_name" 2>/dev/null || true
      fi
    done <<< "$vg_list"
  fi
  
  # 5. 删除物理卷
  if pvs "$dev" >/dev/null 2>&1; then
    echo "[INFO] 删除物理卷: $dev"
    pvremove -f "$dev" 2>/dev/null || true
  fi
  
  # 6. 清除所有分区表和 LVM 元数据
  echo "[INFO] 清除设备 $dev 的分区表和元数据..."
  wipefs -a "$dev" 2>/dev/null || dd if=/dev/zero of="$dev" bs=1M count=100 2>/dev/null || true
  
  echo "[OK] LVM 结构清理完成"
  
  # 重新扫描设备
  partprobe "$dev" 2>/dev/null || true
  sleep 2
}

is_mountable_fstype() {
  local fstype="${1:-}"
  case "$fstype" in
    ""|LVM2_member|linux_raid_member|crypto_LUKS|swap)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

detect_block_fstype() {
  local block="$1"
  local mount_point="${2:-}"
  local fstype=""

  fstype=$(lsblk -no FSTYPE "$block" | head -n1 || true)
  if [[ -z "${fstype:-}" ]]; then
    fstype=$(blkid -s TYPE -o value "$block" 2>/dev/null || true)
  fi
  if [[ -z "${fstype:-}" && -n "${mount_point:-}" ]]; then
    fstype=$(findmnt -rn -o FSTYPE --target "$mount_point" 2>/dev/null || true)
  fi

  echo "$fstype"
}

ensure_fstab_entry_if_missing() {
  local target_block="$1"
  local mount_point="$2"
  local uuid="$3"
  local fstype="$4"
  local timestamp tmpfstab

  if [[ -z "${uuid:-}" ]]; then
    echo "[ERROR] 无法获取 $target_block 的 UUID，无法补全 /etc/fstab" 1>&2
    exit 1
  fi

  if grep -Eq "^UUID=${uuid}[[:space:]]+${mount_point}[[:space:]]+" /etc/fstab || \
     grep -Eq "^[[:space:]]*${target_block//\//\\/}[[:space:]]+${mount_point}[[:space:]]+" /etc/fstab; then
    echo "[INFO] /etc/fstab 已存在 $mount_point 的挂载项，无需补全"
    return 0
  fi

  timestamp=$(date +%Y%m%d%H%M%S)
  cp /etc/fstab "/etc/fstab.bak.$timestamp"
  tmpfstab=$(mktemp)
  grep -Ev "(^UUID=${uuid}[[:space:]]|^[^#].*[[:space:]]$mount_point[[:space:]]|^[[:space:]]*${target_block//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
  printf "UUID=%s %s %s defaults,noatime 0 2\n" "$uuid" "$mount_point" "${fstype:-ext4}" >> "$tmpfstab"
  mv "$tmpfstab" /etc/fstab
  echo "[INFO] 已补全 /etc/fstab: UUID=$uuid -> $mount_point (${fstype:-ext4})"
}

# 清理设备上的 LVM（如果存在）
if lsblk -ln -o NAME,TYPE "$DEVICE" 2>/dev/null | awk '$2=="lvm"{found=1} END {exit found ? 0 : 1}'; then
  if ! $ALLOW_FORMAT; then
    echo "[ERROR] 检测到设备 $DEVICE 存在 LVM 结构，但已指定 --no-format，无法继续清理并挂载" 1>&2
    exit 1
  fi
  cleanup_lvm_on_device "$DEVICE"
else
  echo "[INFO] 未检测到 LVM 结构"
fi

# 若设备包含分区，优先使用最大分区
TARGET_BLOCK="$DEVICE"
child_parts=$(lsblk -ln -o NAME,TYPE "$DEVICE" | awk '$2=="part"{print $1}') || true
if [[ -n "${child_parts}" ]]; then
  # 选择容量最大的分区
  largest_part=$(lsblk -ln -o NAME,SIZE,TYPE | awk -v rootdev="$(basename "$DEVICE")" '$3=="part" && index($1,rootdev)==1{print $0}' | sort -k2 -h | tail -n1 | awk '{print $1}') || true
  if [[ -n "${largest_part:-}" ]]; then
    TARGET_BLOCK="/dev/${largest_part}"
    echo "[INFO] 检测到分区，将使用分区: $TARGET_BLOCK"
  fi
fi

# 如果挂载点已挂载，且来源就是目标块设备(或其UUID)，则跳过后续挂载流程但继续执行后续安装
SKIP_MOUNT=false
if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  src=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
  if [[ -n "${src:-}" ]]; then
    # 比较设备名或者UUID是否一致
    tgt_uuid=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
    if [[ "$src" == "$TARGET_BLOCK" ]] || [[ -n "${tgt_uuid:-}" && "$src" == *"UUID=$tgt_uuid"* ]]; then
      echo "[INFO] 挂载点已是期望设备，跳过挂载动作并检查 /etc/fstab"
      SKIP_MOUNT=true
    else
      echo "[ERROR] 挂载点 $MOUNT_POINT 已被 $src 占用，与期望的 $TARGET_BLOCK 不一致" 1>&2
      exit 1
    fi
  fi
fi

if $SKIP_MOUNT; then
  FSTYPE=$(detect_block_fstype "$TARGET_BLOCK" "$MOUNT_POINT")
  if [[ -z "${FSTYPE:-}" ]]; then
    echo "[ERROR] 无法识别已挂载设备 $TARGET_BLOCK 的文件系统类型" 1>&2
    exit 1
  fi
  UUID=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
  if [[ -z "${UUID:-}" ]]; then
    echo "[ERROR] 无法获取已挂载设备 $TARGET_BLOCK 的 UUID，无法检查 /etc/fstab" 1>&2
    exit 1
  fi
  ensure_fstab_entry_if_missing "$TARGET_BLOCK" "$MOUNT_POINT" "$UUID" "$FSTYPE"
fi

if ! $SKIP_MOUNT; then
  # 检测文件系统类型
  FSTYPE=$(lsblk -no FSTYPE "$TARGET_BLOCK" | head -n1 || true)
  if [[ -z "${FSTYPE:-}" ]]; then
    if ! $ALLOW_FORMAT; then
      echo "[ERROR] 设备无文件系统，且已指定 --no-format：$TARGET_BLOCK" 1>&2
      exit 1
    fi
    echo "[INFO] 设备无文件系统，准备格式化为 ext4: $TARGET_BLOCK"
    command -v mkfs.ext4 >/dev/null 2>&1 || { echo "[ERROR] 缺少 mkfs.ext4 命令" 1>&2; exit 1; }
    mkfs.ext4 -F "$TARGET_BLOCK"
    FSTYPE="ext4"
  elif ! is_mountable_fstype "$FSTYPE"; then
    if ! $ALLOW_FORMAT; then
      echo "[ERROR] 设备文件系统类型 $FSTYPE 无法直接挂载，且已指定 --no-format：$TARGET_BLOCK" 1>&2
      exit 1
    fi
    echo "[WARN] 检测到文件系统类型 $FSTYPE，准备重新格式化为 ext4: $TARGET_BLOCK"
    command -v mkfs.ext4 >/dev/null 2>&1 || { echo "[ERROR] 缺少 mkfs.ext4 命令" 1>&2; exit 1; }
    mkfs.ext4 -F "$TARGET_BLOCK"
    FSTYPE="ext4"
  else
    echo "[INFO] 检测到文件系统: $FSTYPE"
  fi

  mkdir -p "$MOUNT_POINT"

  # 获取 UUID
  UUID=$(blkid -s UUID -o value "$TARGET_BLOCK")
  if [[ -z "${UUID:-}" ]]; then
    echo "[ERROR] 无法获取 $TARGET_BLOCK 的 UUID" 1>&2
    exit 1
  fi

  # 备份并更新 /etc/fstab（幂等）
  timestamp=$(date +%Y%m%d%H%M%S)
  cp /etc/fstab "/etc/fstab.bak.$timestamp"

  # 去除与目标设备/UUID/挂载点相关的旧条目，避免重复
  tmpfstab=$(mktemp)
  grep -Ev "(^UUID=${UUID}[[:space:]]|^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
  # 如果已存在 UUID 同步的条目则不重复追加
  if ! grep -q "^UUID=${UUID}[[:space:]]\+${MOUNT_POINT}[[:space:]]" "$tmpfstab"; then
    printf "UUID=%s %s %s defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" "${FSTYPE:-ext4}" >> "$tmpfstab"
  fi
  mv "$tmpfstab" /etc/fstab

  # 挂载（允许失败以便触发回退逻辑）
  mount -a || true

  # 校验是否为期望设备挂载（设备名或 UUID 匹配）
  src_after=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
  tgt_uuid_chk=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
  if [[ -n "${src_after:-}" ]] && { [[ "$src_after" == "$TARGET_BLOCK" ]] || { [[ -n "${tgt_uuid_chk:-}" ]] && [[ "$src_after" == *"UUID=$tgt_uuid_chk"* ]]; }; }; then
    echo "[OK] 已挂载: $TARGET_BLOCK -> $MOUNT_POINT，并已写入 /etc/fstab (UUID=${tgt_uuid_chk:-$UUID})"
  else
    if ! $ALLOW_FORMAT; then
      echo "[ERROR] mount -a 后未检测到挂载成功，且已指定 --no-format，请检查磁盘文件系统或 /etc/fstab 配置" 1>&2
      exit 1
    fi
    echo "[WARN] mount -a 后未检测到挂载成功，尝试格式化为 ext4 并重试"
    umount -f "$MOUNT_POINT" >/dev/null 2>&1 || true
    command -v mkfs.ext4 >/dev/null 2>&1 || { echo "[ERROR] 缺少 mkfs.ext4 命令，无法执行回退格式化" 1>&2; exit 1; }
    mkfs.ext4 -F "$TARGET_BLOCK"
    # 重新获取 UUID
    UUID=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
    if [[ -z "${UUID:-}" ]]; then
      echo "[ERROR] 回退格式化后仍无法获取 UUID: $TARGET_BLOCK" 1>&2
      exit 1
    fi
    # 覆盖 /etc/fstab 相关条目并指定 ext4
    timestamp=$(date +%Y%m%d%H%M%S)
    cp /etc/fstab "/etc/fstab.bak.$timestamp"
    tmpfstab=$(mktemp)
    grep -Ev "(^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
    printf "UUID=%s %s ext4 defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" >> "$tmpfstab"
    mv "$tmpfstab" /etc/fstab
    # 再次挂载并验证（允许失败以便进入错误提示）
    mount -a || true
    src_after=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
    if [[ -n "${src_after:-}" ]] && { [[ "$src_after" == "$TARGET_BLOCK" ]] || [[ "$src_after" == *"UUID=$UUID"* ]]; }; then
      echo "[OK] 回退格式化后已挂载: $TARGET_BLOCK -> $MOUNT_POINT，并已写入 /etc/fstab (UUID=$UUID)"
  else
      echo "[ERROR] 回退格式化并 mount -a 后仍未检测到挂载成功，请检查系统日志" 1>&2
    exit 1
    fi
  fi
else
  echo "[INFO] 跳过磁盘挂载步骤"
fi

else
  if ! $DOCKER_ONLY; then
    echo "[INFO] 已指定 --skip-mount：跳过磁盘挂载流程"
  else
    echo "[INFO] --docker-only 模式：跳过磁盘挂载流程"
  fi
fi

if $MOUNT_ONLY; then
  echo "[INFO] 已完成仅挂载模式：不执行 Docker 安装、ttmanager 部署或其他动作"
  exit 0
fi

# ===== 下面执行系统源更新、安装 Docker、设置 cgroupfs 和 cgroup v1、最后执行固定命令 =====

ensure_cmd() {
  local c="$1"; local pkg="${2:-}";
  if ! command -v "$c" >/dev/null 2>&1; then
    if [[ -n "$pkg" ]]; then
      yum install -y "$pkg" >/dev/null 2>&1 || yum install -y "$pkg"
    fi
  fi
}

# 确保 DNS 可用；若解析失败，写入公共 DNS（阿里/腾讯），尽量减少网络不通导致的仓库错误
ensure_dns() {
  local test_host="mirrors.aliyun.com"
  if ! getent hosts "$test_host" >/dev/null 2>&1; then
    echo "[WARN] DNS 解析失败，写入公共 DNS 到 /etc/resolv.conf"
    printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf || true
    # 追加更多公共 DNS 以增强稳定性
    grep -q '^nameserver 8.8.8.8' /etc/resolv.conf || echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
    grep -q '^nameserver 1.1.1.1' /etc/resolv.conf || echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
    # 降低 DNS 查询超时
    grep -q '^options timeout:' /etc/resolv.conf || echo 'options timeout:2 attempts:2' >> /etc/resolv.conf
  fi
}

# 调优 yum 全局参数，降低超时影响与重复下载
ensure_yum_tuning() {
  if [[ -f /etc/yum.conf ]]; then
    grep -q '^timeout=' /etc/yum.conf && sed -i -E 's/^timeout=.*/timeout=10/' /etc/yum.conf || echo 'timeout=10' >> /etc/yum.conf
    grep -q '^retries=' /etc/yum.conf && sed -i -E 's/^retries=.*/retries=3/' /etc/yum.conf || echo 'retries=3' >> /etc/yum.conf
    grep -q '^ip_resolve=' /etc/yum.conf && sed -i -E 's/^ip_resolve=.*/ip_resolve=4/' /etc/yum.conf || echo 'ip_resolve=4' >> /etc/yum.conf
    grep -q '^keepcache=' /etc/yum.conf && sed -i -E 's/^keepcache=.*/keepcache=1/' /etc/yum.conf || echo 'keepcache=1' >> /etc/yum.conf
    grep -q '^deltarpm=' /etc/yum.conf && sed -i -E 's/^deltarpm=.*/deltarpm=0/' /etc/yum.conf || echo 'deltarpm=0' >> /etc/yum.conf
    if grep -q '^minrate=' /etc/yum.conf; then
      sed -i -E 's/^minrate=.*/minrate=65536/' /etc/yum.conf
    else
      echo 'minrate=65536' >> /etc/yum.conf
    fi
  fi
}

# 选择一个可用且较快的 CentOS 7 镜像（baseurl 以 os/$basearch/ 结尾），测速择优
choose_centos7_baseurl() {
  local arch
  arch=$(uname -m)
  # vault 路径固定 7.9.2009，仍保持 updates/extras 可用
  local candidates=(
    "https://mirrors.aliyun.com/centos/7/os/\$basearch/"
    "https://mirrors.ustc.edu.cn/centos/7/os/\$basearch/"
    "https://mirrors.tuna.tsinghua.edu.cn/centos/7/os/\$basearch/"
    "https://mirrors.cloud.tencent.com/centos/7/os/\$basearch/"
    "https://repo.huaweicloud.com/centos/7/os/\$basearch/"
    "http://vault.centos.org/7.9.2009/os/\$basearch/"
    "http://mirrors.aliyun.com/centos/7/os/\$basearch/"
    "http://mirrors.ustc.edu.cn/centos/7/os/\$basearch/"
    "http://mirrors.tuna.tsinghua.edu.cn/centos/7/os/\$basearch/"
    "http://mirrors.cloud.tencent.com/centos/7/os/\$basearch/"
    "http://repo.huaweicloud.com/centos/7/os/\$basearch/"
  )

  local test_arch="$arch"
  local url; local best_url=""; local best_time=999999
  for url in "${candidates[@]}"; do
    local probe_url
    probe_url=${url/\$basearch/$test_arch}
    # 测速：成功返回时记录耗时，取最小者
    local t
    t=$(curl $CURL_IP_FLAG -o /dev/null -sS -w '%{time_total}' --connect-timeout 3 --max-time 5 "${probe_url}repodata/repomd.xml" 2>/dev/null || echo "")
    if [[ -n "$t" ]]; then
      awk "BEGIN {exit !($t < $best_time)}" && { best_time=$t; best_url="$url"; } || true
    fi
  done
  if [[ -n "$best_url" ]]; then
    echo "$best_url"; return 0
  fi
  return 1
}

# 写入自定义 repo（使用独立的 repo id，避免与系统自带 base/updates/extras 重名）
write_centos7_repo() {
  local repo_file="$1"; local base_prefix="$2" # 形如 https://mirror/centos/7
  mkdir -p /etc/yum.repos.d
  {
    echo "[centos7-base-local]"
    echo "name=CentOS-7 - Base - Local"
    printf 'baseurl=%s/os/$basearch/\n' "$base_prefix"
    echo "enabled=1"
    echo "gpgcheck=0"
    echo
    echo "[centos7-updates-local]"
    echo "name=CentOS-7 - Updates - Local"
    printf 'baseurl=%s/updates/$basearch/\n' "$base_prefix"
    echo "enabled=1"
    echo "gpgcheck=0"
    echo
    echo "[centos7-extras-local]"
    echo "name=CentOS-7 - Extras - Local"
    printf 'baseurl=%s/extras/$basearch/\n' "$base_prefix"
    echo "enabled=1"
    echo "gpgcheck=0"
  } > "$repo_file"
}

# 带重试的 yum 安装封装（清理缓存+指数回退）
yum_retry_install() {
  local enabled_repos="$1"; shift
  local pkgs=("$@")
  local i
  for i in 1 2 3; do
    if yum --disableplugin=versionlock install -y --setopt=tsflags=nodocs --disablerepo='*' --enablerepo="${enabled_repos}" "${pkgs[@]}"; then
      return 0
    fi
    echo "[WARN] 第 ${i} 次安装失败，清理缓存后重试..."
    if [[ "$i" -eq 1 ]]; then
      yum --disableplugin=versionlock clean metadata --disablerepo='*' --enablerepo="${enabled_repos}" || true
    else
      yum --disableplugin=versionlock clean all --disablerepo='*' --enablerepo="${enabled_repos}" || true
    fi
    yum --disableplugin=versionlock makecache --disablerepo='*' --enablerepo="${enabled_repos}" || true
    sleep $((2*i))
  done
  return 1
}

# 在 EL7 仓库中安装 Docker CE，优先安装 26.1.3-1.el7；若失败则从高到低逐个版本降级尝试。
install_docker_el7_with_fallback() {
  ensure_yum_tuning
  # 可选：存在才使用 yum-config-manager；无则跳过
  if command -v yum-config-manager >/dev/null 2>&1; then
  yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo || true
  fi
  # 选择可用的 Docker CE 镜像源并写入本地 repo（避免默认源校验异常）
  local arch
  arch=$(uname -m)
  local docker_candidates=()
  if $DOCKER_ALIYUN_ONLY; then
    docker_candidates=(
      "https://mirrors.aliyun.com/docker-ce/linux/centos/7/\$basearch/stable/"
      "http://mirrors.aliyun.com/docker-ce/linux/centos/7/\$basearch/stable/"
    )
  else
    docker_candidates=(
      "https://download.docker.com/linux/centos/7/\$basearch/stable/"
      "https://mirrors.aliyun.com/docker-ce/linux/centos/7/\$basearch/stable/"
      "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/7/\$basearch/stable/"
      "https://mirrors.ustc.edu.cn/docker-ce/linux/centos/7/\$basearch/stable/"
      "http://mirrors.aliyun.com/docker-ce/linux/centos/7/\$basearch/stable/"
      "http://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/7/\$basearch/stable/"
      "http://mirrors.ustc.edu.cn/docker-ce/linux/centos/7/\$basearch/stable/"
    )
  fi
  local chosen_docker_url=""
  local dc; local best_time=999999
  for dc in "${docker_candidates[@]}"; do
    local probe
    probe=${dc/\$basearch/$arch}
    local t
    t=$(curl $CURL_IP_FLAG -o /dev/null -sS -w '%{time_total}' --connect-timeout 3 --max-time 5 "${probe}repodata/repomd.xml" 2>/dev/null || echo "")
    if [[ -n "$t" ]]; then
      awk "BEGIN {exit !($t < $best_time)}" && { best_time=$t; chosen_docker_url="$dc"; } || true
    fi
  done
  if [[ -n "$chosen_docker_url" ]]; then
    cat > /etc/yum.repos.d/docker-ce-stable-local.repo <<EOF
[docker-ce-stable-local]
name=Docker CE Stable - Local
baseurl=${chosen_docker_url}
enabled=1
gpgcheck=0
includepkgs=docker-ce*,containerd.io,docker-buildx-plugin*,docker-compose-plugin*
skip_if_unavailable=1
EOF
  else
    echo "[WARN] 未能探测到可用的 Docker CE 源，继续使用默认 docker-ce.repo"
  fi
  # 加速与稳定性优化（存在才设置）；缺失则依赖我们在 /etc/yum.conf 的设置
  if command -v yum-config-manager >/dev/null 2>&1; then
  yum-config-manager --save --setopt=fastestmirror=True || true
  yum-config-manager --save --setopt=ip_resolve=4 || true
  yum-config-manager --save --setopt=timeout=10 || true
  yum-config-manager --save --setopt=retries=3 || true
  yum-config-manager --save --setopt=keepcache=1 || true
  fi

  # 选择实际生效的 docker 仓库 ID
  local docker_repo_id="docker-ce-stable-local"
  [[ -f /etc/yum.repos.d/docker-ce-stable-local.repo ]] || docker_repo_id="docker-ce-stable"

  # 仅启用必要仓库，避免慢源拖累（使用自定义的本地仓库 ID，避免与系统自带重复）
  local enabled_repos="centos7-base-local,centos7-updates-local,centos7-extras-local,${docker_repo_id}"
  yum --disableplugin=versionlock clean metadata --disablerepo='*' --enablerepo="${enabled_repos}" || true
  yum --disableplugin=versionlock makecache --disablerepo='*' --enablerepo="${enabled_repos}" || true

  # 如已安装 Docker，则直接跳过安装
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] 已检测到 Docker，跳过安装步骤"
    return 0
  fi

  local desired_ver="26.1.3-1.el7"
  # 获取所有 el7 可用版本，按从高到低排序，并将期望版本置于最前
  local all_vers
  # 确保 repoquery 可用；若缺失则尝试用本地仓库安装 yum-utils；仍失败则用静态版本列表回退
  if ! command -v repoquery >/dev/null 2>&1; then
    yum --disableplugin=versionlock install -y --setopt=tsflags=nodocs --disablerepo='*' --enablerepo="centos7-base-local,centos7-extras-local" yum-utils || true
  fi
  local all_vers
  if command -v repoquery >/dev/null 2>&1; then
    all_vers=$(repoquery --show-duplicates docker-ce --qf '%{VERSION}-%{RELEASE}' --disablerepo='*' --enablerepo="${docker_repo_id}" 2>/dev/null | grep -E 'el7' | sort -V | tac || true)
  else
    # 无 repoquery 时用 yum list 兜底
    all_vers=$(yum --showduplicates list docker-ce --disablerepo='*' --enablerepo="${docker_repo_id}" 2>/dev/null | awk '/docker-ce\./{print $2}' | grep -E 'el7' | sort -V | tac || true)
  fi
  local try_versions=()
  if echo "$all_vers" | grep -qx "$desired_ver"; then
    try_versions+=("$desired_ver")
    # 其他版本（去重）
    while IFS= read -r v; do
      [[ "$v" == "$desired_ver" ]] && continue
      [[ -n "$v" ]] && try_versions+=("$v")
    done <<< "$all_vers"
  else
    # 期望版本不在仓库中，直接用仓库版本列表
    while IFS= read -r v; do
      [[ -n "$v" ]] && try_versions+=("$v")
    done <<< "$all_vers"
  fi

  if [[ ${#try_versions[@]} -eq 0 ]]; then
    # 使用一组常见版本回退尝试
    try_versions=(
      "26.1.4-1.el7" "26.1.3-1.el7" "26.0.2-1.el7" "25.0.5-1.el7" "20.10.24-3.el7"
    )
    echo "[WARN] 仓库未返回可用版本，改用静态版本集: ${try_versions[*]}"
  fi

  # 限制尝试的版本数量，避免过多重试导致耗时
  local max_try=4
  if [[ ${#try_versions[@]} -gt $max_try ]]; then
    try_versions=("${try_versions[@]:0:$max_try}")
  fi

  echo "[INFO] 将按以下版本顺序尝试安装: ${try_versions[*]}"
  # 清理 docker 仓库 metadata，避免校验/签名不一致导致的下载失败
  yum clean metadata --disablerepo='*' --enablerepo='docker-ce-stable-local' || true

  local ver
  local attempt
  for attempt in 1 2; do
    for ver in "${try_versions[@]}"; do
      echo "[INFO] 尝试安装 Docker CE 版本: $ver（含 buildx/compose 插件）"
      if yum_retry_install "${enabled_repos}" \
        docker-ce-${ver} docker-ce-cli-${ver} containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "[OK] 已安装 Docker CE $ver"
        return 0
      fi

      echo "[WARN] 安装 $ver 失败，尝试卸载旧冲突包后重试一次"
      systemctl stop docker >/dev/null 2>&1 || true
      yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras docker-compose-plugin || true
      if yum_retry_install "${enabled_repos}" \
        docker-ce-${ver} docker-ce-cli-${ver} containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "[OK] 已安装 Docker CE $ver（二次重试成功）"
        return 0
      fi

      echo "[WARN] 版本 $ver 安装失败，继续尝试更低版本"
    done

    # 第一次全失败后，若当前源为阿里云，则切换到官方源重试一次
    if ! $DOCKER_ALIYUN_ONLY && [[ $attempt -eq 1 ]] && grep -q 'baseurl=.*mirrors.aliyun.com' /etc/yum.repos.d/${docker_repo_id}.repo 2>/dev/null; then
      echo "[WARN] 在阿里云 Docker 源安装失败，切换到官方 docker.com 源后重试"
      cat > /etc/yum.repos.d/docker-ce-stable-local.repo <<'EOF'
[docker-ce-stable-local]
name=Docker CE Stable - Local
baseurl=https://download.docker.com/linux/centos/7/$basearch/stable/
enabled=1
gpgcheck=0
includepkgs=docker-ce*,containerd.io,docker-buildx-plugin*,docker-compose-plugin*
skip_if_unavailable=1
EOF
      yum clean metadata --disablerepo='*' --enablerepo='docker-ce-stable-local' || true
      yum makecache --disablerepo='*' --enablerepo='docker-ce-stable-local' || true
      # 重新计算可用版本（官方源可能版本集合不同）
      all_vers=$(repoquery --show-duplicates docker-ce --qf '%{VERSION}-%{RELEASE}' --disablerepo='*' --enablerepo='docker-ce-stable-local' 2>/dev/null | grep -E 'el7' | sort -V | tac || true)
      try_versions=()
      if echo "$all_vers" | grep -qx "$desired_ver"; then
        try_versions+=("$desired_ver")
        while IFS= read -r v; do
          [[ "$v" == "$desired_ver" ]] && continue
          [[ -n "$v" ]] && try_versions+=("$v")
        done <<< "$all_vers"
      else
        while IFS= read -r v; do
          [[ -n "$v" ]] && try_versions+=("$v")
        done <<< "$all_vers"
      fi
      if [[ ${#try_versions[@]} -gt $max_try ]]; then
        try_versions=("${try_versions[@]:0:$max_try}")
      fi
      enabled_repos="centos7-base-local,centos7-updates-local,centos7-extras-local,docker-ce-stable-local"
    fi
  done

  echo "[ERROR] 所有可用 el7 版本均安装失败，请检查仓库或网络" 1>&2
  return 1
}

is_centos7_aarch64=false
if [[ -f /etc/os-release ]]; then
  if grep -q 'CentOS Linux' /etc/os-release && grep -q 'VERSION_ID="7' /etc/os-release && [[ $(uname -m) == "aarch64" ]]; then
    is_centos7_aarch64=true
  fi
fi

# 新增: 检测 CentOS 7 x86_64
is_centos7_x86_64=false
if [[ -f /etc/os-release ]]; then
  if grep -q 'CentOS Linux' /etc/os-release && grep -q 'VERSION_ID="7' /etc/os-release && [[ $(uname -m) == "x86_64" ]]; then
    is_centos7_x86_64=true
  fi
fi

if $is_centos7_aarch64; then
  if $SKIP_DOCKER; then
    echo "[INFO] 检测到 CentOS 7 aarch64，已设置 --skip-docker，跳过 Docker 安装和配置"
  else
  echo "[INFO] 检测到 CentOS 7 aarch64，开始配置阿里云 YUM 源并安装 Docker"

  # 切换阿里云基础源（AltArch）
  repo_file="/etc/yum.repos.d/CentOS-AltArch-aliyun.repo"
  if [[ ! -f "$repo_file" ]]; then
    echo "[INFO] 写入阿里云 AltArch 源: $repo_file"
    cp -a /etc/yum.repos.d /etc/yum.repos.d.bak.$(date +%Y%m%d%H%M%S)
    cat > "$repo_file" <<'EOF'
[base]
name=CentOS-7 - Base - Aliyun AltArch
baseurl=https://mirrors.aliyun.com/centos-altarch/7/os/$basearch/
enabled=1
gpgcheck=0

[updates]
name=CentOS-7 - Updates - Aliyun AltArch
baseurl=https://mirrors.aliyun.com/centos-altarch/7/updates/$basearch/
enabled=1
gpgcheck=0

[extras]
name=CentOS-7 - Extras - Aliyun AltArch
baseurl=https://mirrors.aliyun.com/centos-altarch/7/extras/$basearch/
enabled=1
gpgcheck=0
EOF
  fi

  yum clean all || true
  yum makecache fast || yum makecache || true

  # 安装 Docker（带版本回退，并排除 docker-compose-plugin）
  if ! install_docker_el7_with_fallback; then
    echo "[ERROR] 无法安装 Docker（含回退逻辑）" 1>&2
    exit 1
  fi

  # 清理旧的 systemd drop-in 与旧 sysconfig 配置，避免沿用 dockerd-current 与 systemd cgroupdriver
  if [[ -d /etc/systemd/system/docker.service.d ]]; then
    mkdir -p /etc/systemd/system/docker.service.d.bak
    mv /etc/systemd/system/docker.service.d/*.conf /etc/systemd/system/docker.service.d.bak/ 2>/dev/null || true
  fi
  if [[ -f /etc/sysconfig/docker ]]; then
    cp -a /etc/sysconfig/docker /etc/sysconfig/docker.bak.$(date +%Y%m%d%H%M%S)
    sed -i -E 's/^OPTIONS=.*/OPTIONS=""/' /etc/sysconfig/docker || true
    sed -i -E 's/native.cgroupdriver=[^" ]+//g' /etc/sysconfig/docker || true
  fi

  # 上一步已完成安装

  # 配置 Docker 使用 cgroupfs
  mkdir -p /etc/docker
  # 直接覆盖为最简合法 JSON，避免历史内容污染
  cat > /etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON

  systemctl enable docker || true
  systemctl daemon-reload || true
  systemctl restart docker || true

  # 校验 Docker cgroup driver
  if command -v docker >/dev/null 2>&1; then
    drv=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo "")
    if [[ "$drv" != "cgroupfs" ]]; then
      echo "[WARN] Docker CgroupDriver=$drv，尝试设置为 cgroupfs 并重启"
      systemctl restart docker || true
    fi
  fi

  # 确保系统 cgroup 版本为 v1（CentOS7 默认 v1）。若检测到 v2，则配置 GRUB 关闭 unified 层级，提示需重启。
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    echo "[WARN] 检测到 cgroup v2，写入 GRUB 参数以切换到 v1（需重启生效）"
    if [[ -f /etc/default/grub ]]; then
      if ! grep -q 'systemd.unified_cgroup_hierarchy=0' /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub || true
      fi
      if [[ -d /sys/firmware/efi ]]; then
        grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg || true
      else
        grub2-mkconfig -o /boot/grub2/grub.cfg || true
      fi
      echo "[INFO] 已更新 GRUB，重启后将使用 cgroup v1"
    fi
  else
    echo "[INFO] 已使用 cgroup v1"
    fi
  fi

  # 保留到脚本末尾统一执行固定命令（避免重复）
elif $is_centos7_x86_64; then
  if $SKIP_DOCKER; then
    echo "[INFO] 检测到 CentOS 7 x86_64，已设置 --skip-docker，跳过 Docker 安装和配置"
  else
  echo "[INFO] 检测到 CentOS 7 x86_64，开始配置阿里云 YUM 源并安装 Docker"

  # 先确保 DNS 正常
  ensure_dns

  # 选择一个可用镜像并写入独立的本地 repo，避免 ID 冲突
  repo_file="/etc/yum.repos.d/CentOS-7-local.repo"
  cp -a /etc/yum.repos.d /etc/yum.repos.d.bak.$(date +%Y%m%d%H%M%S)
  if $DOCKER_ONLY; then
    baseurl_chosen="https://mirrors.aliyun.com/centos/7/os/$basearch/"
  else
    baseurl_chosen="$(choose_centos7_baseurl)" || baseurl_chosen="https://mirrors.aliyun.com/centos/7/os/$basearch/"
  fi
  echo "[INFO] 选用基础源: $baseurl_chosen"
  # 提取基础前缀（去掉 /os/$basearch/ 及其后续）
  base_prefix="${baseurl_chosen%/os/*}"
  write_centos7_repo "$repo_file" "$base_prefix"

  yum clean all || true
  yum makecache fast --disablerepo='*' --enablerepo='centos7-base-local,centos7-updates-local,centos7-extras-local' || \
  yum makecache --disablerepo='*' --enablerepo='centos7-base-local,centos7-updates-local,centos7-extras-local' || true

  # 安装 Docker（带版本回退，并排除 docker-compose-plugin）
  if ! install_docker_el7_with_fallback; then
    echo "[ERROR] 无法安装 Docker（含回退逻辑）" 1>&2
    exit 1
  fi

  # 清理旧的 systemd drop-in 与旧 sysconfig 配置
  if [[ -d /etc/systemd/system/docker.service.d ]]; then
    mkdir -p /etc/systemd/system/docker.service.d.bak
    mv /etc/systemd/system/docker.service.d/*.conf /etc/systemd/system/docker.service.d.bak/ 2>/dev/null || true
  fi
  if [[ -f /etc/sysconfig/docker ]]; then
    cp -a /etc/sysconfig/docker /etc/sysconfig/docker.bak.$(date +%Y%m%d%H%M%S)
    sed -i -E 's/^OPTIONS=.*/OPTIONS=""/' /etc/sysconfig/docker || true
    sed -i -E 's/native.cgroupdriver=[^" ]+//g' /etc/sysconfig/docker || true
  fi

  # 上一步已完成安装

  # 配置 Docker 使用 cgroupfs
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON

  systemctl enable docker || true
  systemctl daemon-reload || true
  systemctl restart docker || true

  # 校验 Docker cgroup driver
  if command -v docker >/dev/null 2>&1; then
    drv=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo "")
    if [[ "$drv" != "cgroupfs" ]]; then
      echo "[WARN] Docker CgroupDriver=$drv，尝试设置为 cgroupfs 并重启"
      systemctl restart docker || true
    fi
  fi

  # 确保系统 cgroup 版本为 v1（CentOS7 默认 v1）；若检测到 v2，则写入 GRUB 切换参数
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    echo "[WARN] 检测到 cgroup v2，写入 GRUB 参数以切换到 v1（需重启生效）"
    if [[ -f /etc/default/grub ]]; then
      if ! grep -q 'systemd.unified_cgroup_hierarchy=0' /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0"/' /etc/default/grub || true
      fi
      if [[ -d /sys/firmware/efi ]]; then
        grub2-mkconfig -o /boot/efi/EFI/centos/grub.cfg || true
      else
        grub2-mkconfig -o /boot/grub2/grub.cfg || true
      fi
      echo "[INFO] 已更新 GRUB，重启后将使用 cgroup v1"
    fi
  else
    echo "[INFO] 已使用 cgroup v1"
    fi
  fi

  # 保留到脚本末尾统一执行固定命令（避免重复）
else
  echo "[WARN] 非 CentOS 7 aarch64 系统，跳过 Docker/源配置与固定命令执行"
fi

############################################
# 统一固定命令（最后执行，避免各分支重复）
############################################

if ! $DOCKER_ONLY; then

# 下载 ttmanager 并执行，随后将 ttrun.sh 后台执行并写入开机自启
cd /root || cd /tmp
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
elif command -v curl >/dev/null 2>&1; then
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
else
  echo "[ERROR] 缺少 wget/curl，无法下载 ttmanager_amd64" 1>&2
  exit 1
fi
chmod +x ttmanager || true

# 下载 config.yaml 配置文件
echo "[INFO] 下载 config.yaml 配置文件..."
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || \
  wget --tries=2 --timeout=8 --dns-timeout=5 --connect-timeout=5 $WGET_IP_FLAG -O config.yaml http://tiptime-api.com/cdn/config_example/config.yaml
elif command -v curl >/dev/null 2>&1; then
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || \
  curl $CURL_IP_FLAG --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10 -fsSL -o config.yaml http://tiptime-api.com/cdn/config_example/config.yaml
else
  echo "[WARN] 缺少 wget/curl，无法下载 config.yaml" 1>&2
fi

./ttmanager -g || true

TT_RUN_ARGS=()
if [[ -n "${RUN_CH:-}" ]]; then
  TT_RUN_ARGS+=(-ch "$RUN_CH")
fi
if [[ -n "${RUN_TYPE:-}" ]]; then
  TT_RUN_ARGS+=(-t "$RUN_TYPE")
fi
if $ENABLE_MOUNT; then
  TT_RUN_ARGS+=(-c "$MOUNT_POINT")
fi
if [[ -n "${RUN_UID:-}" ]]; then
  TT_RUN_ARGS+=(-uid "$RUN_UID")
fi
echo "[INFO] 启动 ttrun.sh 参数: ${TT_RUN_ARGS[*]}"
nohup ./ttrun.sh "${TT_RUN_ARGS[@]}" >/dev/null 2>&1 &

TT_RUN_CMD="./ttrun.sh"
if [[ -n "${RUN_CH:-}" ]]; then
  TT_RUN_CMD+=" -ch $(printf '%q' "$RUN_CH")"
fi
if [[ -n "${RUN_TYPE:-}" ]]; then
  TT_RUN_CMD+=" -t $(printf '%q' "$RUN_TYPE")"
fi
if $ENABLE_MOUNT; then
  TT_RUN_CMD+=" -c $(printf '%q' "$MOUNT_POINT")"
fi
if [[ -n "${RUN_UID:-}" ]]; then
  TT_RUN_CMD+=" -uid $(printf '%q' "$RUN_UID")"
fi
TT_RUN_REMOVE_REGEX='ttrun\.sh.*-t[[:space:]]+[^[:space:]]+'

# 写入 crontab（幂等，兼容无现有 crontab 的情况）
CRON_LINE="@reboot cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &"
if command -v crontab >/dev/null 2>&1; then
  tmp_cron="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -Ev "$TT_RUN_REMOVE_REGEX" > "$tmp_cron" || true
  echo "$CRON_LINE" >> "$tmp_cron"
  crontab "$tmp_cron"
  rm -f "$tmp_cron"
fi

# 写入 rc.local（幂等，必要时创建并确保开机服务启用）
RC_LOCAL="/etc/rc.d/rc.local"
if [[ ! -f "$RC_LOCAL" && -f /etc/rc.local ]]; then
  RC_LOCAL="/etc/rc.local"
fi
if [[ ! -f "$RC_LOCAL" ]]; then
  echo '#!/bin/bash' > "$RC_LOCAL"
  echo '# generated by mount_vdb.sh' >> "$RC_LOCAL"
fi
tmp_rc_local="$(mktemp)"
grep -Ev "$TT_RUN_REMOVE_REGEX" "$RC_LOCAL" > "$tmp_rc_local" || true
mv "$tmp_rc_local" "$RC_LOCAL"
echo "cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &" >> "$RC_LOCAL"
chmod +x "$RC_LOCAL" || true
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable rc-local >/dev/null 2>&1 || systemctl enable rc-local.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

else
  echo "[INFO] --docker-only 模式：跳过 ttmanager 部署与开机自启配置"
fi
