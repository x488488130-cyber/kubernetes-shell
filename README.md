# kubernetes-shell

K8s 全流程自动化部署脚本，一键完成 Kubernetes 集群的安装与配置。

## 支持平台

| 系统 | 版本 |
|------|------|
| Ubuntu | 20.04+ |
| Debian | 11+ |
| CentOS | 7 / 8 / 9 |
| RHEL / Rocky Linux | 8 / 9 |
| Alibaba Cloud Linux | 2 / 3 |
| Anolis OS / TencentOS / openEuler | - |

支持架构：`amd64` / `arm64`

## 功能特性

- **系统环境检查** — CPU、内存、磁盘、SELinux、主机名、swap 状态
- **系统初始化** — 关闭 swap/firewalld/SELinux/ufw，加载内核模块，内核参数优化，NTP 时间同步
- **镜像加速代理** — 支持 DaoCloud 公共加速、阿里云 ACR、自定义 Harbor、HTTP/HTTPS 代理
- **容器运行时** — 自动安装配置 containerd（SystemdCgroup + 镜像加速）
- **K8s 组件安装** — kubeadm / kubelet / kubectl，国内外双源切换，版本锁定
- **External etcd** — 支持独立部署 etcd 集群 (单节点/多节点)，TLS 双向认证，自动健康检查
- **网络插件选择** — Flannel / Calico / Cilium (eBPF) / Weave Net
- **主从模式** — 纯 Master / 混合调度 / All-in-One 单节点
- **HA 高可用** — 支持 Control Plane Endpoint（多 Master + 负载均衡）
- **附加组件** — Metrics Server / Ingress Nginx / Kubernetes Dashboard
- **节点重置** — 一键清理还原 (含 etcd 数据)

## 快速开始

```bash
# 克隆仓库
git clone https://github.com/x488488130-cyber/kubernetes-shell.git
cd kubernetes-shell

# 赋予执行权限
chmod +x k8s-deploy.sh

# 交互式菜单（推荐，逐步引导配置）
sudo bash k8s-deploy.sh
```

## 使用方式

| 命令 | 说明 |
|------|------|
| `sudo bash k8s-deploy.sh` | 交互式菜单，一步步引导选择所有配置 |
| `sudo bash k8s-deploy.sh init` | 一键部署 Master 节点 (内嵌 etcd, Calico + aliyun 镜像) |
| `sudo bash k8s-deploy.sh init-external` | 一键部署 Master 节点 (外部 etcd, 需已有 etcd 集群) |
| `sudo bash k8s-deploy.sh etcd` | 部署 External etcd 集群 |
| `sudo bash k8s-deploy.sh etcd-check` | etcd 集群健康检查 |
| `sudo bash k8s-deploy.sh join` | 一键加入 Worker 节点 (需提供 join 命令) |
| `sudo bash k8s-deploy.sh allinone` | 单节点 All-in-One 部署 (内嵌 etcd) |

### 交互式菜单选项

```
1) 初始化 Master 节点 (内嵌 etcd, 含网络插件 + 组件选择)
2) 初始化 Master 节点 (外部 etcd, 需已有 etcd 集群)
3) 部署 External etcd 集群
4) 加入 Worker 节点
5) 加入 Control Plane 节点 (多 Master HA)
6) 单节点 All-in-One 部署 (内嵌 etcd, Master+Worker)
7) 检查集群状态
8) etcd 集群健康检查
9) 重置节点 (kubeadm reset + etcd 清理)
10) 退出
```

## 部署流程

### 内嵌 etcd 模式 (默认)

```
系统检测 → 环境检查 → 镜像加速代理配置 → 系统初始化
    → 容器运行时安装(containerd) → CNI 网络插件选择
    → K8s 组件安装(kubeadm/kubelet/kubectl) → 主节点初始化
    → 安装网络插件 → 主节点调度模式配置 → 可选组件安装
    → 集群状态检查 → 完成
```

### 外部 etcd 模式 (生产推荐)

```
>>> etcd 节点: 系统初始化 → K8s 工具安装 → etcd 集群参数配置
                → 下载 etcd 二进制 → 生成 TLS 证书
                → 配置 systemd 服务 → 启动 etcd → 健康检查

>>> Master 节点: 系统初始化 → 容器运行时 → CNI 选择
                  → K8s 工具安装 → kubeadm init (--external-etcd-endpoints)
                  → 安装网络插件 → 调度模式选择 → 可选组件安装
```

