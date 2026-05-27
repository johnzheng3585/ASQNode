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
    --uid/-uid)
      [[ $# -ge 2 ]] || { echo "缺少 --uid 的值" 1>&2; usage; exit 2; }
      RUN_UID="$2"; shift 2;;
    --ch/-ch)
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

# 需要 root 权限
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 运行此脚本" 1>&2
  exit 1
fi

# 全局优先使用 IPv4（适配 Debian 的 gai.conf, wgetrc, curlrc）
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
    echo "[WARN] DNS 解析失败，写入公共 DNS 到 /etc/resolv.conf"
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

if ! $DOCKER_ONLY && $ENABLE_MOUNT; then

  # 基本工具检查与自动安装
  command -v lsblk >/dev/null 2>&1 || { apt-get update && apt-get install -y util-linux; }
  command -v blkid >/dev/null 2>&1 || { apt-get update && apt-get install -y e2fsprogs; }

  if [[ ! -b "$DEVICE" ]]; then
    echo "[WARN] 指定设备不存在或不是块设备: $DEVICE"
    AUTO_DEVICE="$(detect_data_device || true)"
    if [[ -n "$AUTO_DEVICE" && -b "$AUTO_DEVICE" ]]; then
      DEVICE="$AUTO_DEVICE"
      echo "[INFO] 自动识别到数据盘设备: $DEVICE"
    else
      echo "[ERROR] 未找到可用数据盘，请通过 --device 指定" 1>&2
      lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 1>&2 || true
      exit 1
    fi
  fi
  echo "[INFO] 实际挂载设备: $DEVICE"

  # 清理 LVM 结构
  cleanup_lvm_on_device() {
    local dev="$1"
    echo "[INFO] 检查设备 $dev 上的 LVM 结构..."
    local lvm_volumes=$(lsblk -ln -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="lvm"{print $1}' || true)
    if [[ -z "$lvm_volumes" ]]; then
      echo "[INFO] 未检测到 LVM 结构"
      return 0
    fi

    echo "[WARN] 检测到 LVM 结构，开始清理..."
    command -v vgs >/dev/null 2>&1 || { echo "[INFO] 安装 lvm2..." 1>&2; apt-get update && apt-get install -y lvm2 || exit 1; }
    
    while IFS= read -r lv_name; do
      if [[ -n "$lv_name" ]]; then
        local lv_dev="/dev/mapper/${lv_name}"
        if findmnt "$lv_dev" >/dev/null 2>&1; then
          umount -f "$lv_dev" 2>/dev/null || true
        fi
      fi
    done <<< "$lvm_volumes"
    
    local vg_list=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | sort -u | tr -d ' ' || true)
    if [[ -n "$vg_list" ]]; then
      while IFS= read -r vg_name; do
        if [[ -n "$vg_name" ]]; then
          local lv_paths=$(lvs --noheadings -o lv_path "$vg_name" 2>/dev/null || true)
          while IFS= read -r lv_path; do
            if [[ -n "$lv_path" ]]; then
              lv_path=$(echo "$lv_path" | tr -d ' ')
              lvremove -f "$lv_path" 2>/dev/null || true
            fi
          done <<< "$lv_paths"
          vgremove -f "$vg_name" 2>/dev/null || true
        fi
      done <<< "$vg_list"
    fi
    
    if pvs "$dev" >/dev/null 2>&1; then
      pvremove -f "$dev" 2>/dev/null || true
    fi
    
    echo "[INFO] 清除设备 $dev 的分区表和元数据..."
    wipefs -a "$dev" 2>/dev/null || dd if=/dev/zero of="$dev" bs=1M count=100 2>/dev/null || true
    
    # Debian 下对应的分区刷新
    command -v partprobe >/dev/null 2>&1 || apt-get install -y parted || true
    partprobe "$dev" 2>/dev/null || true
    sleep 2
  }

  if lsblk -ln -o NAME,TYPE "$DEVICE" 2>/dev/null | awk '$2=="lvm"{found=1} END {exit found ? 0 : 1}'; then
    if ! $ALLOW_FORMAT; then
      echo "[ERROR] 检测到 LVM 结构，但已指定 --no-format" 1>&2; exit 1
    fi
    cleanup_lvm_on_device "$DEVICE"
  fi

  TARGET_BLOCK="$DEVICE"
  child_parts=$(lsblk -ln -o NAME,TYPE "$DEVICE" | awk '$2=="part"{print $1}') || true
  if [[ -n "${child_parts}" ]]; then
    largest_part=$(lsblk -ln -o NAME,SIZE,TYPE | awk -v rootdev="$(basename "$DEVICE")" '$3=="part" && index($1,rootdev)==1{print $0}' | sort -k2 -h | tail -n1 | awk '{print $1}') || true
    if [[ -n "${largest_part:-}" ]]; then
      TARGET_BLOCK="/dev/${largest_part}"
      echo "[INFO] 检测到分区，将使用分区: $TARGET_BLOCK"
    fi
  fi

  SKIP_MOUNT=false
  if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
    src=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
    if [[ -n "${src:-}" ]]; then
      tgt_uuid=$(blkid -s UUID -o value "$TARGET_BLOCK" || true)
      if [[ "$src" == "$TARGET_BLOCK" ]] || [[ -n "${tgt_uuid:-}" && "$src" == *"UUID=$tgt_uuid"* ]]; then
        echo "[INFO] 挂载点已是期望设备，跳过挂载动作"
        SKIP_MOUNT=true
      else
        echo "[ERROR] 挂载点 $MOUNT_POINT 已被 $src 占用" 1>&2; exit 1
      fi
    fi
  fi

  if ! $SKIP_MOUNT; then
    FSTYPE=$(lsblk -no FSTYPE "$TARGET_BLOCK" | head -n1 || true)
    if [[ -z "${FSTYPE:-}" ]]; then
      if ! $ALLOW_FORMAT; then
        echo "[ERROR] 设备无文件系统且禁止格式化" 1>&2; exit 1
      fi
      echo "[INFO] 设备无文件系统，准备格式化为 ext4..."
      command -v mkfs.ext4 >/dev/null 2>&1 || apt-get install -y e2fsprogs
      mkfs.ext4 -F "$TARGET_BLOCK"
      FSTYPE="ext4"
    fi

    mkdir -p "$MOUNT_POINT"
    UUID=$(blkid -s UUID -o value "$TARGET_BLOCK")
    
    # 备份并幂等写入 /etc/fstab
    cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    tmpfstab=$(mktemp)
    grep -Ev "(^UUID=${UUID}[[:space:]]|^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
    printf "UUID=%s %s %s defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" "$FSTYPE" >> "$tmpfstab"
    mv "$tmpfstab" /etc/fstab

    mount -a || true

    # 校验结果，失败则触发回退逻辑
    src_after=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT" || true)
    if [[ -z "${src_after:-}" ]]; then
      if ! $ALLOW_FORMAT; then
        echo "[ERROR] mount -a 失败且禁止格式化" 1>&2; exit 1
      fi
      echo "[WARN] 挂载失败，尝试重新初始化为 ext4..."
      umount -f "$MOUNT_POINT" >/dev/null 2>&1 || true
      mkfs.ext4 -F "$TARGET_BLOCK"
      UUID=$(blkid -s UUID -o value "$TARGET_BLOCK")
      tmpfstab=$(mktemp)
      grep -Ev "(^[^#].*[[:space:]]$MOUNT_POINT[[:space:]]|^[[:space:]]*${TARGET_BLOCK//\//\\/}[[:space:]])" /etc/fstab > "$tmpfstab" || true
      printf "UUID=%s %s ext4 defaults,noatime 0 2\n" "$UUID" "$MOUNT_POINT" >> "$tmpfstab"
      mv "$tmpfstab" /etc/fstab
      mount -a || true
    fi
    echo "[OK] 磁盘挂载成功"
  fi
fi

if $MOUNT_ONLY; then
  echo "[INFO] 仅挂载模式完成，退出"
  exit 0
fi

# ==================== Debian 12 Docker CE 安装 ====================
if $SKIP_DOCKER; then
  echo "[INFO] 跳过 Docker 安装流程"
else
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] 检测到已安装 Docker，跳过安装步骤"
  else
    echo "[INFO] 开始在 Debian 12 (amd64) 上配置源并安装 Docker..."
    
    # 1. 卸载可能冲突的旧版本
    for pkg in docker.io docker-doc docker-compose podman-docker container-snapshot; do 
      apt-get remove -y $pkg >/dev/null 2>&1 || true
    done
    
    # 2. 安装必要的基础工具
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    # 3. 配置 Docker 官方 GPG 密钥和 APT 源（默认使用阿里镜像源加速）
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.gpg
    
    DOCKER_SOURCE_URL="https://mirrors.aliyun.com/docker-ce"
    if ! $DOCKER_ALIYUN_ONLY; then
      # 如果没强制阿里源，可测速或直接采用阿里源（国内最稳定）
      DOCKER_SOURCE_URL="https://mirrors.aliyun.com/docker-ce"
    fi

    curl -fsSL "${DOCKER_SOURCE_URL}/linux/debian/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_SOURCE_URL}/linux/debian \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 4. 执行安装
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # 5. 配置 cgroupfs 驱动（保持你原脚本的业务需求）
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
JSON

    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker
    echo "[OK] Docker 安装配置完成"
  fi
