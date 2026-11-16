#!/bin/bash
# 体检任意磁盘镜像（qcow2/raw/vmdk/vdi…），判断它能不能直接当 OpenStack 镜像用。
# 只读挂载，不改任何东西。用法： inspect-image.sh <image> [--json]
# 退出码：0 = 没发现明显问题；1 = 有 WARN；2 = 有 FAIL
set -uo pipefail

IMG=${1:?usage: inspect-image.sh <image> [--json]}
JSON=${2:-}
[ "$(id -u)" = 0 ] || { echo "need root (nbd + mount)"; exit 1; }
[ -r "$IMG" ] || { echo "no such image: $IMG"; exit 1; }
command -v qemu-nbd >/dev/null || { echo "install qemu-utils/qemu-tools"; exit 1; }

NBDS=$(for i in $(seq 0 15); do [ ! -e /sys/block/nbd$i/pid ] && { echo $i; break; }; done)
NBD=/dev/nbd$NBDS
M=$(mktemp -d /mnt/inspect.XXXXXX)
FAILN=0; WARN=0
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILN=$((FAILN+1)); }
val()  { printf '  %-26s %s\n' "$1" "$2"; }

cleanup() {
    set +e
    for d in dev/pts dev proc sys run boot ""; do umount "$M${d:+/$d}" 2>/dev/null; done
    [ -n "${ROOTPART:-}" ] && { umount "$M/boot" 2>/dev/null; umount "$M" 2>/dev/null; }
    rmdir "$M" 2>/dev/null
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
}
trap cleanup EXIT

modprobe nbd max_part=16 2>/dev/null
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
qemu-nbd -c "$NBD" -r "$IMG" || { echo "qemu-nbd failed"; exit 1; }
sleep 1

hdr "metadata"
qemu-img info "$IMG" | sed -n '1,8p' | sed 's/^/  /'
BACKING=$(qemu-img info "$IMG" | sed -n 's/^backing file: //p')
[ -n "$BACKING" ] && warn "有 backing file（$BACKING）—— 分发前必须自己 qemu-img convert 掉"

hdr "partitions"
sfdisk -d "$NBD" 2>/dev/null | sed 's/^/  /' 
lsblk -lno NAME,SIZE,TYPE,FSTYPE,LABEL,PARTTYPENAME "$NBD" 2>/dev/null | sed 's/^/  /'

# 找根分区：优先带 rootfs 标签的 ext4/xfs，否则最大的 linux 数据分区
ROOTPART=$(lsblk -lno NAME,FSTYPE,PARTTYPENAME "$NBD" 2>/dev/null |
           awk '$2!="" && $2!="vfat" {print $1}' | tail -1)
ROOTPART=$(basename "$ROOTPART")
[ -z "$ROOTPART" ] && { echo "找不到可挂的根分区"; exit 2; }
BOOTPART=$(lsblk -lno NAME,FSTYPE "$NBD" 2>/dev/null | awk '$2=="vfat"{print $1}' | head -1 | xargs -r basename)

# 脏文件系统（needs_recovery）会拒绝 ro 挂载，用 norecovery 读最后提交状态
mount -o ro "/dev/$ROOTPART" "$M" 2>/dev/null ||
    mount -o ro,norecovery "/dev/$ROOTPART" "$M" 2>/dev/null ||
    { bad "根分区挂不上（文件系统脏？先 e2fsck -fp /dev/$ROOTPART）"; exit 2; }
if [ -n "$BOOTPART" ]; then
    mkdir -p "$M/boot"
    mount -o ro "/dev/$BOOTPART" "$M/boot" 2>/dev/null || true
fi
R="$M"

hdr "OS"
val "os-release" "$(. "$R/etc/os-release" 2>/dev/null; echo "${PRETTY_NAME:-?}")"
val "kernel"      "$(ls "$R"/boot/vmlinuz-* 2>/dev/null | head -1 | xargs -r basename)"
val "efi"         "$([ -d "$R/boot/efi" ] || [ -d "$R"/boot/EFI ] || ls "$R"/boot/efi/EFI >/dev/null 2>&1 && echo yes || echo no)"
val "fstab"       "$(grep -vE '^\s*#|^$' "$R/etc/fstab" 2>/dev/null | tr '\n' ' ')"

