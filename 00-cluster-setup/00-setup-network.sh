#!/usr/bin/env bash
# ==============================================================================
# Enterprise SRE 클러스터: 노드 네트워크 고정 IP 및 hosts 자동 설정 스크립트
# 사용법: sudo ./00-setup-network.sh <호스트명> <고정IP>
# 예시:   sudo ./00-setup-network.sh k8s-cp-01 10.40.101.11
# ==============================================================================
set -euo pipefail

NODE_NAME="${1:-${NODE_NAME:-}}"
NODE_IP="${2:-${NODE_IP:-}}"
GATEWAY="${GATEWAY:-10.40.101.1}"
DNS="${DNS:-8.8.8.8}"

if [ -z "$NODE_NAME" ] || [ -z "$NODE_IP" ]; then
    echo "❌ 에러: 호스트명과 고정 IP를 인자로 전달해야 합니다."
    echo "사용법: sudo $0 <호스트명> <IP주소>"
    echo "예시:   sudo $0 k8s-cp-01 10.40.101.181"
    exit 1
fi

echo ">>> [1/4] 호스트명 설정: ${NODE_NAME}"
hostnamectl set-hostname "${NODE_NAME}"

echo ">>> [2/4] /etc/hosts 클러스터 노드 맵 등록"
# 기존 k8s 노드 설정 제거 후 재등록
sudo sed -i '/k8s-/d' /etc/hosts

cat <<EOF | sudo tee -a /etc/hosts
# --- High Availability K8s Cluster Nodes ---
${CONTROL_PLANE_VIP:-10.40.101.180} k8s-vip ${VIP_DOMAIN:-k8s-vip.infra.internal}
${CP1_IP:-10.40.101.181} k8s-cp-01
${CP2_IP:-10.40.101.182} k8s-cp-02
${CP3_IP:-10.40.101.183} k8s-cp-03
${WORKER1_IP:-10.40.101.184} k8s-worker-01
${WORKER2_IP:-10.40.101.185} k8s-worker-02
${WORKER3_IP:-10.40.101.186} k8s-worker-03
EOF

echo ">>> [3/4] 활성 네트워크 인터페이스 감지"
IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || echo "")
if [ -z "$IFACE" ]; then
    IFACE=$(ip -br link | grep -v "lo" | head -n1 | awk '{print $1}')
fi
echo "  - 감지된 네트워크 인터페이스: ${IFACE}"

echo ">>> [4/4] Netplan 고정 IP 설정 적용 (/etc/netplan/01-netcfg.yaml)"
# 기존 netplan 백업
sudo mkdir -p /etc/netplan/backup
sudo mv /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true

cat <<EOF | sudo tee /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses:
        - ${NODE_IP}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS}
          - 8.8.8.8
EOF

sudo chmod 600 /etc/netplan/01-netcfg.yaml
sudo netplan apply

echo "=========================================================="
echo "✅ 네트워크 설정 완료!"
echo "  - 호스트명: $(hostname)"
echo "  - IP 주소:  $(ip -4 addr show dev $IFACE | grep inet | awk '{print $2}')"
echo "  - 게이트웨이: ${GATEWAY}"
echo "  - DNS:       ${DNS}"
echo "=========================================================="
