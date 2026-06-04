#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kubernetes 全流程自动部署脚本
# 支持: Ubuntu 20.04+ / Debian 11+ / CentOS 7/8/9 / Rocky Linux / Alibaba Cloud Linux
#
# 功能:
#   - 系统环境检查与内核参数优化
#   - 容器运行时安装 (containerd)
#   - 镜像加速代理配置
#   - kubeadm/kubelet/kubectl 安装
#   - 网络插件选择 (Calico / Flannel / Cilium / Weave)
#   - External etcd 集群独立部署 / 内嵌 etcd 两种模式
#   - 主节点 / 工作节点 / 单节点(All-in-One) 模式
#   - HA 高可用 Control Plane Endpoint 支持
#   - 主节点污点移除 (允许 Master 调度 Pod)
#
# 用法:
#   bash k8s-deploy.sh                # 交互式菜单
#   bash k8s-deploy.sh init           # 一键初始化主节点（内嵌 etcd, 非交互）
#   bash k8s-deploy.sh init-external  # 一键初始化主节点（外部 etcd, 非交互）
#   bash k8s-deploy.sh etcd           # 部署外部 etcd 集群
#   bash k8s-deploy.sh join           # 一键加入工作节点（非交互）
#   bash k8s-deploy.sh allinone       # 单节点 All-in-One 部署
# =============================================================================

# ------------------------------ 颜色定义 --------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ------------------------------ 全局变量 --------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/k8s-deploy-$(date +%Y%m%d-%H%M%S).log"
JOIN_CMD_FILE="${SCRIPT_DIR}/k8s-join-command.txt"
K8S_VERSION="1.28"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CNI_PLUGIN=""
CONTAINERD_VERSION=""
MASTER_IP=""
CONTROL_PLANE_ENDPOINT=""
NODE_NAME=""

# ------------------------------ etcd 全局变量 -----------------------------------
ETCD_VERSION="3.5.10"
ETCD_ENDPOINTS=""
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_CLUSTER_MODE="single"
ETCD_INITIAL_CLUSTER=""
ETCD_NODES=()

# ------------------------------ 工具函数 --------------------------------------
log()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
info()  { echo -e "${CYAN}[*]${NC} $*"; }
banner() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        Kubernetes 全流程自动部署脚本 v2.0               ║"
    echo "║        K8s Version: ${K8S_VERSION}                                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

run_cmd() {
    local cmd_desc="$1"
    shift
    log "执行: $*"
    if "$@" >> "$LOG_FILE" 2>&1; then
        success "$cmd_desc"
        return 0
    else
        error "$cmd_desc 失败，详情查看日志: $LOG_FILE"
        return 1
    fi
}

die() {
    error "$*"
    exit 1
}

# ------------------------------ 系统检测 --------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-}"
        OS_NAME="$NAME"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION="$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides redhat-release)")"
    else
        die "无法识别操作系统"
    fi

    case "$OS" in
        ubuntu|debian)
            OS_TYPE="debian"
            ;;
        centos|rhel|rocky|almalinux|alinux|anolis|tencentos|openeuler)
            OS_TYPE="redhat"
            ;;
        *)
            die "不支持的操作系统: $OS"
            ;;
    esac

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)  ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="arm64" ;;
        *)       die "不支持的架构: $ARCH" ;;
    esac

    log "系统: ${OS_NAME:-$OS} ${OS_VERSION:-}, 类型: $OS_TYPE, 架构: $ARCH_TYPE"
}

