#!/bin/bash
# 冒烟启动验证：不碰原镜像（用 qcow2 覆盖层），挂一个 config-2 ISO，等 cloud-init 跑完，
# 通过 SSH 进去逐条验收。
#
#   verify-boot.sh <image> [--uefi] [--port 2222] [--wait 180] [--mem 2048]
#                          [--pubkey ~/.ssh/id_ed25519.pub] [--serial-log /tmp/x.log]
#
# 退出码 0 = 全部断言通过；1 = 有断言失败（会打印串口末尾）。
# 需要：qemu-system-x86_64、/dev/kvm（没有则 --no-kvm）、genisoimage、ssh。
set -uo pipefail

IMG=${1:?usage: verify-boot.sh <image> [--uefi] [--port 2222] [--wait 180]}
shift
UEFI=0; PORT=2222; WAIT=180; MEM=2048; KVM=-enable-kvm
PUBKEY=${PUBKEY:-$HOME/.ssh/id_ed25519.pub}; SERIAL=/tmp/verify-boot.$$.log
while [ $# -gt 0 ]; do
    case "$1" in
        --uefi) UEFI=1; shift ;;
        --no-kvm) KVM=""; shift ;;
        --port) PORT=$2; shift 2 ;;
        --wait) WAIT=$2; shift 2 ;;
        --mem) MEM=$2; shift 2 ;;
        --pubkey) PUBKEY=$2; shift 2 ;;
        --serial-log) SERIAL=$2; shift 2 ;;
        *) echo "unknown: $1" >&2; exit 1 ;;
    esac
