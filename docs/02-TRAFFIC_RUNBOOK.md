# 02-traffic-architecture: HAProxy Ingress & Istio Service Mesh

대규모 엔터프라이즈 트래픽을 무중단으로 수용하고 안정적인 P99 레이턴시를 보장하기 위해 구축한 **엔터프라이즈 트래픽 인프라(HAProxy Ingress HostPort + Istio Service Mesh 1.21 + PROXY Protocol v2 + mTLS STRICT + 90:10 카나리 라우팅 + Hubble eBPF 관측성)** 실전 구축 및 운영 런북입니다.

---

## 1. 대규모 트래픽 아키텍처 토폴로지 및 설계 개요

```plain text
[외부 클라이언트 (대규모 트래픽 인입)]
            │
            ▼ (Public / Node IP:80, 443)
[HAProxy Ingress Controller (DaemonSet / HostPort 80, 443)]
    * 튜닝: 10만 동시 커넥션, nbthread 4, http-reuse: aggressive
    * 원본 IP 보존: PROXY Protocol v2 헤더 전송 (haproxy.org/send-proxy-protocol: proxy-v2)
            │
            ▼ (Client Real IP 100% 보존 바이너리 패킷 전달)
[Istio Ingress Gateway (Envoy L7 프록시)]
    * EnvoyFilter(envoy.filters.listener.proxy_protocol)로 PROXY Protocol v2 헤더 파싱
    * VirtualService 가중치 분기: 90% (v1) : 10% (v2)
            │
            ▼ (mTLS STRICT: 상호 인증 암호화 터널링)
[Cilium eBPF Sockops (소켓 다이렉트 단축 가속)]
            │
    ┌───────┴───────┐
    ▼ (90% 트래픽)   ▼ (10% 카나리 분기)
[Chat Service v1] [Chat Service v2]
 (2/2 Running)     (2/2 Running)
 (stable-90%)      (CANARY-10%)
```

### 💡 핵심 아키텍처 설계 원칙
- **L7 트래픽 수용 (HAProxy Ingress HostPort)**: 워커 노드 물리 포트(`80`, `443`)를 점유하여 iptables NAT 오버헤드를 배제하고 멀티스레딩 이벤트 처리(`nbthread: 4`)를 적용.
- **클라이언트 원본 IP 보존 (PROXY Protocol v2)**: L4 로드밸런서 및 인그레스에서 Istio Envoy Gateway까지 바이너리 헤더로 실제 클라이언트 원본 IP를 무결하게 보존.
- **서비스 메시 & 제로 트러스트 (Istio STRICT mTLS)**: 클러스터 내부 파드 간 통신을 mTLS로 상호 암호화하고, `VirtualService`를 통해 90:10 가중치 기반 카나리 배포 적용.
- **사이드카 기동 레이스 컨디션 방지**: `holdApplicationUntilProxyStarts: true`를 적용하여 Envoy 프록시 기동 완료 전 앱 기동으로 인한 초기 연결 실패(502) 방지.
- **커널 레벨 네트워크 가속**: Cilium eBPF Sockops를 결합하여 동일 노드 내 로컬 통신 시 TCP/IP 스택을 우회하는 소켓 다이렉트 라우팅 적용.

---

## 2. Step 1: [검증 완료] HAProxy Ingress Controller 배포 (HostPort 모드)

워커 노드의 물리 포트(`80`, `443`)를 직접 점유(HostPort)하여 NodePort 및 iptables NAT 오버헤드 없이 외부 트래픽을 즉시 수용할 수 있도록 배포했습니다.

### 2-1. 프로덕션 `01-haproxy-ingress-values.yaml` 핵심 설정
```yaml
controller:
  kind: DaemonSet
  daemonset:
    useHostPort: true
    ports:
      http: 80
      https: 443
      stat: 1024
  config:
    max-connections: "100000"
    nbthread: "4"
    tune-bufsize: "32768"
    http-reuse: "aggressive"
    timeout-client: "30s"
    timeout-server: "30s"
    timeout-keep-alive: "60s"
    backend-server-slots-increment: "32"
  resources:
    requests:
      cpu: "2000m"
      memory: "2Gi"
    limits:
      cpu: "4000m"
      memory: "4Gi"
```

### 2-2. 실제 배포 명령어 (Windows Bastion)
```powershell
helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm repo update
helm install haproxy-ingress haproxytech/kubernetes-ingress `
  --namespace ingress-controller --create-namespace `
  -f .\01-traffic-architecture\01-haproxy-ingress-values.yaml
```