## External etcd 部署详解

### 为什么使用外部 etcd？

K8s 默认将 etcd 与 Master 节点部署在一起（Stacked etcd），适合开发/测试环境。
**生产环境推荐外部 etcd**，主要优势：

- **故障隔离** — etcd 故障不影响 API Server，Master 故障不影响 etcd 数据
- **独立扩缩容** — etcd 集群可独立扩展，不受 Master 节点数量限制
- **性能优化** — etcd 使用独立磁盘 (SSD)，避免与控制平面组件争抢 I/O
- **安全加固** — etcd 可部署在独立网络区域，缩小攻击面

### 架构对比

| 模式 | 架构 | 适用场景 | 最少节点数 |
|------|------|----------|------------|
| **内嵌 etcd** | etcd 作为 Static Pod 运行在 Master 上 | 开发/测试/小规模 | 1 |
| **外部 etcd** | etcd 独立部署在专用节点上 | 生产/大型集群 | etcd x3 + Master x2 |

### 部署步骤

**步骤 1: 部署 etcd 集群**

在 etcd 节点上执行：

```bash
# 交互式部署 (推荐)
sudo bash k8s-deploy.sh etcd

# 或通过交互菜单选择 3)
sudo bash k8s-deploy.sh
```

脚本将自动完成：
1. 下载并安装 etcd 二进制 (默认 v3.5.10)
2. 使用 kubeadm 生成 TLS 双向认证证书
3. 配置 systemd 服务并启动
4. 创建 etcd 专用系统用户
5. 配置 etcdctl 环境变量和别名
6. 等待 etcd 就绪并验证健康状态

**步骤 2: 初始化 Master 指向外部 etcd**

在 Master 节点上执行：

```bash
sudo bash k8s-deploy.sh
# 选择: 2) 初始化 Master 节点 (外部 etcd)
# 输入 etcd endpoints: https://10.0.0.1:2379,https://10.0.0.2:2379,https://10.0.0.3:2379
```

### etcd 常用运维命令

```bash
# 查看集群成员
etcdctl member list

# 查看节点健康状态
etcdctl endpoint health

# 查看集群状态
etcdctl endpoint status --write-out=table

# 备份快照
etcdctl snapshot save /backup/etcd-snapshot.db

# 查看告警
etcdctl alarm list

# 检查 etcd 服务状态
systemctl status etcd

# 查看 etcd 日志
journalctl -u etcd -f
```

## 网络插件对比

| 插件 | 特点 | Pod CIDR | 适用场景 |
|------|------|----------|----------|
| **Flannel** | 简单易用，VXLAN/Host-GW | 10.244.0.0/16 | 小规模集群，入门首选 |
| **Calico** | 高性能，BGP/VXLAN，网络策略 | 192.168.0.0/16 | 生产环境，安全要求高 |
| **Cilium** | eBPF 驱动，高性能+可观测性 | 10.0.0.0/8 | 大规模集群，需要可观测性 |
| **Weave Net** | 简单部署，自动发现，加密通信 | 10.32.0.0/12 | 多云/混合云场景 |

## 部署后常用命令

```bash
# 查看节点状态
kubectl get nodes -o wide

# 查看所有 Pod
kubectl get pods -A

# 查看服务
kubectl get svc -A

# 查看 etcd 集群状态
etcdctl endpoint status --write-out=table

# 查看 Join 命令（用于添加 Worker 节点）
cat k8s-join-command.txt

# 查看部署日志
ls k8s-deploy-*.log
```

## 端口要求

| 节点类型 | 端口 |
|----------|------|
| Master | 6443, 10250, 10257, 10259 |
| Worker | 10250, 30000-32767 (NodePort) |
| etcd | 2379 (client), 2380 (peer) |

## 注意事项

1. 必须以 **root** 用户或 `sudo` 执行
2. 建议至少 2 核 CPU、2GB 内存、20GB 磁盘 (etcd 节点建议 SSD)
3. 所有节点之间网络互通，无需 NAT
4. 部署日志自动保存到脚本同目录 `k8s-deploy-YYYYMMDD-HHMMSS.log`
5. Join 命令保存在 `k8s-join-command.txt`，有效期为 24 小时
6. External etcd 模式建议至少 3 个 etcd 节点以保证高可用 (奇数个)
7. etcd 数据目录默认 `/var/lib/etcd`，建议使用独立 SSD 磁盘

## License

MIT