hdr "cloud-init 栈"
if [ -e "$R/usr/bin/cloud-init" ] || [ -e "$R/usr/lib/python3*/site-packages/cloudinit" ]; then
    ok "cloud-init 已安装"
    DL=$(grep -rhs '^datasource_list' "$R"/etc/cloud/cloud.cfg "$R"/etc/cloud/cloud.cfg.d/ 2>/dev/null | tail -1)
    [ -n "$DL" ] && val "datasource_list" "$DL" || warn "没配 datasource_list（会盲探，非云环境卡 2 分钟）"
    [ -e "$R/etc/cloud/cloud-init.disabled" ] && bad "存在 /etc/cloud/cloud-init.disabled"
    [ -n "$(ls -A "$R/var/lib/cloud" 2>/dev/null)" ] && warn "/var/lib/cloud 非空（镜像被跑过，克隆会带实例状态）"
else
    bad "没有 cloud-init：注入不了 SSH 公钥 / hostname / 密码"
fi
if [ -x "$R/usr/bin/growpart" ] || [ -x "$R/usr/sbin/growpart" ] || [ -x "$R/sbin/growpart" ]; then
    ok "growpart 在（首启能扩根分区）"
else
    bad "没有 cloud-utils-growpart：flavor 磁盘比镜像大时根分区不会自动扩"
fi
[ -x "$R/usr/bin/qemu-ga" ] || [ -x "$R/usr/sbin/qemu-ga" ] && ok "qemu-guest-agent 在" \
    || bad "没有 qemu-guest-agent：nova 看不到 IP / 改不了密码 / 只能硬关机"

hdr "身份与凭据"
MIDB=$(stat -c %s "$R/etc/machine-id" 2>/dev/null || echo missing)
if [ "$MIDB" = 0 ] || [ "$MIDB" = missing ]; then ok "machine-id 空的（首启会生成）"
else bad "machine-id 已固化（$MIDB 字节）：所有克隆实例 ID 相同"; fi
HK=$(ls "$R"/etc/ssh/ssh_host_* 2>/dev/null | wc -l)
[ "$HK" = 0 ] && ok "无 ssh host key（首启生成）" || bad "带 $HK 个 ssh host key：所有实例共用同一主机指纹"
RS=$(grep '^root:' "$R/etc/shadow" 2>/dev/null | cut -d: -f2)
case "$RS" in
    '!'*|'*'*) ok "root 密码已锁（只走公钥）" ;;
    '') warn "root 密码为空！" ;;
    *) bad "root 有预设密码哈希：公开镜像等于后门" ;;
esac
PRL=$(grep -rhs '^PermitRootLogin' "$R"/etc/ssh/sshd_config "$R"/etc/ssh/sshd_config.d/ 2>/dev/null | head -1)
val "PermitRootLogin" "${PRL:-<默认 prohibit-password>}"
if [ -s "$R/etc/resolv.conf" ] && ! [ -L "$R/etc/resolv.conf" ]; then
    warn "/etc/resolv.conf 是静态文件：$(tr '\n' ' ' < "$R/etc/resolv.conf")  —— 内网大概率不通"
elif [ -L "$R/etc/resolv.conf" ]; then
    ok "resolv.conf 是软链（由 NM/systemd-resolved 托管）"
else
    ok "resolv.conf 空（交给 DHCP/NM）"
fi
[ -e "$R/etc/hostname" ] && val "/etc/hostname" "$(cat "$R/etc/hostname")"

hdr "启动"
GD="$R/etc/default/grub"; [ -f "$GD" ] || GD="$R/etc/sysconfig/grub"
[ -f "$GD" ] && val "cmdline" "$(grep -h '^GRUB_CMDLINE_LINUX=' "$GD" | cut -d'"' -f2)"
case "$(grep -h '^GRUB_CMDLINE_LINUX=' "$GD" 2>/dev/null)" in
    *console=ttyS0*) ok "有 console=ttyS0（nova console-log 能看到东西）" ;;
    *) warn "cmdline 没有 console=ttyS0（串口控制台没输出）" ;;
esac
case "$(grep -h '^GRUB_CMDLINE_LINUX=' "$GD" 2>/dev/null)" in
    *crashkernel=*) bad "cmdline 带 crashkernel=（白占内存，除非真要 kdump）" ;;
esac
grep -q 'rd.shell=0' "$GD" 2>/dev/null && warn "rd.shell=0：initramfs 排障时进不去 shell"
GRUBPW=$(grep -rl 'password_pbkdf2 root grub' "$R"/etc/grub.d/ 2>/dev/null | sed "s|$R||")
if [ -n "$GRUBPW" ]; then
    bad "grub 里硬编码了密码（$GRUBPW）：控制台改不了内核参数"