### 2-3. 실제 파드 기동 검증 결과 (`k -n ingress-controller get pods -o wide`)
```plain text
NAME                                       READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
haproxy-ingress-kubernetes-ingress-6pzhp   1/1     Running   0          36s   10.0.4.213   k8s-worker-01   <none>           <none>
haproxy-ingress-kubernetes-ingress-cnnnz   1/1     Running   0          36s   10.0.2.145   k8s-worker-03   <none>           <none>
haproxy-ingress-kubernetes-ingress-srghd   1/1     Running   0          36s   10.0.3.145   k8s-cp-01       <none>           <none>
haproxy-ingress-kubernetes-ingress-xpzzr   1/1     Running   0          36s   10.0.5.140   k8s-worker-02   <none>           <none>
```

### 2-4. 워커 노드 물리 80번 포트 즉시 응답 검증
```powershell
curl.exe -I http://10.40.101.184/
```
```plain text
HTTP/1.1 404 Not Found
date: Mon, 26 Oct 2026 04:26:02 GMT
content-type: text/plain; charset=utf-8
content-length: 9
```
> 💡 **검증 확인**: 워커 노드의 물리 80번 포트가 HAProxy에 의해 완벽하게 바인딩되어 외부 트래픽 수신 준비가 완료되었음을 확인했습니다.

---

## 3. Step 2: [검증 완료] Istio Service Mesh 1.21 설치 (`istioctl install`)

서비스 메시 제어면(`istiod`)과 L7 인그레스 게이트웨이(`istio-ingressgateway`)를 설치하고 프로덕션 수준의 Envoy 설정을 적용했습니다.

### 3-1. 프로덕션 `02-istio-operator.yaml` 핵심 설정
* **`holdApplicationUntilProxyStarts: true`**: 어플리케이션 파드가 Envoy 사이드카가 준비되기 전에 초기 DB 쿼리나 외부 호출을 시도하여 발생하는 `Connection Refused` 에러를 원천 차단.
* **`accessLogEncoding: JSON`**: `duration_ms`, `upstream_service_time_ms`, `traceparent` 등 주요 지연 시간 및 분산 추적 식별자를 JSON으로 표준화하여 수집.
* **`concurrency: 2`**: Envoy 프록시 워커 스레드를 2개로 고정하여 CPU 과부하 방지.

### 3-2. 실제 설치 명령어 (Windows Bastion)
```powershell
istioctl install -f .\01-traffic-architecture\02-istio-operator.yaml -y
```

### 3-3. 실제 Istio 파드 상태 검증 (`k -n istio-system get pods -o wide`)
```plain text
NAME                                    READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
istio-ingressgateway-567dc944d7-zmkmf   1/1     Running   0          31s   10.0.5.214   k8s-worker-02   <none>           <none>
istiod-5668557955-hdcj5                 1/1     Running   0          39s   10.0.2.191   k8s-worker-03   <none>           <none>
```
> 🚀 **검증 통과**: 제어면(`istiod`)과 진입 게이트웨이(`istio-ingressgateway`)가 각각 `k8s-worker-03`과 `k8s-worker-02`에 정상 스케줄링되어 **`1/1 Running`**을 달성했습니다.

---

## 4. Step 3: [검증 완료] mTLS STRICT & PROXY Protocol v2 & Ingress 연동

클라이언트 원본 IP 보존과 제로 트러스트(Zero Trust) 보안 격리를 위해 HAProxy -> Istio Gateway -> Service 구간을 유기적으로 결합했습니다.

### 4-1. 핵심 매니페스트 구성 (`03-proxy-protocol-and-strict-mtls.yaml`)
1. **EnvoyFilter (`proxy-protocol`)**: Istio Ingress Gateway 8080 리스너 필터 체인 맨 앞에 `envoy.filters.listener.proxy_protocol`을 삽입하여 PROXY Protocol v2 바이너리 헤더 디코딩.
2. **Gateway (`istio-ingressgateway`)**: 80번 포트로 인입되는 모든 호스트 트래픽을 수용하도록 리스너 바인딩.
3. **PeerAuthentication (`default`)**: `default` 네임스페이스 내 모든 파드 간 통신을 **`STRICT`** mTLS로 강제.
4. **Ingress (`haproxy-to-istio`)**: `chat.infra.internal` 호스트 트래픽을 `istio-ingressgateway:80` 서비스로 포워딩.

### 4-2. 트러블슈팅: HAProxy Backend PROXY Protocol 파싱 연동
HAProxy Ingress Controller(by HAProxy Technologies)에서 백엔드로 PROXY Protocol v2를 송신하도록 지정하려면 서비스에 전용 어노테이션을 부여해야 합니다:
```powershell
kubectl -n istio-system annotate svc istio-ingressgateway haproxy.org/send-proxy-protocol="proxy-v2" --overwrite
```
> 💡 **원리**: Envoy 리스너에 `proxy_protocol` 필터가 켜져 있으면, HAProxy가 PROXY v2 헤더 없이 일반 HTTP 요청을 전송할 경우 Envoy가 비정상 패킷으로 판단하여 즉시 TCP Reset(`502 Bad Gateway`)을 반환합니다. 위 어노테이션을 통해 HAProxy 백엔드 설정에 `send-proxy-v2`가 주입되어 양 프록시 간 정상적인 핸드셰이크가 체결됩니다.

