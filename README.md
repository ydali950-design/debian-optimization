# Debian / Ubuntu Optimization

Debian / Ubuntu relay / VPN landing host network optimization scripts.

这个仓库用于 Debian、Ubuntu 中转机、VPN 落地机、代理网关等场景的网络优化。脚本目标是在速度、稳定性和内存占用之间取得比较激进但可长期运行的平衡。

## 功能

- `main.sh` 一键入口：启动后默认刷新系统软件源、执行网络优化、安装并启用 `irqbalance`，然后进入菜单
- 覆盖 `/etc/sysctl.conf`，并链接到 `/etc/sysctl.d/99-network-optimization.conf`，让网络参数重启后持续生效
- 开启 IPv4 转发，设置 IPv4 优先，并强制关闭 IPv6
- 启用 `fq + bbr`，提升高延迟线路吞吐
- 自动按内存估算 `conntrack` 容量，兼顾并发和内存
- 调整 socket buffer、队列、SYN backlog、TIME_WAIT、UDP 参数
- 配置 systemd limits，让服务进程也获得更高文件句柄限制
- 创建开机网卡调优服务，自动设置 RPS/XPS、txqueuelen、ring buffer、offload
- 默认启用 IPv4 MTU/MSS 修正，自动添加 TCP MSS clamp，降低 VPN/隧道/中转链路因 MTU 不匹配导致的卡顿和掉速
- 提供 Debian / Ubuntu IPv4 UDP 多网卡映射脚本，修正 UDP 多网卡回包源地址，减少 UDP 流量走错出口导致的丢包
- 提供 swap 管理和 root SSH 管理脚本
- 默认安装并启用 Chrony，重启服务后执行 `chronyc makestep` 立即校准系统时间
- `main2.sh` 默认按系统和软件包架构切换 Debian/Ubuntu 官方源，刷新失败时自动恢复原源

## 使用

克隆仓库后，root 用户执行入口脚本：

```bash
apt update && apt install -y git
git clone https://github.com/ydali950-design/debian-optimization.git
cd debian-optimization
bash main.sh
```

`main.sh` 默认会依次执行：

```bash
刷新系统软件源
apt install chrony -y
systemctl enable chrony
systemctl restart chrony
chronyc makestep
设置 IPv4 优先并强制关闭 IPv6
执行 sysctl/network 优化
启用 MTU/MSS 修正
apt install irqbalance -y
systemctl start irqbalance
systemctl enable irqbalance
```

执行完成后会进入菜单，可继续选择 swap、root SSH、UDP 多网卡映射、MTU/MSS 修正、WARP、状态查看等功能。

## main2 测试版

`main2.sh` 用于全新 Debian/Ubuntu 机器，也能自动接管已经完整执行过本仓库 `main.sh` 的机器，并支持以后下载新版脚本直接覆盖更新。测试期间不会修改 `main.sh`。

在独立目录运行：

```bash
(
  set -e
  install_dir=/root/debian-optimization-main2
  if [[ -L "${install_dir}" || ( -e "${install_dir}" && ! -d "${install_dir}" ) ]]; then
    echo "安装目录不是安全的真实目录，已停止。" >&2
    exit 1
  fi
  mkdir -p -- "${install_dir}"
  cd -- "${install_dir}"
  if [[ ( -e main2.sh || -L main2.sh ) && ( ! -f main2.sh || -L main2.sh ) ]]; then
    echo "main2.sh 不是安全的普通文件，已停止覆盖。" >&2
    exit 1
  fi
  install_file="$(mktemp ./.main2.sh.new.XXXXXX)"
  trap 'rm -f -- "${install_file}"' EXIT
  curl -fL https://raw.githubusercontent.com/ydali950-design/debian-optimization/refs/heads/main/main2.sh -o "${install_file}"
  bash -n "${install_file}"
  chmod 0755 "${install_file}"
  mv -f -- "${install_file}" main2.sh
  trap - EXIT
  bash main2.sh
)
```

以后覆盖更新 `main2.sh` 时，先下载到同目录临时文件并检查 Bash 语法，再替换正在使用的脚本：

