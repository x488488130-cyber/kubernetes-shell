# Kubernetes 知识体系：由浅及深

> 本文档从零开始，循序渐进梳理 K8s 各组件与模块，适合作为系统学习的知识地图。
> 每个模块末尾标注了对应 `k8s-deploy.sh` 中的实现位置，方便理论与实践对照。

---

## 目录

| 层级 | 模块 | 难度 |
|------|------|------|
| [第一层](#第一层-核心概念与集群架构) | 核心概念与集群架构 | ★☆☆☆☆ |
| &nbsp;&nbsp; 1.1 什么是 K8s / 1.2 集群架构全景图 / 1.3 两种 etcd 拓扑 | | |
| [第二层](#第二层-控制面组件详解) | 控制面组件详解 | ★★☆☆☆ |
| &nbsp;&nbsp; 2.1 etcd / 2.2 API Server / 2.3 Scheduler / 2.4 Controller Mgr / 2.5 kubeadm / 2.6 Cloud Controller Mgr | | |
| [第三层](#第三层-工作节点组件详解) | 工作节点组件详解 | ★★☆☆☆ |
| &nbsp;&nbsp; 3.1 kubelet / 3.2 kube-proxy / 3.3 Container Runtime / 3.4 节点维护 | | |
| [第四层](#第四层-核心工作负载资源) | 核心工作负载资源 | ★★★☆☆ |
| &nbsp;&nbsp; 4.1 Pod (生命周期/Init/Hook) / 4.2 Deployment / 4.3 StatefulSet / 4.4 DaemonSet / 4.5 Job/CronJob / 4.6 ReplicaSet / 4.7 Namespace | | |
| [第五层](#第五层-服务发现与网络) | 服务发现与网络 | ★★★★☆ |
| &nbsp;&nbsp; 5.1 网络模型 / 5.2 Service / 5.3 Ingress / 5.4 CNI / 5.5 CoreDNS / 5.6 NetworkPolicy / 5.7 Gateway API | | |
| [第六层](#第六层-存储体系) | 存储体系 | ★★★★☆ |
| &nbsp;&nbsp; 6.1 PV/PVC / 6.2 存储类型 / 6.3 StorageClass / 6.4 CSI / 6.5 Volume 类型详解 | | |
| [第七层](#第七层-配置与安全) | 配置与安全 | ★★★★☆ |
| &nbsp;&nbsp; 7.1 ConfigMap / 7.2 Secret (加密) / 7.3 RBAC / 7.4 Pod Security / 7.5 ServiceAccount / 7.6 PSA / 7.7 准入控制器 | | |
| [第八层](#第八层-调度与资源管理) | 调度与资源管理 | ★★★★☆ |
| &nbsp;&nbsp; 8.1 资源请求/限制 / 8.2 HPA+VPA+CA / 8.3 Taints / 8.4 Affinity / 8.5 PDB / 8.6 PriorityClass / 8.7 Topology Manager | | |
| [第九层](#第九层-可观测性与进阶主题) | 可观测性与进阶主题 | ★★★★★ |
| &nbsp;&nbsp; 9.1 Prometheus / 9.2 EFK/Loki / 9.3 Istio / 9.4 CRD+Operator / 9.5 备份 / 9.6 Helm / 9.7 GitOps / 9.8 集群升级 / 9.9 多租户 | | |
| [第十层](#第十层-运维实战与部署脚本对照) | 运维实战与部署脚本对照 | ★★★★★ |
| &nbsp;&nbsp; 10.1 部署全景 / 10.2 函数对照表 / 10.3 命令速查 / 10.4 故障排查 / 10.5 生产最佳实践 | | |

---

## 第一层: 核心概念与集群架构

### 1.1 什么是 Kubernetes

Kubernetes（K8s）是一个**容器编排平台**，负责自动化容器的部署、扩缩容、负载均衡、自愈和滚动更新。

```
传统部署: 物理机上直接跑应用, 资源利用率低
        ↓
虚拟化:   VM 隔离应用, 但启动慢, 有 OS 开销
        ↓
容器化:   Docker 打包应用+依赖, 轻量快速
        ↓
编排:     K8s 管理成千上万个容器, 自动调度/伸缩/自愈
```

### 1.2 集群架构全景图

```
┌──────────────────────────────────────────────────────────────────┐
│                         Control Plane (Master)                     │
│  ┌──────────┐  ┌──────────┐  ┌─────────────┐  ┌───────────────┐  │
│  │   etcd   │  │API Server│  │  Scheduler   │  │Controller Mgr │  │
│  │ 键值存储  │  │ 集群入口  │  │   Pod调度    │  │  状态协调      │  │
│  └──────────┘  └──────────┘  └─────────────┘  └───────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   Worker Node 1  │ │   Worker Node 2  │ │   Worker Node 3  │
│ ┌─────┐ ┌──────┐ │ │ ┌─────┐ ┌──────┐ │ │ ┌─────┐ ┌──────┐ │
│ │kubelet│kube │ │ │ │kubelet│kube │ │ │ │kubelet│kube │ │
│ │       │proxy │ │ │ │       │proxy │ │ │ │       │proxy │ │
│ └─────┘ └──────┘ │ │ └─────┘ └──────┘ │ │ └─────┘ └──────┘ │
│ ┌──────────────┐ │ │ ┌──────────────┐ │ │ ┌──────────────┐ │
│ │ Container    │ │ │ │ Container    │ │ │ │ Container    │ │
│ │ Runtime      │ │ │ │ Runtime      │ │ │ │ Runtime      │ │
│ │ (containerd) │ │ │ │ (containerd) │ │ │ │ (containerd) │ │
│ └──────────────┘ │ │ └──────────────┘ │ │ └──────────────┘ │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

### 1.3 两种 etcd 拓扑

| 拓扑 | 结构 | 优点 | 缺点 | 部署脚本 |
|------|------|------|------|----------|
| **Stacked etcd** (内嵌) | etcd 与 Master 同节点运行 | 部署简单，节点数少 | etcd 故障影响 Master | `init` / `allinone` |
| **External etcd** (外部) | etcd 独立部署在专用节点 | 故障隔离，独立扩展 | 节点数多，运维复杂 | `etcd` + `init-external` |

```
Stacked:                        External:
┌──────────────┐                ┌─────────┐  ┌──────────────┐
│   Master     │                │  etcd   │  │   Master     │
│  ┌────────┐  │                │ Cluster │  │  (no etcd)   │
│  │  etcd  │  │                │ (3节点)  │  └──────────────┘
│  └────────┘  │                └─────────┘         │
│  API/Sched.. │                      │             │
└──────────────┘                ┌──────┴──────┐      │
       │                        │   etcd 集群  │◄────┘
       │                        │  独立管理    │
```

---

## 第二层: 控制面组件详解

### 2.1 etcd — 集群的大脑

**角色：** 分布式键值存储，保存集群所有状态数据。

```
etcd 存储的内容:
├── /registry/namespaces/         → 命名空间
├── /registry/pods/               → 所有 Pod 定义和状态
├── /registry/services/           → Service 定义
├── /registry/deployments/        → Deployment 定义
├── /registry/secrets/            → Secret 数据 (Base64)
├── /registry/configmaps/         → ConfigMap 数据
├── /registry/serviceaccounts/    → ServiceAccount
└── /registry/leases/             → 选举锁 (Leader Election)
```

**核心概念：**

| 概念 | 说明 |
|------|------|
| Raft 共识 | etcd 使用 Raft 算法在节点间达成一致，需要 **奇数个** 节点 (通常 3 或 5) |
| WAL (Write-Ahead Log) | 所有写操作先记录到 WAL，再应用到数据文件，保证崩溃恢复 |
| Snapshot | 定期快照压缩历史数据，防止数据文件无限增长 |
| MVCC | 多版本并发控制，每次修改产生新版本，支持历史查询 |
| Lease | 租约机制，实现服务发现和心跳检测 |

**关键参数：**

| 参数 | 作用 | 部署脚本位置 |
|------|------|-------------|
| `--quota-backend-bytes=8G` | 存储配额上限，默认 2GB | `deploy_etcd()` |
| `--snapshot-count=10000` | 每 1 万次写触发快照 | `deploy_etcd()` |
| `--auto-compaction-retention=1` | 自动压缩，保留 1 小时历史 | `deploy_etcd()` |
| `--peer-urls` | etcd 节点间通信端口 2380 | `deploy_etcd()` |
| `--client-urls` | 客户端访问端口 2379 | `deploy_etcd()` |

**运维要点：**
- 定期备份: `etcdctl snapshot save /backup/snapshot.db`
- 监控磁盘 IO，etcd 对磁盘延迟极其敏感（建议使用 SSD）
- 定期碎片整理: `etcdctl defrag`

> 🔗 部署脚本: [deploy_etcd()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) | [etcd_health_check()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh)

---

### 2.2 kube-apiserver — 集群统一入口

**角色：** 所有操作的唯一入口，提供 RESTful API，负责认证、授权、准入控制。

```
                ┌──────────────────┐
    kubectl ──► │                  │
     SDK    ──► │   API Server     │ ◄── 唯一入口，所有操作经此
    Web UI  ──► │   (Port 6443)    │
                └────────┬─────────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
      etcd         Scheduler      Controller Mgr
    (读写状态)    (监听新Pod)     (监听资源变更)
```

**请求处理管道 (Pipeline):**

```
请求 → 认证(Authentication) → 授权(Authorization) → 准入控制(Admission) → etcd
       │                       │                      │
       ├─ X.509 证书            ├─ RBAC                 ├─ ResourceQuota 检查
       ├─ Bearer Token          ├─ Node 鉴权             ├─ LimitRange 注入
       ├─ ServiceAccount Token  ├─ ABAC                  ├─ PodSecurity 校验
       └─ Webhook Token         └─ Webhook               └─ MutatingWebhook 修改
```

> 🔗 部署脚本: [init_master()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — `kubeadm init --apiserver-advertise-address`

---

### 2.3 kube-scheduler — 智能调度器

**角色：** 监听未调度的 Pod，选择最优 Node 运行。

```
Scheduler 工作流程:

1. 监听 (Watch)
   └── API Server 通知: 有新 Pod, nodeName 为空

2. 预选 (Filtering)
   ├── 节点资源是否充足 (CPU/Mem)
   ├── 端口是否冲突
   ├── NodeSelector / NodeAffinity 是否匹配
   ├── Taints/Tolerations 是否容忍
   └── 卷是否可挂载

3. 优选 (Scoring)
   ├── 资源最空闲得分高
   ├── Pod 分散策略 (反亲和)
   ├── 镜像已存在的节点加分
   └── 自定义打分插件

4. 绑定 (Binding)
   └── 设置 Pod.spec.nodeName, 写入 API Server
```

**关键调度策略：**

| 策略 | 说明 |
|------|------|
| `nodeName` | 直接指定节点 (跳过调度器) |
| `nodeSelector` | 按标签选择节点 |
| Node Affinity | 灵活的节点亲和性 (硬/软) |
| Pod Affinity / Anti-Affinity | Pod 之间的亲和/反亲和 |
| Taints & Tolerations | 节点污点 + Pod 容忍 |
| Topology Spread | 跨拓扑域均匀分布 Pod |

> 🔗 部署脚本: [configure_master_mode()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — Master 污点管理

---

### 2.4 kube-controller-manager — 控制循环集合

**角色：** 一组控制器，每个控制器负责将"当前状态"调整为"期望状态"。

```
Controller Manager 包含的控制器:
│
├── Node Controller        → 监控节点心跳, 驱逐失联节点
├── Replication Controller → 确保 Pod 副本数符合期望
├── Deployment Controller  → 管理滚动更新/回滚
├── StatefulSet Controller → 管理有状态应用
├── DaemonSet Controller   → 确保每个节点运行一个 Pod
├── Job Controller         → 管理一次性/定时任务
├── Service Controller     → 为 Service 分配 ClusterIP
├── Endpoint Controller    → 维护 Service 的 Endpoint 列表
├── Namespace Controller   → 管理命名空间生命周期
├── PV Controller          → 绑定 PV 和 PVC
├── ServiceAccount Controller → 自动创建 SA Token
└── Garbage Collector      → 清理孤儿对象
```

**控制循环模式:**

```
        期望状态
           │
     ┌─────▼─────┐     差异计算     ┌──────────┐
     │  Controller │ ◄────────────── │ API Server│
     │    逻辑      │    (Watch)     │ (当前状态) │
     └─────┬─────┘                  └──────────┘
           │ 调谐 (Reconcile)
           ▼
     执行变更 (调 API Server)
```

### 2.5 kubeadm — 集群生命周期管理

**角色：** kubeadm 是官方推荐的集群引导工具，`kubeadm init` 会按阶段(Phase)执行一系列操作。

```
kubeadm init 执行阶段:

preflight             → 环境检查 (OS/内核/cgroup/端口冲突)
├── certs/             → 证书生成 (CA/apiserver/etcd/sa/...)
├── kubeconfig/        → 生成管理用 kubeconfig 文件
├── kubelet-start/     → 启动 kubelet
├── control-plane/     → 启动静态 Pod (apiserver/controller/scheduler)
│   ├── etcd/          → 仅 Stacked 模式, etcd 作为静态 Pod 启动
│   ├── apiserver/
│   ├── controller-manager/
│   └── scheduler/
├── etcd/              → 外部 etcd 模式, 生成 apiserver-etcd-client 证书
├── upload-config/     → 上传 kubeadm/kubelet 配置到集群 ConfigMap
├── upload-certs/      → 上传证书到集群 Secret (用于新 Master 加入)
├── mark-control-plane/ → 给节点打 control-plane 标签 + Taint
├── bootstrap-token/    → 创建 Bootstrap Token (用于 Worker 加入)
├── kubelet-finalize/   → 完成 kubelet 配置
└── addon/              → 安装 CoreDNS + kube-proxy
```

**证书管理：**

```
/etc/kubernetes/pki/ 目录结构:

├── ca.crt / ca.key                  ← 集群 CA (根证书)
├── apiserver.crt / apiserver.key    ← API Server 服务端证书
├── apiserver-kubelet-client.crt     ← API Server 访问 kubelet 的客户端证书
├── front-proxy-ca.crt               ← 前端代理 CA
├── front-proxy-client.crt           ← 前端代理客户端证书
├── sa.pub / sa.key                  ← ServiceAccount 签名密钥
├── etcd/
│   ├── ca.crt / ca.key              ← etcd 专用 CA
│   ├── server.crt / server.key      ← etcd 服务端证书
│   ├── peer.crt / peer.key          ← etcd 节点间通信证书
│   ├── healthcheck-client.crt       ← etcd 健康检查客户端证书
│   └── apiserver-etcd-client.crt    ← API Server 访问 etcd 的客户端证书
```

**证书续签：**

```bash
kubeadm certs check-expiration          # 检查证书过期时间
kubeadm certs renew all                 # 续签全部证书
kubeadm certs renew apiserver           # 续签单个证书
```

> 🔗 部署脚本: [install_k8s_tools()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — 安装 kubeadm
> 🔗 部署脚本: [deploy_etcd()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — 使用 kubeadm init phase certs 生成 etcd 证书

### 2.6 Cloud Controller Manager — 云提供商集成

**角色：** 将集群与云平台 API 对接，实现云资源的自动管理。K8s 1.26+ 要求 Cloud Controller Manager 必须作为独立进程运行（不再内嵌在 kube-controller-manager 中）。

```
Cloud Controller Manager 包含的控制器:

├── Node Controller         → 通过云 API 检查节点状态, 删除已释放的云实例
├── Route Controller        → 配置云 VPC 路由表, 实现 Pod 跨节点通信
├── Service Controller      → 自动创建云 LB (LoadBalancer 类型 Service)
└── Volume Controller       → 创建/挂载/卸载云盘
```

**使用方式（以 AWS 为例）：**

```yaml
# 部署 aws-cloud-controller-manager
# DaemonSet + ClusterRole + ClusterRoleBinding
# 自动为 LoadBalancer Service 创建 AWS NLB/ALB
```

**与 kube-controller-manager 的关系：**

```
kube-controller-manager          Cloud Controller Manager
├── Node (健康检查+驱逐)          ├── Node (云实例生命周期)
├── Service (ClusterIP分配)      ├── Service (云 LB 管理)
│                                 ├── Route (云路由表)
└── 其他 K8s 原生控制器           └── Volume (云盘管理)
```

> 注意：自建集群通常不需要 Cloud Controller Manager，kube-controller-manager 中的 Service Controller 会为 LoadBalancer Service 保持 Pending 状态。

---

## 第三层: 工作节点组件详解

### 3.1 kubelet — 节点管家

**角色：** 每个 Node 上运行的 Agent，负责管理该节点上的 Pod 生命周期。

```
kubelet 职责:

1. 节点注册
   └── 向 API Server 注册本节点, 上报资源容量

2. Pod 管理
   ├── 从 API Server 获取分配给本节点的 Pod 列表
   ├── 调用 CRI 接口创建/启动/停止容器
   ├── 调用 CNI 接口配置 Pod 网络
   └── 调用 CSI 接口挂载/卸载存储卷

3. 健康检查
   ├── Liveness Probe  → 失败则重启容器
   ├── Readiness Probe → 失败则移出 Service
   └── Startup Probe   → 慢启动容器保护

4. 资源监控
   └── 通过 cAdvisor 采集容器资源指标

5. 节点心跳
   └── 每隔 NodeLeaseDuration 上报心跳
```

**三种探针对比：**

| 探针 | 作用 | 失败后果 | 典型场景 |
|------|------|----------|----------|
| **Liveness** | 容器是否存活 | 重启容器 | 死锁、内存泄漏导致无响应 |
| **Readiness** | 容器是否就绪 | 移出 Service | 启动预热、依赖未就绪 |
| **Startup** | 容器是否启动完成 | 重启容器 | 慢启动应用 (保护 Liveness) |

> 🔗 部署脚本: [install_k8s_tools()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — kubelet 安装与启用

---

### 3.2 kube-proxy — 服务代理

**角色：** 实现 Service 的负载均衡，将流量转发到后端 Pod。

```
kube-proxy 三种模式:

┌─────────────────────────────────────────────────────────────┐
│ 模式          原理                    性能      会话亲和     │
├─────────────────────────────────────────────────────────────┤
│ userspace     用户态转发, 慢          ★☆☆☆☆      ✔         │
│ iptables      内核态 NAT 规则         ★★★☆☆      ✘         │
│ IPVS          内核态 L4 负载均衡      ★★★★★      ✔         │
└─────────────────────────────────────────────────────────────┘
```

**IPVS 模式 (推荐):**

```
Client → ClusterIP:Port
              │
              ▼
        ┌──────────┐
        │  IPVS    │  负载均衡算法: rr / lc / sh / dh / wrr
        │  Virtual │
        │  Server  │
        └──────────┘
         ╱    │    ╲
        ▼     ▼     ▼
    Pod A  Pod B  Pod C
```

> 🔗 部署脚本: [system_init()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — 安装 ipvsadm 依赖

---

### 3.3 Container Runtime — 容器引擎

**角色：** 负责拉取镜像、运行和管理容器。K8s 通过 CRI (Container Runtime Interface) 统一接口对接。

```
CRI 体系:

K8s (kubelet)
    │
    ▼  CRI (gRPC 接口)
┌───────────────┐
│ containerd    │ ◄── 推荐, K8s 默认, 轻量
│ (CRI-O)       │ ◄── 专为 K8s 设计, 轻量
│ (Docker)      │ ◄── 已弃用 (需 dockershim 适配)
└───────────────┘
    │
    ▼  OCI 规范
┌───────────────┐
│ runc          │ ◄── 创建容器
│ kata/gVisor   │ ◄── 安全容器 (VM 级隔离)
└───────────────┘
```

**containerd 关键配置：**

| 配置 | 说明 | 部署脚本 |
|------|------|----------|
| `SystemdCgroup = true` | 使用 systemd 管理 cgroup，与 kubelet 一致 | `install_containerd()` |
| `registry.mirrors` | 镜像加速源 | `configure_image_proxy()` |
| `sandbox_image` | Pause 容器镜像 | — |

**OCI 规范层：**

```
OCI (Open Container Initiative):
├── OCI Runtime Spec  → 定义容器运行标准
│   ├── runc (最流行)
│   ├── crun (C 语言实现, 更快)
│   ├── kata-runtime (轻量虚拟化)
│   └── gVisor (用户态内核)
└── OCI Image Spec    → 定义镜像格式标准
```

> 🔗 部署脚本: [install_containerd()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh)

### 3.4 节点维护操作

**Cordon (隔离) / Uncordon (恢复) / Drain (驱逐)：**

```
cordon:   标记节点不可调度, 已运行的 Pod 不受影响
          kubectl cordon node-1

uncordon: 取消隔离, 恢复调度
          kubectl uncordon node-1

drain:    驱逐节点上的 Pod + 标记不可调度
          kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data
```

**Drain 工作原理：**

```
1. kubectl drain node-1 后台执行:
2. cordon node-1          → 标记为不可调度
3. 检查 PodDisruptionBudget → 是否有 PDB 阻止
4. 驱逐 Pod:
   ├── 先 Evict (优雅, 尊重 PDB, 发 SIGTERM)
   └── 后 Delete (强制, 跳过 PDB, --force)
5. 跳过: DaemonSet Pod + 独立 Pod (孤儿) + emptyDir 数据
```

**优雅驱逐流程（单个 Pod）：**

```
API Server 收到 Eviction 请求
    → 创建/更新 PDB 资源记录
    → 向 Pod 对应 Node 的 kubelet 发送 Delete 请求
    → kubelet 向容器发 SIGTERM
    → 等待 terminationGracePeriodSeconds (默认 30s)
    → 超时后发 SIGKILL
    → API Server 更新 Pod 状态为 Terminated
    → Scheduler 选择新节点
    → 新节点 kubelet 创建新 Pod
```

---

## 第四层: 核心工作负载资源

### 4.1 Pod — 最小调度单元

**角色：** 一个或多个容器的组合，共享网络命名空间和存储卷。

```
Pod 内部结构:

┌─────────────────────────────────────┐
│  Pod: my-app                        │
│                                     │
│  ┌─────────────┐  ┌─────────────┐   │
│  │ Container A  │  │ Container B  │   │
│  │  (主容器)     │  │  (Sidecar)  │   │
│  │  localhost ←─┼──┤  localhost   │   │  共享网络
│  │              │  │              │   │
│  └──────┬───────┘  └──────┬───────┘   │
│         └────Volume 共享───┘          │
│                                     │
│  ┌─────────────┐                     │
│  │Pause 容器    │  持有网络命名空间    │
│  └─────────────┘                     │
└─────────────────────────────────────┘
```

**Pod 生命周期完整流程：**

```
1. Pod 创建请求 → API Server → 写入 etcd (status: Pending)
2. Scheduler 调度 → 绑定 Node → status: Pending (nodeName 已设置)
3. kubelet 收到通知 → 拉取镜像
4. Init Containers 按顺序运行 (每个必须成功完成)
5. 主容器启动:
   ├── postStart Hook 执行 (异步, 不阻塞启动)
   ├── Startup Probe 检查 (通过后, Liveness Probe 接管)
   ├── Readiness Probe 检查 (通过后加入 Service)
   └── Liveness Probe 持续检查
6. Pod Running → 正常运行

7. Pod 终止:
   ├── preStop Hook 执行
   ├── SIGTERM 发送到容器主进程
   ├── 等待 terminationGracePeriodSeconds (默认 30s)
   ├── SIGKILL 强制终止
   └── Pod 从 API Server 移除
```

**Init Containers (初始化容器)：**

```yaml
spec:
  initContainers:
  - name: init-db
    image: busybox
    command: ['sh', '-c', 'until nslookup mydb; do sleep 2; done']
  - name: init-migration
    image: myapp
    command: ['./migrate-db.sh']
  containers:
  - name: app
    image: myapp
```

| 特性 | Init Container | 普通 Container |
|------|---------------|----------------|
| 运行时机 | 主容器之前 | 主容器 |
| 执行顺序 | 严格按顺序 | 并行 |
| 资源限制 | 独立设置 | 独立设置 |
| 重试策略 | restartPolicy 控制 | restartPolicy 控制 |
| 典型用途 | 数据库迁移/等待依赖/权限设置 | 业务逻辑 |

**Pod 生命周期钩子 (Lifecycle Hooks)：**

```yaml
containers:
- name: app
  lifecycle:
    postStart:            # 容器启动后立即执行 (与 ENTRYPOINT 并行)
      exec:
        command: ["/bin/sh", "-c", "echo 'started' > /tmp/started"]
    preStop:              # 容器终止前执行 (阻塞, 必须先完成)
      exec:
        command: ["/bin/sh", "-c", "nginx -s quit; sleep 20"]
```

**重启策略 (restartPolicy)：**

| 值 | 行为 | 适用场景 |
|----|------|---------|
| `Always` | 总是重启 | Deployment/StatefulSet/DaemonSet (默认) |
| `OnFailure` | 失败时重启 (退出码非 0) | Job |
| `Never` | 永不重启 | 一次性任务 |

**镜像拉取策略 (imagePullPolicy)：**

| 值 | 行为 |
|----|------|
| `Always` | 每次创建 Pod 都拉取 (默认 `latest` 标签) |
| `IfNotPresent` | 本地有就不拉 (默认非 `latest` 标签) |
| `Never` | 仅使用本地镜像 |

---

### 4.2 Deployment — 无状态应用管理

**角色：** 管理 ReplicaSet，提供声明式更新、滚动升级和回滚。

```
Deployment ──创建──► ReplicaSet ──创建──► Pod × N

更新策略:
├── RollingUpdate (默认)
│   └── 逐步替换旧 Pod, 滚动期间保持可用
│
└── Recreate
    └── 先删光旧 Pod, 再创建新 Pod (有短暂中断)
```

**滚动更新过程:**

```
时刻 T0:  [v1] [v1] [v1]          3 个旧版本
时刻 T1:  [v1] [v1] [v1] [v2]     创建 1 个新版本
时刻 T2:  [v1] [v1] [v2] [v2]     再替换 1 个
时刻 T3:  [v1] [v2] [v2] [v2]     最终 3 个新版本
```

**回滚：**

```bash
kubectl rollout undo deployment/my-app          # 回滚到上一版本
kubectl rollout undo deployment/my-app --to-revision=3  # 回滚到指定版本
kubectl rollout history deployment/my-app       # 查看版本历史
```

---

### 4.3 StatefulSet — 有状态应用管理

**角色：** 为每个 Pod 提供稳定的网络标识和持久存储。

```
StatefulSet vs Deployment:

┌──────────────┬─────────────────┬─────────────────────┐
│ 特性         │ Deployment      │ StatefulSet         │
├──────────────┼─────────────────┼─────────────────────┤
│ Pod 名称     │ 随机后缀        │ 有序编号 (app-0,1,2)│
│ 网络标识     │ 不固定          │ 稳定 DNS             │
│ 存储         │ 共享 PVC        │ 每个 Pod 独立 PVC    │
│ 启动顺序     │ 并行            │ 0→1→2 依次启动       │
│ 删除顺序     │ 并行            │ 2→1→0 逆序删除       │
│ 典型应用     │ Web API, Nginx  │ MySQL, Kafka, Redis  │
└──────────────┴─────────────────┴─────────────────────┘
```

**Headless Service + StatefulSet:**

```
Service: db (clusterIP: None)  ← Headless Service
    │
    ├── db-0.db.default.svc.cluster.local  → 10.0.1.10
    ├── db-1.db.default.svc.cluster.local  → 10.0.1.11
    └── db-2.db.default.svc.cluster.local  → 10.0.1.12
```

---

### 4.4 DaemonSet — 每节点守护

**角色：** 确保每个（或部分）Node 上运行一个 Pod 副本。

```
典型用途:
├── 日志采集    → Fluentd / Filebeat
├── 监控 Agent  → Prometheus Node Exporter
├── 网络插件    → Calico / Flannel / Cilium agent
├── 存储插件    → CSI Node Plugin
└── GPU 驱动    → NVIDIA Device Plugin
```

---

### 4.5 Job & CronJob

```
Job:   一次性任务, 确保指定数量的 Pod 成功完成
       ├── 并行 Job
       ├── 串行 Job
       └── 带完成次数的 Job

CronJob:  定时任务, 类似 Linux crontab
          └── CronJob ──创建──► Job ──创建──► Pod
```

```yaml
# CronJob 示例 — 每天凌晨 2 点执行数据库备份
apiVersion: batch/v1
kind: CronJob
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: mysql:8.0
            command: ["mysqldump", "-h", "db", "mydb"]
          restartPolicy: OnFailure
```

### 4.6 ReplicaSet — 副本控制器

**角色：** 确保指定数量的 Pod 副本始终运行。Deployment 通过管理 ReplicaSet 来实现版本管理。

```
ReplicaSet 工作机制:

1. 通过 label selector 匹配 Pod
2. 如果实际 Pod 数 < replicas → 从 template 创建 Pod
3. 如果实际 Pod 数 > replicas → 删除多余的 Pod
4. 如果 Pod 被意外删除 → 自动重建

关键三要素:
├── replicas: 期望副本数
├── selector:  Pod 选择器 (matchLabels / matchExpressions)
└── template:  Pod 模板
```

**Owner References 级联关系：**

```
Deployment
  └── ownerReferences → apiVersion: apps/v1, kind: Deployment, name: my-app
       │
       ▼
  ReplicaSet
     └── ownerReferences → apiVersion: apps/v1, kind: ReplicaSet, name: my-app-abc123
          │
          ▼
     Pod
       └── ownerReferences → apiVersion: apps/v1, kind: ReplicaSet, name: my-app-abc123
```

> 级联删除: 删除 Deployment 时，K8s 自动级联删除其 ReplicaSet 和 Pod（通过 Owner References + Garbage Collector）。

### 4.7 Namespace — 资源隔离与配额

**角色：** 命名空间是 K8s 中实现多租户隔离的核心机制，将集群资源划分为逻辑分区。

```
┌──────────────────────────────────────────────────┐
│  K8s 集群                                         │
│  ┌─────────────────┐  ┌─────────────────┐        │
│  │ namespace: dev   │  │ namespace: prod  │        │
│  │ ┌────┐ ┌────┐   │  │ ┌────┐ ┌────┐   │        │
│  │ │Pod │ │Svc │   │  │ │Pod │ │Svc │   │        │
│  │ └────┘ └────┘   │  │ └────┘ └────┘   │        │
│  │ ResourceQuota    │  │ ResourceQuota    │        │
│  │ LimitRange       │  │ LimitRange       │        │
│  └─────────────────┘  └─────────────────┘        │
│  ┌─────────────────┐                              │
│  │ namespace: kube- │  系统命名空间                │
│  │     system      │                              │
│  └─────────────────┘                              │
└──────────────────────────────────────────────────┘
```

**ResourceQuota (资源配额)：** 限制 Namespace 的资源总量

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "10"           # CPU 请求总量上限
    requests.memory: 20Gi        # 内存请求总量上限
    limits.cpu: "20"             # CPU 限制总量上限
    limits.memory: 40Gi          # 内存限制总量上限
    persistentvolumeclaims: "5"  # PVC 数量上限
    services: "10"               # Service 数量上限
    secrets: "20"                # Secret 数量上限
    configmaps: "20"             # ConfigMap 数量上限
    pods: "50"                   # Pod 数量上限
```

**LimitRange (默认限制)：** 为 Namespace 中的容器设置默认资源请求/限制

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: dev
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"        # 未设 limits 时默认值
      memory: "512Mi"
    defaultRequest:
      cpu: "200m"        # 未设 requests 时默认值
      memory: "256Mi"
    max:
      cpu: "4"            # 单个容器上限
      memory: "8Gi"
    min:
      cpu: "50m"          # 单个容器下限
      memory: "64Mi"
```

---

## 第五层: 服务发现与网络

### 5.1 K8s 网络模型

K8s 网络的三个核心要求：

```
1. 所有 Pod 可以互相通信 (无需 NAT)
2. 所有 Node 可以与所有 Pod 通信 (无需 NAT)
3. Pod 看到的自己的 IP 与其他 Pod 看到的一致
```

**跨节点通信流程 (以 Flannel VXLAN 为例):**

```
Node A                    Node B
┌───────────┐            ┌───────────┐
│ Pod A     │            │ Pod B     │
│ 10.244.1.5│            │ 10.244.2.8│
└─────┬─────┘            └─────┬─────┘
      │eth0                    │eth0
┌─────▼─────┐            ┌─────▼─────┐
│  cni0     │            │  cni0     │
│10.244.1.1 │            │10.244.2.1 │
└─────┬─────┘            └─────┬─────┘
      │flannel.1               │flannel.1  ← VXLAN 隧道设备
┌─────▼───────────────────┐    │
│eth0: 192.168.1.10       │    │
└─────────────────────────┘    │
         │                     │
         └──── 物理网络 ────────┘
         VXLAN 封装: 外层 IP 头 + UDP + 内层原始包
```

---

### 5.2 Service — 服务发现与负载均衡

```
Service 类型:

┌──────────────┬──────────────────────────────────────┐
│ ClusterIP    │ 集群内部访问 (默认)                   │
│ NodePort     │ 通过 NodeIP:30000-32767 暴露          │
│ LoadBalancer │ 云厂商 LB 暴露公网                    │
│ ExternalName │ DNS CNAME 映射到外部服务              │
│ Headless     │ clusterIP: None, 直接返回 Pod IP 列表 │
└──────────────┴──────────────────────────────────────┘
```

**Service 工作原理:**

```
Client → my-svc:80
              │
              ▼  kube-proxy / IPVS
         ┌─────────┐
         │Selector:│  app=web
         └─────────┘
              │
      ┌───────┼───────┐
      ▼       ▼       ▼
  Pod A    Pod B    Pod C
  (Ready)  (Ready)  (Ready)
```

---

### 5.3 Ingress — HTTP/HTTPS 路由

```
                     ┌──────────────────────┐
                     │    Ingress Controller │
                     │    (Nginx/Traefik)    │
Internet ──► LB ──► └──────────┬───────────┘
                               │
                  ┌────────────┼────────────┐
                  ▼            ▼            ▼
            /api/*       /app/*        /*
            Service A    Service B    Service C
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /v1
        backend:
          service:
            name: api-v1
            port:
              number: 8080
      - path: /v2
        backend:
          service:
            name: api-v2
            port:
              number: 8080
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls-cert
```

> 🔗 部署脚本: [install_addons()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — Ingress Nginx 安装

---

### 5.4 CNI 网络插件

| 插件 | 数据面 | 网络策略 | 加密 | 部署脚本 |
|------|--------|----------|------|----------|
| **Flannel** | VXLAN / Host-GW | ✘ | ✘ | [select_cni_plugin()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) |
| **Calico** | BGP / VXLAN / IPIP | ✔ | WireGuard | [install_cni()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) |
| **Cilium** | eBPF | ✔ | IPsec/WireGuard | [install_cni()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) |
| **Weave** | VXLAN | ✔ | NaCl | [install_cni()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) |

---

### 5.5 CoreDNS — 集群 DNS

```
Pod 发起 DNS 查询: my-svc.default.svc.cluster.local

1. Pod /etc/resolv.conf 指向 CoreDNS Service IP
2. CoreDNS 根据 Service 名返回 ClusterIP
3. 如果查的是 Pod 名 (StatefulSet), 返回 Pod IP
```

**DNS 命名规范:**

```
<service-name>.<namespace>.svc.<cluster-domain>
     ↓              ↓        ↓         ↓
   my-svc        default    svc     cluster.local
```

### 5.6 NetworkPolicy — 网络策略

**角色：** 定义 Pod 之间的网络访问规则，实现微分段 (Micro-Segmentation)。需要 CNI 插件支持（Calico/Cilium/Weave 支持，Flannel 不支持）。

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-network-policy
spec:
  podSelector:
    matchLabels:
      app: api           # 目标: 标签为 app=api 的 Pod
  policyTypes:
  - Ingress             # 入站规则
  - Egress              # 出站规则
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend # 允许来自 role=frontend 的 Pod
    - namespaceSelector:
        matchLabels:
          env: monitoring # 允许来自 monitoring 命名空间的 Pod
    - ipBlock:
        cidr: 10.0.0.0/8 # 允许来自 IP 段的流量
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database  # 允许访问 app=database 的 Pod
    ports:
    - protocol: TCP
      port: 5432
```

**默认策略（零信任）：**

```yaml
# 拒绝所有入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}       # 空 = 选择所有 Pod
  policyTypes:
  - Ingress
```

**NetworkPolicy 选择器组合规则：**

```
from / to 中的多个条目是 OR 关系:
  from:
  - podSelector: {role: frontend}  ← 条件 A
  - namespaceSelector: {env: dev}  ← 条件 B
  → 满足 A 或 B 的流量都放行

同一个条目内的多个条件是 AND 关系:
  from:
  - podSelector: {role: frontend}    ← 条件 A1
    namespaceSelector: {env: dev}    ← 条件 A2
  → 必须同时满足 A1 和 A2
```

### 5.7 Gateway API — 下一代 Ingress

**角色：** Gateway API 是 Kubernetes SIG-Network 推出的新一代网关 API，旨在取代 Ingress，提供更强大的流量管理能力。

```
Ingress vs Gateway API:

┌──────────────┬────────────────────┬──────────────────────┐
│              │ Ingress            │ Gateway API          │
├──────────────┼────────────────────┼──────────────────────┤
│ 角色分离     │ 开发者+运维混在一起  │ 运维定义 Gateway, 开发者定义 Route │
│ 协议支持     │ HTTP/HTTPS         │ HTTP/HTTPS/TCP/UDP   │
│ 流量管理     │ 基础路由           │ 权重分流/Header匹配/重写/镜像 │
│ 跨命名空间   │ 不支持             │ 支持 Route 跨 NS 引用 │
│ 扩展性       │ 靠 Annotation      │ 原生扩展 Policy        │
└──────────────┴────────────────────┴──────────────────────┘
```

**Gateway API 三大核心资源：**

```yaml
# 1. GatewayClass — 集群管理员定义网关类型
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller

---
# 2. Gateway — 运维人员部署网关实例
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All  # 允许所有命名空间的 Route 绑定

---
# 3. HTTPRoute — 开发者定义路由规则
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
spec:
  parentRefs:
  - name: prod-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api/v1
    backendRefs:
    - name: api-v1
      port: 8080
      weight: 90     # 90% 流量
  - matches:
    - path:
        type: PathPrefix
        value: /api/v2
    backendRefs:
    - name: api-v2
      port: 8080
      weight: 10     # 10% 流量 (金丝雀发布)
```

---

## 第六层: 存储体系

### 6.1 存储抽象层

```
PV (PersistentVolume)      PVC (PersistentVolumeClaim)     Pod
    │                              │                        │
    │ 管理员预配/动态创建            │ 用户申请存储              │ 挂载使用
    │                              │                        │
    └────────── Bound ─────────────┘────────────────────────┘
```

### 6.2 存储类型

| 类型 | 生命周期 | 用途 |
|------|----------|------|
| **emptyDir** | 随 Pod 生命周期 | 临时缓存、共享数据 |
| **hostPath** | 节点本地路径 | 日志采集、Docker socket |
| **PV/PVC** | 独立于 Pod | 持久化数据 |
| **ConfigMap/Secret** | 独立于 Pod | 配置文件、密钥 |
| **CSI** | 外部存储插件 | 云盘、NAS、Ceph |

### 6.3 存储类 (StorageClass) 与动态供给

```
用户创建 PVC (指定 StorageClass)
          │
          ▼
StorageClass → Provisioner (CSI)
          │
          ▼
    自动创建 PV → 绑定 PVC → Pod 挂载
```

```yaml
# 用户只需声明 PVC，PV 自动创建
apiVersion: v1
kind: PersistentVolumeClaim
spec:
  storageClassName: ssd
  resources:
    requests:
      storage: 10Gi
```

### 6.4 CSI (Container Storage Interface)

```
K8s (kubelet / controller-manager)
    │                  │
    ▼                  ▼
CSI Driver  ───┬─── CSI Controller Plugin (创建/删除/快照)
               │     └── 运行在控制面
               │
               └─── CSI Node Plugin (挂载/卸载/格式化)
                     └── 运行在每个 Node (DaemonSet)
```

### 6.5 Volume 类型详解

| 类型 | 数据生命周期 | 典型用途 |
|------|-------------|----------|
| **emptyDir** | 随 Pod | 临时缓存、共享数据 (Pod 内容器间通信) |
| **hostPath** | 随 Node | 访问宿主机文件、DaemonSet 日志采集 |
| **configMap** | 随 ConfigMap | 配置文件注入 |
| **secret** | 随 Secret | 密钥/证书注入 |
| **downwardAPI** | 随 Pod | 暴露 Pod 元信息给容器 |
| **projected** | 组合多个源 | 将多个卷源合并到一个目录 |
| **PVC** | 独立于 Pod | 持久化存储 |

#### Downward API — 向容器暴露 Pod 信息

```yaml
volumes:
- name: podinfo
  downwardAPI:
    items:
    - path: "labels"           # 文件内容: Pod 标签
      fieldRef:
        fieldPath: metadata.labels
    - path: "annotations"      # 文件内容: Pod 注解
      fieldRef:
        fieldPath: metadata.annotations
    - path: "cpu-limit"
      resourceFieldRef:
        containerName: app
        resource: limits.cpu    # 暴露容器资源限制
        divisor: "1m"

env:  # 或通过环境变量
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
```

#### Projected Volume — 多源组合

```yaml
volumes:
- name: all-in-one
  projected:
    sources:
    - secret:
        name: tls-certs
    - configMap:
        name: app-config
    - downwardAPI:
        items:
        - path: "pod-name"
          fieldRef:
            fieldPath: metadata.name
    - serviceAccountToken:
        audience: api
        expirationSeconds: 3600
        path: token
```

#### Ephemeral Volumes (临时卷) — K8s 1.23+

```yaml
# 通用临时卷 (Generic Ephemeral Volume)
# 声明周期与 Pod 绑定, 支持 StorageClass 动态创建
volumes:
- name: scratch
  ephemeral:
    volumeClaimTemplate:
      spec:
        storageClassName: ssd
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

---

## 第七层: 配置与安全

### 7.1 ConfigMap — 配置管理

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  app.properties: |
    server.port=8080
    db.host=mysql.default.svc.cluster.local
  log-level: debug
```

**三种使用方式：**

| 方式 | 示例 | 特性 |
|------|------|------|
| 环境变量 | `envFrom.configMapRef` | 静态，不更新 |
| 命令行参数 | `$(CONFIG_KEY)` | 静态 |
| 文件挂载 | `volumes.configMap` | 支持热更新 (需应用 reload) |

---

### 7.2 Secret — 敏感信息

```
Secret vs ConfigMap:

┌──────────┬──────────────┬──────────────┐
│          │ ConfigMap    │ Secret       │
├──────────┼──────────────┼──────────────┤
│ 数据编码 │ 明文         │ Base64       │
│ 存储     │ API Server   │ API Server 或外部加密 │
│ etcd 加密│ 默认不加密    │ 可开启加密存储 │
│ 内存     │ tmpfs 挂载   │ tmpfs 挂载 (不落盘) │
│ RBAC     │ 可隔离       │ 可隔离       │
└──────────┴──────────────┴──────────────┘
```

**Secret 类型：**

| 类型 | 用途 |
|------|------|
| `Opaque` | 通用键值对 (默认) |
| `kubernetes.io/tls` | TLS 证书 |
| `kubernetes.io/dockerconfigjson` | 镜像仓库认证 |
| `kubernetes.io/basic-auth` | 基础认证 |
| `kubernetes.io/service-account-token` | SA Token |

**etcd 静态加密 (Encryption at Rest)：**

默认情况下 K8s Secret 在 etcd 中仅以 Base64 编码存储（非加密）。启用 EncryptionConfiguration 可实现真正的静态加密。

```
不加密:   etcd 中的 Secret.data = Base64(原始值)  ← 可逆
加密后:   etcd 中的 Secret.data = AES-CBC(Base64(原始值))  ← 需密钥解密
```

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets        # 对 Secret 加密
  - configmaps     # (可选) 对 ConfigMap 也加密
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}   # 兜底: 明文存储 (用于渐进式迁移)
```

```bash
# 启用加密:
# 1. 创建 encryption-config.yaml
# 2. 修改 /etc/kubernetes/manifests/kube-apiserver.yaml:
#    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
#    - 挂载 hostPath volume
# 3. API Server 自动重启后生效

# 重新加密所有现有 Secret:
kubectl get secrets --all-namespaces -o json | \
  kubectl replace -f -
```

---

### 7.3 RBAC — 基于角色的访问控制

```
RBAC 四要素:

Subject (主体)        → Role / ClusterRole (角色) → RoleBinding (绑定)
├── User                         ├── 定义权限             └── 关联主体和角色
├── Group                        └── verbs + resources
└── ServiceAccount
```

```yaml
# 角色: 允许读 Pod
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]

---
# 绑定: 将角色赋予 ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: default
subjects:
- kind: ServiceAccount
  name: reader-sa
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

---

### 7.4 Pod Security — 安全上下文

```yaml
spec:
  securityContext:
    runAsNonRoot: true        # 禁止 root 运行
    runAsUser: 1000            # 指定 UID
    fsGroup: 2000              # 文件系统组
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]          # 删除所有 Linux Capability
        add: ["NET_BIND_SERVICE"]
```

### 7.5 ServiceAccount — 工作负载身份

**角色：** ServiceAccount (SA) 是 Pod 在集群内使用的身份，用于访问 API Server 和其他集群资源。每个 Namespace 有默认 SA `default`。

```
ServiceAccount 工作流程:

1. 创建 SA 时, K8s 自动创建对应的 Secret (Token)
2. Pod 指定 serviceAccountName, Token 自动挂载到 /var/run/secrets/kubernetes.io/serviceaccount/
3. Pod 内的应用通过 Token 调用 API Server
4. API Server 验证 Token → 提取 SA 身份 → RBAC 鉴权

Token 挂载内容:
/var/run/secrets/kubernetes.io/serviceaccount/
├── token       ← JWT Token (有效期有限, 自动轮换)
├── ca.crt      ← API Server CA 证书
└── namespace   ← Pod 所在 NS
```

**IRSA (IAM Roles for Service Accounts) — AWS 场景：**

传统做法是将云凭证（Access Key/Secret Key）放入 Secret 或环境变量，存在安全隐患。IRSA 通过 OIDC Federation 将 IAM Role 与 SA 关联。

```
AWS IRSA 流程:

1. 集群创建 OIDC Provider (AWS IAM)
2. 创建 IAM Role, Trust Policy 允许 SA 扮演
3. SA 添加 Annotation:
   eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/my-app-role
4. Pod 挂载 Projected ServiceAccountToken (含 aud 字段)
5. AWS SDK 通过 Token 兑换临时凭证 (STS)
6. 应用获得 IAM Role 权限访问 AWS 资源 (S3/DynamoDB/...)
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456:role/s3-reader
---
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: s3-reader
  containers:
  - name: app
    image: amazon/aws-cli
```

**禁止自动挂载 Token：**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: no-api-access
automountServiceAccountToken: false  # Pod 不会自动挂载 Token
```

### 7.6 Pod Security Admission (PSA) — 安全准入

**背景：** K8s 1.25 移除了 PodSecurityPolicy (PSP)，取而代之的是 Pod Security Admission (PSA)，更简单、更高效。

**三种安全策略级别：**

| 级别 | 说明 | 典型限制 |
|------|------|----------|
| **privileged** | 无限制 | 允许一切 |
| **baseline** | 最低安全标准 | 禁止 hostPath/hostNetwork/privileged 容器 |
| **restricted** | 严格限制 | baseline + 禁止 root 运行/特权提升/非标准 capabilities |

**使用方式（Namespace 标签）：**

```bash
# 整个 Namespace 使用 restricted 策略
kubectl label ns my-ns pod-security.kubernetes.io/enforce=restricted

# 仅警告, 不拦截
kubectl label ns my-ns pod-security.kubernetes.io/warn=restricted

# 审计
kubectl label ns my-ns pod-security.kubernetes.io/audit=restricted

# 豁免特定用户/SA/RuntimeClass
kubectl label ns my-ns pod-security.kubernetes.io/enforce=restricted
kubectl label ns my-ns pod-security.kubernetes.io/enforce-version=latest
kubectl label ns my-ns pod-security.kubernetes.io/exempt-users=admin
```

### 7.7 准入控制器 (Admission Controllers)

**角色：** 拦截 API Server 的请求，在对象持久化到 etcd 之前执行验证或修改。

```
内置准入控制器 (部分):

命名空间生命周期:
├── NamespaceLifecycle    → 防止在 terminating namespace 创建资源
└── NamespaceExists       → 拒绝使用不存在的 namespace

资源管理:
├── ResourceQuota         → 检查 namespace 的 ResourceQuota
├── LimitRanger           → 应用 LimitRange 默认值
├── LimitPodHardAntiAffinityTopology → 限制反亲和拓扑域

安全:
├── NodeRestriction       → 限制 kubelet 对 Node/Pod 的修改范围
├── SecurityContextDenial  → 拒绝不安全的 SecurityContext (K8s < 1.25)
└── PodSecurity           → 实施 Pod Security Standards (K8s 1.25+)

存储:
├── PersistentVolumeClaimResize → 允许/拒绝 PVC 扩容请求
└── StorageObjectInUseProtection → 保护正在使用的 PV/PVC

其他:
├── MutatingAdmissionWebhook  → 调用外部 Mutating Webhook (可修改对象)
├── ValidatingAdmissionWebhook → 调用外部 Validating Webhook (仅验证)
├── DefaultStorageClass       → 为 PVC 设置默认 StorageClass
└── DefaultIngressClass       → 为 Ingress 设置默认 IngressClass
```

**Webhook 工作流程：**

```
                    ┌─────────────────┐
                    │   API Server    │
                    └───────┬─────────┘
                            │ 请求
                    ┌───────▼─────────┐
                    │ Mutating        │  修改对象 (注入 Sidecar/挂载卷)
                    │ Webhooks        │
                    └───────┬─────────┘
                            │ 修改后的对象
                    ┌───────▼─────────┐
                    │ Validating      │  验证对象 (拒绝/放行)
                    │ Webhooks        │
                    └───────┬─────────┘
                            │
                    ┌───────▼─────────┐
                    │     etcd        │  持久化
                    └─────────────────┘
```

> 🔗 部署脚本: [install_k8s_tools()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — kubeadm 会启用默认的准入控制器插件

---

## 第八层: 调度与资源管理

### 8.1 资源请求与限制

```yaml
resources:
  requests:      # 调度器保证的最低资源
    cpu: "500m"  # 0.5 核
    memory: "512Mi"
  limits:        # 容器允许使用的最大资源
    cpu: "2"     # 2 核
    memory: "2Gi"
```

**资源 QoS 等级：**

```
┌────────────────┬─────────────────┬─────────────────┐
│ Guaranteed     │ Burstable       │ BestEffort      │
│ (高优先级)      │ (中优先级)       │ (低优先级)       │
├────────────────┼─────────────────┼─────────────────┤
│ requests=limits│ requests<limits │ 未设 requests   │
│ 最后被驱逐      │ 可能被驱逐       │ 最先被驱逐       │
└────────────────┴─────────────────┴─────────────────┘
```

---

### 8.2 HPA — 水平自动扩缩

```
             ┌──────────────┐
             │ Metrics      │  采集指标
             │ Server       │  └── CPU / Memory / 自定义指标
             └──────┬───────┘
                    │
             ┌──────▼───────┐
             │     HPA      │  计算期望副本数
             │              │  desired = ceil( current * (currentMetric / desiredMetric))
             └──────┬───────┘
                    │
             ┌──────▼───────┐
             │  Deployment  │  调整 replicas
             └──────────────┘
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

> 🔗 部署脚本: [install_addons()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — Metrics Server 安装

**VPA (Vertical Pod Autoscaler) — 垂直自动扩缩：**

与 HPA 水平扩展不同，VPA 调整的是单个 Pod 的 CPU/内存资源请求量。

```
HPA vs VPA:

┌─────────┬────────────────────┬──────────────────────┐
│         │ HPA                │ VPA                  │
├─────────┼────────────────────┼──────────────────────┤
│ 扩展方向 │ 水平 (增加 Pod 数量) │ 垂直 (增加 Pod 资源)  │
│ 适用    │ 无状态服务          │ 资源预估不准的服务     │
│ 触发    │ 实时指标超标        │ 历史使用量分析         │
│ 限制    │ 最多扩到 maxReplicas│ OOM 后自动调高         │
│ 副作用  │ Pod 数变化           │ Pod 重建 (需重启)      │
└─────────┴────────────────────┴──────────────────────┘
```

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: Auto      # Off / Initial / Auto
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: "4"
        memory: 8Gi
```

| VPA 更新模式 | 说明 |
|-------------|------|
| `Off` | 仅计算推荐值，不自动更新 |
| `Initial` | 仅创建时设置资源，不更新运行中的 Pod |
| `Auto` | 自动驱逐并重建 Pod 以应用新资源 |
| `Recreate` | 与 Auto 类似，但不优雅驱逐 |

**Cluster Autoscaler — 集群节点自动扩缩：**

```
多层扩缩体系:

Cluster Autoscaler → 增加/减少 Node
        │
        ▼
HPA (水平)        → 增加/减少 Pod 副本数
VPA (垂直)        → 增加/减少单个 Pod 的 CPU/内存
```

```yaml
# Cluster Autoscaler 根据 Pending Pod 自动扩容节点
# 缩容条件: 节点利用率低 + 关键 Pod 不会被驱逐 + 满足最短空闲时间

# 部署方式 (以 AWS EKS 为例):
# 1. 创建 Auto Scaling Group (ASG)
# 2. 部署 cluster-autoscaler
# 3. 设置节点的 min/max:
#    kubectl annotate node worker-1 cluster-autoscaler.kubernetes.io/safe-to-evict=true
```

---

### 8.3 Taints & Tolerations — 节点排斥与容忍

```
Taint (污点) 在 Node 上:
  kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule

Toleration (容忍) 在 Pod 上:
  spec:
    tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
```

**三种 Effect:**

| Effect | 行为 |
|--------|------|
| `NoSchedule` | 新 Pod 不会被调度到此节点 |
| `PreferNoSchedule` | 尽量不调度到此节点 (软限制) |
| `NoExecute` | 已有 Pod 也会被驱逐 |

> 🔗 部署脚本: [configure_master_mode()](file:///Users/xyx/Documents/kubernetes-shell/k8s-deploy.sh) — Master 污点配置

---

### 8.4 Node Affinity / Pod Affinity

```yaml
# Node Affinity: Pod 调度到有 GPU 标签的节点
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: gpu
          operator: In
          values: ["nvidia-a100"]

# Pod Anti-Affinity: 同 app 的 Pod 分散到不同节点
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app
          operator: In
          values: ["web"]
      topologyKey: kubernetes.io/hostname
```

### 8.5 Pod Disruption Budget (PDB) — 中断预算

**角色：** 限制自愿中断 (Voluntary Disruption) 期间可以同时不可用的 Pod 数量，确保应用高可用。

```
自愿中断 vs 非自愿中断:

自愿中断 (可控制):
├── kubectl drain 驱逐节点
├── Deployment 滚动更新
├── 直接删除 Pod
└── HPA 缩容

非自愿中断 (不可控):
├── 节点硬件故障
├── 内核 panic
├── 云实例被回收
└── 网络分区导致节点失联
```

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
spec:
  minAvailable: 2         # 最少保持 2 个 Pod 可用
  # 或者: maxUnavailable: 1  # 最多 1 个 Pod 不可用
  selector:
    matchLabels:
      app: api
```

**PDB 与 Drain 的交互：**

```
kubectl drain node-1
  → 检查 PDB, 如果驱逐 Pod 会导致 minAvailable 不满足
    → drain 被阻塞, 等待 Pod 在新节点 Ready
    → 或使用 --disable-eviction 强制 Delete
```

### 8.6 PriorityClass — Pod 优先级与抢占

**角色：** 为 Pod 设置优先级，资源紧张时高优先级 Pod 可以抢占 (Preempt) 低优先级 Pod。

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000                    # 数值越大优先级越高
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "用于生产环境关键服务"

---
# 系统内置 PriorityClass:
# system-cluster-critical:  2000000000  (kube-system 组件)
# system-node-critical:     2000001000  (kubelet/DaemonSet)
```

```yaml
# Pod 引用 PriorityClass
spec:
  priorityClassName: high-priority
```

**抢占过程：**

```
1. Scheduler 发现 Pod pending (资源不足)
2. 选择一个节点, 计算需要驱逐哪些 Pod
3. 按优先级从低到高排序被驱逐的目标 Pod
4. 驱逐低优先级 Pod (优雅终止)
5. 调度高优先级 Pod 到该节点
```

### 8.7 Topology Manager — NUMA 感知调度

**角色：** 协调 CPU Manager、Memory Manager、Device Plugin，确保 Pod 的 CPU/内存/设备在同一个 NUMA 节点上，避免跨 NUMA 访问的延迟。

```
NUMA (Non-Uniform Memory Access):

┌──────── Node ───────────────────────────────────────┐
│  ┌──── NUMA 0 ──────────┐  ┌──── NUMA 1 ──────────┐│
│  │ CPU 0-7               │  │ CPU 8-15             ││
│  │ Memory: 64GB          │  │ Memory: 64GB         ││
│  │ GPU 0                 │  │ GPU 1                ││
│  └───────────────────────┘  └───────────────────────┘│
└─────────────────────────────────────────────────────┘

跨 NUMA 访问: CPU 0 访问 NUMA 1 内存 → 延迟 2x
最优配置: Pod 的 CPU + 内存 + GPU 全在 NUMA 0
```

**Topology Manager 四种策略：**

| 策略 | 说明 |
|------|------|
| `none` | 不做任何拓扑对齐 (默认) |
| `best-effort` | 尽量对齐，失败也不拒绝 |
| `restricted` | 必须对齐，否则拒绝调度 |
| `single-numa-node` | 所有资源必须在同一个 NUMA 节点，最严格 |

```yaml
# kubelet 配置
cpuManagerPolicy: static
topologyManagerPolicy: single-numa-node
topologyManagerScope: pod  # container 或 pod
```

---

## 第九层: 可观测性与进阶主题

### 9.1 监控体系 (Prometheus + Grafana)

```
采集层:
┌──────────────┐
│ Prometheus   │──► Node Exporter        (节点指标)
│              │──► kube-state-metrics   (K8s 对象状态指标)
│              │──► cAdvisor (内嵌 kubelet) (容器资源指标)
│              │──► App Metrics          (应用自定义指标)
└──────┬───────┘
       │
告警层: ┌────▼─────┐
       │AlertManager│ → Slack / PagerDuty / 邮件
       └──────────┘
       │
可视化: ┌────▼─────┐
       │  Grafana  │
       └──────────┘
```

---

### 9.2 日志体系 (EFK/Loki)

```
EFK Stack:                      Loki Stack:
┌──────────┐                    ┌──────────┐
│ Fluentd  │ (DaemonSet)        │ Promtail │ (DaemonSet)
│ 采集转发  │                    │ 采集转发  │
└────┬─────┘                    └────┬─────┘
     ▼                               ▼
┌──────────┐                    ┌──────────┐
│Elasticsearch│                 │   Loki   │
│ 存储检索   │                   │ 存储检索  │
└────┬─────┘                    └────┬─────┘
     ▼                               ▼
┌──────────┐                    ┌──────────┐
│  Kibana  │                    │ Grafana  │
│ 可视化    │                    │ 可视化    │
└──────────┘                    └──────────┘
```

---

### 9.3 Service Mesh (Istio)

```
无 Service Mesh:         有 Service Mesh (Istio):
App A → App B           App A → Envoy Sidecar → Envoy Sidecar → App B
                                ├─ mTLS 加密
                                ├─ 流量管理 (金丝雀/蓝绿)
                                ├─ 可观测性 (Tracing)
                                └─ 策略控制 (限流/熔断)
```

---

### 9.4 CRD 与 Operator 模式

```
CRD (CustomResourceDefinition)   → 扩展 K8s API, 定义自定义资源
Operator                         → 自定义控制器 + CRD, 自动化运维
```

```
Prometheus Operator 示例:
Probe ──创建─→ Probe CRD ──Watch──→ Prometheus Operator
                                        │
                              ┌─────────┼─────────┐
                              ▼         ▼         ▼
                         生成配置    热加载    告警规则
```

---

### 9.5 备份与灾难恢复

```
备份策略:

1. etcd 快照 (集群状态)
   etcdctl snapshot save /backup/snapshot-$(date +%Y%m%d).db

2. 资源 YAML 导出 (GitOps)
   kubectl get all --all-namespaces -o yaml > cluster-backup.yaml

3. 持久卷数据备份 (Velero)
   velero backup create full-backup --include-namespaces '*'

恢复:
   etcdctl snapshot restore /backup/snapshot.db --data-dir=/var/lib/etcd-restore
```

### 9.6 Helm — 包管理器

**角色：** Helm 是 K8s 的包管理器，类似 `apt`/`yum`/`brew`。通过 Chart 封装 K8s 资源，实现一键安装、升级、回滚。

```
Helm 核心概念:

Chart       → 打包的 K8s 应用 (模板 + 配置)
Repository  → Chart 仓库 (类似 Docker Hub)
Release     → Chart 的运行实例 (可以安装同一个 Chart 多次)
Values      → 配置参数 (values.yaml), 覆盖 Chart 默认值
```

**Chart 目录结构：**

```
mychart/
├── Chart.yaml          # Chart 元信息 (名称/版本/依赖)
├── values.yaml         # 默认配置值
├── charts/             # 子 Chart 依赖
├── templates/          # K8s 资源模板 (Go template)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl    # 可复用的模板辅助函数
│   └── NOTES.txt       # 安装后显示的信息
└── .helmignore
```

**常用命令：**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami   # 添加仓库
helm search repo nginx                                       # 搜索 Chart
helm install my-nginx bitnami/nginx                          # 安装
helm upgrade my-nginx bitnami/nginx --set service.type=NodePort  # 升级
helm rollback my-nginx 1                                     # 回滚到版本 1
helm list -A                                                 # 查看所有 Release
helm uninstall my-nginx                                      # 卸载
helm template . > all.yaml                                   # 渲染模板(本地预览)
```

### 9.7 GitOps — 声明式运维

**角色：** GitOps 将 Git 仓库作为单一事实来源 (Single Source of Truth)，集群状态自动与 Git 仓库同步。

```
传统 CI/CD:                          GitOps:
  CI → Push Image → CD 工具部署    │  开发者 Push 到 Git
         │                         │       │
         ▼                         │       ▼
    手动审批 → 执行 kubectl apply  │  ArgoCD/Flux 自动检测差异
                                   │       │
                                   │       ▼
                                   │  自动同步到集群
```

**ArgoCD 工作原理：**

```
┌──────────┐  Poll/Watch  ┌──────────┐  Sync   ┌──────────┐
│   Git    │ ───────────→ │  ArgoCD  │ ──────→ │  K8s     │
│  Repo    │              │          │         │ Cluster  │
└──────────┘              └────┬─────┘         └──────────┘
                              │
                    ┌─────────▼─────────┐
                    │   Web UI / CLI    │
                    │  (查看差异/回滚)   │
                    └───────────────────┘
```

**Flux CD 对比：**

| 特性 | ArgoCD | Flux CD |
|------|--------|---------|
| 架构 | Pull (Server 拉取 Git) | Pull (Agent 拉取 Git) |
| UI | 内置 Web UI | 无 (需额外部署) |
| 多集群 | 原生支持 | 原生支持 |
| Helm 支持 | 内置 | 内置 Helm Controller |
| 镜像自动更新 | ArgoCD Image Updater | 内置 Image Automation |
| 学习曲线 | 适中 | 略陡 |

### 9.8 集群升级策略

```
升级流程 (kubeadm):

1. 升级前准备
   │  ├── 备份 etcd
   │  ├── 阅读 Release Notes (API 废弃/变更)
   │  └── 确认集群版本 ≤ 升级目标版本的 skew policy (差 2 个小版本)
   │
2. 升级 Master 节点
   │  ├── 升级 kubeadm       → apt/yum install kubeadm-x.y.z
   │  ├── kubeadm upgrade plan → 检查可以升级的版本
   │  ├── kubeadm upgrade apply v1.29.x → 升级控制面
   │  ├── 升级 kubelet       → apt/yum install kubelet-x.y.z
   │  ├── 升级 kubectl       → apt/yum install kubectl-x.y.z
   │  └── systemctl restart kubelet
   │
3. 升级 Worker 节点 (逐个或批量)
   │  ├── kubectl drain worker-1
   │  ├── 升级 kubeadm + kubelet
   │  ├── systemctl restart kubelet
   │  └── kubectl uncordon worker-1
   │
4. 验证
      ├── kubectl get nodes → 版本已更新
      ├── kubectl get pods -A → 所有 Pod Running
      └── 功能测试
```

**版本偏差策略 (Skew Policy)：**

```
K8s 版本 N:
  kube-apiserver:          N 或 N-1
  kube-controller-manager: N 或 N-1
  kube-scheduler:          N 或 N-1
  kubelet:                 N 或 N-1 或 N-2
  kube-proxy:              N 或 N-1 或 N-2
  kubectl:                 N 或 N-1 或 N+1
```

### 9.9 多租户方案

| 方案 | 隔离级别 | 复杂度 | 典型场景 |
|------|----------|--------|----------|
| **Namespace + RBAC** | 软隔离 (逻辑) | ★☆☆☆☆ | 同团队多个项目 |
| **Namespace + NetworkPolicy + ResourceQuota** | 中等隔离 | ★★☆☆☆ | 开发/测试环境 |
| **vcluster (虚拟集群)** | 强隔离 (API 级别) | ★★★☆☆ | 多团队共享集群 |
| **HNC (Hierarchical Namespace)** | 层级继承 | ★★★☆☆ | 多层级组织 |
| **Hard Multi-tenancy (独立集群)** | 完全隔离 | ★★★★★ | 严格合规/安全要求 |

**vcluster 原理：**

```
┌──────── Physical Cluster ────────────────────┐
│  ┌──── vcluster A ────┐ ┌──── vcluster B ───┐│
│  │ namespace: vc-a    │ │ namespace: vc-b   ││
│  │ ┌────────────────┐ │ │ ┌────────────────┐││
│  │ │ mini API Server│ │ │ │ mini API Server│││
│  │ │ mini etcd/     │ │ │ │ mini etcd/     │││
│  │ │ sqlite         │ │ │ │ sqlite         │││
│  │ └──────┬─────────┘ │ │ └──────┬─────────┘││
│  │        │ syncer     │ │        │ syncer   │││
│  └────────┼────────────┘ └────────┼──────────┘│
│           │                       │            │
│     ┌─────▼───────────────────────▼─────────┐  │
│     │    Physical API Server + etcd         │  │
│     └───────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

> 每个 vcluster 有自己的 API Server 和控制面（运行在物理集群的 Pod 中），用户无感知地共享底层计算资源，但 API 层面完全隔离。

---

## 第十层: 运维实战与部署脚本对照

### 10.1 部署流程全景图

```
k8s-deploy.sh 完整流程:

┌─ 系统层 ────────────────────────────────────────────────┐
│ detect_os()       → 系统检测 (Ubuntu/Debian/CentOS/...) │
│ system_check()    → 资源检查 (CPU/内存/磁盘)             │
│ configure_image_proxy() → 镜像加速/代理                  │
│ system_init()     → swap/firewall/内核/时间同步          │
└────────────────────────────────────────────────────────┘
          │
┌─ 运行时层 ──────────────────────────────────────────────┐
│ install_containerd()   → CRI 容器运行时                  │
│ configure_etcd_cluster() → etcd 参数 (外部模式)          │
│ deploy_etcd()          → etcd 安装+证书+服务             │
└────────────────────────────────────────────────────────┘
          │
┌─ K8s 组件层 ────────────────────────────────────────────┐
│ install_k8s_tools()    → kubeadm/kubelet/kubectl         │
│ init_master()          → kubeadm init (内嵌 etcd)        │
│ init_master_external_etcd() → kubeadm init (外部 etcd)   │
└────────────────────────────────────────────────────────┘
          │
┌─ 网络层 ────────────────────────────────────────────────┐
│ select_cni_plugin()    → Flannel/Calico/Cilium/Weave     │
│ install_cni()          → kubectl apply CNI manifest     │
└────────────────────────────────────────────────────────┘
          │
┌─ 配置层 ────────────────────────────────────────────────┐
│ configure_master_mode() → 污点/调度策略                  │
│ install_addons()       → Metrics/Ingress/Dashboard      │
└────────────────────────────────────────────────────────┘
          │
┌─ 验证层 ────────────────────────────────────────────────┐
│ check_cluster_status() → 节点/Pod/组件状态               │
│ print_summary()        → 部署摘要输出                    │
└────────────────────────────────────────────────────────┘
```

### 10.2 脚本函数与 K8s 组件对照表

| 脚本函数 | 涉及的 K8s 组件/概念 | 知识文档章节 |
|----------|---------------------|-------------|
| `deploy_etcd()` | etcd, TLS, Raft | [2.1 etcd](#21-etcd--集群的大脑) |
| `init_master()` | API Server, Scheduler, Controller Manager | [2.2](#22-kube-apiserver--集群统一入口) [2.3](#23-kube-scheduler--智能调度器) [2.4](#24-kube-controller-manager--控制循环集合) |
| `install_k8s_tools()` | kubelet, kubeadm, kubectl | [3.1](#31-kubelet--节点管家) |
| `install_containerd()` | CRI, containerd, OCI | [3.3](#33-container-runtime--容器引擎) |
| `select_cni_plugin()` | CNI, Flannel, Calico, Cilium | [5.4](#54-cni-网络插件) |
| `install_cni()` | Pod 网络, VXLAN, BGP, eBPF | [5.1](#51-k8s-网络模型) |
| `configure_master_mode()` | Taints, Tolerations, 调度 | [8.3](#83-taints--tolerations--节点排斥与容忍) |
| `system_init()` | IPVS, iptables, 内核参数 | [3.2](#32-kube-proxy--服务代理) |
| `install_addons()` | Ingress, HPA (Metrics Server), Dashboard | [5.3](#53-ingress--httphttps-路由) [8.2](#82-hpa--水平自动扩缩) |
| `configure_image_proxy()` | 镜像仓库, containerd mirror | [3.3](#33-container-runtime--容器引擎) |

### 10.3 常用运维命令速查

```bash
# ---- 集群状态 ----
kubectl cluster-info                             # 集群基本信息
kubectl get nodes -o wide                        # 节点列表
kubectl get pods -A                              # 所有 Pod
kubectl get svc -A                               # 所有 Service
kubectl get events --sort-by='.lastTimestamp'    # 事件日志

# ---- 组件状态 ----
kubectl get componentstatuses                    # 组件健康 (老版本)
kubectl get pods -n kube-system | grep -E 'etcd|api|scheduler|controller'
etcdctl endpoint status --write-out=table        # etcd 状态
etcdctl member list                              # etcd 成员
systemctl status kubelet                         # kubelet 状态
journalctl -u kubelet -f                         # kubelet 日志

# ---- Pod 调试 ----
kubectl describe pod <name>                      # Pod 详情
kubectl logs <pod> -c <container>                # 容器日志
kubectl exec -it <pod> -- /bin/sh                # 进入容器
kubectl port-forward <pod> 8080:80               # 端口转发

# ---- 资源管理 ----
kubectl top nodes                                # 节点资源使用
kubectl top pods                                 # Pod 资源使用
kubectl scale deployment <name> --replicas=5     # 扩缩容
kubectl rollout restart deployment <name>        # 重启 Pod

# ---- 备份恢复 ----
etcdctl snapshot save /backup/snapshot.db        # etcd 备份
kubectl get all --all-namespaces -o yaml > backup.yaml  # 资源导出
```

### 10.4 故障排查清单

| 症状 | 可能原因 | 排查命令 |
|------|----------|----------|
| Pod Pending | 资源不足 / 污点 / 亲和性不匹配 | `kubectl describe pod` |
| Pod CrashLoopBackOff | 应用崩溃 / 探针失败 | `kubectl logs <pod> --previous` |
| Service 不通 | Endpoint 为空 / kube-proxy 异常 | `kubectl get endpoints <svc>` |
| 节点 NotReady | kubelet 停掉 / 网络不通 | `systemctl status kubelet` |
| etcd 集群不健康 | 网络分区 / 磁盘满 / Raft 异常 | `etcdctl endpoint health` |
| DNS 解析失败 | CoreDNS Pod 异常 | `kubectl get pods -n kube-system -l k8s-app=kube-dns` |

---

## 学习路线建议

```
第 1 周: 第一层 → 理解集群架构, 用 kubectl 完成基本操作
第 2 周: 第二层 → 深入理解 etcd/API Server/Scheduler/Controller Mgr/kubeadm
第 3 周: 第三层 → 掌握 kubelet/kube-proxy/CRI/节点维护
第 4 周: 第四层 → 掌握 Pod(生命周期/Init/Hook)/Deployment/StatefulSet/DaemonSet/ReplicaSet/Namespace
第 5 周: 第五、六层 → 理解 Service/Ingress/NetworkPolicy/GatewayAPI/PV/PVC/StorageClass
第 6 周: 第七层 → RBAC/Secret加密/ConfigMap/PSA/准入控制器/ServiceAccount
第 7 周: 第八层 → HPA+VPA+CA/PDB/PriorityClass/Affinity/Topology Manager
第 8 周: 第九层 → Prometheus/EFK/Istio/Operator/Helm/GitOps/集群升级/多租户
第 9 周: 第十层 → 动手部署, 阅读 k8s-deploy.sh, 对照生产最佳实践清单
```

### 10.5 生产环境最佳实践清单

**集群层面：**

| 实践 | 说明 |
|------|------|
| etcd 独立部署 (External) | 生产环境强制，故障隔离 |
| etcd 节点 ≥ 3 (奇数) | 保证 Raft 共识可用 |
| etcd 使用 SSD 磁盘 | etcd 对磁盘延迟敏感，HDD 会导致集群不稳定 |
| 定期 etcd 快照备份 | 配合 Velero 定时备份到 S3 等远端存储 |
| API Server 启用加密 | EncryptionConfiguration 加密 Secret 静态存储 |
| 多 Master (≥ 2) | API Server 高可用，配合外部 LB |
| 控制面节点不调度业务 Pod | 加固 NoSchedule Taint (脚本默认行为) |
| CoreDNS 副本数 ≥ 3 | 部署到不同节点，避免 DNS 单点故障 |
| 开启审计日志 | 记录 API 调用行为，用于合规和安全分析 |

**节点层面：**

| 实践 | 说明 |
|------|------|
| 专用节点池 | 按用途划分: 系统组件 / 业务 Pod / GPU / 存储 节点 |
| 节点标签标准化 | 按环境/团队/用途打标签，方便调度和成本核算 |
| 设置节点资源预留 | kube-reserved / system-reserved / eviction-hard 防止 OOM |
| 内核版本 ≥ 4.x | 更好的 cgroup 支持和网络性能 |
| 关闭 swap | K8s 硬性要求 (脚本已自动处理) |
| 使用 IPVS 模式 | 替代 iptables，大规模集群性能更好 |

**应用部署层面：**

| 实践 | 说明 |
|------|------|
| 设置 requests = limits | 获取 Guaranteed QoS，避免被驱逐 (关键服务) |
| 配置 Readiness + Liveness Probe | 确保流量只到就绪 Pod，不健康自动重启 |
| 配置 PDB | 保证自愿中断时最小可用副本数 |
| 使用 PriorityClass | 区分关键服务和非关键服务，资源紧张时优先保护 |
| 使用 NetworkPolicy | 最小权限网络访问，默认拒绝 + 白名单 |
| 使用非 root 用户运行容器 | SecurityContext.runAsNonRoot: true |
| 容器镜像固定版本/摘要 | 避免使用 `latest` 标签 |
| 定义 ResourceQuota + LimitRange | 限制每个 Namespace 资源用量 |
| 合理使用 anti-affinity | 关键 Pod 分散到不同节点/可用区 |

**安全合规：**

| 实践 | 说明 |
|------|------|
| RBAC 最小权限 | 每个 SA 仅授予必需权限 |
| 禁用默认 SA 自动挂载 Token | automountServiceAccountToken: false |
| Secret 使用外部密钥管理 | HashiCorp Vault / AWS Secrets Manager + External Secrets Operator |
| 镜像扫描 | Trivy / Clair 扫描镜像漏洞 |
| 启用 PSA (restricted) | 生产 Namespace 使用 restricted 策略 |
| TLS 双向认证 | etcd peer/client 通信全部 TLS (脚本已配置) |
| API Server 证书 ≤ 1 年 | 定期轮换 (kubeadm certs renew) |

**可观测性：**

| 实践 | 说明 |
|------|------|
| Prometheus + Grafana | 核心监控，至少采集节点/容器/API Server/etcd 指标 |
| 配置关键告警 | Node NotReady / Pod CrashLoop / etcd 无 Leader / 磁盘使用率高 |
| 集中日志 (EFK/Loki) | 所有容器日志集中采集和检索 |
| 分布式追踪 (Jaeger) | 微服务调用链追踪 |

---

> 📘 本文档随 `k8s-deploy.sh` 一同维护更新，每个模块末尾标注了脚本中对应的函数位置。
