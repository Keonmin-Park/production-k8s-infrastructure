# 01-cluster-init: kube-vip VIP & HA 클러스터 부트스트랩

대규모 트래픽을 지탱하는 **고가용성 쿠버네티스 클러스터(HA Multi-Control Plane + Cilium eBPF)** 구축이 100% 완료된 프로덕션 런북입니다.  
외부 L4 로드밸런서 없이 `kube-vip`(Layer 2 ARP)으로 제어면 VIP를 선출하고, `kube-proxy`(iptables)를 완전히 제거한 뒤 **Cilium eBPF 커널 네이티브 라우팅**을 적용하여 6대 노드 전체가 정상 `Ready` 상태를 달성했습니다.

---

## 1. 클러스터 아키텍처 및 엔드포인트 토폴로지

| 항목 | 설정값 | 설계 의도 및 역할 |
| :--- | :--- | :--- |
| **Control Plane VIP** | **`10.40.101.180:6443`** | 3대의 컨트롤 플레인이 공유하는 단일 가상 엔드포인트 (L2 ARP 리더 선출) |
| **K8s Version** | **`v1.28.15`** | 모듈 3에서 v1.29 무중단 롤링 업그레이드 실습 연계 버전 |
| **Pod CIDR** | **`10.244.0.0/16`** | Cilium CNI eBPF 네이티브 라우팅 대역 (Geneve/VxLAN 오버헤드 0%) |
| **Service CIDR** | **`10.96.0.0/12`** | 클러스터 내부 ClusterIP 서비스 대역 |
| **etcd Quota** | **`8 GB (8589934592)`** | 대규모 트래픽 및 수천 개 파드 생성 시 etcd 데이터베이스 공간 고갈 방지 |
| **maxPods** | **`250`** | 노드당 기본 110개 한도를 250개로 확장하여 고밀도 워크로드 수용 |
| **CNI Engine** | **Cilium v1.15.5 (eBPF)** | `kubeProxyReplacement=true`, `sockops=true`, Hubble 옵저버빌리티 내장 |

---

## 2. Step 1: kube-vip Static Pod 매니페스트 생성 (k8s-cp-01)

쿠버네티스 API Server가 뜨기 전에도 컨트롤 플레인 엔드포인트(`10.40.101.180`)가 Layer 2 ARP 모드로 네트워크에 브로드캐스팅될 수 있도록 `kubelet`이 직접 감시하는 정적 파드(Static Pod) 매니페스트를 생성합니다.

```bash
# 1) Static Pod 디렉토리 생성
sudo mkdir -p /etc/kubernetes/manifests

# 2) kube-vip 컨테이너 이미지 다운로드 (containerd 런타임)
sudo ctr --namespace k8s.io image pull ghcr.io/kube-vip/kube-vip:v0.7.2

# 3) kube-vip Static Pod 매니페스트 생성
sudo ctr --namespace k8s.io run --rm --net-host ghcr.io/kube-vip/kube-vip:v0.7.2 vip-manifest \
/kube-vip manifest pod \
  --interface "ens33" \
  --address "10.40.101.180" \
  --controlplane \
  --services \
  --arp \
  --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

> 💡 **kube-vip 고가용성(HA) 동작 원리**: `kube-vip`은 `--arp`와 `--leaderElection` 플래그를 통해 3대의 마스터 노드 중 활성 노드 1대만 VIP를 소유하며, 해당 노드 장애 시 5초 이내에 다른 노드로 VIP가 자동 승계됩니다.

---

## 3. Step 2: 프로덕션 레벨 `kubeadm-config.yaml` 생성 및 환경 변수 자동화

하드코딩된 설정 대신 `setup-env.sh` 스크립트를 사용하여 환경 변수를 주입하고 `/etc/kubernetes/kubeadm-config.yaml`을 일괄 렌더링합니다.

```bash
# 1) 환경 변수 파일 준비 및 세션 등록
cp cluster.env.example cluster.env
source ./setup-env.sh

# 2) kubeadm 설정 렌더링 (자동으로 /etc/kubernetes/kubeadm-config.yaml 생성)
./setup-env.sh --render
```

생성되는 매니페스트 원형(`03-kubeadm-init-config.yaml`):

```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "0.0.0.0"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
  imagePullPolicy: IfNotPresent
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "${K8S_VERSION}"
clusterName: "${CLUSTER_NAME}"
controlPlaneEndpoint: "${CONTROL_PLANE_VIP}:6443"
networking:
  podSubnet: "${POD_SUBNET}"
  serviceSubnet: "${SERVICE_SUBNET}"
  dnsDomain: "cluster.local"
