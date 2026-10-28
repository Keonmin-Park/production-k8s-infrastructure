# 04-cluster-upgrade: PDB & Graceful Shutdown 기반 v1.28 -> v1.29 무중단 롤링 업그레이드

대규모 엔터프라이즈 트래픽을 처리하는 프로덕션 클러스터 환경에서, 단 한 건의 유의미한 서비스 중단이나 5xx 에러 없이 쿠버네티스 제어면(Control Plane 3대) 및 워커 노드(Worker 3대)를 v1.28.15에서 v1.29.10으로 안전하게 승격시킨 실전 무중단 롤링 업그레이드(Zero-Downtime Rolling Upgrade) 런북입니다.

---

## 1. 무중단 롤링 업그레이드 아키텍처 토폴로지 & 3대 안전장치

```plain text
[클라이언트 트래픽 / Bastion Traffic Probe (7,160 Req)]
                      │ (HTTP GET http://chat.infra.internal/healthz)
                      ▼ (워커 노드 물리 포트 HostPort 직접 인입)
[HAProxy Ingress Controller (DaemonSet / HostPort 80, 443)]
                      │ (PROXY Protocol v2 바이너리 헤더 전송)
                      ▼
[Istio Ingress Gateway (HA: 2 Replicas)]
                      │ (mTLS STRICT 암호화 터널링)
                      ▼
[chat-service-v1 / v2 파드군]
    * PodDisruptionBudget (minAvailable: 1)
    * preStop Hook: sleep 10
    * terminationGracePeriodSeconds: 30
                      │
  ┌───────────────────┼───────────────────┐
  ▼                   ▼                   ▼
[k8s-worker-01]     [k8s-worker-02]     [k8s-worker-03]
(v1.28 -> v1.29)    (v1.28 -> v1.29)    (v1.28 -> v1.29)
* Drain & Evict     * Drain & Evict     * Drain & Evict
```

### 💡 무중단 보장을 위한 3대 안전장치 (Safety Gear)
1. **PodDisruptionBudget (PDB)**:
   - `chat-service-pdb`에 `minAvailable: 1`을 선언하여 노드 드레인 시 최소 1개 이상의 서빙 파드가 반드시 살아있도록 K8s Eviction API 수준에서 강제.
2. **PreStop Hook & Graceful Shutdown**:
   - `preStop: sleep 10` 및 `terminationGracePeriodSeconds: 30` 구성.
   - K8s API 서버의 엔드포인트 삭제 이벤트가 Cilium eBPF 맵 및 Istio Envoy 프록시 라우팅 테이블에 전파되는 지연 시간(2~3초) 동안 파드가 즉시 죽어 발생하는 `Connection Refused / 502 Bad Gateway`를 원천 방지.
3. **Core Addon Ingress & Mesh Control Plane HA 스케일 아웃**:
   - 단일 레플리카였던 `istio-ingressgateway`와 `istiod`를 `replicas: 2`로 스케일 아웃하여, 게이트웨이 파드 축출 중에도 다른 워커 노드의 복제본이 트래픽을 끊김 없이 연속 서빙.

### 💡 업그레이드 방식 비교표
<table header-row="true">
<tr>
<td>비교 항목</td>
<td>전통적인 점검 시간(Maintenance Window) 다운타임 방식</td>
<td>SRE 무중단 롤링 업그레이드 (본 클러스터 채택)</td>
</tr>
<tr>
<td>**서비스 가용성**</td>
<td>새벽 시간대 전체 서비스 중단 공지 및 사용자 인입 차단</td>
<td>**24/365 무중단 서빙**, 라이브 트래픽 인입 상태에서 노드 순차 교체</td>
</tr>
<tr>
<td>**트래픽 연속성 검증**</td>
<td>작업 완료 후 수동 스모크 테스트 수행</td>
<td>업그레이드 전 과정 동안 **고빈도 트래픽 프로브(초당 수회) 실시간 관측**</td>
</tr>
<tr>
<td>**파드 종료 안전성**</td>
<td>SIGTERM 즉시 수신 후 빠른 강제 종료 (TCP RST 유발)</td>
<td>**preStop(10s) + PDB**로 인플라이트 커넥션 완전 드레인 후 종료</td>
</tr>
<tr>
<td>**장애 롤백 복원력**</td>
<td>전체 클러스터 복원 시 장시간 소요</td>
<td>노드 단위 롤링 진행 중 이상 발생 시 **해당 노드 즉시 Uncordon 및 중단**</td>
</tr>
</table>

