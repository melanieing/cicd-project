# 로컬 도구 설치 가이드 (Ubuntu 24.04)

본 문서는 본 프로젝트를 로컬에서 처음부터 구동하기 위해 필요한 도구를 **복붙으로 끝까지 설치·검증**할 수 있도록 작성되었다.

- **대상 OS**: Ubuntu 24.04 LTS (WSL2 또는 베어메탈)
- **사전 조건**: sudo 권한, 인터넷 접속, 약 5 GB 디스크 여유
- **소요 시간**: 약 20~30분 (Docker 첫 다운로드 시간 포함)
- **버전 핀 출처**: `docs/tech-stack-versions.md`

설치 후 마지막 검증까지 끝나면 다음 문서(`scripts/bootstrap.sh` 실행)로 진행한다.

---

## 0. 사전 점검

```bash
# Ubuntu 버전 확인 (24.04여야 함)
lsb_release -a

# 아키텍처 확인 (x86_64여야 함)
uname -m

# 디스크 여유 (5G 이상 권장)
df -h /
```

**예상 출력**:
```
Distributor ID:  Ubuntu
Description:     Ubuntu 24.04.x LTS
Codename:        noble
x86_64
```

---

## 1. Docker Engine

> kind는 Docker(또는 Podman)를 백엔드로 사용한다. 본 가이드는 Docker Engine 기준.

### 1.1 설치

```bash
# 기존 충돌 패키지 제거 (있다면)
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null || true
done

# 의존성 설치
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Docker 공식 GPG 키 추가
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 저장소 등록
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 설치
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 1.2 비루트 사용자로 docker 실행

```bash
sudo usermod -aG docker "$USER"
# 그룹 변경을 즉시 적용하려면 새 셸을 띄운다
newgrp docker
```

### 1.3 검증

```bash
docker --version
docker run --rm hello-world
```

**성공 판정**:
- `Docker version 27.x` 이상 출력
- `hello-world` 컨테이너에서 `Hello from Docker!` 메시지 출력

**자주 발생하는 오류**:
| 증상 | 원인 | 해결 |
|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | docker 그룹 적용 안 됨 | `newgrp docker` 또는 재로그인 |
| `Cannot connect to the Docker daemon` | docker 데몬 미기동 | `sudo systemctl start docker && sudo systemctl enable docker` |
| WSL2에서 `systemd not running` | WSL systemd 비활성 | `/etc/wsl.conf`에 `[boot]\nsystemd=true` 추가 후 `wsl --shutdown` |

---

## 2. kind — `v0.27.0`

```bash
# 다운로드 + 설치
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
sudo install -m 0755 /tmp/kind /usr/local/bin/kind
rm /tmp/kind

# 검증
kind version
```

**예상 출력**:
```
kind v0.27.0 go1.23.x linux/amd64
```

---

## 3. kubectl — `v1.33.x`

> kind 노드 K8s 1.33과 호환되는 kubectl을 설치한다. kubectl은 ±1 minor까지 호환되므로 최신 1.33 패치를 사용.

```bash
# 최신 1.33 stable 패치 버전 조회
KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable-1.33.txt)"
echo "Installing kubectl ${KUBECTL_VERSION}"

# 다운로드
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"

# 체크섬 검증 (필수)
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
# kubectl: OK 가 출력되어야 함

# 설치
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl kubectl.sha256

# 검증
kubectl version --client
```

**예상 출력**:
```
Client Version: v1.33.x
Kustomize Version: v5.x.x
```

---

## 4. Helm — `v3.20.x`

```bash
# 공식 설치 스크립트 (Helm 3 latest)
curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
DESIRED_VERSION="v3.20.0" /tmp/get_helm.sh
rm /tmp/get_helm.sh

# 검증
helm version
```

**예상 출력**:
```
version.BuildInfo{Version:"v3.20.x", ...}
```

> 더 최신 3.20 패치가 있다면 `DESIRED_VERSION` 환경변수를 빼면 자동으로 latest stable이 설치된다. 단, **반드시 v4가 아닌 v3 계열인지 확인**할 것 (`helm version` 출력이 `v3.x`여야 함).

---

## 5. istioctl — `1.29.2`

```bash
# 다운로드 (지정 버전)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.29.2 TARGET_ARCH=x86_64 sh -