apiServer:
  certSANs:
    - "${CONTROL_PLANE_VIP}"                      # Control Plane VIP
    - "${CP1_IP}"                                 # CP 1 고정 IP
    - "${CP2_IP}"                                 # CP 2 고정 IP
    - "${CP3_IP}"                                 # CP 3 고정 IP
    - "${VIP_DOMAIN}"
    - "127.0.0.1"
    - "localhost"
controllerManager:
  extraArgs:
    bind-address: "0.0.0.0"                # 프로메테우스 메트릭 스크랩 허용
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"                # 프로메테우스 메트릭 스크랩 허용
etcd:
  local:
    extraArgs:
      listen-metrics-urls: "http://0.0.0.0:2381" # etcd 메트릭 엔드포인트
      quota-backend-bytes: "8589934592"           # 8GB etcd 스토리지 쿼터
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
maxPods: 250
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
```

---

## 4. Step 3: [검증 완료] 클러스터 초기화 부트스트랩 (k8s-cp-01)

```bash
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
```

**실제 실행 결과 로그 (k8s-cp-01)**:
```plain text
[init] Using Kubernetes version: v1.28.15
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes cluster
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [k8s-cp-01 k8s-vip.infra.internal kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local localhost] and IPs [10.96.0.1 10.40.101.181 10.40.101.180 10.40.101.182 10.40.101.183 127.0.0.1]
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[kubelet-start] Starting the kubelet
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods...
[apiclient] All control plane components are healthy after 6.566607 seconds
[upload-certs] Using certificate key:
<masked-certificate-key-64hex>
[mark-control-plane] Marking the node k8s-cp-01 as control-plane
[bootstrap-token] Using token: <bootstrap-token-6x16>

Your Kubernetes control-plane has initialized successfully!
```

---

## 5. Step 4: [검증 완료] kubectl 관리자 권한 설정 & VIP 응답 검증

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo 'alias k=kubectl' >> ~/.bashrc
source ~/.bashrc
```

**실제 VIP Ping 응답 및 1차 노드 확인 (k8s-cp-01)**:
```plain text
kadmin@k8s-cp-01:~$ ping -c 2 10.40.101.180
PING 10.40.101.180 (10.40.101.180) 56(84) bytes of data.
64 bytes from 10.40.101.180: icmp_seq=1 ttl=64 time=0.045 ms
64 bytes from 10.40.101.180: icmp_seq=2 ttl=64 time=0.050 ms

--- 10.40.101.180 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.045/0.047/0.050/0.002 ms
```

> 💡 **VIP 검증 완료**: `10.40.101.180` 가상 IP가 `0.045ms` 초저지연으로 즉각 응답하여 kube-vip의 L2 ARP 바인딩이 성공했습니다.

---

## 6. Step 5: [검증 완료] Multi-Control Plane 노드(`k8s-cp-02`, `k8s-cp-03`) 조인

베이스 VM 템플릿 복제 잔존 파일(`/etc/kubernetes/kubelet.conf`) 초기화 및 `kube-vip.yaml` 배치 후, 3대의 마스터 노드가 모두 클러스터에 조인되어 **etcd 3노드 Quorum(과반수 합의)**을 달성했습니다.

```bash
# 1) 복제 잔재 초기화 및 Swap 끄기 (cp-02, cp-03 각각 실행)
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/kubelet/* /var/lib/etcd
sudo swapoff -a

# 2) kube-vip 정적 파드 생성 (VIP 리더 선출 참여)
sudo mkdir -p /etc/kubernetes/manifests
sudo ctr --namespace k8s.io run --rm --net-host ghcr.io/kube-vip/kube-vip:v0.7.2 vip-manifest \
/kube-vip manifest pod \
  --interface "ens33" \
  --address "10.40.101.180" \
  --controlplane \
  --services \
  --arp \
  --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

# 3) 컨트롤 플레인 조인 실행
sudo kubeadm join 10.40.101.180:6443 --token <bootstrap-token> \
  --discovery-token-ca-cert-hash sha256:<discovery-token-ca-cert-hash> \
  --control-plane --certificate-key <certificate-key>
```

