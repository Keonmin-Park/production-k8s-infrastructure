# [별첨] SRE Bastion Workstation 구축 런북: Windows 로컬 PC 연동 & Multi-Cluster 무손실 병합

프로덕션 클러스터 운영 시 보안, 감사(Audit), 장애 격리 관점에서 엔지니어가 마스터 노드에 직접 SSH로 접속하여 작업하는 것은 엄격히 금지된 안티패턴입니다.  
본 문서는 엔지니어의 로컬 PC(Windows)를 전용 **SRE Bastion Workstation**으로 구성하고, 기존 사내 업무용 클러스터(Enterprise OpenShift)와의 충돌 없이 **HA Control Plane VIP(`10.40.101.180:6443`)**를 안전하게 원격 제어할 수 있도록 구축한 실전 런북입니다.

---

## 1. 마스터 노드 격리 및 Bastion 원격 제어 배경

| 비교 항목 | 마스터 노드 직접 SSH 접속 | Bastion 원격 제어 (권장) |
| :--- | :--- | :--- |
| **보안 및 망 분리** | 제어면 노드가 외부/개발망에 직접 노출되어 침해 위험 급증 | 제어면 노드는 사설망(Private Subnet)에 100% 격리, API Server(6443)만 노출 |
| **감사 추적 (Audit Trail)** | 로컬 `kadmin` 단일 계정으로 실행되어 엔지니어별 행위 추적 불가 | 개별 엔지니어 인증서/OIDC 토큰으로 실행되어 API Server 감사 로그에 전수 기록 |
| **제어면 안정성** | 대용량 YAML 적용 및 로컬 스크립트 실행 시 etcd/API Server 자원 고갈 위험 | 클러스터 밖의 독립 컴퓨팅 자원(Bastion)에서 연산 수행, 제어면 영향도 0% |
| **멀티 클러스터 제어** | 클러스터마다 SSH 세션을 별도로 열어 작업하므로 운영 피로도 및 실수 유발 | 단일 워크스테이션에서 Context 전환만으로 On-Premise, OpenShift, EKS 통합 통제 |

---

## 2. Step 1: Bastion SRE Toolchain 셋업 (Windows Host)

Windows 호스트 머신에서 쿠버네티스 생태계 표준 CLI 도구 체계를 일관되게 사용할 수 있도록 구축했습니다.

### 2-1. 핵심 CLI 바이너리 설치
* **`kubectl.exe` (v1.28.15)**: 클러스터 서버 버전(`v1.28.15`)과 100% 마이너 버전 일치 (Skew 정책 준수)
* **`helm.exe` (v3.14.4)**: 패키지 매니저 설치 (`haproxy-ingress`, `cilium` 배포용)
* **`istioctl.exe` (v1.21.2)**: Istio 서비스 메시 제어 도구 설치
* **설치 경로**: `C:\Work\bin` 및 `AppData\Roaming\npm`에 등록하여 전역 PATH 적용

### 2-2. PowerShell 단축어(`k`) 영구 등록
Linux bash의 `alias k=kubectl`과 달리, Windows PowerShell에서 `alias`는 `Get-Alias`(조회 전용) 명령어입니다. 또한 `Set-Alias`는 서브 인자(`$args`)를 온전히 포워딩하지 못하므로, **함수(`function`)로 프로필(`$PROFILE`)에 등록하는 것이 표준**입니다.