# ------------------------------ 系统环境检查 ----------------------------------
system_check() {
    info "========== 系统环境检查 =========="

    local cores; cores="$(nproc)"
    local mem_mb; mem_mb="$(free -m | awk '/^Mem:/{print $2}')"
    local disk_gb; disk_gb="$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')"

    log "CPU 核心数: $cores"
    log "内存: ${mem_mb}MB"
    log "磁盘可用空间: ${disk_gb}GB"

    [ "$cores" -lt 2 ] && warn "CPU 核心数不足 2，建议至少 2 核"
    [ "$mem_mb" -lt 1700 ] && warn "内存不足 2GB，建议至少 2GB"
    [ "$disk_gb" -lt 20 ] && warn "磁盘空间不足 20GB"

    if [ "$OS_TYPE" = "redhat" ]; then
        # 检查 SELinux
        if [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
            warn "SELinux 未禁用，将在后续步骤中禁用"
        fi
    fi

    # 检查主机名
    local hostname; hostname="$(hostname)"
    if echo "$hostname" | grep -q 'localhost'; then
        warn "主机名为 localhost，建议设置一个有意义的主机名"
    fi
    log "主机名: $hostname"

    success "系统环境检查完成"
}

# ------------------------------ 系统初始化 --------------------------------------
system_init() {
    info "========== 系统初始化 =========="

    # 关闭 swap
    log "关闭 swap..."
    swapoff -a
    sed -i '/swap/d' /etc/fstab 2>/dev/null || true
    success "swap 已关闭"

    # 关闭防火墙 (CentOS/RHEL)
    if [ "$OS_TYPE" = "redhat" ]; then
        log "停止 firewalld..."
        systemctl stop firewalld 2>/dev/null || true
        systemctl disable firewalld 2>/dev/null || true
        success "firewalld 已禁用"

        # 禁用 SELinux
        log "禁用 SELinux..."
        setenforce 0 2>/dev/null || true
        sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true
        success "SELinux 已禁用"
    fi

    # 关闭 UFW (Ubuntu)
    if [ "$OS_TYPE" = "debian" ]; then
        if command -v ufw &>/dev/null; then
            ufw disable 2>/dev/null || true
            success "ufw 已禁用"
        fi
    fi

    # 加载内核模块
    log "加载内核模块..."
    cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    success "内核模块已加载"

    # 内核参数优化
    log "配置内核参数..."
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.ip_nonlocal_bind           = 1
net.ipv4.tcp_tw_reuse               = 1
vm.swappiness                       = 0
vm.overcommit_memory                = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
fs.file-max                         = 52706963
fs.nr_open                          = 52706963
EOF
    sysctl --system > /dev/null 2>&1
    success "内核参数已优化"

    # 安装依赖工具
    info "安装基础依赖..."
    if [ "$OS_TYPE" = "debian" ]; then
        run_cmd "更新 apt" apt-get update -y
        run_cmd "安装依赖" apt-get install -y apt-transport-https ca-certificates curl \
            gnupg lsb-release wget jq chrony ipset ipvsadm conntrack 2>/dev/null
    else
        run_cmd "安装依赖" yum install -y yum-utils device-mapper-persistent-data \
            lvm2 curl wget jq chrony ipset ipvsadm 2>/dev/null
    fi

    # NTP 时间同步
    log "配置时间同步..."
    if [ "$OS_TYPE" = "debian" ]; then
        systemctl enable --now chrony 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true
    else
        systemctl enable --now chronyd 2>/dev/null || true
    fi
    success "时间同步已配置"

    success "系统初始化完成"
}

# ------------------------------ 镜像加速代理配置 --------------------------------
configure_image_proxy() {
    info "========== 镜像加速 / 代理配置 =========="

    echo ""
    echo -e "  请选择镜像拉取策略:"
    echo -e "    ${GREEN}1)${NC} Docker Hub 镜像加速 (国内推荐: docker.m.daocloud.io)"
    echo -e "    ${GREEN}2)${NC} 阿里云 ACR 镜像加速器"
    echo -e "    ${GREEN}3)${NC} 自定义镜像仓库地址"
    echo -e "    ${GREEN}4)${NC} 不配置代理 (直连)"
    echo ""

    local proxy_choice
    read -rp "  请输入选项 [1-4, 默认:1]: " proxy_choice
    proxy_choice="${proxy_choice:-1}"

    case "$proxy_choice" in
        1)
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            log "使用公共镜像加速: Docker Hub Mirror"
            ;;
        2)
            echo ""
            echo -e "  请输入阿里云 ACR 加速地址"
            echo -e "  (在阿里云容器镜像服务控制台 -> 镜像加速器 中获取)"
            read -rp "  加速地址 (例: https://xxxx.mirror.aliyuncs.com): " aliyun_mirror
            if [ -z "$aliyun_mirror" ]; then
                warn "未输入地址，跳过镜像加速配置"
                MIRROR_REGISTRY=""
                MIRROR_ENDPOINT=""
                K8S_MIRROR=""
            else
                MIRROR_REGISTRY=""
                MIRROR_ENDPOINT="$aliyun_mirror"
                K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            fi
            ;;
        3)
            read -rp "  请输入镜像仓库地址 (例: harbor.example.com): " custom_registry
            if [ -n "$custom_registry" ]; then
                MIRROR_REGISTRY="$custom_registry"
                read -rp "  请输入镜像加速 endpoint (例: https://harbor.example.com, 无则回车跳过): " custom_endpoint
                MIRROR_ENDPOINT="$custom_endpoint"
                read -rp "  请输入 K8s 组件镜像仓库 (例: harbor.example.com/google_containers, 无则回车跳过): " custom_k8s
                K8S_MIRROR="$custom_k8s"
            fi
            ;;
        4)
            MIRROR_REGISTRY=""
            MIRROR_ENDPOINT=""
            K8S_MIRROR=""
            info "不使用镜像代理，直连拉取"
            ;;
        *)
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            ;;
    esac

    # 如果需要配置 HTTP 代理
    echo ""
    read -rp "  是否需要配置 HTTP/HTTPS 代理? [y/N]: " need_proxy
    if [[ "$need_proxy" =~ ^[Yy]$ ]]; then
        read -rp "  HTTP 代理地址 (例: http://proxy.example.com:8080): " HTTP_PROXY_URL
        read -rp "  HTTPS 代理地址 (同 HTTP 则回车): " HTTPS_PROXY_URL
        HTTPS_PROXY_URL="${HTTPS_PROXY_URL:-$HTTP_PROXY_URL}"
        read -rp "  NO_PROXY (不走代理的地址, 逗号分隔, 例: localhost,10.0.0.0/8): " NO_PROXY_ADDR

        export http_proxy="$HTTP_PROXY_URL"
        export https_proxy="$HTTPS_PROXY_URL"
        export no_proxy="${NO_PROXY_ADDR:-localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
        log "代理已配置: HTTP=$HTTP_PROXY_URL, NO_PROXY=$no_proxy"
    fi

    success "镜像加速/代理配置完成"
}

# ------------------------------ etcd 集群配置交互 --------------------------------
configure_etcd_cluster() {
    info "========== etcd 集群配置 =========="

    echo ""
    echo -e "  ${BOLD}etcd 部署模式:${NC}"
    echo -e "    ${GREEN}1)${NC} 单节点 etcd (本机部署, 与 Master 同节点)"
    echo -e "    ${GREEN}2)${NC} 多节点 etcd 集群 (至少 3 节点, 推荐独立节点)"
    echo ""

    local etcd_mode
    read -rp "  请选择 [1-2, 默认:1]: " etcd_mode
    etcd_mode="${etcd_mode:-1}"

    read -rp "  etcd 版本 [默认: ${ETCD_VERSION}]: " input_etcd_ver
    ETCD_VERSION="${input_etcd_ver:-$ETCD_VERSION}"

    local default_ip
    default_ip="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}' | xargs -I{} ip -o -4 addr show {} 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    if [ "$etcd_mode" = "1" ]; then
        ETCD_CLUSTER_MODE="single"
        local etcd_name_default="${NODE_NAME:-$(hostname)}"
        read -rp "  本机 etcd 节点名称 [默认: ${etcd_name_default}]: " etcd_name
        etcd_name="${etcd_name:-$etcd_name_default}"
        read -rp "  本机 IP [默认: ${default_ip}]: " etcd_ip
        etcd_ip="${etcd_ip:-$default_ip}"
        ETCD_ENDPOINTS="https://${etcd_ip}:2379"
        ETCD_INITIAL_CLUSTER="${etcd_name}=https://${etcd_ip}:2380"
        ETCD_NODES=("${etcd_name}|${etcd_ip}")
        log "单节点 etcd 模式, IP: $etcd_ip, 名称: $etcd_name"
    else
        ETCD_CLUSTER_MODE="cluster"
        read -rp "  etcd 集群节点数 [默认: 3]: " etcd_node_count
        etcd_node_count="${etcd_node_count:-3}"

        ETCD_NODES=()
        local etcd_endpoints_list=()
        local etcd_cluster_list=()
        local this_ip="$default_ip"
        local this_hostname; this_hostname="$(hostname)"

        for i in $(seq 1 "$etcd_node_count"); do
            echo ""
            echo -e "  ${BOLD}--- etcd 节点 $i ---${NC}"
            read -rp "    节点名称: " etcd_name
            read -rp "    节点 IP:   " etcd_ip

            ETCD_NODES+=("${etcd_name}|${etcd_ip}")
            etcd_cluster_list+=("${etcd_name}=https://${etcd_ip}:2380")
            etcd_endpoints_list+=("https://${etcd_ip}:2379")

            if [ "$etcd_ip" = "$this_ip" ] || [ "$etcd_name" = "$this_hostname" ]; then
                IS_THIS_ETCD_NODE="true"
            fi
        done

        ETCD_INITIAL_CLUSTER="$(IFS=,; echo "${etcd_cluster_list[*]}")"
        ETCD_ENDPOINTS="$(IFS=,; echo "${etcd_endpoints_list[*]}")"

        log "etcd 集群模式: $etcd_node_count 节点"
        log "Initial Cluster: $ETCD_INITIAL_CLUSTER"
        log "Endpoints: $ETCD_ENDPOINTS"
    fi

    read -rp "  etcd 数据目录 [默认: ${ETCD_DATA_DIR}]: " input_data_dir
    ETCD_DATA_DIR="${input_data_dir:-$ETCD_DATA_DIR}"

    success "etcd 集群配置完成"
}

