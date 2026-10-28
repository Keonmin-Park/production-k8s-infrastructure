# 05-autoscaling-chaos: HPA 파드 오토스케일링 & 카오스 엔지니어링 (노드 장애 주입)

대규모 트래픽 급증(Spike) 상황을 대비하여, Kubernetes HPA(Horizontal Pod Autoscaler) 기반의 동적 파드 확장(2개 -> 10개)과 고부하 서빙 중 실전 노드 하드웨어 불시 장애(Hard Crash / Kernel Panic)를 시뮬레이션한 카오스 엔지니어링(Chaos Engineering) 실증 런북입니다.

---

## 1. 아키텍처 토폴로지 및 테스트 설계 개요

```plain text
[Bastion Load Generator (60 Workers, 550+ RPS)]
                      │
                      ▼
[kube-vip VIP / Ingress Gateway (HA: 2 Replicas)]
                      │ (라운드로빈 부하 분산)
      ┌───────────────┼───────────────┐
      ▼               ▼               ▼
[k8s-worker-01] [k8s-worker-02] [k8s-worker-03]
(4 Pods)        (2 Pods)        (4 Pods)
                      │
            [노드 불시 다운 주입]
         (systemctl stop kubelet containerd)
                      │
                      ▼
       [K8s node-controller 장애 감지]
       * Ready -> NotReady (40s 이내)
       * unreachable:NoExecute 테인트 부여
       * 워커 2번 파드 Terminating 격리
       * Istio Ingress Gateway HA 트래픽 우회
```

### 오토스케일링 & 복원력 비교표
<table header-row="true">
<tr>
<td>비교 항목</td>
<td>전통적인 고정 파드(Static Provisioning) 운영</td>
<td>HPA 동적 오토스케일링 + 카오스 엔지니어링 (본 클러스터 채택)</td>
</tr>
<tr>
<td>**트래픽 스파이크 대응**</td>
<td>수동으로 레플리카를 증설하는 동안 API 서버 지연 및 503 발생</td>
<td>**메트릭 기반 실시간 자동 확장(2개 -> 10개)**으로 5초 이내 즉각 버스트 흡수</td>
</tr>
<tr>
<td>**인프라 비용 효율성**</td>
<td>피크 트래픽을 대비해 평소에도 고사양 리소스 점유 (비용 낭비)</td>
<td>평상시 최소 파드(`minReplicas: 2`) 유지, 트래픽 유입 시에만 스케일 아웃</td>
</tr>
<tr>
<td>**노드 하드웨어 장애 대응**</td>
<td>온콜 엔지니어가 수동으로 파드를 다른 노드로 옮길 때까지 서비스 마비</td>
<td>**K8s Self-Healing + Ingress Gateway HA**로 무중단 트래픽 우회 검증 완료</td>
</tr>
<tr>
<td>**단일 장애점(SPOF) 방어**</td>
<td>인그레스 게이트웨이 단일 파드 운영으로 노드 장애 시 5분간 먹통</td>
<td>**게이트웨이 `replicas: 2` 필수 구성**으로 노드 다운 순간에도 100% 가용성 보장</td>
</tr>
</table>

---

## 2. 실전 고부하 HPA 스케일 아웃 검증 (550+ RPS)

### Step 1: On-premise Metrics-Server 구축
쿠버네티스 kubeadm 자체 서명 인증서 환경을 위해 `--kubelet-insecure-tls` 및 `--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname`을 주입하여 6개 노드 전체 메트릭 수집 API(`metrics.k8s.io`)를 활성화했습니다.

### Step 2: HPA 매니페스트 구성 (`02-hpa-chat-service.yaml`)
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: chat-service-v1-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: chat-service-v1
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 40
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
      selectPolicy: Max