fi

if $DOCKER_ONLY; then
  echo "[INFO] --docker-only 模式完成，退出"
  exit 0
fi

# ==================== 统一固定业务部署命令 ====================
echo "[INFO] 开始部署业务组件..."
cd /root || cd /tmp

# 下载组件（增加对 debian 自带 curl/wget 的兼容）
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 $WGET_IP_FLAG -O ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  wget --tries=2 --timeout=8 $WGET_IP_FLAG -O ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
elif command -v curl >/dev/null 2>&1; then
  curl $CURL_IP_FLAG --retry 2 --connect-timeout 5 -fsSL -o ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64 || \
  curl $CURL_IP_FLAG --retry 2 --connect-timeout 5 -fsSL -o ttmanager http://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
else
  apt-get update && apt-get install -y curl
  curl $CURL_IP_FLAG --retry 2 -fsSL -o ttmanager https://tiptime-api.com/cdn/ttmanager2/1.18.17/ttmanager_amd64
fi
chmod +x ttmanager || true

# 下载 config.yaml
if command -v wget >/dev/null 2>&1; then
  wget --tries=2 --timeout=8 $WGET_IP_FLAG -O config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || true
else
  curl $CURL_IP_FLAG --retry 2 -fsSL -o config.yaml https://tiptime-api.com/cdn/config_example/config.yaml || true
