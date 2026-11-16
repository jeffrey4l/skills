#!/bin/bash
# 用 qemu-nbd + chroot 改镜像里的文件（不启动虚拟机）。
#
#   chroot-image.sh mount  <image>          # 只读挂载 + bind /dev /proc /sys /run，打印挂载点
#   chroot-image.sh mount  <image> --rw     # 可写挂载（要改东西用这个）
#   chroot-image.sh shell  <image>          # 挂可写 + 进 chroot 交互 shell，退出来自动卸载
#   chroot-image.sh umount [/mnt/cloud-image]
#   chroot-image.sh run    <image> <cmd...>  # 挂可写 → chroot 执行命令 → 卸载
#
# 注意：qcow2/raw/vmdk 都行；会挑一个空闲的 /dev/nbdN。
set -euo pipefail

STATE_DIR=/run/cloud-image
STATE=$STATE_DIR/state
M=/mnt/cloud-image

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "need root (nbd + mount)"

pick_nbd() {
    for i in $(seq 0 15); do
        [ -e "/sys/block/nbd$i/pid" ] || { echo "/dev/nbd$i"; return; }
    done
    die "no free /dev/nbdN (modprobe nbd max_part=16)"
}

do_mount() {
    local img=$1 rw=${2:-ro}; rw=${rw#--}
    [ -r "$img" ] || die "no such image: $img"
    modprobe nbd max_part=16 2>/dev/null || true
    local nbd; nbd=$(pick_nbd)
    qemu-nbd -c "$nbd" $( [ "$rw" = ro ] && echo -r ) "$img"
    sleep 1
    # 根分区 = 最后一个非 vfat 分区；vfat 分区（若有）挂到 /boot
    local root boot
    root=$(basename "$(lsblk -lno NAME,FSTYPE "$nbd" | awk '$2!="" && $2!="vfat"{print $1}' | tail -1)")
    boot=$(basename "$(lsblk -lno NAME,FSTYPE "$nbd" | awk '$2=="vfat"{print $1}' | head -1)")
    [ -n "$root" ] || { qemu-nbd --disconnect "$nbd" >/dev/null; die "no usable root partition"; }
    mkdir -p "$M" "$M/boot"
    if [ "$rw" = rw ]; then
        mount "/dev/$root" "$M"
    else
        mount -o ro "/dev/$root" "$M" 2>/dev/null ||
            mount -o ro,norecovery "/dev/$root" "$M"
    fi
    [ -n "$boot" ] && mount "$( [ "$rw" = ro ] && echo -o ro )" "/dev/$boot" "$M/boot" 2>/dev/null || true
    mkdir -p "$M"/{dev,dev/pts,proc,sys,run}
    mount --bind /dev "$M/dev"; mount --bind /dev/pts "$M/dev/pts"
    mount -t proc proc "$M/proc"; mount --bind /sys "$M/sys"; mount --bind /run "$M/run"
    mkdir -p "$STATE_DIR"
    # chroot 里要能解析域名（装包用）；退出时恢复原内容
    if [ -f "$M/etc/resolv.conf" ] && [ ! -L "$M/etc/resolv.conf" ]; then
        cp -a "$M/etc/resolv.conf" "$STATE_DIR/resolv.conf.bak"
    fi
    cp /etc/resolv.conf "$M/etc/resolv.conf" 2>/dev/null || true
    printf 'NBD=%s\nM=%s\nRW=%s\n' "$nbd" "$M" "$rw" > "$STATE"
    echo "$M"
}

do_umount() {
    local m=${1:-$M}
    [ -f "$STATE" ] && . "$STATE"
    sync
    for d in dev/pts dev proc sys run boot ""; do
        umount "$m${d:+/$d}" 2>/dev/null || true
    done
    if mountpoint -q "$m"; then
        echo "!! $m 还在忙，别硬拆 nbd（会丢数据/坏文件系统）。占用者：" >&2
        fuser -vm "$m" >&2 || true
        exit 1
    fi
    if [ -f "$STATE_DIR/resolv.conf.bak" ] && [ -n "${M:-}" ]; then
        cp -a "$STATE_DIR/resolv.conf.bak" "$M/etc/resolv.conf" 2>/dev/null || true
        rm -f "$STATE_DIR/resolv.conf.bak"
    fi
    [ -n "${NBD:-}" ] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
    rm -f "$STATE"
    echo "unmounted $m"
}

case "${1:-}" in
    mount)  shift; do_mount "$@" ;;
    umount) shift; do_umount "${1:-$M}" ;;
    shell)
        img=$2; do_mount "$img" rw >/dev/null
        echo "chroot at $M — 退出后自动卸载（改完记得清理 machine-id / ssh host key / 日志）"
        chroot "$M" /bin/bash -i || true
        do_umount
        ;;
    run)
        img=$2; shift 2
        do_mount "$img" rw >/dev/null
        set +e
        chroot "$M" "$@"
        rc=$?
        set -e
        do_umount
        exit $rc
        ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \?//' ; exit 1 ;;
esac