# PATH 등록 (영구)
sudo install -m 0755 istio-1.29.2/bin/istioctl /usr/local/bin/istioctl
# 압축 해제된 디렉토리는 정리해도 됨 (필요시 manifests 참조용으로 보관 가능)
# rm -rf istio-1.29.2

# 검증
istioctl version --remote=false
```

**예상 출력**:
```
client version: 1.29.2
```

---

## 6. ArgoCD CLI

> ArgoCD 서버는 클러스터 안에서 Helm으로 설치하지만, CLI는 로컬에서 사용. 서버 버전과 매칭되도록 ArgoCD 9.5.x와 호환되는 latest argocd CLI를 설치한다.

```bash
# 최신 release 자동 감지 후 설치
ARGOCD_VERSION="$(curl -L -s -H 'Accept: application/json' https://github.com/argoproj/argo-cd/releases/latest | sed -E 's/.*"tag_name":"([^"]+)".*/\1/')"
echo "Installing argocd CLI ${ARGOCD_VERSION}"

curl -sSL -o /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
rm /tmp/argocd

# 검증
argocd version --client
```

**예상 출력**:
```
argocd: v3.x.x ... (서버 버전은 클러스터 설치 후 확인)
```

---

## 7. 보조 도구 (선택적이지만 권장)

```bash
# yq — YAML 조작 (kubectl/Helm 결과 가공에 유용)
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# jq — JSON 조작 (kubectl -o json 가공)
sudo apt-get install -y jq

# stern — 멀티 파드 로그 tail (디버깅 필수)
sudo wget -qO /tmp/stern.tar.gz https://github.com/stern/stern/releases/latest/download/stern_$(curl -s https://api.github.com/repos/stern/stern/releases/latest | jq -r '.tag_name | sub("v"; "")')_linux_amd64.tar.gz
sudo tar -xzf /tmp/stern.tar.gz -C /usr/local/bin stern && rm /tmp/stern.tar.gz
sudo chmod +x /usr/local/bin/stern
```

검증:
```bash
yq --version
jq --version
stern --version
```

---

## 8. 최종 검증 (한 번에)

설치 완료 후 모든 도구가 PATH에 잡혔는지 한 번에 확인.

```bash
echo "--- versions ---"
docker --version
kind version
kubectl version --client | head -2
helm version --short
istioctl version --remote=false
argocd version --client | head -1
yq --version
jq --version
stern --version
```

**성공 판정 기준** — 다음과 같은 출력이 나오면 모든 설치 정상:

```
--- versions ---
Docker version 27.x.x, build ...
kind v0.27.0 go1.23.x linux/amd64
Client Version: v1.33.x
Kustomize Version: v5.x.x
v3.20.x+g...
client version: 1.29.2
argocd: v3.x.x+...
yq (https://github.com/mikefarah/yq/) version v4.x.x
jq-1.7.x
version: 1.x.x
```

하나라도 빠지면 해당 섹션으로 돌아가 재설치한다.

---

## 9. 다음 단계

설치 완료 후:

```bash
# 프로젝트 루트에서
./scripts/bootstrap.sh
```

스크립트는 다음을 수행한다:
1. kind 클러스터 `payment` 생성 (control-plane 1 + worker 2)
2. K8s 컨텍스트 전환 (`kind-payment`)
3. 네임스페이스 5개 생성 (`payment-dev`, `payment-prod`, `argocd`, `istio-system`, `observability`)
4. 노드/네임스페이스 상태 출력

상세는 `scripts/bootstrap.sh` 주석 참조.

---

## 10. 트러블슈팅 모음

| 문제 | 진단 명령 | 해결 |
|---|---|---|
| Docker pull 속도 느림 | `docker info` 출력의 Registry Mirrors 확인 | `/etc/docker/daemon.json`에 미러 추가 후 `sudo systemctl restart docker` |
| WSL2에서 kind 노드가 죽음 | `wsl --status` | `.wslconfig`에 `memory=12GB`, `swap=4GB` 추가 |
| kubectl이 클러스터 못 찾음 | `kubectl config current-context` | `kubectl config use-context kind-payment` |
| istioctl install OOM | `kubectl top nodes` (불가하면 `docker stats`) | demo profile 다른 컴포넌트 일시 중단, 또는 `--set components.cni.enabled=false` |

---

## 참조

- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [kubectl Install on Linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [Helm Install](https://helm.sh/docs/intro/install/)
- [Istio Getting Started](https://istio.io/latest/docs/setup/getting-started/)
- [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
