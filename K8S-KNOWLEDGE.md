# Kubernetes 知识体系：由浅及深

> 本文档从零开始，循序渐进梳理 K8s 各组件与模块，适合作为系统学习的知识地图。
> 每个模块末尾标注了对应 `k8s-deploy.sh` 中的实现位置，方便理论与实践对照。

---

## 目录

| 层级 | 模块 | 难度 |
|------|------|------|
| [第一层](#第一层-核心概念与集群架构) | 核心概念与集群架构 | ★☆☆☆☆ |
| [第二层](#第二层-控制面组件详解) | 控制面组件详解 | ★★☆☆☆ |
| [第三层](#第三层-工作节点组件详解) | 工作节点组件详解 | ★★☆☆☆ |
| [第四层](#第四层-核心工作负载资源) | 核心工作负载资源 | ★★★☆☆ |
| [第五层](#第五层-服务发现与网络) | 服务发现与网络 | ★★★★☆ |
| [第六层](#第六层-存储体系) | 存储体系 | ★★★★☆ |
| [第七层](#第七层-配置与安全) | 配置与安全 | ★★★★☆ |
| [第八层](#第八层-调度与资源管理) | 调度与资源管理 | ★★★★☆ |
| [第九层](#第九层-可观测性与进阶主题) | 可观测性与进阶主题 | ★★★★★ |
| [第十层](#第十层-运维实战与部署脚本对照) | 运维实战与部署脚本对照 | ★★★★★ |

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

**Pod 生命周期：**

```
Pending → Running → Succeeded / Failed
              │
              └──→ Unknown (节点失联)
```

**Sidecar 模式：** 辅助容器与主容器共存，例如：
- 日志采集 (Filebeat Sidecar)
- 代理 (Envoy Sidecar / Istio)
- 配置热更新 (Config Reloader)

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
第 2 周: 第二、三层 → 深入理解控制面和数据面的每个组件
第 3 周: 第四层 → 掌握 Pod/Deployment/StatefulSet/DaemonSet/Job
第 4 周: 第五、六层 → 理解 Service/Ingress/CNI/PV/PVC/StorageClass
第 5 周: 第七、八层 → RBAC/Secret/ConfigMap/HPA/调度策略
第 6 周: 第九层 → Prometheus/Grafana/EFK/Istio/Operator
第 7 周: 第十层 → 动手部署, 阅读 k8s-deploy.sh, 对照每个函数理解原理
```

---

> 📘 本文档随 `k8s-deploy.sh` 一同维护更新，每个模块末尾标注了脚本中对应的函数位置。