```bash
(
  set -e
  cd /root/debian-optimization-main2
  if [[ ( -e main2.sh || -L main2.sh ) && ( ! -f main2.sh || -L main2.sh ) ]]; then
    echo "main2.sh 不是安全的普通文件，已停止覆盖。" >&2
    exit 1
  fi
  update_file="$(mktemp ./.main2.sh.new.XXXXXX)"
  trap 'rm -f -- "${update_file}"' EXIT
  curl -fL https://raw.githubusercontent.com/ydali950-design/debian-optimization/refs/heads/main/main2.sh -o "${update_file}"
  bash -n "${update_file}"
  chmod 0755 "${update_file}"
  mv -f -- "${update_file}" main2.sh
  trap - EXIT
  bash main2.sh
)
```

新版 `main2.sh` 启动后会同步以下 5 个配套脚本：

- `sysctl_optimization_debian_overwrite_main2.sh`
- `scripts/swap.sh`
- `scripts/ssh_root.sh`
- `scripts/udp_multinic_main2.sh`
- `scripts/mtu_mss_main2.sh`

缺失文件和通过精确 SHA256 识别的本仓库旧版本会自动覆盖更新。每个待更新文件会先下载到目标所在目录的临时文件，逐个通过固定 SHA256 和 `bash -n` 校验后才开始原子替换；下载或校验任意一项失败时，原文件均不修改，替换中途失败时已替换文件会回滚。即使 `scripts/` 是独立挂载点，也不会退化为跨文件系统复制。检测到同名自定义文件、符号链接、目录或其他非普通文件时，会在下载前停止整包同步，`AUTO_UPDATE_SUPPORT=1` 也不会绕过此保护。

脚本在任何下载、`apt`、迁移和网络写入前获取 `/run/debian-optimization-main2.lock` 非阻塞进程锁，并持续持有到脚本退出；已有另一份 `main2.sh` 运行时，后启动的实例会立即停止，避免两个版本交错更新配套文件或系统配置。该锁依赖 Debian/Ubuntu 基础包 `util-linux` 提供的 `flock`。

首次执行默认完成：

```bash
# 按系统和软件包架构设置 Debian/Ubuntu 官方源
apt update
apt install chrony -y
systemctl enable chrony
systemctl restart chrony
chronyc makestep
# 关闭 IPv6
# 执行用户态 TCP/UDP 中转和代理落地优化
# 安装并启用 irqbalance
```

`irqbalance` 软件包安装和服务启动分别允许一次受控重试。安装后会显式刷新 systemd，先设置开机启用，再启动服务。最终失败会指出精确阶段；如果服务连续启动失败，还会输出服务状态和最近 40 行日志，不需要再次运行整套脚本才能看清原因。

网络优化仍会严格校验转发、IPv6 关闭等必要参数。`net.core.netdev_budget_usecs` 和 `net.ipv4.ipfrag_high_thresh` 在不同云厂商内核上的可接受范围不一致，因此改为运行期探测：内核接受时应用目标值，明确拒绝时保留当前内核值并继续完成其余优化，不会再让整个服务失败。`network-optimization-sysctl.service` 首次启动失败时会清除该服务失败状态并重试一次；最终失败会输出完整服务状态和最近 120 行日志，其他 sysctl 错误不会被忽略。

全新机器上，`main2` 使用独立的 `/etc/sysctl.d/99-network-optimization.conf` 和 `/etc/security/limits.d/99-network-optimization.conf`，不会覆盖现有 `/etc/sysctl.conf` 或 `/etc/security/limits.conf`。

检测到旧版 `main.sh` 产物时，`main2` 会在写入新配置前完成所有权和 UDP 规则校验，然后执行以下迁移：

- 备份旧版覆盖的 `sysctl.conf` 和 `limits.conf`，移除旧版管理内容，保留其他现有内容
- 清理旧版默认启用的 MTU/MSS 服务和规则，避免未知隧道 MTU 被全局规则限制
- 由 main2 版本的 `network-max-tune.service` 接管网卡调优
- 保留有效的 IPv4 UDP 多网卡映射；运行文件缺失或不完整时自动重建
- 旧 UDP 配置含 IPv6 或格式无效时，在修改任何系统配置前停止并保留原文件

默认迁移不会自行选择多个历史备份。需要精确恢复某次 `main.sh` 执行前的两份配置时，明确传入同一个 14 位备份时间戳：

```bash
LEGACY_BACKUP_SUFFIX=20260725013000 bash main2.sh
```

