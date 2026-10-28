#!/usr/bin/env bash
# ==============================================================================
# Enterprise SRE 클러스터: kube-vip Control Plane VIP 생성 스크립트
# 별도의 외부 LB 장비 없이 컨트롤 플레인 노드 간 ARP 기반 VIP 페일오버를 구현합니다.
# ==============================================================================
set -euo pipefail

# [사용자 환경에 맞게 수정할 변수]
export VIP="${1:-${CONTROL_PLANE_VIP:-10.40.101.180}}"              # 컨트롤 플레인 공용 가상 IP (VIP)
export INTERFACE="${2:-${NET_INTERFACE:-ens33}}"                   # 네트워크 인터페이스
export KVVERSION="v0.7.2"

echo ">>> kube-vip 설정 정보"
echo "  - Control Plane VIP: ${VIP}"
echo "  - Network Interface: ${INTERFACE}"

# kube-vip 바이너리 / 컨테이너를 통해 Static Pod 매니페스트 생성
sudo mkdir -p /etc/kubernetes/manifests

echo ">>> kube-vip Static Pod 매니페스트 생성: /etc/kubernetes/manifests/kube-vip.yaml"
sudo ctr --namespace k8s.io image pull ghcr.io/kube-vip/kube-vip:$KVVERSION

sudo ctr --namespace k8s.io run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip-manifest \
/kube-vip manifest pod \
  --interface "$INTERFACE" \
  --address "$VIP" \
  --controlplane \
  --services \
  --arp \
  --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml > /dev/null

echo "✅ kube-vip static pod 생성 완료! (kubelet에 의해 자동 기동됨)"