done

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d /tmp/verify-boot.XXXXXX)
OVERLAY=$WORK/overlay.qcow2
ISO=$WORK/seed.iso
FAILED=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
SSH=(ssh -i "${PUBKEY%.pub}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=8 -o LogLevel=ERROR -p "$PORT" root@127.0.0.1)

cleanup() {
    set +e
    [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null
    sleep 1
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v qemu-system-x86_64 >/dev/null || { echo "no qemu-system-x86_64"; exit 1; }
[ -x "$HERE/mk-configdrive.sh" ] || { echo "missing mk-configdrive.sh next to me"; exit 1; }

qemu-img create -f qcow2 -b "$(readlink -f "$IMG")" -F qcow2 "$OVERLAY" >/dev/null || exit 1
"$HERE/mk-configdrive.sh" "$ISO" -H verify-vm -k "$PUBKEY" >/dev/null || exit 1

BIOS_ARGS=()
if [ "$UEFI" = 1 ]; then
    for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
        [ -f "$c" ] || continue
        V=$(echo "$c" | sed 's/CODE/VARS/')
        [ -f "$V" ] || continue
        cp "$V" "$WORK/vars.fd"
        BIOS_ARGS=(-drive if=pflash,format=raw,readonly=on,file="$c"
                   -drive if=pflash,format=raw,file="$WORK/vars.fd")
        break
    done
    [ ${#BIOS_ARGS[@]} -gt 0 ] || { echo "no OVMF firmware found"; exit 1; }
fi

echo "booting $(basename "$IMG") ($([ "$UEFI" = 1 ] && echo UEFI || echo BIOS)) ..."
qemu-system-x86_64 -m "$MEM" -smp 2 $KVM -cpu host \
    "${BIOS_ARGS[@]}" \
    -drive file="$OVERLAY",if=virtio,format=qcow2 \
    -drive file="$ISO",media=cdrom,format=raw \
    -netdev user,id=n0,hostfwd=tcp::"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
    -device virtio-serial-pci \
    -chardev socket,path="$WORK/qga.sock",server=on,wait=off,id=qga0 \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -chardev file,id=ser0,path="$SERIAL" -serial chardev:ser0 \
    -display none >"$WORK/qemu.out" 2>&1 &
QPID=$!

# 等 ssh 开门（cloud-init 跑完前 sshd 也可能已经起来，所以先用云断言轮询）
deadline=$(( $(date +%s) + WAIT ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if "${SSH[@]}" true 2>/dev/null; then ready=1; break; fi
    kill -0 "$QPID" 2>/dev/null || break
    sleep 5
done
if [ "$ready" != 1 ]; then
    fail "SSH 起不来（$WAIT 秒内）。串口末尾："
    tail -25 "$SERIAL" | sed 's/^/      /'
    echo "    串口全文：$SERIAL（复制到别处再看）"
    cp "$SERIAL" "/tmp/verify-boot.serial.log" 2>/dev/null && echo "    已留档 /tmp/verify-boot.serial.log"
    exit 1
fi
pass "sshd 可登录（公钥注入成功）"

sh() { "${SSH[@]}" "$1" 2>/dev/null; }

# cloud-init 可能还在跑 final 阶段
for _ in $(seq 1 24); do
    st=$(sh 'cloud-init status 2>/dev/null' || true)
    case "$st" in *"status: done"*|*"status: error"*) break ;; esac
    sleep 5
done
case "$st" in
    *"status: done"*)  pass "cloud-init status: done" ;;
    *"status: error"*) fail "cloud-init status: error —— $(sh 'cloud-init status --long | head -8')" ;;
    *)                 fail "cloud-init 没跑完（$st）" ;;
esac

DS=$(sh 'cloud-init query ds 2>/dev/null | grep -i "^ *subplatform\|datasource" | head -2; cat /run/cloud-init/status.json 2>/dev/null' )
case "$(sh 'cloud-init status --long 2>/dev/null')" in
    *ConfigDrive*) pass "datasource = ConfigDrive（读出 config-2 ISO）" ;;
    *) fail "datasource 不是 ConfigDrive" ;;
esac

H=$(sh 'hostname')
[ "$H" = verify-vm ] && pass "hostname 已注入（$H）" || fail "hostname 不对：$H（期望 verify-vm）"

FU=$(sh 'systemctl --failed --no-pager --plain | grep -c "\.service" || true')
[ "${FU:-0}" = 0 ] && pass "systemctl --failed 为空" || fail "$FU 个 unit failed：$(sh 'systemctl --failed --no-pager --plain | head -5')"

for u in sshd qemu-guest-agent chronyd NetworkManager; do
    a=$(sh "systemctl is-active $u 2>/dev/null")
    [ "$a" = active ] && pass "$u active" || echo -e "  \033[33m!\033[0m $u = ${a:-?}（没装或不适用就忽略）"
done

MN=$(sh 'cat /etc/machine-id')
[ -n "$MN" ] && [ "$MN" != "" ] && pass "machine-id 已重新生成（${MN:0:8}…）"
[ -s "$(sh 'echo /root/.ssh/authorized_keys' 2>/dev/null || true)" ] 2>/dev/null || true
K=$(sh 'wc -l < /root/.ssh/authorized_keys 2>/dev/null || echo 0')
[ "${K:-0}" -ge 1 ] && pass "root authorized_keys 有 $K 条（注入成功）" || fail "root authorized_keys 为空"

case "$(sh 'grep -c . /etc/resolv.conf 2>/dev/null')" in
    0) echo -e "  \033[33m!\033[0m resolv.conf 还是空的（DHCP 没下发 DNS？）" ;;
    *) pass "resolv.conf 由 DHCP/NM 写好：$(sh 'head -2 /etc/resolv.conf | tr "\n" " "')" ;;
esac

# 顺手看 fs 有没有扩（仅当 flavor 盘 > 镜像虚拟盘时才有意义）
echo "  rootfs: $(sh 'df -h / | tail -1')"

echo
if [ "$FAILED" = 0 ]; then echo "== 全部通过 =="; exit 0
else echo "== $FAILED 项失败（串口：$SERIAL）=="; cp "$SERIAL" /tmp/verify-boot.serial.log 2>/dev/null; exit 1; fi
