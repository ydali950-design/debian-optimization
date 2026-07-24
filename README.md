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

在 Debian 上刷新软件源时，脚本会清理 `/etc/apt/sources.list.d/` 里旧的 Debian 官方源残留，例如已经失效的 `bullseye-backports`，但会保留 Docker、Cloudflare、Tailscale、NodeSource 等常见第三方源。Debian 10 会自动使用 `archive.debian.org`，Debian 11/12/13 默认不启用 backports。

在 Ubuntu 上，脚本保留系统现有的 `/etc/apt/sources.list` 和 `/etc/apt/sources.list.d/ubuntu.sources` 配置，只执行 `apt-get update`。这可以兼容 Ubuntu 官方镜像、云厂商区域镜像和 Ubuntu 24.04 使用的 deb822 源格式。

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
SKIP_INIT=1           # 执行 main.sh 时跳过默认初始化，直接进入菜单
AUTO_UPDATE_SUPPORT=1 # 显式从 RAW_BASE_URL 更新配套脚本；main2 默认也会替换精确识别的已知故障版本
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

脚本会覆盖系统原本的 `/etc/sysctl.conf` 和 `/etc/security/limits.conf`，执行前会自动生成 `.bak.时间戳` 备份。

脚本不会默认格式化磁盘。只有显式设置 `FORMAT_XVDB=1` 时，才会执行 `/dev/xvdb` 格式化操作。

公网测速结果受机房线路、路由、晚高峰拥塞、YouTube CDN、协议 MTU/MSS 等因素影响。此脚本主要优化系统内核网络栈和转发能力。