---

## 2. 실전 무중단 라이브 트래픽 프로브 검증 (Live Traffic Verification)

업그레이드 전 과정(32분 이상 소요) 동안 Bastion 워크스테이션에서 `live-traffic-probe.ps1`을 백그라운드로 구동하여 L7 엔드포인트(`http://chat.infra.internal/healthz`)에 쉼 없이 요청을 인입시켰습니다.

### 📊 실시간 트래픽 프로브 최종 결과
<table header-row="true">
<tr>
<td>총 요청 수 (Total Requests)</td>
<td>성공 (HTTP 200)</td>
<td>실패 (HTTP 5xx / 000)</td>
<td>에러율 (Error Rate)</td>
<td>서비스 가용성 (SLO 달성도)</td>
</tr>
<tr>
<td>**7,160 건**</td>
<td>**7,159 건**</td>
<td>**1 건 (HTTP 000)**</td>
<td>**0.014%**</td>
<td>**99.986% (SLO 99.9% 초과 달성)**</td>
</tr>
</table>

```plain text
[15:57:34] TOTAL: 7130 | SUCCESS(200): 7129 | FAILED(5xx): 1 | ErrorRate: 0.01%
[15:57:36] TOTAL: 7140 | SUCCESS(200): 7139 | FAILED(5xx): 1 | ErrorRate: 0.01%
[15:57:39] TOTAL: 7150 | SUCCESS(200): 7149 | FAILED(5xx): 1 | ErrorRate: 0.01%
[15:57:41] TOTAL: 7160 | SUCCESS(200): 7159 | FAILED(5xx): 1 | ErrorRate: 0.01%
```

### 🔍 실패 1건 (HTTP 000) 심층 사후 분석 (Post-Mortem)
- **증상**: `worker-01` 업그레이드 진행 중 단 1회의 `HTTP 000` 기록.
- **원인 분석**:
  - `HTTP 000`은 서버가 응답한 502/503 에러가 아니며, 클라이언트(curl) 레벨의 **TCP Handshake Timeout**입니다.
  - 테스트 프로브가 Bastion 로컬의 `/etc/hosts`에서 임시로 지정한 단일 노드 IP(`10.40.101.184`)로 직접 요청을 전송하던 중, 워커 1번의 `containerd` 및 노드 네트워크 스택이 재시작되는 찰나(수 밀리초)에 커널 소켓 SYN 패킷 응답이 지연되어 발생했습니다.
- **프로덕션 환경 시사점**:
  - 실서비스 인프라에서는 Ingress 앞단에 외부 L4 로드밸런서가 배치되어 비정상 노드를 밀리초 단위로 헬스체크하여 트래픽 전송 대상에서 사전 제외하므로, 클라이언트 레벨의 핸드셰이크 타임아웃을 방지할 수 있습니다.

---

## 3. 단계별 상세 업그레이드 절차 & 실행 가이드

### Step 1: K8s 공식 Apt 저장소 v1.29 전환 (전체 6개 노드 공통)
Kubernetes 패키지 저장소 정책 변경에 따라 마이너 버전별 전용 레포지토리 키와 소스를 갱신합니다.
```bash
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
```

### Step 2: 제어면 첫 번째 노드(`k8s-cp-01`) 업그레이드
첫 마스터 노드에서만 클러스터 전체 설정 및 etcd, Static Pod 매니페스트를 갱신하는 `apply`를 수행합니다.
```bash
# 1. kubeadm 1.29.10 설치
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.29.10-1.1
sudo apt-mark hold kubeadm

# 2. 업그레이드 플랜 검증 및 실행
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.29.10 -y

# 3. kubelet 및 kubectl 업그레이드
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.29.10-1.1 kubectl=1.29.10-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### Step 3: 보조 제어면(`k8s-cp-02`, `k8s-cp-03`) 롤링 업그레이드
보조 마스터 노드는 이미 갱신된 제어면 설정을 다운로드받아 로컬 컴포넌트만 갱신하는 `upgrade node`를 수행합니다.
```bash
# kubeadm 설치 후 로컬 노드 업그레이드
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.29.10-1.1
sudo apt-mark hold kubeadm

sudo kubeadm upgrade node

