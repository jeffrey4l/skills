---
name: cloud-image
description: 把 qcow2/raw/vmdk 等磁盘镜像改造成 OpenStack 云镜像（补 cloud-init/growpart/qemu-guest-agent/NTP、拆 grub 硬编码密码、清 machine-id 与 ssh host key、缩盘、ephemeral 分区对齐），并对改完的镜像做真启动验证。也用于体检「从网上下载的镜像能不能直接上云」「为什么实例起不来/拿不到 IP/hostname 改不掉」。当用户说「改造镜像」「做个 OpenStack 镜像」「qcow2 转 raw」「镜像里加 cloud-init」「镜像太大要缩小」「这个镜像有什么问题」「configdrive/seed iso 怎么配」时使用。
---

# cloud-image：把任意磁盘镜像变成能上云的 cloud image

输入一个 `qcow2`/`raw`/`vmdk`/`vdi`（例如从官网下的 `xxx-cloud.qcow2`、厂商给的 `xxx.raw`），
输出一个 **能在 OpenStack 里注入公钥、自动改 hostname、自动扩分区、nova 能看到 IP** 的镜像。

## 铁律

1. **先体检再动手**。`scripts/inspect-image.sh` 只读挂载，把问题一次列全，别边改边猜。
2. **永远改副本**。`cp --reflink=auto` 出一份再改；验证时再套一层 qcow2 覆盖层（`verify-boot.sh` 自动做），原镜像随时能重来。
3. **不启动就无法验证**。"文件都在"不等于能起——initramfs 有没有 virtio 驱动、grub 会不会要密码、cloud-init 会不会报 error，只有真启动能看出来。
4. **改完必须清身份**：machine-id、ssh host key、`/var/lib/cloud`、NM lease、日志、bash_history。漏一个，克隆出来的机器就全是双胞胎。

## 1. 体检

```bash
scripts/inspect-image.sh /path/to/img.qcow2      # 0=干净 1=有WARN 2=有FAIL
```

按输出分四类看：**cloud-init 栈**（能不能注入）、**身份与凭据**（会不会双胞胎/后门）、
**启动**（BIOS/UEFI 能不能起、串口有没有、grub 要不要密码、initramfs 有没有 virtio_blk）、
**首启服务**（sshd、NTP、kdump 是否白占内存）。

## 2. 必改清单（动手照这个顺序）

详细命令（dnf / apt / zypper 三套）见 [`references/checklist.md`](references/checklist.md)。

| # | 改什么 | 不改的后果 |
|---|---|---|
| 1 | 装 `cloud-init` + 配 `datasource_list`（`/etc/cloud/cloud.cfg.d/*.cfg`，**别改 cloud.cfg 本体**） | 注入不了公钥/hostname/密码 |
| 2 | 装 `cloud-utils-growpart`（或同功能 `growpart`） | flavor 磁盘更大时根分区不扩 |
| 3 | 装 `qemu-guest-agent`（注意官方 unit 常常**没有 `[Install]` 段**，得手拉软链） | nova 看不到 IP、改不了密码、只能硬关机 |
| 4 | 装 NTP 客户端（chrony / systemd-timesyncd 至少一个） | 时间漂，TLS/集群全歪 |
| 5 | cmdline 补 `console=ttyS0`（+ `console=tty1` 保图形） | `nova console-log` 空白，排障瞎 |
| 6 | 去掉 `crashkernel=` 并 disable `kdump` | 每台白扔 256M+ 内存 |
| 7 | 拆 grub 硬编码密码（`/etc/grub.d/*` 里的 `password_pbkdf2`），重建两份 cfg（BIOS + EFI） | 控制台改不了内核参数 |
| 8 | 清 `/etc/resolv.conf`（留空交给 DHCP/NM） | 写死的 DNS 在内网不通 → 全盘失联 |
| 9 | `machine-id` 清空、删 `/etc/ssh/ssh_host_*`、清 `/var/lib/cloud`、`/var/lib/NetworkManager`、`/etc/hostname` | 实例双胞胎 + 主机指纹重复 |
| 10 | root 锁定（`passwd -l root`）+ `PermitRootLogin prohibit-password` | 预设密码哈希等于后门 |
| 11 | 清日志/缓存/bash_history；关 `debuginfo`/`source` 仓库 | 信息泄露 + `dnf` 慢到离谱 |
| 12 | 看盘尺寸（见第 4 节） | flavor 磁盘小于虚拟盘大小时**创建直接失败** |

**额外的隐形坑**：厂商镜像常带一个"首次开机自查工具"（如 openEuler 的
`openEuler-security.service`、某些 `*-harden.service`），它会在**首启把 grub 密码写回去、
把 sysctl/权限改一遍**。第 7 步做完如果重启又冒出来，八成是它——把它也 disable。

## 3. 怎么改

### 推荐：qemu-nbd + chroot（可控、不依赖 libguestfs 网络）

```bash
scripts/chroot-image.sh shell img.qcow2        # 挂可写 + 进 chroot，退出自动卸载
# 或脚本化：
scripts/chroot-image.sh run img.qcow2 /root/prepare.sh
```

因为走的是宿主内核和宿主网络，`dnf install`/`apt install` 跟在自己机器上一样，
还能用本机 `systemctl enable`（离线改软链）。

### 不推荐：`virt-customize --install / --run-command`

