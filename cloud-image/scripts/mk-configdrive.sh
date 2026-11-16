#!/bin/bash
# 做一个 cloud-init 的 ConfigDrive v2 ISO（卷标 config-2），用于 virt-manager /
# 裸 qemu 本地起云镜像时注入 hostname、SSH 公钥、（可选）root 密码和 network_data。
#
#   ./make-configdrive.sh out.iso -H my-vm -k ~/.ssh/id_ed25519.pub
#   ./make-configdrive.sh out.iso -H my-vm -u user-data.yaml -p 'Passw0rd!'
#
# 挂载方式：当成 CD-ROM 塞给虚拟机即可（virt-manager: Add Hardware → Storage →
# Device type: CDROM；qemu: -drive file=out.iso,media=cdrom）
set -euo pipefail

OUT=""; HOST="oe-vm"; PUBKEY="${PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
USERDATA=""; ADMINPASS=""; AZ="nova"; NAME=""
UUID=$(cat /proc/sys/kernel/random/uuid)

usage() { sed -n '2,10p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage 0 ;;
        -H|--hostname) HOST=$2; shift 2 ;;
        -n|--name) NAME=$2; shift 2 ;;
        -k|--pubkey) PUBKEY=$2; shift 2 ;;
        -u|--user-data) USERDATA=$2; shift 2 ;;
        -p|--password) ADMINPASS=$2; shift 2 ;;
        -z|--az) AZ=$2; shift 2 ;;
        -*) echo "unknown option: $1" >&2; usage 1 ;;
        *) OUT=$1; shift ;;
    esac
done
[ -n "$OUT" ] || usage 1
: "${NAME:=$HOST}"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/openstack/latest"

PUBKEY="$PUBKEY" HOST="$HOST" NAME="$NAME" UUID="$UUID" AZ="$AZ" ADMINPASS="$ADMINPASS" \
python3 - "$WORK/openstack/latest/meta_data.json" <<'PY'
import json, os, sys
d = {
    "uuid": os.environ["UUID"],
    "name": os.environ["NAME"],
    "hostname": os.environ["HOST"],
    "launch_index": 0,
    "availability_zone": os.environ["AZ"],
    "meta": {},
}
keyfile = os.environ.get("PUBKEY") or ""
try:
    key = open(os.path.expanduser(keyfile)).read().strip()
    d["public_keys"] = {"default": key}
except OSError:
    print("warn: no ssh public key (%s), only password login will work" % keyfile,
          file=sys.stderr)
    d["public_keys"] = {}
if os.environ.get("ADMINPASS"):
    d["admin_pass"] = os.environ["ADMINPASS"]
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY

if [ -n "$USERDATA" ]; then
    cp "$USERDATA" "$WORK/openstack/latest/user_data"
else
    printf '#cloud-config\nssh_pwauth: %s\n' \
        "$([ -n "$ADMINPASS" ] && echo true || echo false)" \
        > "$WORK/openstack/latest/user_data"
fi

# 空的 vendor_data / network_data 不必给；需要固定 IP 时自己放 network_data.json

ISO=""
for tool in genisoimage mkisofs xorriso; do
    command -v "$tool" >/dev/null || continue
    case "$tool" in
        xorriso) xorriso -as mkisofs -quiet -volid config-2 -J -R -o "$OUT" "$WORK" ;;
        *)       "$tool" -quiet -volid config-2 -J -R -o "$OUT" "$WORK" ;;
    esac
    ISO=$tool; break
done
[ -n "$ISO" ] || { echo "need genisoimage / mkisofs / xorriso" >&2; exit 1; }

echo "wrote $OUT  (label=config-2, $ISO)"
echo "hostname=$HOST uuid=$UUID az=$AZ"
command -v blkid >/dev/null && blkid "$OUT" || true
echo "inside the guest, verify with:  cloud-init status --long  /  cloud-init query ds"