# ------------------------------ 部署 etcd ---------------------------------------
deploy_etcd() {
    info "========== 部署 External etcd =========="

    ETCD_VER="v${ETCD_VERSION}"
    local etcd_download_url

    if [ "$ARCH_TYPE" = "arm64" ]; then
        etcd_download_url="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-arm64.tar.gz"
    else
        etcd_download_url="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"
    fi

    if [ ! -f /usr/local/bin/etcd ]; then
        info "下载 etcd ${ETCD_VER}..."
        curl -sSL "$etcd_download_url" -o /tmp/etcd.tar.gz
        tar xzf /tmp/etcd.tar.gz -C /tmp/
        mv "/tmp/etcd-${ETCD_VER}-linux-${ARCH_TYPE}/etcd" /usr/local/bin/
        mv "/tmp/etcd-${ETCD_VER}-linux-${ARCH_TYPE}/etcdctl" /usr/local/bin/
        mv "/tmp/etcd-${ETCD_VER}-linux-${ARCH_TYPE}/etcdutl" /usr/local/bin/ 2>/dev/null || true
        chmod +x /usr/local/bin/etcd /usr/local/bin/etcdctl
        rm -rf /tmp/etcd.tar.gz "/tmp/etcd-${ETCD_VER}-linux-${ARCH_TYPE}"
        success "etcd 二进制安装完成"
    else
        log "etcd 已安装: $(etcd --version 2>/dev/null | head -1)"
    fi

    info "生成 etcd TLS 证书..."
    mkdir -p /etc/kubernetes/pki/etcd

    if [ -f /etc/kubernetes/pki/etcd/ca.crt ]; then
        log "etcd CA 证书已存在, 跳过生成"
    else
        kubeadm init phase certs etcd-ca 2>&1 | tee -a "$LOG_FILE"
    fi

    kubeadm init phase certs etcd-server 2>&1 | tee -a "$LOG_FILE" || true
    kubeadm init phase certs etcd-peer 2>&1 | tee -a "$LOG_FILE" || true
    kubeadm init phase certs etcd-healthcheck-client 2>&1 | tee -a "$LOG_FILE" || true
    kubeadm init phase certs apiserver-etcd-client 2>&1 | tee -a "$LOG_FILE" || true

    success "etcd 证书生成完成"

    if ! id etcd &>/dev/null; then
        useradd -r -s /sbin/nologin etcd 2>/dev/null || true
    fi
    mkdir -p "$ETCD_DATA_DIR"
    chown -R etcd:etcd "$ETCD_DATA_DIR" /etc/kubernetes/pki/etcd

    local this_ip
    this_ip="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}' | xargs -I{} ip -o -4 addr show {} 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
    local this_hostname; this_hostname="$(hostname)"

    local this_etcd_name="${this_hostname}"
    for node_info in "${ETCD_NODES[@]}"; do
        local n_name="${node_info%%|*}"
        local n_ip="${node_info##*|}"
        if [ "$n_ip" = "$this_ip" ] || [ "$n_name" = "$this_hostname" ]; then
            this_etcd_name="$n_name"
            break
        fi
    done

    info "配置 etcd systemd 服务..."

    cat > /etc/systemd/system/etcd.service <<ETCD_SERVICE_EOF
[Unit]
Description=etcd - highly-available key-value store
Documentation=https://etcd.io/docs
After=network.target

[Service]
Type=notify
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd \\
  --name=${this_etcd_name} \\
  --data-dir=${ETCD_DATA_DIR} \\
  --listen-client-urls=https://${this_ip}:2379,https://127.0.0.1:2379 \\
  --listen-peer-urls=https://${this_ip}:2380 \\
  --advertise-client-urls=https://${this_ip}:2379 \\
  --initial-advertise-peer-urls=https://${this_ip}:2380 \\
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \\
  --initial-cluster-state=new \\
  --initial-cluster-token=k8s-etcd-cluster \\
  --cert-file=/etc/kubernetes/pki/etcd/server.crt \\
  --key-file=/etc/kubernetes/pki/etcd/server.key \\
  --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt \\
  --peer-key-file=/etc/kubernetes/pki/etcd/peer.key \\
  --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \\
  --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \\
  --client-cert-auth=true \\
  --peer-client-cert-auth=true \\
  --auto-compaction-retention=1 \\
  --snapshot-count=10000 \\
  --quota-backend-bytes=8589934592
Restart=always
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCD_SERVICE_EOF

    systemctl daemon-reload
    run_cmd "启动 etcd" systemctl enable --now etcd

    info "等待 etcd 就绪..."
    sleep 2
    local etcd_ready=false
    for i in $(seq 1 30); do
        if ETCDCTL_API=3 /usr/local/bin/etcdctl \
            --cacert=/etc/kubernetes/pki/etcd/ca.crt \
            --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
            --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
            endpoint health 2>/dev/null | grep -q 'is healthy'; then
            success "etcd 已就绪"
            etcd_ready=true
            break
        fi
        sleep 2
    done

    if [ "$etcd_ready" = false ]; then
        warn "etcd 启动后未检测到健康状态, 请检查: systemctl status etcd"
    fi

    cat > /etc/profile.d/etcd.sh <<'EOF'
export ETCDCTL_API=3
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key
alias ectl='etcdctl'
EOF

    success "etcd 部署完成"
}

