# 03-observability: Prometheus & Grafana & Google SRE Multi-Burn-Rate SLI/SLO

대규모 엔터프라이즈 트래픽 환경에서 단순 리소스 임계치 알람의 한계(Alert Fatigue)를 극복하고, 서비스 가용성(SLO 99.9%) 기반의 에러 예산(Error Budget) 번 레이트 관측 및 통합 관측성(Prometheus Operator + Grafana + Istio L7 / Cilium eBPF Telemetry)을 구축한 실전 운영 런북입니다.

---

## 1. 대규모 관측성 아키텍처 토폴로지 및 설계 개요

```plain text
[클러스터 노드 6대 (HostNetwork)]
    │
    ▼ (:9100 /proc, /sys 커널 지표)
[Node Exporter (DaemonSet 6/6)]
    │
[Cilium eBPF Agent (:9090)] ────┐
[Istio Envoy Proxies (:15090)] ──┼──> [Prometheus Server (TSDB 15d / 20GiB)]
[Istiod Control Plane (:15014)] ─┘         │
                                           ├──────> [Alertmanager]
                                           │           ├─ (14.4x / 6.0x) -> P1 긴급 호출 (Page)
                                           │           └─ (1.0x Burn)   -> P3 티켓 발행 (Ticket)
                                           │
                                           ▼
                                    [Grafana Dashboard]
                                    * USE Method (Node CPU/Mem/Disk/Net)
                                    * Istio Service Mesh L7 Telemetry
```

### SLI/SLO 알람 아키텍처 비교표
| 비교 항목 | 전통적인 임계치 알람 (CPU > 80%, Error > 1%) | Google SRE Multi-Window Multi-Burn-Rate (본 클러스터 채택) |
| :--- | :--- | :--- |
| **알람의 의미 (Signal)** | 단순한 리소스 사용률 (고객 영향도와 직결되지 않음) | **실제 사용자 경험(SLO 99.9%)의 침해 속도(Error Budget 소진율)**를 정확히 반영 |
| **양치기 소년 효과 (Alert Fatigue)** | 일시적 스파이크(1~2분 트래픽 증가)에도 야간 온콜이 호출되어 피로도 누적 | **긴 윈도우(1h)와 짧은 윈도우(5m)를 `and` 조건으로 동시 검증**하여 일시적 노이즈 100% 필터링 |
| **대형 장애 감지 속도** | 안티패턴 방지를 위해 `for: 30m` 등을 걸어두면 전면 장애 감지가 수십 분 지연됨 | 급격한 장애(14.4x 속도로 예산 소진) 시 **2분 이내 즉각 온콜 자동 호출** |
| **알람 심각도 분류** | 모든 알람이 슬랙 채널에 쏟아져 담당자가 무시하게 됨 | 소진 속도에 따라 **P1 Page(즉각 대응)**와 **P3 Ticket(업무 시간 내 조사)**으로 엄격히 2원화 |

---

## 2. Step 1: [검증 완료] kube-prometheus-stack 배포 (프로덕션 튜닝)

프로메테우스 오퍼레이터 기반으로 TSDB 보관 주기, 리소스 제한, 대시보드 자동 탐지 사이드카를 적용했습니다.

### 2-1. 프로덕션 `01-prometheus-stack-values.yaml` 핵심 설정
```yaml
prometheus:
  enabled: true
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    podMonitorSelector: {}
    ruleSelector: {}
    retention: 15d
    retentionSize: "20GiB"
    enableAdminAPI: true
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    securityContext:
      runAsUser: 1000
      runAsNonRoot: true
      fsGroup: 2000
grafana:
  enabled: true
  adminPassword: "<grafana-admin-password>"
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
    datasources:
      enabled: true
      defaultDatasourceEnabled: true
```

### 2-2. 트러블슈팅: Prometheus Operator CRD 정규식 검증
* **문제 상황**: 최초 배포 시 `retentionSize: "20Gi"`로 지정하여 배포했으나 아래 CRD 스키마 정규식 에러 발생:
  ```plain text
  Prometheus.monitoring.coreos.com "prometheus-stack-kube-prom-prometheus" is invalid: 
  spec.retentionSize: Invalid value: "20Gi": spec.retentionSize in body should match '(^0|([0-9]*[.])?[0-9]+((K|M|G|T|E|P)i?)?B)$'
  ```
