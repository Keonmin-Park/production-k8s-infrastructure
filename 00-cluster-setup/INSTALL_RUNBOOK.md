# vSphere HA 쿠버네티스 클러스터 구축 런북 (kubeadm v1.28 + Cilium eBPF)

이 문서는 엔터프라이즈 환경 기준의 **Multi-Control Plane (HA) 고가용성 클러스터**를 구축하는 전체 실무 절차를 다룹니다.

---

## 1. 클러스터 노드 토폴로지 설계

| 호스트명 | 역할 | 권장 vSphere Spec | 고정 IP (180~190 대역) | 비고 |
| :--- | :--- | :--- | :--- | :--- |
| **k8s-vip** | **Virtual IP** | - | `10.40.101.180` | kube-vip이 ARP로 동적 바인딩 |
| `k8s-cp-01` | Control Plane 1 | 4 vCPU / 8GB RAM / 60GB Disk | `10.40.101.181` | 최초 초기화 노드 (Bootstrap) |
| `k8s-cp-02` | Control Plane 2 | 4 vCPU / 8GB RAM / 60GB Disk | `10.40.101.182` | HA etcd / API Server |
| `k8s-cp-03` | Control Plane 3 | 4 vCPU / 8GB RAM / 60GB Disk | `10.40.101.183` | HA etcd / API Server |
| `k8s-worker-01` | Worker Node 1 | 4~8 vCPU / 8~16GB RAM / 80GB Disk | `10.40.101.184` | 워크로드 실행 노드 |
| `k8s-worker-02` | Worker Node 2 | 4~8 vCPU / 8~16GB RAM / 80GB Disk | `10.40.101.185` | 워크로드 실행 노드 |
| `k8s-worker-03` | Worker Node 3 | 4~8 vCPU / 8~16GB RAM / 80GB Disk | `10.40.101.186` | 워크로드 실행 노드 |

> **[실습 팁]** VM 리소스가 부족하다면 최소 **CP 3대 + Worker 2대** (또는 단기 검증 시 CP 1대 + Worker 2대)로 축소하여 시작해도 무방합니다.

---

## 2. Phase 1: 모든 노드(CP/Worker) 공통 사전 작업

모든 노드에 SSH로 접속하여 `01-node-prerequisites.sh`를 실행합니다:

```bash
# 1. 호스트명 설정 (노드별로 변경)
sudo hostnamectl set-hostname k8s-cp-01

# 2. 사전 설정 스크립트 실행 (Swap 비활성화, 커널 파라미터, containerd, kubeadm v1.28)
chmod +x 01-node-prerequisites.sh
./01-node-prerequisites.sh
```

---

## 3. Phase 2: 컨트롤 플레인 VIP (kube-vip) 설정

첫 번째 컨트롤 플레인(`k8s-cp-01`)에서 kube-vip Static Pod를 먼저 생성하여 API Server 트래픽을 중계할 가상 IP를 띄웁니다:

```bash
# 사용 중이지 않은 가상 IP와 실제 네트워크 인터페이스명을 지정합니다.
# 인터페이스명 확인: ip -br a (여기서는 확인된 ens33 사용)
chmod +x 02-setup-kube-vip.sh
./02-setup-kube-vip.sh 10.40.101.180 ens33
```

---

## 4. Phase 3: 첫 번째 컨트롤 플레인 부트스트랩 (kubeadm init)

`03-kubeadm-init-config.yaml` 파일의 `controlPlaneEndpoint`와 `certSANs`의 VIP 주소(10.40.101.180)를 확인한 후 실행합니다.

```bash
# 1. 필요한 K8s 컨테이너 이미지 사전 다운로드
sudo kubeadm config images pull --config 03-kubeadm-init-config.yaml

# 2. 클러스터 초기화 실행 (--upload-certs 로 인증서를 etcd Secret에 자동 공유)
sudo kubeadm init --config 03-kubeadm-init-config.yaml --upload-certs
```

초기화가 끝나면 화면에 **두 종류의 join 명령어**가 출력됩니다:
1. **Control Plane 추가용 join 명령어** (`--control-plane --certificate-key <KEY>`)
2. **Worker 노드 추가용 join 명령어**

```bash
# 3. kubectl 관리자 권한 설정
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## 5. Phase 4: 컨트롤 플레인 2, 3번 추가 (HA 구성)

`k8s-cp-02`, `k8s-cp-03` 노드에서도 고가용성 VIP를 바인딩할 수 있도록 kube-vip을 생성한 뒤 join합니다:

```bash
# 1. kube-vip 생성 (cp-02, cp-03 각각 실행)
./02-setup-kube-vip.sh 10.40.101.180 ens33

# 2. Control Plane Join 명령어 실행 (Phase 3 결과에서 복사한 명령어)
sudo kubeadm join 10.40.101.180:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --control-plane --certificate-key <CERT_KEY>
```

---

## 6. Phase 5: 워커 노드 조인 (Worker Nodes)

각 워커 노드(`k8s-worker-01` ~ `03`)에서 워커용 join 명령어를 실행합니다:

```bash
sudo kubeadm join 10.40.101.180:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

---

## 7. Phase 6: Cilium eBPF CNI 설치 및 클러스터 활성화

`k8s-cp-01`에서 CNI를 설치합니다. CNI가 설치되기 전까지는 노드 상태가 `NotReady`인 것이 정상입니다.

```bash
# Cilium eBPF 설치 스크립트 실행
chmod +x 04-install-cilium.sh
./04-install-cilium.sh

# 설치 상태 검증
cilium status
```

---

## 8. 최종 클러스터 상태 검증

```bash
# 1. 노드 상태 확인 (모두 Ready 상태여야 함)
kubectl get nodes -o wide

# 2. 모든 시스템 파드 정상 동작 확인
kubectl get pods -A -o wide

# 3. Cilium eBPF 맵 및 커널 기능 상태 점검
cilium bpf lb list
```