# ------------------------------ 容器运行时 (containerd) -------------------------
install_containerd() {
    info "========== 安装容器运行时 (containerd) =========="

    # 检查 containerd 是否已安装
    if command -v containerd &>/dev/null; then
        local cur_ver
        cur_ver="$(containerd --version 2>/dev/null | awk '{print $3}')"
        log "containerd 已安装: $cur_ver"
        read -rp "  是否重新安装/升级 containerd? [y/N]: " reinstall_ctr
        if [[ ! "$reinstall_ctr" =~ ^[Yy]$ ]]; then
            success "跳过 containerd 安装"
            return
        fi
    fi

    if [ "$OS_TYPE" = "debian" ]; then
        # 安装 Docker 仓库以获得 containerd
        log "配置 Docker apt 仓库..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/${OS}/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${OS} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        run_cmd "更新 apt" apt-get update -y
        run_cmd "安装 containerd" apt-get install -y containerd.io
    else
        # CentOS/RHEL
        run_cmd "安装 Docker 仓库" yum-config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo
        run_cmd "安装 containerd" yum install -y containerd.io
    fi

    # 生成默认配置
    log "生成 containerd 默认配置..."
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml 2>/dev/null || true

    # 配置 SystemdCgroup
    log "配置 containerd SystemdCgroup..."
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    # 配置镜像加速
    if [ -n "${MIRROR_ENDPOINT:-}" ] || [ -n "${MIRROR_REGISTRY:-}" ]; then
        log "配置 containerd 镜像加速..."

        local reg_config=""
        if [ -n "${MIRROR_ENDPOINT:-}" ]; then
            reg_config="${reg_config}
        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"docker.io\"]
          endpoint = [\"${MIRROR_ENDPOINT}\"]"
        fi

        if [ -n "${MIRROR_REGISTRY:-}" ]; then
            reg_config="${reg_config}
        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${MIRROR_REGISTRY}\"]
          endpoint = [\"https://${MIRROR_REGISTRY}\"]"
        fi

        # 在 config.toml 中添加 mirror 配置
        if ! grep -q 'registry.mirrors' /etc/containerd/config.toml; then
            cat >> /etc/containerd/config.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["${MIRROR_ENDPOINT:-https://registry-1.docker.io}"]
EOF
        fi
    fi

    # 配置 HTTP 代理
    if [ -n "${HTTP_PROXY_URL:-}" ]; then
        log "配置 containerd 代理..."
        mkdir -p /etc/systemd/system/containerd.service.d
        cat > /etc/systemd/system/containerd.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY_URL}"
Environment="HTTPS_PROXY=${HTTPS_PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY_ADDR:-localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local}"
EOF
        systemctl daemon-reload
    fi

    # 启用并启动 containerd
    run_cmd "启动 containerd" systemctl enable --now containerd
    success "containerd 安装配置完成"

    # 安装 crictl 并配置 endpoint
    log "配置 crictl..."
    cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    success "crictl 配置完成"
}

# ------------------------------ 安装 kubeadm/kubelet/kubectl --------------------
install_k8s_tools() {
    info "========== 安装 kubeadm / kubelet / kubectl =========="

    local pkg_version="${K8S_VERSION}.0-*"
    if [ -n "${K8S_MIRROR:-}" ]; then
        if [ "$OS_TYPE" = "debian" ]; then
            log "使用镜像仓库: $K8S_MIRROR (aliyun)"
            curl -fsSL "https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg" | \
                gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg 2>/dev/null

            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] \
https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" \
                > /etc/apt/sources.list.d/kubernetes.list

            run_cmd "更新 apt" apt-get update -y
            run_cmd "安装 kubeadm/kubelet/kubectl" apt-get install -y \
                "kubeadm=${pkg_version}" "kubelet=${pkg_version}" "kubectl=${pkg_version}"
        else
            log "使用镜像仓库: $K8S_MIRROR (aliyun)"
            cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
            run_cmd "安装 kubeadm/kubelet/kubectl" yum install -y \
                "kubeadm-${pkg_version}" "kubelet-${pkg_version}" "kubectl-${pkg_version}"
        fi
    else
        if [ "$OS_TYPE" = "debian" ]; then
            log "使用官方仓库"
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
                gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null

            echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
                > /etc/apt/sources.list.d/kubernetes.list

            run_cmd "更新 apt" apt-get update -y
            run_cmd "安装 kubeadm/kubelet/kubectl" apt-get install -y \
                "kubeadm=${pkg_version}" "kubelet=${pkg_version}" "kubectl=${pkg_version}"
        else
            log "使用官方仓库"
            cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
            run_cmd "安装 kubeadm/kubelet/kubectl" yum install -y \
                "kubeadm-${pkg_version}" "kubelet-${pkg_version}" "kubectl-${pkg_version}"
        fi
    fi

    # 锁定版本，防止意外升级
    if [ "$OS_TYPE" = "debian" ]; then
        apt-mark hold kubeadm kubelet kubectl 2>/dev/null || true
    else
        yum versionlock kubeadm kubelet kubectl 2>/dev/null || true
    fi

    # 启用 kubelet
    run_cmd "启用 kubelet" systemctl enable kubelet

    # kubectl 自动补全
    log "配置 kubectl 自动补全..."
    kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
    echo 'alias k=kubectl' >> /etc/profile.d/k8s-aliases.sh 2>/dev/null || true
    echo 'complete -F __start_kubectl k' >> /etc/profile.d/k8s-aliases.sh 2>/dev/null || true

    success "kubeadm/kubelet/kubectl 安装完成"
}

