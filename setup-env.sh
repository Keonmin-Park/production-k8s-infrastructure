#!/usr/bin/env bash
# ==============================================================================
# Enterprise SRE Cluster: 환경 변수 등록 및 YAML 매니페스트 렌더링 스크립트
# ==============================================================================
# 사용법:
#   1) 현재 세션에 변수 로드:
#      source ./setup-env.sh
#
#   2) 서버 전체에 변수 영구 등록 (/etc/profile.d/):
#      sudo ./setup-env.sh --register
#
#   3) 템플릿 YAML 매니페스트를 실제 설정 파일로 렌더링:
#      ./setup-env.sh --render
#
#   4) 현재 로드된 변수 상태 확인:
#      ./setup-env.sh --show
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/cluster.env"
EXAMPLE_FILE="${SCRIPT_DIR}/cluster.env.example"

# 색상 정의
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 1. cluster.env 확인 및 자동 생성
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$EXAMPLE_FILE" ]; then
        echo -e "${YELLOW}⚠️  'cluster.env' 파일이 존재하지 않아 'cluster.env.example'을 복사하여 생성합니다.${NC}"
        cp "$EXAMPLE_FILE" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        echo -e "${GREEN}✅ 'cluster.env' 생성 완료! 필요한 경우 값을 수정하세요.${NC}"
    else
        echo -e "${RED}❌ 에러: ${EXAMPLE_FILE} 파일을 찾을 수 없습니다.${NC}"
        exit 1
    fi
fi

# 2. cluster.env 로드 및 export
# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

# 기본값 보정 (Fallback Defaults)
export CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-10.40.101.180}"
export CP1_IP="${CP1_IP:-10.40.101.181}"
export CP2_IP="${CP2_IP:-10.40.101.182}"
export CP3_IP="${CP3_IP:-10.40.101.183}"
export WORKER1_IP="${WORKER1_IP:-10.40.101.184}"
export WORKER2_IP="${WORKER2_IP:-10.40.101.185}"
export WORKER3_IP="${WORKER3_IP:-10.40.101.186}"
export GATEWAY="${GATEWAY:-10.40.101.1}"
export DNS="${DNS:-8.8.8.8}"
export NET_INTERFACE="${NET_INTERFACE:-ens33}"
export VIP_DOMAIN="${VIP_DOMAIN:-k8s-vip.infra.internal}"
export CLUSTER_NAME="${CLUSTER_NAME:-core-cluster}"
export K8S_VERSION="${K8S_VERSION:-v1.28.15}"
export POD_SUBNET="${POD_SUBNET:-10.244.0.0/16}"
export SERVICE_SUBNET="${SERVICE_SUBNET:-10.96.0.0/12}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-prom-operator-admin}"

# 템플릿 치환 함수 (envsubst 또는 Pure Bash Fallback)
render_template() {
    local src="$1"
    local dest="$2"

    if [ ! -f "$src" ]; then
        echo -e "${RED}❌ 템플릿 파일이 없습니다: ${src}${NC}"
        return 1
    fi

    echo -e "  - 변환 중: ${src} -> ${dest}"
    if command -v envsubst >/dev/null 2>&1; then
        envsubst < "$src" > "$dest"
    else
        # envsubst가 없는 경량 서버를 위한 Python / Sed 치환 Fallback
        python3 -c "
import os, sys
with open('$src', 'r', encoding='utf-8') as f:
    content = f.read()
for k, v in os.environ.items():
    content = content.replace('\${' + k + '}', str(v))
with open('$dest', 'w', encoding='utf-8') as f:
    f.write(content)
" 2>/dev/null || {
            sed \
                -e "s|\${CONTROL_PLANE_VIP}|${CONTROL_PLANE_VIP}|g" \
                -e "s|\${CP1_IP}|${CP1_IP}|g" \
                -e "s|\${CP2_IP}|${CP2_IP}|g" \
                -e "s|\${CP3_IP}|${CP3_IP}|g" \
                -e "s|\${WORKER1_IP}|${WORKER1_IP}|g" \
                -e "s|\${WORKER2_IP}|${WORKER2_IP}|g" \
                -e "s|\${WORKER3_IP}|${WORKER3_IP}|g" \
                -e "s|\${GATEWAY}|${GATEWAY}|g" \
                -e "s|\${DNS}|${DNS}|g" \
                -e "s|\${NET_INTERFACE}|${NET_INTERFACE}|g" \
                -e "s|\${VIP_DOMAIN}|${VIP_DOMAIN}|g" \
                -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" \
                -e "s|\${K8S_VERSION}|${K8S_VERSION}|g" \
                -e "s|\${POD_SUBNET}|${POD_SUBNET}|g" \
                -e "s|\${SERVICE_SUBNET}|${SERVICE_SUBNET}|g" \
                -e "s|\${GRAFANA_ADMIN_PASSWORD}|${GRAFANA_ADMIN_PASSWORD}|g" \
                "$src" > "$dest"
        }
    fi
}