```powershell
# 1) PowerShell 프로필 파일 생성 및 k 단축 함수 등록
if (!(Test-Path $PROFILE)) { New-Item -Type File -Path $PROFILE -Force }
Add-Content $PROFILE "`nfunction k { kubectl `$args }"

# 2) 현재 세션 즉시 적용 및 버전 검증
function k { kubectl $args }
k version --client
```

---

## 3. Step 2: 마스터 노드 Kubeconfig 무결성 전송 (`scp`)

### 트러블슈팅 사례: 터미널 텍스트 복사-붙여넣기 시 RSA 개인키 손상
* **문제 현상**: `cp-01` 터미널에서 `cat ~/.kube/config`로 출력된 텍스트를 복사하여 Windows에 저장한 후 `kubectl` 실행 시 `error: tls: failed to parse private key` 에러 발생.
* **근본 원인**: 터미널 콘솔의 가로폭 줄바꿈(Word Wrap) 및 폰트 합자/특수문자 처리 과정에서 Base64 문자열 일부가 왜곡(예: `NAHJ`가 `N@ J`로 치환)되어 RSA Private Key의 ASN.1 DER 구조가 깨짐.
* **해결책**: 터미널 클립보드를 거치지 않고 OpenSSH scp 명령어를 사용하여 파일을 온전히 전송함.

```powershell
# Windows Bastion 터미널에서 실행
scp kadmin@10.40.101.181:~/.kube/config $env:USERPROFILE\.kube\core-cluster.yaml
```

---

## 4. Step 3: 사내 기존 업무 환경(사내 업무용 OpenShift) 무손실 병합

현재 엔지니어 PC의 `~/.kube/config`에는 사내 중요 업무용 클러스터인 **기존 업무용 OpenShift(`api.internal.company.net:6443`)** 환경이 등록되어 있었습니다. 기존 업무 환경을 절대 덮어써서 날리지 않고 두 클러스터를 공존시키는 무손실 병합을 적용했습니다.

### 4-1. 다중 클러스터 병합 스크립트 (`merge_kubeconfig.ps1`)
```powershell
$mainConfigPath = "$env:USERPROFILE\.kube\config"
$backupConfigPath = "$env:USERPROFILE\.kube\config.bak"
$coreClusterPath = "$env:USERPROFILE\.kube\core-cluster.yaml"

# 1) 원본 순정 설정 백업
Copy-Item $mainConfigPath $backupConfigPath -Force

# 2) KUBECONFIG 환경 변수를 활용한 플랫 병합 (Flatten Merge)
$env:KUBECONFIG = "$mainConfigPath;$coreClusterPath"
$merged = kubectl config view --flatten
Set-Content -Path $mainConfigPath -Value $merged -Encoding UTF8
$env:KUBECONFIG = $null

# 3) 온프레미스 K8s 클러스터 컨텍스트로 전환
kubectl config use-context kubernetes-admin@core-cluster
```

### 4-2. 컨텍스트 전환(Context Switching) 자유 스위칭 검증
```powershell
# 기존 업무용 OpenShift 클러스터로 전환
kubectl config use-context default/api-internal-company-net:6443/developer

# 온프레미스 HA 클러스터로 복귀
kubectl config use-context kubernetes-admin@core-cluster
```

---

## 5. Step 4: [검증 완료] Windows Bastion에서 Control Plane VIP 원격 제어

Windows 로컬 머신에서 가상 IP인 **`10.40.101.180:6443`(kube-vip)**를 호출하여 클러스터의 모든 6개 노드 및 시스템 파드가 완벽히 제어됨을 확인했습니다.

### 5-1. 클러스터 6개 노드 조회 (`k get nodes -o wide`)
```plain text
PS C:\Work> k get nodes -o wide
NAME            STATUS   ROLES           AGE   VERSION    INTERNAL-IP     EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION       CONTAINER-RUNTIME
k8s-cp-01       Ready    control-plane   42m   v1.28.15   10.40.101.181   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-cp-02       Ready    control-plane   32m   v1.28.15   10.40.101.182   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-cp-03       Ready    control-plane   33m   v1.28.15   10.40.101.183   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-01   Ready    <none>          26m   v1.28.15   10.40.101.184   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-02   Ready    <none>          24m   v1.28.15   10.40.101.185   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
k8s-worker-03   Ready    <none>          24m   v1.28.15   10.40.101.186   <none>        Ubuntu 22.04.5 LTS   5.15.0-198-generic   containerd://2.4.2
```

### 5-2. 전체 시스템 네임스페이스 파드 상태 (`k get pods -A`)
```plain text
PS C:\Work> k get pods -A
NAMESPACE     NAME                                READY   STATUS    RESTARTS      AGE
kube-system   cilium-brrsk                        1/1     Running   0             22m
kube-system   cilium-bx782                        1/1     Running   0             22m
kube-system   cilium-g6km5                        1/1     Running   0             22m
kube-system   cilium-lwpdc                        1/1     Running   0             22m
kube-system   cilium-operator-5df9cc4f7d-7sd9n    1/1     Running   0             22m
kube-system   cilium-operator-5df9cc4f7d-trmk9    1/1     Running   0             22m
kube-system   cilium-pjvg4                        1/1     Running   0             22m
kube-system   cilium-zbnll                        1/1     Running   0             22m
kube-system   coredns-5dd5756b68-bjttq            1/1     Running   0             42m
kube-system   coredns-5dd5756b68-f8xls            1/1     Running   0             42m
kube-system   etcd-k8s-cp-01                      1/1     Running   0             42m
kube-system   etcd-k8s-cp-02                      1/1     Running   0             32m
kube-system   etcd-k8s-cp-03                      1/1     Running   0             33m
kube-system   hubble-relay-7897c9d75b-lgfgj       1/1     Running   0             22m
kube-system   hubble-ui-6548d56557-2d79v          2/2     Running   0             22m
kube-system   kube-apiserver-k8s-cp-01            1/1     Running   0             42m
kube-system   kube-apiserver-k8s-cp-02            1/1     Running   0             32m
kube-system   kube-apiserver-k8s-cp-03            1/1     Running   0             33m
kube-system   kube-controller-manager-k8s-cp-01   1/1     Running   0             42m
kube-system   kube-controller-manager-k8s-cp-02   1/1     Running   0             32m
kube-system   kube-controller-manager-k8s-cp-03   1/1     Running   0             33m
kube-system   kube-scheduler-k8s-cp-01            1/1     Running   0             42m
kube-system   kube-scheduler-k8s-cp-02            1/1     Running   0             32m
kube-system   kube-scheduler-k8s-cp-03            1/1     Running   0             33m
kube-system   kube-vip-k8s-cp-01                  1/1     Running   1 (33m ago)   42m
kube-system   kube-vip-k8s-cp-02                  1/1     Running   0             32m
kube-system   kube-vip-k8s-cp-03                  1/1     Running   0             33m
```
> **검증 성공**: Windows 로컬 PC가 정식 Bastion 워크스테이션으로 등록되어, 향후 모든 매니페스트 배포, Helm 릴리즈, 카나리 트래픽 분기 실습을 로컬에서 직접 제어할 수 있습니다.