# ------------------------------ 网络插件选择 ------------------------------------
select_cni_plugin() {
    info "========== 网络插件 (CNI) 选择 =========="

    echo ""
    echo -e "  ${BOLD}请选择 CNI 网络插件:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Flannel      - 简单易用，适合小规模集群，VXLAN/Host-GW 模式"
    echo -e "  ${GREEN}2)${NC} Calico       - 高性能，支持网络策略，BGP/VXLAN 模式"
    echo -e "  ${GREEN}3)${NC} Cilium       - eBPF 驱动，高性能网络+可观测性+安全"
    echo -e "  ${GREEN}4)${NC} Weave Net    - 简单部署，自动发现，加密通信"
    echo ""

    local cni_choice
    read -rp "  请输入选项 [1-4, 默认:2]: " cni_choice
    cni_choice="${cni_choice:-2}"

    case "$cni_choice" in
        1)
            CNI_PLUGIN="flannel"
            POD_CIDR="10.244.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
            log "选择 Flannel 网络插件, Pod CIDR: $POD_CIDR"
            ;;
        2)
            CNI_PLUGIN="calico"
            POD_CIDR="192.168.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
            log "选择 Calico 网络插件, Pod CIDR: $POD_CIDR"
            ;;
        3)
            CNI_PLUGIN="cilium"
            POD_CIDR="10.0.0.0/8"
            log "选择 Cilium 网络插件"
            ;;
        4)
            CNI_PLUGIN="weave"
            POD_CIDR="10.32.0.0/12"
            CNI_MANIFEST="https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml"
            log "选择 Weave Net 网络插件, Pod CIDR: $POD_CIDR"
            ;;
        *)
            CNI_PLUGIN="calico"
            POD_CIDR="192.168.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
            log "默认选择 Calico 网络插件"
            ;;
    esac

    # 询问是否自定义 Pod CIDR
    echo ""
    read -rp "  是否自定义 Pod CIDR? 当前: ${POD_CIDR} [y/N]: " custom_cidr
    if [[ "$custom_cidr" =~ ^[Yy]$ ]]; then
        read -rp "  请输入 Pod CIDR: " POD_CIDR
        log "自定义 Pod CIDR: $POD_CIDR"
    fi

    success "网络插件配置完成: $CNI_PLUGIN"
}

# ------------------------------ 主节点初始化 ------------------------------------
init_master() {
    info "========== 主节点初始化 =========="

    # 获取网络信息
    local default_iface; default_iface="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')"
    local default_ip; default_ip="$(ip -o -4 addr show "$default_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    echo ""
    log "检测到默认网卡: $default_iface, IP: $default_ip"

    read -rp "  请输入 Master 节点 IP [默认: $default_ip]: " MASTER_IP
    MASTER_IP="${MASTER_IP:-$default_ip}"

    echo ""
    echo -e "  ${BOLD}HA 高可用配置 (可选):${NC}"
    read -rp "  是否需要配置 Control Plane Endpoint (多 Master/负载均衡)? [y/N]: " ha_setup
    if [[ "$ha_setup" =~ ^[Yy]$ ]]; then
        read -rp "  请输入 Control Plane Endpoint (域名或 VIP, 例: k8s-api.example.com:6443): " CONTROL_PLANE_ENDPOINT
        log "Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT"
    fi

    read -rp "  请输入 K8s 版本 [默认: ${K8S_VERSION}]: " input_ver
    K8S_VERSION="${input_ver:-$K8S_VERSION}"

    read -rp "  请输入节点名称 [默认: 自动]: " NODE_NAME
    if [ -n "$NODE_NAME" ]; then
        hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || true
        log "节点名称设置为: $NODE_NAME"
    fi

    # 预拉取镜像
    info "预拉取 K8s 组件镜像..."
    if [ -n "${K8S_MIRROR:-}" ]; then
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" \
            --image-repository "$K8S_MIRROR" 2>&1 | tee -a "$LOG_FILE"
    else
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" 2>&1 | tee -a "$LOG_FILE"
    fi

    # 构建 kubeadm init 参数
    local init_args=(
        "--kubernetes-version=v${K8S_VERSION}"
        "--pod-network-cidr=${POD_CIDR}"
        "--service-cidr=${SERVICE_CIDR}"
        "--apiserver-advertise-address=${MASTER_IP}"
    )

    if [ -n "${K8S_MIRROR:-}" ]; then
        init_args+=("--image-repository=${K8S_MIRROR}")
    fi

    if [ -n "${CONTROL_PLANE_ENDPOINT:-}" ]; then
        init_args+=("--control-plane-endpoint=${CONTROL_PLANE_ENDPOINT}")
    fi

    # 设置 cgroup driver
    init_args+=("--cri-socket=unix:///run/containerd/containerd.sock")

    # 执行 kubeadm init
    info "执行 kubeadm init..."
    log "参数: ${init_args[*]}"
    kubeadm init "${init_args[@]}" 2>&1 | tee -a "$LOG_FILE"

    # 配置 kubectl
    info "配置 kubectl..."
    mkdir -p "$HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
    chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null || true

    # 为 root 也配置
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config

    # 保存 join 命令
    kubeadm token create --print-join-command > "$JOIN_CMD_FILE" 2>/dev/null
    log "Join 命令已保存到: $JOIN_CMD_FILE"

    success "Master 节点初始化完成"
}

# ------------------------------ 使用外部 etcd 初始化 Master -----------------------
init_master_external_etcd() {
    info "========== 主节点初始化 (External etcd) =========="

    local default_iface; default_iface="$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')"
    local default_ip; default_ip="$(ip -o -4 addr show "$default_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"

    echo ""
    log "检测到默认网卡: $default_iface, IP: $default_ip"

    read -rp "  请输入 Master 节点 IP [默认: $default_ip]: " MASTER_IP
    MASTER_IP="${MASTER_IP:-$default_ip}"

    if [ -n "${ETCD_ENDPOINTS:-}" ]; then
        log "使用已配置的 etcd endpoints: $ETCD_ENDPOINTS"
        read -rp "  确认 etcd endpoints [${ETCD_ENDPOINTS}]: " input_endpoints
        ETCD_ENDPOINTS="${input_endpoints:-$ETCD_ENDPOINTS}"
    else
        read -rp "  请输入 etcd endpoints (例: https://10.0.0.1:2379,https://10.0.0.2:2379,https://10.0.0.3:2379): " ETCD_ENDPOINTS
        if [ -z "$ETCD_ENDPOINTS" ]; then
            die "etcd endpoints 不能为空"
        fi
    fi

    echo ""
    echo -e "  ${BOLD}HA 高可用配置 (可选):${NC}"
    read -rp "  是否需要配置 Control Plane Endpoint (多 Master/负载均衡)? [y/N]: " ha_setup
    if [[ "$ha_setup" =~ ^[Yy]$ ]]; then
        read -rp "  请输入 Control Plane Endpoint (域名或 VIP, 例: k8s-api.example.com:6443): " CONTROL_PLANE_ENDPOINT
        log "Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT"
    fi

    read -rp "  请输入 K8s 版本 [默认: ${K8S_VERSION}]: " input_ver
    K8S_VERSION="${input_ver:-$K8S_VERSION}"

    read -rp "  请输入节点名称 [默认: 自动]: " NODE_NAME
    if [ -n "$NODE_NAME" ]; then
        hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || true
        log "节点名称设置为: $NODE_NAME"
    fi

    info "预拉取 K8s 组件镜像..."
    if [ -n "${K8S_MIRROR:-}" ]; then
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" \
            --image-repository "$K8S_MIRROR" 2>&1 | tee -a "$LOG_FILE"
    else
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" 2>&1 | tee -a "$LOG_FILE"
    fi

    local init_args=(
        "--kubernetes-version=v${K8S_VERSION}"
        "--pod-network-cidr=${POD_CIDR}"
        "--service-cidr=${SERVICE_CIDR}"
        "--apiserver-advertise-address=${MASTER_IP}"
        "--external-etcd-endpoints=${ETCD_ENDPOINTS}"
        "--cri-socket=unix:///run/containerd/containerd.sock"
    )

    if [ -n "${K8S_MIRROR:-}" ]; then
        init_args+=("--image-repository=${K8S_MIRROR}")
    fi

    if [ -n "${CONTROL_PLANE_ENDPOINT:-}" ]; then
        init_args+=("--control-plane-endpoint=${CONTROL_PLANE_ENDPOINT}")
    fi

    info "执行 kubeadm init (External etcd)..."
    log "参数: ${init_args[*]}"
    kubeadm init "${init_args[@]}" 2>&1 | tee -a "$LOG_FILE"

    info "配置 kubectl..."
    mkdir -p "$HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
    chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null || true
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config

    kubeadm token create --print-join-command > "$JOIN_CMD_FILE" 2>/dev/null
    log "Join 命令已保存到: $JOIN_CMD_FILE"

    success "Master 节点初始化完成 (External etcd)"
}

