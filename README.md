# Production Kubernetes Infrastructure: Vanilla K8s HA 클러스터 구축 및 대규모 트래픽·복원력 실증

> **참고:** 본 저장소는 SRE 엔지니어링 실증 및 아키텍처 검증을 위해 구축한 독립 랩 환경입니다.

OpenShift 환경 운영 경험을 바탕으로, 상위 플랫폼 추상화(CVO, Machine Config 등)에 가려져 있던 **Kubernetes 코어 동작 원리(Vanilla K8s)를 검증하기 위해 vSphere 온프레미스 환경에 구축한 고가용성(HA 6노드) 클러스터 및 엔지니어링 실증 저장소**입니다.

---

## 프로젝트 엔지니어링 배경 (Background & Motivation)
- **OpenShift ➔ Vanilla K8s 코어 확장**: 플랫폼 자동화 영역이었던 제어면 고가용성(`kube-vip`), 커널 레벨 네트워크(`Cilium eBPF`), 서비스 메시(`Istio`), 인그레스(`HAProxy`)를 베어메탈/VM 레벨부터 직접 설계·구축하여 K8s 원천 기술 내재화.
- **대규모 트래픽 아키텍처 실증**: L7 프록시 체인(`HAProxy Ingress` ➔ `Istio Ingress Gateway` ➔ `Envoy Sidecar`)에서 지연 시간을 최소화하고 클라이언트 원본 IP를 보존하기 위해 `PROXY Protocol v2` 및 `Cilium eBPF Sockops` 가속 검증.
- **무중단 운영(Zero-Downtime) & 복원력(Resilience)**: `PodDisruptionBudget`과 `preStop(10s)` 훅을 적용하여 실시간 트래픽 서빙 중 v1.28 ➔ v1.29 무중단 롤링 업그레이드(7,160건 검증, 가용성 99.986%) 및 HPA 부하 스케일링, 워커 노드 불시 장애(Hard Crash) 카오스 엔지니어링 완수.

---

## 디렉토리 구조 및 실습 구성

```text
production-k8s-infrastructure/
├── 00-cluster-setup/          # [모듈 0] Ubuntu 22.04 HA K8s 클러스터 부트스트랩 (kube-vip + containerd + Cilium eBPF)
├── 01-traffic-architecture/   # [모듈 1] HAProxy Ingress(PROXY v2) + Istio Service Mesh(STRICT mTLS, eBPF Sockops)
├── 02-observability/          # [모듈 2] Prometheus Operator + Grafana + Multi-Window Multi-Burn-Rate SLI/SLO
├── 03-cluster-upgrade/        # [모듈 3] PDB / Graceful Shutdown(10s) 기반 v1.28 -> v1.29 무중단 롤링 업그레이드
├── 04-autoscaling-chaos/      # [모듈 4] Metrics-Server + HPA 초당 550+ RPS 오토스케일링 & 노드 불시 다운 카오스 실증
├── docs/                      # [엔터프라이즈 운영 런북 모음]
│   ├── 01-CLUSTER_INIT_RUNBOOK.md      # 클러스터 부트스트랩 & kube-vip L2 ARP & Cilium eBPF
│   ├── 02-TRAFFIC_RUNBOOK.md           # 대규모 트래픽 아키텍처(PROXY v2) & Istio 서비스 메시
│   ├── 03-OBSERVABILITY_RUNBOOK.md     # 통합 관측성 & Google SRE Multi-Burn-Rate SLI/SLO
│   ├── 04-UPGRADE_RUNBOOK.md           # v1.28 -> v1.29 무중단 롤링 업그레이드 및 프로브 실증
│   └── 05-AUTOSCALING_CHAOS_RUNBOOK.md # HPA 부하 스케일링 & 노드 장애 SPOF 트러블슈팅
├── cluster.env.example        # 클러스터 고정 IP / VIP / CIDR 환경 변수 템플릿
├── setup-env.sh               # 환경 변수 등록 및 YAML 매니페스트 렌더링 스크립트
└── README.md                  # 저장소 개요 및 아키텍처 마스터 문서
```

---

## 클러스터 인프라 사양 (On-Premise HA Lab)
- **OS**: Ubuntu 22.04.5 LTS (Kernel 5.15.0-198-generic)
- **Architecture**: Multi-Control Plane (HA: 3대) + Multi-Worker (3대) = 총 6대 노드
- **Container Runtime**: containerd 1.7.22 (cgroup v2, `SystemdCgroup = true`)
- **K8s Version**: v1.29.10 (v1.28.15에서 7,160건 무중단 라이브 트래픽 서빙 중 승격 완료)
- **CNI**: Cilium eBPF v1.15.5 (`kubeProxyReplacement: "true"`, `sockops` 가속)
- **Control Plane VIP**: kube-vip L2 ARP 모드 (`192.168.100.180:6443`)
- **Ingress & Service Mesh**: HAProxy Ingress (`PROXY Protocol v2`) + Istio v1.21.2 (`STRICT mTLS`)
- **Observability**: kube-prometheus-stack + Grafana + Multi-Burn-Rate Alerting
- **Autoscaling & Resilience**: Metrics-Server + HPA v2 + PodDisruptionBudget (PDB)

---

## 환경 변수 등록 및 매니페스트 실행 가이드

본 저장소의 모든 설정 파일은 인프라 정보(VIP, 노드 IP, 비밀번호 등)를 하드코딩하지 않고 환경 변수로 템플릿화되어 있습니다.

```bash
# 1) 환경 변수 파일 복사 및 환경에 맞게 수정
cp cluster.env.example cluster.env
vim cluster.env

# 2) 현재 쉘 세션에 변수 로드
source ./setup-env.sh

# 3) 템플릿 YAML 매니페스트 일괄 렌더링
./setup-env.sh --render

# 4) 클러스터 초기화 진행
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
```
