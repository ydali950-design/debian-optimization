# Debian Optimization

Debian relay / VPN landing host network optimization scripts.

这个仓库用于 Debian 中转机、VPN 落地机、代理网关等场景的网络优化。脚本目标是在速度、稳定性和内存占用之间取得比较激进但可长期运行的平衡。

## 功能

- `main.sh` 一键入口：启动后默认设置 Debian 源、执行网络优化、安装并启用 `irqbalance`，然后进入菜单
- 覆盖 `/etc/sysctl.conf`，让网络参数重启后持续生效
- 开启 IPv4/IPv6 转发，适合中转、NAT、VPN 网关
- 启用 `fq + bbr`，提升高延迟线路吞吐
- 自动按内存估算 `conntrack` 容量，兼顾并发和内存
- 调整 socket buffer、队列、SYN backlog、TIME_WAIT、UDP 参数
- 配置 systemd limits，让服务进程也获得更高文件句柄限制
- 创建开机网卡调优服务，自动设置 RPS/XPS、txqueuelen、ring buffer、offload
- 提供 Debian 专用 UDP 多网卡映射脚本，修正 UDP 多网卡回包源地址，减少 UDP 流量走错出口导致的丢包
- 提供 swap 管理和 root SSH 管理脚本

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
设置 Debian 官方源
执行 sysctl/network 优化
apt install irqbalance -y
systemctl start irqbalance
systemctl enable irqbalance
```

执行完成后会进入菜单，可继续选择 swap、root SSH、UDP 多网卡映射、WARP、状态查看等功能。

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
ENABLE_IPV6=1         # 默认开启 IPv6 转发
ENABLE_NIC_TUNING=1   # 默认启用网卡调优服务
RP_FILTER=0           # 默认关闭反向路径过滤，适合隧道/多线路
SKIP_INIT=1           # 执行 main.sh 时跳过默认初始化，直接进入菜单
```

示例：

```bash
PROFILE=max ENABLE_IPV6=0 bash sysctl_optimization_debian_overwrite.sh
```

## UDP 多网卡映射

用于一台 Debian 机器多网卡、多 IP 的 UDP 落地场景。它通过 UDP DNAT/SNAT 修正回包源地址，避免 UDP 流量因为回包源地址或出口不一致被上游、客户端或策略路由丢弃。

菜单执行：

```bash
bash scripts/udp_multinic.sh
```

命令行添加规则：

```bash
bash scripts/udp_multinic.sh add <源IP> <目标IP> [UDP端口]
```

示例：

```bash
bash scripts/udp_multinic.sh add 203.0.113.10 10.0.0.2 443
```

注意：此脚本只支持 Debian，只做 IPv4->IPv4 或 IPv6->IPv6 的同协议 UDP 地址映射。IPv4/IPv6 跨协议转换应使用 Jool、TAYGA 等专门工具。

## 注意

脚本会覆盖系统原本的 `/etc/sysctl.conf` 和 `/etc/security/limits.conf`，执行前会自动生成 `.bak.时间戳` 备份。

脚本不会默认格式化磁盘。只有显式设置 `FORMAT_XVDB=1` 时，才会执行 `/dev/xvdb` 格式化操作。

公网测速结果受机房线路、路由、晚高峰拥塞、YouTube CDN、协议 MTU/MSS 等因素影响。此脚本主要优化系统内核网络栈和转发能力。