# ------------------------------ 安装网络插件 ------------------------------------
install_cni() {
    info "========== 安装 CNI 网络插件 =========="

    case "$CNI_PLUGIN" in
        flannel)
            kubectl apply -f "$CNI_MANIFEST" 2>&1 | tee -a "$LOG_FILE"
            ;;
        calico)
            # 如果 Pod CIDR 不是默认值，替换 manifest
            curl -sSL "$CNI_MANIFEST" -o /tmp/calico.yaml
            if [ "$POD_CIDR" != "192.168.0.0/16" ]; then
                sed -i "s|192\.168\.0\.0/16|$POD_CIDR|g" /tmp/calico.yaml
            fi
            kubectl apply -f /tmp/calico.yaml 2>&1 | tee -a "$LOG_FILE"
            rm -f /tmp/calico.yaml
            ;;
        cilium)
            # Cilium CLI 安装
            local cilium_version="1.14.5"
            if [ "$ARCH_TYPE" = "amd64" ]; then
                curl -sSL "https://github.com/cilium/cilium-cli/releases/download/v${cilium_version}/cilium-linux-amd64.tar.gz" \
                    -o /tmp/cilium.tar.gz
            else
                curl -sSL "https://github.com/cilium/cilium-cli/releases/download/v${cilium_version}/cilium-linux-arm64.tar.gz" \
                    -o /tmp/cilium.tar.gz
            fi
            tar xzf /tmp/cilium.tar.gz -C /usr/local/bin cilium
            rm -f /tmp/cilium.tar.gz

            cilium install \
                --cluster-pool-ipv4-cidr="$POD_CIDR" \
                --version "${cilium_version}" 2>&1 | tee -a "$LOG_FILE"
            ;;
        weave)
            kubectl apply -f "$CNI_MANIFEST" 2>&1 | tee -a "$LOG_FILE"
            ;;
    esac

    success "CNI 网络插件 ($CNI_PLUGIN) 部署完成"
}

# ------------------------------ 主节点模式选择 ----------------------------------
configure_master_mode() {
    info "========== 主节点调度模式配置 =========="

    echo ""
    echo -e "  ${BOLD}请选择 Master 节点调度模式:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 纯 Master 模式 - Master 仅负责管理，不调度业务 Pod (默认)"
    echo -e "  ${GREEN}2)${NC} 混合模式     - Master 同时作为工作节点，允许调度 Pod"
    echo -e "  ${GREEN}3)${NC} 单节点模式   - All-in-One，移除污点并允许单节点运行"
    echo ""

    local mode_choice
    read -rp "  请输入选项 [1-3, 默认:1]: " mode_choice
    mode_choice="${mode_choice:-1}"

    case "$mode_choice" in
        1)
            log "纯 Master 模式: Master 节点不调度 Pod"
            info "Master 节点保持默认，仅运行系统组件"
            ;;
        2)
            log "混合模式: 移除 Master 污点，允许调度 Pod"
            kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
            kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
            success "已移除 Master 污点，允许 Pod 调度到 Master 节点"
            ;;
        3)
            log "单节点 All-in-One 模式"
            kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
            kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
            success "单节点 All-in-One 模式: 污点已移除"

            # 对于单节点，配置容忍度使得关键组件可以调度
            info "提示: 单节点模式下建议配置存储类(如 local-path)以支持 PVC"
            ;;
    esac
}

# ------------------------------ 安装基础组件 ------------------------------------
install_addons() {
    info "========== 可选组件安装 =========="

    echo ""
    echo -e "  ${BOLD}选择要安装的附加组件:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Metrics Server  - HPA 自动扩缩容指标采集"
    echo -e "  ${GREEN}2)${NC} Ingress Nginx  - 入口控制器"
    echo -e "  ${GREEN}3)${NC} Dashboard      - Kubernetes Web UI 仪表盘"
    echo -e "  ${GREEN}4)${NC} 跳过，不安装任何组件"
    echo ""

    local addon_choice
    read -rp "  请输入选项 [1-4, 支持多选如: 123, 默认:4]: " addon_choice
    addon_choice="${addon_choice:-4}"

    if [[ "$addon_choice" == *"1"* ]]; then
        info "安装 Metrics Server..."
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
            2>&1 | tee -a "$LOG_FILE"
        # 跳过 TLS 验证 (某些环境需要)
        kubectl patch deployment metrics-server -n kube-system \
            --type='json' \
            -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' \
            2>/dev/null || true
        success "Metrics Server 安装完成"
    fi

    if [[ "$addon_choice" == *"2"* ]]; then
        info "安装 Ingress Nginx..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.1/deploy/static/provider/cloud/deploy.yaml \
            2>&1 | tee -a "$LOG_FILE"
        success "Ingress Nginx 安装完成"
    fi

    if [[ "$addon_choice" == *"3"* ]]; then
        info "安装 Kubernetes Dashboard..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml \
            2>&1 | tee -a "$LOG_FILE"

        # 创建 admin 用户
        cat <<EOF | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

        # 获取 Token
        local dash_token
        dash_token="$(kubectl -n kubernetes-dashboard create token admin-user --duration=87600h 2>/dev/null || \
                     kubectl -n kubernetes-dashboard get secret "$(kubectl -n kubernetes-dashboard get sa admin-user -o jsonpath='{.secrets[0].name}' 2>/dev/null)" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
        echo ""
        info "====== Dashboard 访问 Token ======"
        echo "$dash_token"
        echo "=================================="
        success "Kubernetes Dashboard 安装完成"
        info "启动 Dashboard 访问: kubectl proxy 后访问 http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    fi
}