show_env() {
    echo -e "${BLUE}==========================================================${NC}"
    echo -e "${BLUE}📌 현재 등록된 Kubernetes 클러스터 환경 변수${NC}"
    echo -e "${BLUE}==========================================================${NC}"
    echo "  - CONTROL_PLANE_VIP : ${CONTROL_PLANE_VIP}"
    echo "  - CP 노드 IP 목록   : ${CP1_IP}, ${CP2_IP}, ${CP3_IP}"
    echo "  - Worker 노드 IP    : ${WORKER1_IP}, ${WORKER2_IP}, ${WORKER3_IP}"
    echo "  - VIP 내부 도메인   : ${VIP_DOMAIN}"
    echo "  - 클러스터 이름     : ${CLUSTER_NAME}"
    echo "  - K8s 버전          : ${K8S_VERSION}"
    echo "  - Pod CIDR          : ${POD_SUBNET}"
    echo "  - Service CIDR      : ${SERVICE_SUBNET}"
    echo "  - 네트워크 인터페이스: ${NET_INTERFACE}"
    echo "  - 게이트웨이 / DNS  : ${GATEWAY} / ${DNS}"
    echo "  - Grafana Password  : ******** (마스킹됨)"
    echo -e "${BLUE}==========================================================${NC}"
}

register_system_wide() {
    echo -e "${YELLOW}>>> 시스템 전체 환경 변수 영구 등록 중...${NC}"
    local TARGET_DIR="/etc/profile.d"
    local TARGET_FILE="${TARGET_DIR}/k8s-cluster-env.sh"

    if [ -w "$TARGET_DIR" ] || [ "$EUID" -eq 0 ]; then
        cp "$ENV_FILE" "$TARGET_FILE"
        chmod 644 "$TARGET_FILE"
        echo -e "${GREEN}✅ /etc/profile.d/k8s-cluster-env.sh 등록 완료! (모든 사용자/세션에 자동 적용)${NC}"
    else
        echo -e "${YELLOW}⚠️ sudo 권한이 없어 ~/.bashrc 에 등록합니다.${NC}"
        if ! grep -q "source ${ENV_FILE}" ~/.bashrc; then
            echo "source ${ENV_FILE}" >> ~/.bashrc
            echo -e "${GREEN}✅ ~/.bashrc 에 환경 변수 로드 등록 완료!${NC}"
        else
            echo "ℹ️  이미 ~/.bashrc 에 등록되어 있습니다."
        fi
    fi
}

render_all_manifests() {
    echo -e "${YELLOW}>>> 매니페스트 렌더링 시작...${NC}"
    mkdir -p "${SCRIPT_DIR}/rendered"

    # 1. Kubeadm 초기화 설정
    render_template \
        "${SCRIPT_DIR}/00-cluster-setup/03-kubeadm-init-config.yaml" \
        "${SCRIPT_DIR}/rendered/03-kubeadm-init-config.rendered.yaml"

    # 2. Cilium Helm Values
    render_template \
        "${SCRIPT_DIR}/00-cluster-setup/04-cilium-values.yaml" \
        "${SCRIPT_DIR}/rendered/04-cilium-values.rendered.yaml"

    # 3. Prometheus Stack Values
    render_template \
        "${SCRIPT_DIR}/02-observability/01-prometheus-stack-values.yaml" \
        "${SCRIPT_DIR}/rendered/01-prometheus-stack-values.rendered.yaml"

    # 컨트롤 플레인 표준 경로(/etc/kubernetes/kubeadm-config.yaml) 자동 배포 옵션
    if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
        sudo mkdir -p /etc/kubernetes
        sudo cp "${SCRIPT_DIR}/rendered/03-kubeadm-init-config.rendered.yaml" /etc/kubernetes/kubeadm-config.yaml
        echo -e "${GREEN}✅ /etc/kubernetes/kubeadm-config.yaml 생성 완료! 바로 'sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml' 실행 가능합니다.${NC}"
    fi

    echo -e "${GREEN}✅ 모든 매니페스트 렌더링 완료! -> ${SCRIPT_DIR}/rendered/${NC}"
}

# 파라미터 처리
ACTION="${1:-}"

case "$ACTION" in
    --register|register)
        register_system_wide
        show_env
        ;;
    --render|render)
        render_all_manifests
        ;;
    --show|show)
        show_env
        ;;
    --help|-h)
        echo "사용법: $0 [--register | --render | --show | --help]"
        echo "  --register : 시스템(/etc/profile.d/)에 클러스터 변수 영구 등록"
        echo "  --render   : 템플릿 YAML 파일을 실제 환경 설정 파일로 일괄 변환"
        echo "  --show     : 현재 로드된 환경 변수 출력"
        ;;
    *)
        # source로 호출된 경우 세션에 export 안내
        show_env
        echo -e "${GREEN}💡 현재 쉘 세션에 클러스터 환경 변수가 성공적으로 로드되었습니다.${NC}"
        echo -e "   다음 명령으로 매니페스트를 바로 렌더링할 수 있습니다: ${YELLOW}./setup-env.sh --render${NC}\n"
        ;;
esac
