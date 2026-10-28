#!/usr/bin/env bash
# ==============================================================================
# Enterprise SRE 클러스터: 모든 노드(CP/Worker) 공통 사전 설정 스크립트
# 대상 OS: Ubuntu 22.04 LTS
# ==============================================================================
set -euo pipefail

echo ">>> [1/6] Swap 비활성화 (K8s kubelet 안정성 보장)"
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo ">>> [2/6] 커널 모듈 로드 설정 (overlay, br_netfilter)"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo ">>> [3/6] 리눅스 커널 sysctl 파라미터 최적화"
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
# 패킷 포워딩 및 브리지 트래픽 iptables 처리 활성화
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.forwarding        = 1

# 대용량 인그레스 트래픽 및 파일 디스크립터 대응
fs.file-max                         = 2097152
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 8192
vm.max_map_count                    = 262144

# 커넥션 트래킹 및 소켓 버퍼 튜닝
net.core.somaxconn                  = 32768
net.ipv4.tcp_max_syn_backlog        = 16384
net.ipv4.ip_local_port_range        = 1024 65535
EOF

sudo sysctl --system

echo ">>> [4/6] containerd 컨테이너 런타임 설치"
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Docker 공식 GPG 키 등록
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Docker apt 레포지토리 추가
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y containerd.io

echo ">>> [5/6] containerd cgroup v2 및 systemd 드라이버 설정"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# SystemdCgroup = true 로 치환
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# pause 이미지 버전을 K8s 1.28 표준인 3.9로 고정
sudo sed -i 's|registry.k8s.io/pause:3.8|registry.k8s.io/pause:3.9|g' /etc/containerd/config.toml
sudo sed -i 's|registry.k8s.io/pause:3.6|registry.k8s.io/pause:3.9|g' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo ">>> [6/6] Kubernetes v1.28 패키지 (kubeadm, kubelet, kubectl) 설치"
# K8s v1.28 패키지 저장소 등록 (pkgs.k8s.io)
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet=1.28.15-1.1 kubeadm=1.28.15-1.1 kubectl=1.28.15-1.1
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

echo "=========================================================="
echo "✅ 노드 사전 설정 완료! (containerd + K8s v1.28 고정)"
echo "=========================================================="
