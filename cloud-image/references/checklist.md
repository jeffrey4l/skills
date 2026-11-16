# 必改清单 · 分发行版命令

在 `chroot-image.sh shell img.qcow2` 里执行（或写成脚本用 `chroot-image.sh run` 跑）。
`$R` 一律指你当前所在的环境（已经 chroot 进镜像了，所以就是 `/`）。

## 包管理器前缀

```bash
# RHEL 系（openEuler / CentOS / Rocky / Alma / Fedora）
dnf --disablerepo=debuginfo --disablerepo=source --disablerepo=update-source install -y ...
# Debian 系（Ubuntu / Debian）
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ...
# SUSE
zypper --non-interactive install ...
```

## 1. cloud-init + growpart + guest agent + NTP

```bash
dnf install -y cloud-init cloud-utils-growpart qemu-guest-agent chrony hostname tar
# Debian: apt install -y cloud-init cloud-guest-utils qemu-guest-agent chrony
# SUSE:   zypper in -y cloud-init cloud-utils-growpart qemu-guest-agent chrony

systemctl enable cloud-init cloud-init-local cloud-config cloud-final
systemctl enable chronyd          # Debian: systemctl enable chrony ／ 或 systemd-timesyncd
```

`hostname` 包不是凑数：cloud-init 的 `update_hostname` 会调 `hostname(1)`，
RHEL 系最小化安装里**没有**这个命令，日志会写
`ProcessExecutionError: ... 'hostname': No such file or directory`，然后整个 module 失败。

## 2. datasource（放 cloud.cfg.d，别改 cloud.cfg 本体）

`/etc/cloud/cloud.cfg.d/99-cloud-image.cfg`

```yaml
datasource_list: [ 'ConfigDrive', 'OpenStack', 'Ec2' ]
# 想兼容 virt-manager 自带 cloud-init（NoCloud/cidata）就加 'NoCloud'
# 想非云环境不卡元数据探测，就在最后加 'None'
disable_root: false
ssh_pwauth: false
ssh_deletekeys: true
ssh_genkeytypes: [ rsa, ecdsa, ed25519 ]
users:
  - name: root
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys: []
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
manage_etc_hosts: true      # 需要 /etc/cloud/templates/hosts.<osfamily>.tmpl 存在
```

`manage_etc_hosts: true` 的前提是模板在：RHEL 系是
`/etc/cloud/templates/hosts.redhat.tmpl`，openEuler 镜像**一个模板都没有**，得自己放
`hosts.openeuler.tmpl`（`datasource_list` 之外的另一个隐形坑）。

## 3. qemu-guest-agent 的 enable 陷阱

```bash
grep -A3 '^\[Install\]' /usr/lib/systemd/system/qemu-guest-agent.service
# 若 [Install] 段是空的：
ln -sf /usr/lib/systemd/system/qemu-guest-agent.service \
       /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
```

## 4. 内核 cmdline / grub

```bash
# 只改一个源文件，然后两边同步（有的发行版 /etc/default/grub 和 /etc/sysconfig/grub 是两份拷贝）
sed -i -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' \
       -e 's/ crashkernel=[^ "]*//' \
       -e 's/  */ /g' /etc/default/grub
# 确保 GRUB_CMDLINE_LINUX 里有 console=ttyS0（已有 console=tty1 就都留着）：
#   GRUB_CMDLINE_LINUX="console=tty1 console=ttyS0"
grub2-mkconfig -o /boot/grub2/grub.cfg
[ -f /boot/efi/EFI/*/grub.cfg ] && cp -f /boot/grub2/grub.cfg /boot/efi/EFI/*/grub.cfg
# Debian: update-grub；ESP 上那份要一起更新

# 拆掉硬编码密码（厂商构建残留），顺便 disable 会写回它的首启服务
python3 - <<'PY'
import re, glob
for p in glob.glob('/etc/grub.d/*'):
    s = open(p).read()
    s2 = re.sub(r'cat <<EOF\nset superusers="?root"?\npassword_pbkdf2 [^\n]*\nEOF\n', '', s)
    if s2 != s: open(p, 'w').write(s2); print('cleaned', p)
PY
rm -f /boot/grub2/user.cfg /boot/efi/EFI/*/user.cfg
systemctl disable kdump    2>/dev/null || true
systemctl disable openEuler-security harden-security-cloud-init 2>/dev/null || true
```

## 5. 身份清理

```bash
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id /etc/hostname
rm -f /etc/ssh/ssh_host_*
: > /etc/resolv.conf                       # 交给 NM/DHCP
rm -rf /var/lib/cloud/* /var/lib/NetworkManager/* /etc/NetworkManager/system-connections/*
rm -f /etc/udev/rules.d/70-persistent-net.rules /var/lib/systemd/random-seed
rm -rf /var/log/journal/* ; find /var/log -maxdepth 1 -type f -delete
rm -f /root/.bash_history /home/*/.bash_history
dnf clean all ; rm -rf /var/cache/dnf/* /var/lib/dnf/history.sqlite*
passwd -l root
```

Debian 系没有 `/etc/machine-id` 就 `rm -f /var/lib/dbus/machine-id` 即可；
`netplan` 的镜像要把 `/etc/netplan/*.yaml` 里的固定 MAC 去掉（否则换了网卡起不来）。

## 6. sshd

```bash
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\nPasswordAuthentication yes\n' \
    > /etc/ssh/sshd_config.d/10-cloud-image.conf
sshd -t
```

sshd 的 `Include /etc/ssh/sshd_config.d/*.conf` 在最前面，**第一个匹配上的关键字生效**，
所以放 drop-in 才盖得住 `sshd_config` 里的设置。

## 7. 尺寸

```bash
# 缩小（离线做，先 e2fsck，再 resize2fs，最后动分区表和 qcow2 虚拟盘）
e2fsck -f /dev/nbd0p2 && resize2fs /dev/nbd0p2 9G
sfdisk --no-reread -N 2 /dev/nbd0 <<< 'start=4194304, size=18874367, type=83'
qemu-img resize --shrink img.qcow2 10G

# 瘦身（不改变内容）
virt-sparsify --format qcow2 in.qcow2 out.qcow2

# 转换
qemu-img convert -p -O qcow2 in.raw out.qcow2
qemu-img convert -p -O raw   in.qcow2 out.raw
```

经验值：glance 里 qcow2 虚拟盘 10G 起跳最常见；`--min-disk` 要写虚拟盘大小而不是文件大小。

## 8. 上传与注册

```bash
openstack image create --disk-format qcow2 --container-format bare --file img.qcow2 \
  --property hw_qemu_guest_agent=yes --property os_type=linux \
  --property img_config_drive=optional --property os_admin_user=root \
  --min-disk 10 --min-ram 512 my-image
openstack image set --property hw_disk_bus=virtio --property hw_scsi_model=virtio-scsi my-image
```

想让镜像强制走 UEFI：`--property hw_firmware_type=uefi`（同时 `--property hw_machine_type=q35`）。