fi

./ttmanager -g || true

# 组装启动参数
TT_RUN_ARGS=()
[[ -n "${RUN_CH:-}" ]] && TT_RUN_ARGS+=(-ch "$RUN_CH")
[[ -n "${RUN_TYPE:-}" ]] && TT_RUN_ARGS+=(-t "$RUN_TYPE")
$ENABLE_MOUNT && TT_RUN_ARGS+=(-c "$MOUNT_POINT")
[[ -n "${RUN_UID:-}" ]] && TT_RUN_ARGS+=(-uid "$RUN_UID")

echo "[INFO] 启动 ttrun.sh 参数: ${TT_RUN_ARGS[*]}"
nohup ./ttrun.sh "${TT_RUN_ARGS[@]}" >/dev/null 2>&1 &

# 拼接开机命令串
TT_RUN_CMD="./ttrun.sh"
[[ -n "${RUN_CH:-}" ]] && TT_RUN_CMD+=" -ch $(printf '%q' "$RUN_CH")"
[[ -n "${RUN_TYPE:-}" ]] && TT_RUN_CMD+=" -t $(printf '%q' "$RUN_TYPE")"
$ENABLE_MOUNT && TT_RUN_CMD+=" -c $(printf '%q' "$MOUNT_POINT")"
[[ -n "${RUN_UID:-}" ]] && TT_RUN_CMD+=" -uid $(printf '%q' "$RUN_UID")"
TT_RUN_REMOVE_REGEX='ttrun\.sh.*-t[[:space:]]+[^[:space:]]+'

# 1. 写入 crontab 开机自启（Debian 完美支持 @reboot）
if command -v crontab >/dev/null 2>&1 || apt-get install -y cron; then
  systemctl enable cron || true
  systemctl start cron || true
  CRON_LINE="@reboot cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &"
  tmp_cron="$(mktemp)"
  (crontab -l 2>/dev/null || true) | grep -Ev "$TT_RUN_REMOVE_REGEX" > "$tmp_cron" || true
  echo "$CRON_LINE" >> "$tmp_cron"
  crontab "$tmp_cron"
  rm -f "$tmp_cron"
fi

# 2. 写入 rc.local 双保险开机自启（针对 Debian 12 做了标准的 Systemd rc-local 兼容适配）
RC_LOCAL="/etc/rc.local"
if [[ ! -f "$RC_LOCAL" ]]; then
  echo '#!/bin/sh -e' > "$RC_LOCAL"
  echo 'exit 0' >> "$RC_LOCAL"
fi
chmod +x "$RC_LOCAL"

tmp_rc_local="$(mktemp)"
# 在 exit 0 之前插入命令
grep -Ev "exit 0|$TT_RUN_REMOVE_REGEX" "$RC_LOCAL" > "$tmp_rc_local" || true
echo "cd /root && nohup ${TT_RUN_CMD} >/dev/null 2>&1 &" >> "$tmp_rc_local"
echo "exit 0" >> "$tmp_rc_local"
mv "$tmp_rc_local" "$RC_LOCAL"
chmod +x "$RC_LOCAL"

# 确保 Debian 12 的 rc-local 服务加载成功
if [[ -f /lib/systemd/system/rc-local.service ]]; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable rc-local >/dev/null 2>&1 || true
  systemctl start rc-local >/dev/null 2>&1 || true
fi

echo "[OK] 全流程执行完毕！"