* **해결 원리**: 쿠버네티스 리소스 단위(`20Gi`)와 달리, Prometheus Operator CRD는 반드시 끝에 **`B`**를 요구합니다. 이를 **`20GiB`**로 수정하여 검증을 통과했습니다.

### 2-3. 실제 파드 기동 검증 결과 (`k -n monitoring get pods -o wide`)
```plain text
NAME                                                     READY   STATUS    RESTARTS   AGE   IP              NODE            NOMINATED NODE   READINESS GATES
alertmanager-prometheus-stack-kube-prom-alertmanager-0   2/2     Running   0          4m    10.0.2.242      k8s-worker-03   <none>           <none>
prometheus-prometheus-stack-kube-prom-prometheus-0       2/2     Running   0          2m    10.0.5.150      k8s-worker-02   <none>           <none>
prometheus-stack-grafana-7dc68dc96d-k55gl                3/3     Running   0          5m    10.0.4.117      k8s-worker-01   <none>           <none>
prometheus-stack-kube-prom-operator-79b67567ff-wx8b4     1/1     Running   0          5m    10.0.4.243      k8s-worker-01   <none>           <none>
prometheus-stack-kube-state-metrics-578fc46776-sltzz     1/1     Running   0          5m    10.0.2.74       k8s-worker-03   <none>           <none>
prometheus-stack-prometheus-node-exporter-8m27m          1/1     Running   0          5m    10.40.101.182   k8s-cp-02       <none>           <none>
prometheus-stack-prometheus-node-exporter-ctfkp          1/1     Running   0          5m    10.40.101.184   k8s-worker-01   <none>           <none>
prometheus-stack-prometheus-node-exporter-gzw2h          1/1     Running   0          5m    10.40.101.186   k8s-worker-03   <none>           <none>
prometheus-stack-prometheus-node-exporter-l6sm5          1/1     Running   0          5m    10.40.101.185   k8s-worker-02   <none>           <none>
prometheus-stack-prometheus-node-exporter-qd5v5          1/1     Running   0          5m    10.40.101.183   k8s-cp-03       <none>           <none>
prometheus-stack-prometheus-node-exporter-sgthj          1/1     Running   0          5m    10.40.101.181   k8s-cp-01       <none>           <none>
```
> **검증 결과**: 11개 파드 전체(Prometheus Server, Alertmanager, Grafana, Operator, KSM, 6개 노드 Node Exporter)가 **`100% Running`**을 달성했습니다.

---

## 3. Step 2: [검증 완료] Istio Envoy L7 & Cilium eBPF 메트릭 연동

서비스 메시와 eBPF 네트워크 레이어의 내부 지표를 프로메테우스가 자동 발견하여 수집할 수 있도록 모니터링 CRD를 배포했습니다.

### 3-1. 핵심 매니페스트 구성 (`02-mesh-and-ebpf-monitoring.yaml`)
* **`PodMonitor/envoy-stats`**: `istio: *` 라벨이 붙은 모든 파드의 15090 포트(`/stats/prometheus`)에서 L7 응답 코드, 지속 시간, P99 레이턴시 스크랩.
* **`ServiceMonitor/istiod-monitor`**: `istio-system` 제어면의 15014 포트에서 xDS 푸시 지연, 파일럿 동기화 실패율 수집.
* **`ServiceMonitor/cilium-agent-monitor`**: 커널 eBPF 패킷 드롭 및 소켓 맵 가속 지표 수집.

### 3-2. 실제 적용 명령어
```powershell
k apply -f .\02-observability\02-mesh-and-ebpf-monitoring.yaml
```
```plain text
podmonitor.monitoring.coreos.com/envoy-stats created
servicemonitor.monitoring.coreos.com/istiod-monitor created
servicemonitor.monitoring.coreos.com/cilium-agent-monitor created
```