# ------------------------------ 工作节点加入 ------------------------------------
join_worker() {
    info "========== 工作节点加入集群 =========="

    if [ -f "$JOIN_CMD_FILE" ]; then
        info "读取本地 join 命令文件..."
        JOIN_CMD="$(cat "$JOIN_CMD_FILE")"
        log "Join 命令: $JOIN_CMD"
    else
        echo ""
        echo -e "  请从 Master 节点获取 join 命令 (在 Master 执行: ${GREEN}kubeadm token create --print-join-command${NC})"
        read -rp "  粘贴 join 命令: " JOIN_CMD
        if [ -z "$JOIN_CMD" ]; then
            die "未提供 join 命令"
        fi
    fi

    # 设置节点名称
    read -rp "  请输入本节点名称 [默认: 自动]: " NODE_NAME
    if [ -n "$NODE_NAME" ]; then
        hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || true
        log "节点名称设置为: $NODE_NAME"
    fi

    # 预拉取镜像
    info "预拉取 K8s 组件镜像..."
    if [ -n "${K8S_MIRROR:-}" ]; then
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" \
            --image-repository "$K8S_MIRROR" 2>&1 | tee -a "$LOG_FILE"
    else
        kubeadm config images pull \
            --kubernetes-version "v${K8S_VERSION}" 2>&1 | tee -a "$LOG_FILE"
    fi

    # 执行 join
    info "加入集群..."
    $JOIN_CMD 2>&1 | tee -a "$LOG_FILE"

    success "工作节点已加入集群"
    info "请在 Master 节点执行 kubectl get nodes 验证节点状态"
}

# ------------------------------ 添加 Master 节点 --------------------------------
join_control_plane() {
    info "========== 添加 Control Plane 节点 =========="

    echo ""
    echo -e "  请从已有 Master 节点获取以下信息:"
    echo -e "    ${CYAN}kubeadm init phase upload-certs --upload-certs${NC}"
    echo -e "    ${CYAN}kubeadm token create --print-join-command${NC}"
    echo ""

    read -rp "  粘贴 join 命令 (包含 --control-plane --certificate-key 参数): " JOIN_CMD
    if [ -z "$JOIN_CMD" ]; then
        die "未提供 join 命令"
    fi

    read -rp "  请输入本节点名称 [默认: 自动]: " NODE_NAME
    if [ -n "$NODE_NAME" ]; then
        hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || true
        log "节点名称设置为: $NODE_NAME"
    fi

    info "加入集群作为 Control Plane 节点..."
    $JOIN_CMD 2>&1 | tee -a "$LOG_FILE"

    # 配置 kubectl
    mkdir -p "$HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
    chown "$(id -u):$(id -g)" "$HOME/.kube/config" 2>/dev/null || true

    success "Control Plane 节点加入完成"
}

# ------------------------------ 部署状态检查 ------------------------------------
check_cluster_status() {
    info "========== 集群状态检查 =========="

    echo ""
    log "集群节点状态:"
    kubectl get nodes -o wide 2>/dev/null || warn "无法获取节点列表"

    echo ""
    log "系统 Pod 状态:"
    kubectl get pods -n kube-system -o wide 2>/dev/null || warn "无法获取 Pod 列表"

    echo ""
    log "集群组件状态:"
    kubectl get componentstatuses 2>/dev/null || kubectl get pods -n kube-system | grep -E 'etcd|apiserver|controller|scheduler' || true

    success "集群状态检查完成"
}

# ------------------------------ etcd 集群健康检查 --------------------------------
etcd_health_check() {
    info "========== etcd 集群健康检查 =========="
    echo ""

    if ! command -v etcdctl &>/dev/null; then
        warn "etcdctl 未安装, 无法检查 etcd 健康状态"
        return
    fi

    local etcd_endpoints="${ETCD_ENDPOINTS:-https://127.0.0.1:2379}"

    log "etcd 成员列表:"
    ETCDCTL_API=3 etcdctl \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
        --endpoints="$etcd_endpoints" \
        member list 2>/dev/null || warn "无法获取 etcd 成员列表"

    echo ""
    log "etcd 节点健康状态:"
    ETCDCTL_API=3 etcdctl \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
        --endpoints="$etcd_endpoints" \
        endpoint health 2>/dev/null || warn "无法获取 etcd 健康状态"

    echo ""
    log "etcd 集群状态:"
    ETCDCTL_API=3 etcdctl \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
        --endpoints="$etcd_endpoints" \
        endpoint status --write-out=table 2>/dev/null || warn "无法获取 etcd 状态"

    success "etcd 健康检查完成"
}

# ------------------------------ 打印完成信息 ------------------------------------
print_summary() {
    echo ""
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                    部署完成!                             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${BOLD}集群信息:${NC}"
    echo -e "    K8s 版本:      ${GREEN}v${K8S_VERSION}${NC}"
    echo -e "    网络插件:      ${GREEN}${CNI_PLUGIN}${NC}"
    echo -e "    Pod CIDR:      ${GREEN}${POD_CIDR}${NC}"
    echo -e "    Service CIDR:  ${GREEN}${SERVICE_CIDR}${NC}"
    echo -e "    容器运行时:    ${GREEN}containerd${NC}"
    if [ -n "${ETCD_ENDPOINTS:-}" ]; then
        echo -e "    etcd 模式:     ${GREEN}External${NC}"
        echo -e "    etcd 端点:     ${GREEN}${ETCD_ENDPOINTS}${NC}"
    else
        echo -e "    etcd 模式:     ${GREEN}内嵌 (Stacked)${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}常用命令:${NC}"
    echo -e "    查看节点:      kubectl get nodes -o wide"
    echo -e "    查看 Pod:      kubectl get pods -A"
    echo -e "    查看服务:      kubectl get svc -A"
    echo -e "    查看 etcd:     etcdctl member list"
    echo -e "    Join 命令:     cat ${JOIN_CMD_FILE}"
    echo -e "    部署日志:      ${LOG_FILE}"
    echo ""

    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        echo -e "  ${YELLOW}提示:${NC} 请确保安全组/防火墙已开放以下端口:"
        echo -e "    Master: 6443, 2379-2380, 10250, 10257, 10259"
        echo -e "    Worker: 10250, 30000-32767 (NodePort)"
        echo -e "    etcd:   2379-2380"
    fi

    if [ "$OS_TYPE" = "redhat" ]; then
        echo -e "  ${YELLOW}提示:${NC} 请确保 iptables 规则或安全组已开放必要端口"
    fi

    echo ""
}