首次初始化成功后会创建 `/root/.debian_optimization_main2_done`，并在 `/var/lib/debian-optimization-main2/install-state` 精确记录已安装版本、已应用版本、脚本 SHA256、管理文件整体 SHA256，以及 `PROFILE`、`ENABLE_NIC_TUNING`、`RP_FILTER`、`MAXIMIZE_NIC_RING`、`IP_LOCAL_PORT_RANGE` 和优化器支持的 14 个数值性能覆盖项。再次执行相同版本时直接进入菜单；覆盖为新版本后，会按记录值重新应用网络优化，不会把已经选择的 `max` 或自定义缓冲区、队列、连接跟踪等参数恢复成默认值。首次应用或普通版本更新在中途失败时会按上次记录参数续跑；新版 `main2.sh` 仅在状态明确记录“不需要人工文件覆盖”时接管旧版本的未完成事务。覆盖条件未知或需要人工覆盖授权时仍会在任何系统调用前停止。

自动重应用前会核对 main2 管理的 sysctl、limits、systemd 服务和网卡调优文件。任一文件被人工修改、替换或改成符号链接时，只更新脚本包并保留现有系统配置。确认允许覆盖后再明确执行：

```bash
ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=max bash main2.sh
```

该开关只允许覆盖 main2 固定管理路径中的普通文件；符号链接、目录和其他非普通文件仍会被拒绝。覆盖前会为 13 个已存在的固定管理文件分别创建 `.bak.时间戳` 副本。这个权限不会变成后续更新的长期权限；如果本次显式覆盖中断，状态只记录“重试仍需确认”，再次运行时必须重新提供 `ALLOW_MANAGED_CONFIG_OVERWRITE=1`，并且会在执行 `apt`、Chrony 或网络写入前检查。

早期 `main2.sh` 只有初始化标记、没有上述状态文件，无法从现有 sysctl 数值精确还原当时选择的档位。首次运行新版时只覆盖更新配套脚本并保留当前系统参数，随后在菜单明确选择 `3`（balanced）或 `4`（max）；记录完成后，后续版本即可自动覆盖应用。也可以直接明确重做默认初始化；此场景只设置 `REAPPLY_INIT=1` 不会默认选择档位，必须同时提供 `PROFILE=balanced` 或 `PROFILE=max`：

```bash
REAPPLY_INIT=1 PROFILE=max bash main2.sh
```

`main2` 需要 Debian 或 Ubuntu 使用 systemd 作为 PID 1；在普通容器、chroot 或 systemd 未启动的环境中会在修改系统前停止。

在 Debian 上，Debian 10 使用官方 `archive.debian.org`；Debian 11/12/13 使用官方 `deb.debian.org/debian` 和 `security.debian.org/debian-security`，默认不启用 backports。每条源都精确绑定 `/usr/share/keyrings/debian-archive-keyring.gpg`。脚本兼容 Debian 13 官方 `debian-archive-keyring` 包创建的 `debian-archive-keyring.gpg -> debian-archive-keyring.pgp` 相对符号链接，并继续拒绝其他链接关系、断链和不可读目标。

在 Ubuntu 上，`amd64`、`i386` 使用官方 `archive.ubuntu.com/ubuntu` 和 `security.ubuntu.com/ubuntu`；`arm64`、`armhf`、`ppc64el`、`riscv64`、`s390x` 使用官方 `ports.ubuntu.com/ubuntu-ports`。每条源都精确绑定 `/usr/share/keyrings/ubuntu-archive-keyring.gpg` 并限制为当前原生架构，避免 foreign architecture 从错误端点请求索引。

切换前，脚本会备份 `/etc/apt/sources.list`，停用单独文件中的旧系统源，并保留独立 `.list` 或 `.sources` 文件中的第三方仓库。停用备份始终以 `.disabled` 结尾，APT 会安静忽略；覆盖更新时会把旧版生成的 `.disabled.<14 位时间戳>[.<序号>]` 文件迁移为以 `.disabled` 结尾的新命名，内容不变且不覆盖已有备份。deb822 文件即使使用非标准文件名或云厂商镜像，也会根据当前系统代号和发行版密钥环识别并停用；只含 `Enabled: no` 的文件保持不动。主源含无法确认归属的活动仓库、同一扩展源文件混合系统源与第三方源、目标是符号链接或其他非普通文件时，脚本会在修改前停止，要求先拆分配置。