libguestfs 的 appliance 用的是 slirp NAT，很多环境下 **DNS/出网都不通**，
症状是 `dnf` 报 `Couldn't resolve host name` 或 `Failed to connect ... port 7890`。
真要用就先确认 appliance 能上网（`virt-customize --network --run-command 'curl -sI https://...'`），
否则一律回退到 nbd+chroot。

### 清理身份（可选偷懒）

`virt-sysprep -a img.qcow2` 能一次干掉 machine-id、ssh host key、日志、cron 之类，
但它也会顺手删你不想要的东西（比如 `/etc/hostname`、`/var/spool`），还会重写 fstab。
**建议用它的 `--list-operations` 自己挑**，别整包跑。

## 4. 磁盘尺寸（最容易被忽略的一条）

- **太大**：虚拟盘 40G、flavor 磁盘 20G → glance 里能传，但创建实例直接失败。
  云镜像惯例是 **10G 虚拟盘 + 首启 growpart**。缩的步骤：

  ```bash
  qemu-img create -f qcow2 -b img.qcow2 -F qcow2 work.qcow2   # 先做副本
  scripts/chroot-image.sh mount work.qcow2 --rw               # 拿到 /dev/nbdN 分区
  e2fsck -f /dev/nbd0p2 && resize2fs /dev/nbd0p2 9G           # 先缩文件系统（离线！）
  # MBR: 用 sfdisk 把 p2 重写成 9G 结尾；GPT: 用 parted resizepart
  qemu-img resize --shrink work.qcow2 10G                     # 分区表末尾不能越界
  ```
- **太小**：不用改，装 growpart 让 cloud-init 首启扩。
- 顺手瘦身：`virt-sparsify --format qcow2 in out`（把空洞真释放），
  `qemu-img convert -O raw` 转裸盘给 Ceph/RBD 场景。**别用 `-c` 压缩**，镜像 I/O 会变慢。

## 5. 验证（不验证等于没做）

```bash
scripts/mk-configdrive.sh seed.iso -H my-vm -k ~/.ssh/id_ed25519.pub   # 造 config-2 ISO
scripts/verify-boot.sh img.qcow2 --pubkey ~/.ssh/id_ed25519.pub       # BIOS
scripts/verify-boot.sh img.qcow2 --uefi --port 2223                   # UEFI 也要过一遍
```

`verify-boot.sh` 用 qcow2 覆盖层启动（原镜像不变），自动断言：sshd 能进、
`cloud-init status: done`、datasource=ConfigDrive、hostname 注入成功、`systemctl --failed` 为空、
qemu-guest-agent/chrony active、machine-id 已重生、authorized_keys 有内容、DNS 由 DHCP 下发。

还要额外看一眼（脚本不覆盖）：

```bash
# 不带 config drive 起一次：不能卡在元数据探测 2 分钟（datasource_list 里没有 None 时留意）
# 实例内：cloud-init status --long / dmesg -l err / journalctl -p 3 -b
# grub：grep -c password_pbkdf2 /boot/grub2/grub.cfg   # 只该剩 01_users 的条件块
```

## 6. 传上去 / 起实例

```bash
openstack image create --disk-format qcow2 --container-format bare \
  --file img.qcow2 \
  --property hw_qemu_guest_agent=yes \
  --property os_type=linux \
  --property img_config_drive=optional \
  --property os_admin_user=root \
  --property hw_disk_bus=virtio --property hw_scsi_model=virtio-scsi \
  --min-disk 10 --min-ram 512 \
  my-image
```

- `hw_qemu_guest_agent=yes` 才会给虚拟机接上 virtio-serial，qemu-ga 才有活干。
- 镜像里的 `datasource_list` 含 `OpenStack`/`ConfigDrive` 时，`img_config_drive=optional` 更省事；
  要强制走 config drive 就设 `mandatory`。
- 验证 telemetry：`openstack server show <id> -f value -c addresses` 能出 IP 就说明 qemu-ga 通了。

## 7. 最容易踩的坑（都踩过）

| 现象 | 根因 |
|---|---|
| cloud-init `status: error`，hostname 改不掉 | 镜像里没 `hostname(1)` 命令；或缺 `/etc/cloud/templates/hosts.<osfamily>.tmpl` |
| `systemctl enable qemu-guest-agent` 成功但开机不启动 | 官方 unit 没有 `[Install]` 段，enable 是空操作 → 手拉 `multi-user.target.wants` 软链 |
| grub 密码删了重启又回来 | 首启 hardening 服务把它写回 `/etc/grub.d/00_header` |
| virtio 盘起不来 kernel panic | hostonly initramfs 没带 `virtio_blk`（`dracut -f --regenerate-all` 或改 `/etc/dracut.conf.d/*`） |
| virt-manager 自带的 cloud-init 勾选没用 | 它生成的是 NoCloud(`cidata`)，镜像 `datasource_list` 里没有 `NoCloud` 就白搭；要用 `config-2` |
| `qemu-nbd --disconnect` 后镜像坏 | 设备还挂着就强拆了。先 `umount`，忙就 `fuser -vm` 看占用者，别硬来 |
| 文件系统脏导致 `mount -o ro` 失败 | `needs_recovery`：`e2fsck -fp` 或 `mount -o ro,norecovery` 只看不改 |

## 现成案例

- openEuler 24.03 LTS SP4 官方 qcow2 的完整改造脚本（含上面每一条的真实命令）：
  `~/git.xcodest.me/ai-master/scripts/openeuler-cloud-image/`
- 只想要 config-2 ISO 生成器：`~/git.xcodest.me/ai-master/scripts/configdrive-iso/`
