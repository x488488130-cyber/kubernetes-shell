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
- **网络插件选择** — Flannel / Calico / Cilium (eBPF) / Weave Net
- **主从模式** — 纯 Master / 混合调度 / All-in-One 单节点
- **HA 高可用** — 支持 Control Plane Endpoint（多 Master + 负载均衡）
- **附加组件** — Metrics Server / Ingress Nginx / Kubernetes Dashboard
- **节点重置** — 一键清理还原

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
| `sudo bash k8s-deploy.sh init` | 一键部署 Master 节点（非交互，Calico + aliyun 镜像） |
| `sudo bash k8s-deploy.sh join` | 一键加入 Worker 节点（需提供 join 命令） |
| `sudo bash k8s-deploy.sh allinone` | 单节点 All-in-One 部署（非交互） |

### 交互式菜单选项

```
1) 初始化 Master 节点 (含网络插件 + 组件选择)
2) 加入 Worker 节点
3) 加入 Control Plane 节点 (多 Master HA)
4) 单节点 All-in-One 部署 (Master+Worker)
5) 仅检查集群状态
6) 重置节点 (kubeadm reset)
7) 退出
```

## 部署流程

```
系统检测 → 环境检查 → 镜像加速代理配置 → 系统初始化
    → 容器运行时安装(containerd) → CNI 网络插件选择
    → K8s 组件安装(kubeadm/kubelet/kubectl) → 主节点初始化
    → 安装网络插件 → 主节点调度模式配置 → 可选组件安装
    → 集群状态检查 → 完成
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

# 查看 Join 命令（用于添加 Worker 节点）
cat k8s-join-command.txt

# 查看部署日志
ls k8s-deploy-*.log
```

## 端口要求

| 节点类型 | 端口 |
|----------|------|
| Master | 6443, 2379-2380, 10250, 10251, 10252, 10259, 10257 |
| Worker | 10250, 30000-32767 (NodePort) |

## 注意事项

1. 必须以 **root** 用户或 `sudo` 执行
2. 建议至少 2 核 CPU、2GB 内存、20GB 磁盘
3. 所有节点之间网络互通，无需 NAT
4. 部署日志自动保存到脚本同目录 `k8s-deploy-YYYYMMDD-HHMMSS.log`
5. Join 命令保存在 `k8s-join-command.txt`，有效期为 24 小时

## License

MIT
