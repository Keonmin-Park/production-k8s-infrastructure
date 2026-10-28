# Production Kubernetes Infrastructure: OpenShift 엔지니어의 Vanilla K8s HA 클러스터 구축 및 대규모 트래픽 실증

> 💡 **본 저장소는 개인 SRE 엔지니어링 실증 연구를 위해 구축한 독립 랩 환경입니다.**

기존 Red Hat OpenShift 환경을 운영하던 인프라 엔지니어가, 상위 플랫폼 추상화(CVO, OpenShift Router, Machine Config 등)에 가려져 있던 쿠버네티스 원천 기술(Vanilla K8s)의 코어 동작 원리를 깊이 있게 이해하고 검증하기 위해 vSphere 온프레미스 베이스 노드(6대)에 직접 구축한 고가용성(HA) 클러스터 및 실전 엔지니어링 실증 프로젝트입니다.

---

## 💡 프로젝트 엔지니어링 배경 (Persona & Motivation)
- **OpenShift ➡️ Vanilla K8s 코어 확장**: 플랫폼이 자동화해 주던 제어면 고가용성(kube-vip), 커널 레벨 네트워크(Cilium eBPF), 서비스 메시(Istio), 슬림한 Ingress(HAProxy)를 밑바닥(Bare-Metal/VM)부터 직접 구성하여 K8s 원천 기술 내재화.
- **대규모 트래픽 아키텍처 실증**: 초당 수백 회 이상의 버스트 트래픽 인입 상황에서 L7 프록시 체인(HAProxy Ingress ➡️ Istio Ingress Gateway ➡️ Envoy Sidecar)의 지연 시간을 최소화하고 원본 IP를 보존하는 PROXY Protocol v2 및 Cilium eBPF Sockops 가속 검증.
- **무중단 운영(Zero-Downtime) & 복원력(Resilience)**: PDB(PodDisruptionBudget)와 PreStop(10s) 훅을 적용한 라이브 트래픽 서빙 중 무중단 롤링 업그레이드(7,160건 검증, 99.986% 가용성) 및 HPA 550+ RPS 스케일 아웃과 노드 불시 다운 카오스 엔지니어링(Chaos Engineering) 완수.

---

## 📁 디렉토리 구조 및 실습 로드맵

```text
production-k8s-infrastructure/
├── 00-cluster-setup/          # [모듈 0] vSphere Ubuntu 22.04 HA K8s 클러스터 설치 (kube-vip + containerd + Cilium eBPF)
├── 01-traffic-architecture/   # [모듈 1] HAProxy Ingress(PROXY v2) + Istio Service Mesh(STRICT mTLS, eBPF Sockops)
├── 02-observability/          # [모듈 2] 대용량 Prometheus Operator + Grafana + Multi-Window Multi-Burn-Rate SLI/SLO
├── 03-cluster-upgrade/        # [모듈 3] PDB / Graceful Shutdown(10s) 기반 v1.28 -> v1.29 무중단 롤링 업그레이드
├── 04-autoscaling-chaos/      # [모듈 4] Metrics-Server + HPA 초당 550+ RPS 오토스케일링 & 노드 불시 다운 카오스 실증
├── docs/                      # 📖 [엔터프라이즈 공식 운영 런북 모음]
│   ├── 01-CLUSTER_INIT_RUNBOOK.md      # 클러스터 부트스트랩 & kube-vip HA
│   ├── 02-TRAFFIC_RUNBOOK.md           # 대규모 트래픽 아키텍처 & 서비스 메시
│   ├── 03-OBSERVABILITY_RUNBOOK.md     # 통합 관측성 & Google SRE SLI/SLO
│   ├── 04-UPGRADE_RUNBOOK.md           # v1.28 -> v1.29 무중단 롤링 업그레이드
│   ├── 05-AUTOSCALING_CHAOS_RUNBOOK.md # HPA 부하 스케일링 & 카오스 엔지니어링
├── tools/                     # SRE Bastion 워크스테이션 환경 설정 및 자동화 도구
│   └── bastion/
├── cluster.env.example        # 클러스터 고정 IP / VIP / CIDR 환경 변수 템플릿
├── setup-env.sh               # 원클릭 환경 변수 등록 및 YAML 매니페스트 렌더링 스크립트
└── README.md                  # 저장소 개요 및 아키텍처 마스터 문서
```

---

## 🛠️ 클러스터 인프라 사양 (vSphere On-Prem)
- **OS**: Ubuntu 22.04.5 LTS (Kernel 5.15.0-198-generic)
- **Architecture**: Multi-Control Plane (HA: 3대) + Multi-Worker (3대) = 총 6대 노드
- **Container Runtime**: containerd 2.4.2 (cgroup v2, `SystemdCgroup = true`)
- **K8s Version**: v1.29.10 (v1.28.15에서 7,160건 무중단 라이브 트래픽 서빙 중 승격 완료)
- **CNI**: Cilium eBPF v1.16.2 (`kube-proxy-replacement: "true"`, Sockops 가속)
- **Control Plane VIP**: kube-vip L2 ARP 모드 (10.40.101.180:6443)
- **Ingress & Service Mesh**: HAProxy Ingress (PROXY v2) + Istio v1.22.4 (STRICT mTLS)
- **Observability**: kube-prometheus-stack + Grafana + Multi-Burn-Rate Alerting
- **Autoscaling & Resilience**: Metrics-Server + HPA v2 + PodDisruptionBudget (PDB)

---

## ⚡ 빠른 환경 변수 등록 및 매니페스트 실행 가이드

본 저장소의 모든 설정 파일은 민감한 인프라 정보(실제 VIP, IP, 비밀번호 등)를 하드코딩하지 않고 환경 변수로 템플릿화되어 있습니다. 서버 구축 시 한 번의 스크립트 실행으로 환경 변수를 등록하고 즉시 프로비저닝을 진행할 수 있습니다.

```bash
# 1) 환경 변수 파일 복사 및 환경에 맞게 수정
cp cluster.env.example cluster.env
vim cluster.env

# 2) 현재 쉘 세션에 변수 로드 (또는 서버 전체 영구 등록)
source ./setup-env.sh
# 또는 서버 전체 영구 등록 (/etc/profile.d/k8s-cluster-env.sh)
sudo ./setup-env.sh --register

# 3) 템플릿 YAML 매니페스트 일괄 렌더링
./setup-env.sh --render

# 4) 클러스터 초기화 바로 진행
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
```