# kubelet/kubectl 업그레이드 및 재기동
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.29.10-1.1 kubectl=1.29.10-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### Step 4: 워커 노드(`k8s-worker-01`, `02`, `03`) 순차 드레인 & 업그레이드
각 워커 노드마다 `Drain -> Upgrade -> Uncordon` 파이프라인을 엄격히 준수합니다.
```bash
# [Bastion에서 실행] 워커 노드 안전 축출 및 스케줄링 차단
kubectl drain k8s-worker-01 --ignore-daemonsets --delete-emptydir-data

# [워커 노드 내부에서 실행] 패키지 갱신 및 kubeadm 업그레이드
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get install -y kubeadm=1.29.10-1.1 kubelet=1.29.10-1.1 kubectl=1.29.10-1.1
sudo apt-mark hold kubeadm kubelet kubectl
sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# [Bastion에서 실행] 워커 노드 스케줄링 정상 복구
kubectl uncordon k8s-worker-01
```

---

## 4. 실전 트러블슈팅: PDB 교착 상태(Deadlock) 극복

### 🚨 장애 현상
`k8s-worker-02` 및 `k8s-worker-03` 드레인 실행 시 콘솔에 아래 에러가 반복되며 노드가 드레인되지 않는 현상 발생:
```plain text
evicting pod istio-system/istio-ingressgateway-xxx
error when evicting pods/"istio-ingressgateway-xxx" -n "istio-system" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
evicting pod istio-system/istiod-xxx
error when evicting pods/"istiod-xxx" -n "istio-system" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

### 🔬 근본 원인 (Root Cause)
- `istio-ingressgateway`와 `istiod`가 단일 복제본(`replicas: 1`)으로 실행 중인 상태에서, Istio Helm 차트에 기본 정의된 PDB(`minAvailable: 1`)가 활성화되어 있었습니다.
- 복제본이 1개뿐인 파드를 축출하면 순간적으로 가용 파드 수가 0이 되므로, K8s Eviction Controller가 PDB 위반으로 판단하여 파드 퇴출을 거부하고 5초마다 무한 재시도를 반복하는 교착 상태가 발생했습니다.

### 🛠️ 해결 방안 (게이트웨이 사전 다중화)
PDB를 강제로 삭제하거나 무시(`--disable-eviction`)하는 것은 서비스 중단을 야기하는 위험한 방식입니다.  
고가용성 원칙에 따라 **해당 컨트롤러를 사전에 2개 이상으로 스케일 아웃하여 다른 노드에 복제본을 배치**한 후 드레인을 재개하여 안전하게 통과시켰습니다.
```bash
# 1. 인그레스 게이트웨이 및 컨트롤 플레인 HA 스케일 아웃
kubectl -n istio-system scale deploy istio-ingressgateway --replicas=2
kubectl -n istio-system scale deploy istiod --replicas=2

# 2. 타 노드에 신규 파드가 Running/Ready 상태가 된 후 드레인 정상 완료
kubectl drain k8s-worker-03 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon k8s-worker-03
```

---

## 5. 최종 클러스터 무결성 검증 (Cluster Verification)

### 📌 클러스터 전체 6개 노드 상태 (`kubectl get nodes -o wide`)
```plain text
NAME            STATUS   ROLES           AGE     VERSION    INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
k8s-cp-01       Ready    control-plane   3h34m   v1.29.10   10.40.101.181   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
k8s-cp-02       Ready    control-plane   3h24m   v1.29.10   10.40.101.182   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
k8s-cp-03       Ready    control-plane   3h25m   v1.29.10   10.40.101.183   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
k8s-worker-01   Ready    <none>          3h18m   v1.29.10   10.40.101.184   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
k8s-worker-02   Ready    <none>          3h16m   v1.29.10   10.40.101.185   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
k8s-worker-03   Ready    <none>          3h16m   v1.29.10   10.40.101.186   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2        
```

- **제어면(Control Plane 3대)**: `v1.29.10` 승격 완료, etcd 클러스터 쿼럼 정상 유지.
- **워커 노드(Worker 3대)**: `v1.29.10` 승격 완료, 스케줄링 정상 복구(`Ready`).
- **네트워크 & 서비스 메시**: Cilium eBPF 에이전트 및 Istio Envoy 프록시 전 파드 에러 0건 정상 통신 확인.