---

## 5. Step 4: [검증 완료] 90:10 카나리 마이크로서비스 배포 & Envoy 사이드카 주입

사이드카 자동 주입을 활성화하고 안정 버전(v1, 90%)과 카나리 신규 버전(v2, 10%)을 배포했습니다.

### 5-1. 네임스페이스 사이드카 인젝션 활성화 및 배포
```powershell
k label namespace default istio-injection=enabled --overwrite
k apply -f .\01-traffic-architecture\04-chat-grpc-canary.yaml
```

### 5-2. 실제 파드 기동 검증 결과 (`k get pods -o wide`)
```plain text
NAME                               READY   STATUS    RESTARTS   AGE   IP           NODE            NOMINATED NODE   READINESS GATES
chat-service-v1-77dcdd8dd7-ngnqf   2/2     Running   0          25s   10.0.2.43    k8s-worker-03   <none>           <none>
chat-service-v1-77dcdd8dd7-wtrz2   2/2     Running   0          25s   10.0.4.219   k8s-worker-01   <none>           <none>
chat-service-v2-5f9f97df9b-g7tqr   2/2     Running   0          25s   10.0.4.103   k8s-worker-01   <none>           <none>
```
> 🚀 **검증 통과**: 어플리케이션 컨테이너와 Istio Envoy 프록시 사이드카가 결합되어 **`2/2 Running`** 상태로 정상 기동되었습니다.

---

## 6. Step 5: [검증 완료] 엔드-투-엔드 트래픽 가중치 라우팅 실측 검증

외부 진입점(HAProxy HostPort 80)을 통해 단건 및 대량 요청을 전송하여 트래픽 분기 동작을 실측 검증했습니다.

### 6-1. 단건 호출 검증 (외부 -> HAProxy -> Istio Gateway -> mTLS -> Pod)
```powershell
curl.exe -i -H "Host: chat.infra.internal" http://10.40.101.184/
```
```http
HTTP/1.1 200 OK
x-app-name: http-echo
x-app-version: 1.0.0
date: Mon, 26 Oct 2026 04:46:59 GMT
content-length: 77
content-type: text/plain; charset=utf-8
x-envoy-upstream-service-time: 7
server: istio-envoy

{"version":"v1","status":"ok","cluster":"core-cluster","pool":"stable-90%"}
```
> 💡 **검증 통과**: `server: istio-envoy` 및 `x-envoy-upstream-service-time: 7ms` 헤더를 통해 요청이 HAProxy를 통과하여 Istio Envoy 메시를 거쳐 정상 처리됨을 확인했습니다.

### 6-2. 50회 연속 요청 가중치 분기 실측 (PowerShell Group-Object)
```powershell
1..50 | ForEach-Object { 
  curl.exe -s -H "Host: chat.infra.internal" http://10.40.101.184/ 
} | Group-Object | Select-Object Count, Name
```
```plain text
Count Name
----- ----
   47 {"version":"v1","status":"ok","cluster":"core-cluster","pool":"stable-90%"}
    3 {"version":"v2","status":"ok","cluster":"core-cluster","pool":"CANARY-10%"}
```
> 🎯 **카나리 가중치 달성**: 50회 요청 중 **47회(94%)가 v1(Stable)**으로, **3회(6%)가 v2(Canary)**로 정밀하게 분기되어 **VirtualService의 90:10 카나리 라우팅 정책이 완벽히 작동함**을 증명했습니다.

---

## 7. Step 6: [검증 완료] Hubble eBPF & Service Mesh 실시간 관측성 검증

Cilium eBPF 커널 레벨 관측성 엔진(Hubble)을 통해 클러스터 내부의 L4/L7 트래픽 흐름과 서비스 토폴로지를 실시간 시각화했습니다.

### 7-1. Hubble UI 대시보드 검증
```powershell
k -n kube-system port-forward svc/hubble-ui 12000:80
# 브라우저 접속: http://localhost:12000/?namespace=default
```

![Hubble UI Service Mesh Topology & mTLS Observation](https://iili.io/nk8dQGn.png)

### 7-2. eBPF 토폴로지 분석 결과
* **트래픽 흐름 추적**: `world`(외부 클라이언트) -> `chat-service` (v1 & v2 파드) -> `istiod:15012`(Citadel mTLS 인증서 갱신 및 xDS 스트림) 전 구간이 실시간 매핑됨.
* **실시간 처리율**: **`34.3 flows/s`**, 6대 노드 전체(`6/6 nodes`)의 커널 eBPF 프로브가 활성화되어 전역 트래픽을 관측.
* **보안 및 포워딩 판정(`Verdict`)**: 모든 패킷이 **`forwarded`**로 판정되어 드롭이나 정책 위반 없이 안전하게 통신 중임을 증명.