新官方源写入后会立即执行 `apt-get update`。刷新失败或切换事务收到 `INT`、`TERM`、异常退出时，`main2.sh` 会恢复执行前的主源和扩展源；普通刷新失败还会用恢复后的配置重新刷新。同一秒重复执行也不会覆盖已有备份。菜单 `2` 可以随时重新设置当前系统官方源。

如果只想执行网络优化脚本：

```bash
bash sysctl_optimization_debian_overwrite.sh
```

最大化模式，适合 4G 内存以上机器或测速场景：

```bash
PROFILE=max bash sysctl_optimization_debian_overwrite.sh
```

执行优化后建议重启：

```bash
reboot
```

## 可选变量

```bash
PROFILE=balanced      # 默认，速度和内存更均衡
PROFILE=max           # 更激进，适合冲测速或大内存机器
ENABLE_NIC_TUNING=1   # 默认启用网卡调优服务
RP_FILTER=0           # 默认关闭反向路径过滤，适合隧道/多线路
SKIP_INIT=1           # 执行 main.sh 或 main2.sh 时跳过默认初始化，直接进入菜单
REAPPLY_INIT=1        # main2 已初始化后，明确重新执行默认初始化
AUTO_UPDATE_SUPPORT=1 # 强制重新下载本仓库版本的配套脚本；不能覆盖同名自定义文件
ALLOW_MANAGED_CONFIG_OVERWRITE=1 # 明确允许本次重应用覆盖 main2 管理路径中的普通文件
```

示例：

```bash
PROFILE=max bash sysctl_optimization_debian_overwrite.sh
```

IPv6 始终关闭，不能通过环境变量重新启用。脚本会持久化设置 `net.ipv6.conf.all.disable_ipv6=1`、`net.ipv6.conf.default.disable_ipv6=1` 和 `net.ipv6.conf.lo.disable_ipv6=1`，并在执行时立即应用。

## UDP 多网卡映射

用于一台 Debian 或 Ubuntu 机器多网卡、多 IPv4 的 UDP 落地场景。它通过 UDP DNAT/SNAT 修正回包源地址，避免 UDP 流量因为回包源地址或出口不一致被上游、客户端或策略路由丢弃。

菜单执行：

```bash
bash scripts/udp_multinic.sh
```

命令行添加规则：

```bash
bash scripts/udp_multinic.sh add <源IPv4> <目标IPv4> [UDP端口]
```

示例：

```bash
bash scripts/udp_multinic.sh add 203.0.113.10 10.0.0.2 443
```

注意：此脚本支持 Debian 和 Ubuntu，只做 IPv4->IPv4 的 UDP 地址映射。本仓库强制关闭 IPv6，并会清理旧版脚本留下的 IPv6 UDP 规则。

## MTU/MSS 修正

用于 Debian 或 Ubuntu 的中转、NAT、VPN、落地机场景。默认使用 `--clamp-mss-to-pmtu`，让内核按路径 MTU 自动修正 TCP SYN 包里的 MSS，避免 TCP 包在隧道链路里过大导致分片、丢包或速度异常。只生成 IPv4 规则，并清理旧版脚本留下的 IPv6 MSS 规则。

默认启用：

```bash
bash scripts/mtu_mss.sh enable
```

指定固定 MSS：

```bash
bash scripts/mtu_mss.sh fixed 1360
```

查看状态：

```bash
bash scripts/mtu_mss.sh status
```

清理规则：

```bash
bash scripts/mtu_mss.sh disable
```

脚本会创建并启用：

```text
/etc/default/mtu-mss-fix
/usr/local/sbin/mtu-mss-apply.sh
/etc/systemd/system/mtu-mss-fix.service
```

## 注意

`main.sh` 会覆盖系统原本的 `/etc/sysctl.conf` 和 `/etc/security/limits.conf`，执行前会自动生成 `.bak.时间戳` 备份。`main2.sh` 使用独立 drop-in，并按上面的规则迁移旧版配置。

脚本不会默认格式化磁盘。只有显式设置 `FORMAT_XVDB=1` 时，才会执行 `/dev/xvdb` 格式化操作。

公网测速结果受机房线路、路由、晚高峰拥塞、YouTube CDN、协议 MTU/MSS 等因素影响。此脚本主要优化系统内核网络栈和转发能力。