# ------------------------------ 交互式菜单 --------------------------------------
interactive_menu() {
    local action_choice

    while true; do
        banner
        echo -e "  ${BOLD}请选择部署模式:${NC}"
        echo ""
        echo -e "  ${GREEN}1)${NC} 初始化 Master 节点 (内嵌 etcd, 含网络插件 + 组件选择)"
        echo -e "  ${GREEN}2)${NC} 初始化 Master 节点 (外部 etcd, 需已有 etcd 集群)"
        echo -e "  ${GREEN}3)${NC} 部署 External etcd 集群"
        echo -e "  ${GREEN}4)${NC} 加入 Worker 节点"
        echo -e "  ${GREEN}5)${NC} 加入 Control Plane 节点 (多 Master HA)"
        echo -e "  ${GREEN}6)${NC} 单节点 All-in-One 部署 (内嵌 etcd, Master+Worker)"
        echo -e "  ${GREEN}7)${NC} 检查集群状态"
        echo -e "  ${GREEN}8)${NC} etcd 集群健康检查"
        echo -e "  ${GREEN}9)${NC} 重置节点 (kubeadm reset + etcd 清理)"
        echo -e "  ${GREEN}10)${NC} 退出"
        echo ""

        read -rp "  请输入选项 [1-10]: " action_choice

        case "$action_choice" in
            1)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_containerd
                select_cni_plugin
                install_k8s_tools
                init_master
                install_cni
                configure_master_mode
                install_addons
                check_cluster_status
                print_summary
                break
                ;;
            2)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_containerd
                select_cni_plugin
                install_k8s_tools
                init_master_external_etcd
                install_cni
                configure_master_mode
                install_addons
                check_cluster_status
                print_summary
                break
                ;;
            3)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_k8s_tools
                configure_etcd_cluster
                deploy_etcd
                etcd_health_check
                print_summary
                break
                ;;
            4)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_containerd
                install_k8s_tools
                join_worker
                check_cluster_status
                break
                ;;
            5)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_containerd
                install_k8s_tools
                join_control_plane
                check_cluster_status
                break
                ;;
            6)
                detect_os
                system_check
                configure_image_proxy
                system_init
                install_containerd
                select_cni_plugin
                install_k8s_tools
                init_master
                install_cni
                kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
                kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
                install_addons
                check_cluster_status
                print_summary
                break
                ;;
            7)
                detect_os
                check_cluster_status
                break
                ;;
            8)
                detect_os
                etcd_health_check
                break
                ;;
            9)
                info "正在重置节点..."
                systemctl stop etcd 2>/dev/null || true
                systemctl disable etcd 2>/dev/null || true
                rm -f /etc/systemd/system/etcd.service
                rm -rf "$ETCD_DATA_DIR" /etc/profile.d/etcd.sh 2>/dev/null || true
                rm -rf /etc/kubernetes/pki/etcd 2>/dev/null || true
                kubeadm reset -f 2>&1 | tee -a "$LOG_FILE" || true
                rm -rf "$HOME/.kube" /root/.kube 2>/dev/null || true
                iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
                ipvsadm --clear 2>/dev/null || true
                systemctl daemon-reload
                success "节点已重置"
                break
                ;;
            10)
                info "退出"
                exit 0
                ;;
            *)
                warn "无效选项"
                ;;
        esac
    done
}

# ------------------------------ 非交互模式入口 ----------------------------------
# 必须 root 检查
root_check() {
    if [ "$(id -u)" -ne 0 ]; then
        die "此脚本必须以 root 用户运行! 请使用: sudo bash $0"
    fi
}

# 入口
main() {
    root_check

    case "${1:-menu}" in
        init)
            detect_os
            system_check
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            CNI_PLUGIN="calico"
            POD_CIDR="192.168.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
            system_init
            install_containerd
            install_k8s_tools
            init_master
            install_cni
            configure_master_mode
            check_cluster_status
            print_summary
            ;;
        init-external)
            detect_os
            system_check
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            CNI_PLUGIN="calico"
            POD_CIDR="192.168.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
            system_init
            install_containerd
            install_k8s_tools
            init_master_external_etcd
            install_cni
            configure_master_mode
            check_cluster_status
            print_summary
            ;;
        etcd)
            detect_os
            system_check
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            system_init
            install_k8s_tools
            configure_etcd_cluster
            deploy_etcd
            etcd_health_check
            print_summary
            ;;
        etcd-check)
            detect_os
            etcd_health_check
            ;;
        join)
            detect_os
            system_check
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            system_init
            install_containerd
            install_k8s_tools
            join_worker
            check_cluster_status
            ;;
        allinone)
            detect_os
            system_check
            MIRROR_REGISTRY="registry.cn-hangzhou.aliyuncs.com"
            MIRROR_ENDPOINT="https://docker.m.daocloud.io"
            K8S_MIRROR="registry.cn-hangzhou.aliyuncs.com/google_containers"
            CNI_PLUGIN="calico"
            POD_CIDR="192.168.0.0/16"
            CNI_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
            system_init
            install_containerd
            install_k8s_tools
            init_master
            install_cni
            kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
            kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
            check_cluster_status
            print_summary
            ;;
        menu|"")
            interactive_menu
            ;;
        *)
            echo "用法: $0 [init|init-external|etcd|etcd-check|join|allinone|menu]"
            echo ""
            echo "  init          - 一键部署 Master 节点 (内嵌 etcd, 非交互, calico + aliyun 镜像)"
            echo "  init-external - 一键部署 Master 节点 (外部 etcd, 非交互)"
            echo "  etcd          - 部署 External etcd 集群 (非交互)"
            echo "  etcd-check    - etcd 集群健康检查"
            echo "  join          - 一键加入 Worker 节点 (非交互)"
            echo "  allinone      - 单节点 All-in-One 部署 (内嵌 etcd, 非交互)"
            echo "  menu          - 交互式菜单 (默认)"
            exit 1
            ;;
    esac
}

main "$@"