**실제 터미널 검증 결과**:
```plain text
[etcd] Announced new etcd member joining to the existing etcd cluster
[etcd] Creating static Pod manifest for "etcd"
[etcd] Waiting for the new etcd member to join the cluster. This can take up to 40s
[mark-control-plane] Marking the node k8s-cp-02 as control-plane
[mark-control-plane] Marking the node k8s-cp-03 as control-plane
This node has joined the cluster and a new control plane instance was created!
```

---

## 7. Step 6: [검증 완료] 워커 노드(`k8s-worker-01`, `02`, `03`) 디스크 확장 & 조인

### 7-1. 온라인 무중단 80GB 디스크 확장
```bash
echo 1 | sudo tee /sys/class/block/sda/device/rescan && sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2
df -h /
```

**실제 터미널 출력 결과**:
```plain text
CHANGED: partition=2 start=2203648 old: size=123623424 end=125827072 new: size=165568479 end=167772127
The filesystem on /dev/sda2 is now 20696059 (4k) blocks long.
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2        78G  7.9G   66G  11% /
```

### 7-2. 워커 노드 조인 실행
```bash
sudo systemctl restart containerd
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/kubelet/*
sudo swapoff -a

sudo kubeadm join 10.40.101.180:6443 --token <bootstrap-token> \
  --discovery-token-ca-cert-hash sha256:<discovery-token-ca-cert-hash>
```

---

## 8. Step 7: [최종 검증 완료] Cilium eBPF CNI 배포 및 6노드 Ready 달성

`kube-proxy`(iptables)를 완전히 제거하고 커널 레벨 eBPF 라우팅 및 소켓 가속(`sockops`), Hubble 관찰성을 한 번에 활성화했습니다.

### 8-1. Cilium 배포 및 kube-proxy 완전 대체 실행
```bash
# 1) Helm 3 및 Cilium CLI 설치 (k8s-cp-01)
which helm || curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm -f cilium-linux-amd64.tar.gz

# 2) kube-proxy DaemonSet 및 ConfigMap 삭제 (eBPF 전권 위임)
kubectl -n kube-system delete ds kube-proxy 2>/dev/null || true
kubectl -n kube-system delete cm kube-proxy 2>/dev/null || true

# 3) 프로덕션 Values 파일 적용 및 Helm 배포
cat <<'EOF' > cilium-values.yaml
k8sServiceHost: "10.40.101.180"
k8sServicePort: "6443"
kubeProxyReplacement: "true"
bpf:
  masquerade: true
  hostRouting: true
sockops:
  enabled: true
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: "10.244.0.0/16"
bpfCTGlobalAnyMax: 524288
bpfCTGlobalTCPMax: 1048576
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
EOF

helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.15.5 \
  --namespace kube-system \
  -f cilium-values.yaml

# 4) Cilium 상태 대기
cilium status --wait
```

### 8-2. 실제 Cilium 상태 검증 결과 (`cilium status --wait`)
```plain text
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    disabled (using embedded mode)
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet              cilium                   Desired: 6, Ready: 6/6, Available: 6/6
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 6
                       cilium-operator          Running: 2
                       clustermesh-apiserver    
                       hubble-relay             Running: 1
                       hubble-ui                Running: 1
Cluster Pods:          4/4 managed by Cilium
Helm chart version:    1.15.5
```

> 💡 **Cilium 정상 확인**: 6개 노드 전체에서 Cilium 에이전트가 6/6 `Ready`이며, Hubble Relay와 Hubble UI까지 100% 정상 가동되었습니다.

---

### 8-3. 최종 클러스터 노드 검증 (`kubectl get nodes -o wide`)
```plain text
kadmin@k8s-cp-01:~$ kubectl get nodes -o wide
NAME            STATUS   ROLES           AGE     VERSION    INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
k8s-cp-01       Ready    control-plane   21m     v1.28.15   10.40.101.181   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-cp-02       Ready    control-plane   11m     v1.28.15   10.40.101.182   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-cp-03       Ready    control-plane   12m     v1.28.15   10.40.101.183   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-01   Ready    <none>          5m9s    v1.28.15   10.40.101.184   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-02   Ready    <none>          3m34s   v1.28.15   10.40.101.185   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-03   Ready    <none>          3m1s    v1.28.15   10.40.101.186   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
```

> 🚀 6대 노드 전체가 정상 **`Ready`** 상태를 달성하여 고가용성 인프라 부트스트랩이 완료되었습니다.
