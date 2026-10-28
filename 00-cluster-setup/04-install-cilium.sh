#!/usr/bin/env bash
# ==============================================================================
# Enterprise SRE 클러스터: Cilium CNI (eBPF + kube-proxy 완전 대체) 설치
# ==============================================================================
set -euo pipefail

echo ">>> [1/3] Cilium CLI 설치"
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz*

echo ">>> [2/3] Helm 레포지토리 추가"
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add cilium https://helm.cilium.io/
helm repo update

echo ">>> [3/3] Cilium eBPF CNI 배포 (kube-proxy 대체 + sockops 활성화)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helm upgrade --install cilium cilium/cilium \
  --version 1.15.5 \
  --namespace kube-system \
  -f "${SCRIPT_DIR}/04-cilium-values.yaml"

echo ">>> Cilium 상태 확인 대기 중..."
cilium status --wait

echo "=========================================================="
echo "✅ Cilium eBPF CNI 배포 및 클러스터 네트워킹 준비 완료!"
echo "=========================================================="