---

## 4. Step 3: [검증 완료] Google SRE 표준 Multi-Window Multi-Burn-Rate SLI/SLO 알람 룰 배포

엔터프라이즈 메인 서비스인 `chat-service`(목표 가용성 99.9%, 월간 에러 예산 0.1%)의 에러 예산 소진율을 2중 윈도우로 계산하는 프로덕션 알람 룰을 배포했습니다.

### 4-1. 번 레이트(Burn Rate) 수학적 모델
* 30일(720시간) 동안 0.1%의 에러 예산을 100% 소진하는 정상적인 소비 속도를 **Burn Rate = 1.0x**로 정의합니다.
* **Burn Rate 14.4x**: 720시간 동안 쓸 예산을 50시간(약 2일) 만에 다 쓰는 속도 -> **1시간 만에 전체 예산의 2%를 탕진**.
* **Burn Rate 6.0x**: **6시간 만에 전체 예산의 5%를 탕진**.

### 4-2. 실제 적용된 `PrometheusRule` 매니페스트 (`03-slo-multi-burn-rate-alerting.yaml`)
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: chat-service-slo-alerts
  namespace: monitoring
  labels:
    role: alert-rules
    release: prometheus-stack
spec:
  groups:
    - name: chat-service-slo-burn-rate
      rules:
        # [Critical Page] 1시간 동안 예산의 2% 소진 (14.4x)
        - alert: ChatServiceHighErrorBudgetBurnRateFast
          expr: |
            (
              sum(rate(istio_requests_total{reporter="destination", destination_workload="chat-service-v1", response_code=~"5.*"}[1h]))
              /
              sum(rate(istio_requests_total{reporter="destination", destination_workload="chat-service-v1"}[1h]))
              > (14.4 * 0.001)
            )
            and
            (
              sum(rate(istio_requests_total{reporter="destination", destination_workload="chat-service-v1", response_code=~"5.*"}[5m]))
              /
              sum(rate(istio_requests_total{reporter="destination", destination_workload="chat-service-v1"}[5m]))
              > (14.4 * 0.001)
            )
          for: 2m
          labels:
            severity: critical
            tier: p1
            service: chat-service
          annotations:
            summary: "[Critical] Chat Service Error Budget 급속 소진 중 (Burn Rate 14.4x)"
            description: "1시간 만에 30일 치 에러 예산의 2%가 소진되었습니다. 즉시 온콜을 호출합니다."
```

---

## 5. Step 4: [검증 완료] Grafana 대시보드 & 프로메테우스 실시간 지표 관측

Bastion에서 포트포워딩을 통해 Grafana 및 Prometheus에 접속하여 메트릭 수집 파이프라인을 실측 검증했습니다.

### 5-1. 실제 수집 및 대시보드 렌더링 화면
![Grafana Node Exporter USE Method & Prometheus Targets Health](https://iili.io/nk8wYgV.png)

### 5-2. 화면 실측 분석 결과
1. **좌측 Grafana (`Node Exporter / USE Method / Cluster`)**:
   - 6대 노드 전체(`k8s-cp-01~03`, `k8s-worker-01~03`)의 **CPU Utilisation**, **CPU Saturation (Load1 per CPU)**, **Memory Utilisation**, **Network Utilisation (Bytes/sec)** 지표가 멀티 노드 영역 차트로 실시간 수집 및 시각화됨을 확인.
2. **우측 Prometheus (`http://localhost:9090/targets`)**:
   - **`podMonitor/monitoring/envoy-stats/0`**: Envoy 사이드카 15090 포트가 **`State: UP` (1/1 up)**으로 정상 수집 중.
   - **`serviceMonitor/monitoring/istiod-monitor/0`**: Istiod 15014 포트가 **`State: UP` (1/1 up)**으로 정상 수집 중.
   - **`serviceMonitor/monitoring/prometheus-stack-grafana/0`**: Grafana 내부 메트릭 3000 포트가 **`State: UP` (1/1 up)**으로 정상 수집 중.