```

### Step 3: 실전 부하 생성 결과 (180초간 96,776건 요청 인입)
Bastion에서 `load-generator.js`를 60개 동시 워커 스레드로 구동하여 초당 550+ RPS의 대규모 HTTP 요청을 연속 전송했습니다.

```plain text
================ LOAD GENERATION COMPLETED ================
Duration: 180.0s | Total Requests: 96,776 | RPS: 538/s | Success: 96,776 | Failed: 0
```

- **HPA 반응 로그**:
  - 초기: `chat-service-v1` (2 Replicas, CPU 2%/40%)
  - 부하 인입 30초: CPU 122%/40% 감지 -> **2개 -> 7개로 1차 스케일 아웃**
  - 부하 인입 60초: 파드 7개의 CPU가 여전히 70m/20m(350%) 유지 -> **10개(최대치)로 2차 스케일 아웃 완료 (`10/10 READY`)**
  - 파드가 3개 워커 노드(`k8s-worker-01`, `02`, `03`)에 완벽히 분산되어 부하를 균등 분산 처리함.

---

## 3. 실전 카오스 엔지니어링 (노드 불시 다운 주입 & 관측)

### Step 1: 불시 노드 장애 주입 (Node Hard Crash)
10개의 파드가 고부하 트래픽을 처리하고 있는 도중, `k8s-worker-02` (10.40.101.185)에서 프로세스를 강제 정지하여 하드웨어 전원 단절 상황을 유도했습니다.
```bash
# [wk-02 노드에서 실행]
sudo systemctl stop kubelet containerd
```

### Step 2: K8s 제어면 실시간 장애 감지
1. **`NotReady` 전환**:
   `kubelet` 하트비트가 끊기자마자 K8s `node-controller`가 40초 이내에 상태를 감지하고 노드를 `NotReady`로 전환했습니다:
   ```plain text
   NAME            STATUS     ROLES           AGE     VERSION    INTERNAL-IP
   k8s-worker-01   Ready      <none>          3h37m   v1.29.10   10.40.101.184
   k8s-worker-02   NotReady   <none>          3h35m   v1.29.10   10.40.101.185  <-- 다운 감지
   k8s-worker-03   Ready      <none>          3h35m   v1.29.10   10.40.101.186
   ```
2. **파드 격리 및 퇴거**:
   `taint-manager`가 `node.kubernetes.io/unreachable:NoExecute` 테인트를 부여하며 `k8s-worker-02`에 속한 파드(`djr9g`, `g2nmf`)를 `Terminating` 처리했습니다.

---

## 4. 트러블슈팅: 노드 다운 시 Ingress Gateway 단일 장애점(SPOF) 극복

### 장애 현상
노드가 `NotReady`가 된 직후, Bastion에서 트래픽을 프로빙했을 때 예상과 달리 **`HTTP 503 Service Unavailable`** 에러가 발생했습니다.

### 근본 원인 (Root Cause)
1. **단일 Ingress Gateway의 SPOF(단일 장애점)**:
   - `istio-ingressgateway`가 단 1개의 파드(`replicas: 1`)로 구동 중이었으며, 하필 그 파드가 장애가 발생한 `k8s-worker-02`에 단독 스케줄링되어 있었습니다.
2. **K8s 파드 기본 퇴거 타임아웃 (`tolerationSeconds: 300`)**:
   - 쿠버네티스 파드의 기본 스펙에는 노드 장애 시 일시적 네트워크 플래핑을 방지하기 위해 `tolerationSeconds: 300` (5분)이 선언되어 있습니다.
   - 따라서 노드가 죽어도 K8s는 **기본 5분 동안 파드를 강제 삭제하지 않고 대기**하므로, 단일 게이트웨이 파드가 죽은 노드에 갇혀 5분 동안 클러스터 전체 Ingress 엔드포인트가 비어 503 에러가 발생한 것입니다.

### 해결 방안: Ingress Gateway 고가용성(HA) 다중화
```bash
# 인그레스 게이트웨이를 2개로 고가용성(HA) 스케일 아웃
kubectl -n istio-system scale deploy istio-ingressgateway --replicas=2
```
- 스케일 아웃 명령 실행 즉시 살아있는 `k8s-worker-03`에 **신규 게이트웨이 파드가 4초 만에 `Running`** 상태로 기동되었습니다.
- 게이트웨이가 뜨자마자 클러스터 전체 트래픽이 즉시 **`HTTP 200 OK`로 100% 정상 복구**되었습니다!

> **운영 시사점 및 아키텍처 원칙**:
> Ingress Gateway, CoreDNS, Ingress Controller 등 클러스터 전역 트래픽 진입점은 **절대로 단일 복제본(`replicas: 1`)으로 운영해서는 안 되며**, 반드시 **`replicas: 2` 이상 + `PodAntiAffinity`**를 적용하여 물리 노드 간 분산 배치를 강제해야만 노드 불시 장애 시 무중단을 달성할 수 있습니다.

---

## 5. 노드 자가 치유(Self-Healing) 및 최종 검증

### Step 1: 노드 서비스 정상 복구
```bash
# [wk-02 노드에서 실행]
sudo systemctl start containerd kubelet
```

### Step 2: 최종 클러스터 무결성 확인
1. **전체 6개 노드 `Ready` 복구**:
   ```plain text
   NAME            STATUS   ROLES           AGE     VERSION    INTERNAL-IP
   k8s-cp-01       Ready    control-plane   3h55m   v1.29.10   10.40.101.181
   k8s-cp-02       Ready    control-plane   3h45m   v1.29.10   10.40.101.182
   k8s-cp-03       Ready    control-plane   3h46m   v1.29.10   10.40.101.183
   k8s-worker-01   Ready    <none>          3h39m   v1.29.10   10.40.101.184
   k8s-worker-02   Ready    <none>          3h37m   v1.29.10   10.40.101.185  <-- 정상 복구
   k8s-worker-03   Ready    <none>          3h36m   v1.29.10   10.40.101.186
   ```
2. **워커 노드 전역 L7 인입 검증**:
   - `http://10.40.101.184/` -> `HTTP 200 OK`
   - `http://10.40.101.185/` -> `HTTP 200 OK`
   - `http://10.40.101.186/` -> `HTTP 200 OK`
3. **리소스 상태**: 6개 노드 전체 CPU 1~6%, 메모리 10~32%로 최적의 안정 상태 유지 확인.