fi
TCPW=$(grep -c 'set timeout=' "$R/boot/grub2/grub.cfg" 2>/dev/null || echo 0)
[ -d "$R/boot/grub2/i386-pc" ] && ok "有 i386-pc 模块（BIOS 能起）" || warn "没 i386-pc：只能 UEFI 起"
{ [ -d "$R/boot/efi/EFI" ] || [ -d "$R/boot/EFI" ]; } && ok "有 EFI 目录（UEFI 能起）" || warn "没有 ESP/EFI：只能 BIOS 起"
INITRD=$(ls "$R"/boot/initramfs-*.img "$R"/boot/initrd.img-* 2>/dev/null | head -1)
# initramfs 是（可能 zstd/xz 压缩的）cpio，模块名只在归档的路径里，得先列出来
initramfs_list() {
    local f=$1 d
    if command -v lsinitrd >/dev/null; then lsinitrd "$f" 2>/dev/null && return 0; fi
    if command -v unmkinitramfs >/dev/null; then
        d=$(mktemp -d); unmkinitramfs "$f" "$d" >/dev/null 2>&1
        ( cd "$d" && find . -mindepth 1 ) 2>/dev/null; rm -rf "$d"; return 0
    fi
    # 退化：整体当成一个 cpio 流
    ( command -v zstdcat >/dev/null && zstdcat "$f" 2>/dev/null ||
      command -v xzcat   >/dev/null && xzcat   "$f" 2>/dev/null ||
      gzip -dc "$f" 2>/dev/null ) | cpio -t 2>/dev/null
}
if [ -n "$INITRD" ]; then
    IRL=$(initramfs_list "$INITRD")
    if [ -z "$IRL" ]; then warn "initramfs 内容列不出来（缺 lsinitrd/unmkinitramfs），跳过 virtio 检查"
    elif case "$IRL" in *virtio_blk*) true ;; *) false ;; esac; then ok "initramfs 里有 virtio_blk（virtio 盘能引导）"
    else bad "initramfs 里没有 virtio_blk：virtio 盘会 kernel panic（hostonly initramfs 忘了通用驱动）"; fi
else
    warn "找不到 initramfs（容器/特殊发行版？）"
fi
[ -e "$R/etc/systemd/system/multi-user.target.wants/kdump.service" ] && bad "kdump.service 默认启用" || ok "kdump 未启用"

hdr "首启服务"
ls "$R"/etc/systemd/system/multi-user.target.wants/ 2>/dev/null | sed 's/^/  /'
for u in sshd ssh; do
    [ -e "$R/etc/systemd/system/multi-user.target.wants/$u.service" ] && ok "$u 已 enable" 
done
[ -e "$R/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" ] \
    && ok "serial-getty@ttyS0 已 enable" || warn "serial-getty@ttyS0 没显式 enable（若 cmdline 有 console=ttyS0，systemd 会自动建，通常没事）"
{ [ -x "$R/usr/sbin/chronyd" ] || [ -x "$R/usr/sbin/ntpd" ] || [ -x "$R/lib/systemd/systemd-timesyncd" ]; } \
    && ok "有 NTP 客户端" || bad "没有任何 NTP 客户端：时间会漂"

hdr "清理痕迹"
[ -e "$R/root/.bash_history" ] && bad "有 /root/.bash_history" || ok "无 bash_history"
L=$(ls "$R"/var/log/*.log "$R"/var/log/messages "$R"/var/log/dnf*.log 2>/dev/null | wc -l)
[ "$L" = 0 ] && ok "/var/log 干净" || warn "/var/log 有 $L 个日志文件（可选清理）"
[ -n "$(ls -A "$R"/var/lib/NetworkManager 2>/dev/null)" ] && warn "/var/lib/NetworkManager 有旧 lease（含 MAC）" || true
[ -n "$(ls -A "$R"/etc/NetworkManager/system-connections 2>/dev/null)" ] \
    && ok "有 NetworkManager 连接配置" || warn "无 NM 连接配置（靠 NM 自动建，通常可用）"

hdr "磁盘/分区可扩"
if [ -f "$R/etc/fstab" ]; then
    grep -q 'by-uuid\|UUID=' "$R/etc/fstab" && ok "fstab 用 UUID（换设备名不影响）" || warn "fstab 用设备名，可能起不来"
    grep -qE '^\s*[^#].*\bswap\b' "$R/etc/fstab" && warn "fstab 有 swap 分区（flavor 磁盘变了会对不上）"
fi

hdr "结论"
if [ $FAILN -eq 0 ] && [ $WARN -eq 0 ]; then say "  ✔ 看起来可以直接当 OpenStack 镜像用"
else say "  $FAILN 个 FAIL / $WARN 个 WARN —— 见上面红/黄项"; fi
say "  下一步：见 SKILL.md「必改清单」，改完用 mk-configdrive.sh + 起一次的验证流程"
[ -n "$JSON" ] && say "  (JSON 输出未实现)"
exit $([ $FAILN -gt 0 ] && echo 2 || ([ $WARN -gt 0 ] && echo 1 || echo 0))
