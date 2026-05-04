# syntax=docker/dockerfile:1.7
#
# 서비스 컨테이너 이미지를 만드는 빌드 정의 파일.
# Docker engine 이 위에서 아래로 줄을 읽으며 한 줄당 한 layer 를 쌓아 image 를 구성.
#
# [멀티스테이지 빌드 — 왜?]
# `FROM ... AS <name>` 형태의 stage 가 여러 개 있고, 마지막 stage 만 최종 image 에 포함된다.
# 빌드에 필요한 도구(컴파일러, dev header, pip 캐시 등) 는 builder stage 에 두고
# 실행에 필요한 결과물(설치된 venv, app 코드) 만 runtime stage 로 복사한다.
# 결과: 이미지 크기 ↓, attack surface ↓, Trivy CVE 차단 부담 ↓.
#
# [requirements 매핑]
#   R-B2-M1 : 멀티스테이지 + 비루트(appuser, UID 1001) 실행
#
# [버전 핀 출처]
#   docs/tech-stack-versions.md
#     - 베이스 이미지: python:3.13-slim-bookworm  (Python 3.13.13 기준)

# =============================================================================
# Stage 1) builder — 의존성을 venv 에 설치
# =============================================================================
FROM python:3.14-slim-bookworm AS builder

# 빌드 작업 디렉토리. 이 stage 는 어차피 버려지므로 위치 자체는 자유.
WORKDIR /build

# 필요 시 컴파일에 쓰일 시스템 도구. 현재 의존성(asyncpg, pydantic, uvicorn) 은
# python:3.13-slim 환경의 wheel 이 모두 존재하므로 이 RUN 은 주석 처리.
# (만약 wheel 이 없는 패키지가 추가되면 아래를 활성화하여 컴파일 가능하게 한다)
# RUN apt-get update \
#     && apt-get install -y --no-install-recommends gcc libc6-dev \
#     && rm -rf /var/lib/apt/lists/*

# 격리된 venv 에 의존성을 설치하면, runtime stage 에 venv 디렉토리만 복사하면 된다.
# venv 를 쓰지 않고 pip install 하면 시스템 site-packages 가 오염되어
# 후속 layer 에서 어떤 파일이 새로 추가됐는지 추적이 어렵다.
RUN python -m venv /opt/venv

# venv 의 python/pip 가 우선 검색되도록 PATH 를 prepend.
# ENV 는 image 환경변수로 영구 적용되며 이후 RUN/CMD 에 모두 영향.
ENV PATH="/opt/venv/bin:$PATH" \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# requirements.txt 만 먼저 복사해 install 하면, 그 위에 main.py 만 바뀌었을 때
# 의존성 layer 가 캐시되어 빌드 시간이 크게 줄어든다 (Docker layer caching 의 핵심).
COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install -r requirements.txt

# =============================================================================
# Stage 2) runtime — 최소한의 실행 이미지
# =============================================================================
FROM python:3.14-slim-bookworm AS runtime

# OCI 표준 라벨. GHCR 등이 이 라벨을 보고 image ↔ source repo 를 자동 연결한다.
LABEL org.opencontainers.image.source="https://github.com/melanieing/cicd-project" \
      org.opencontainers.image.licenses="MIT"

# 비루트 사용자 생성. UID 1001 / GID 1001 / 홈디렉토리 미생성(-M) / 셸 nologin
# K8s 의 securityContext.runAsUser/runAsGroup 와 일치시켜 podSecurityPolicy 를 통과.
ARG APP_UID=1001
ARG APP_GID=1001
RUN groupadd --system --gid ${APP_GID} appuser \
    && useradd  --system --no-create-home --shell /usr/sbin/nologin \
                --uid ${APP_UID} --gid ${APP_GID} appuser

# builder stage 에서 만든 venv 를 그대로 가져온다. 이 한 줄이 layer 1개로 압축됨.
COPY --from=builder /opt/venv /opt/venv

# 런타임에서도 venv 의 binaries 를 우선 사용.
# PYTHONDONTWRITEBYTECODE=1 : .pyc 파일 미생성 (이미지 클린 + 권한 이슈 회피)
# PYTHONUNBUFFERED=1        : print/log 출력을 즉시 flush (k8s logs 가 실시간으로 받음)
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# 애플리케이션 코드 설치 위치. /app 자체는 root 소유로 두고, 안의 파일만 appuser 권한.
WORKDIR /app
COPY --chown=appuser:appuser main.py /app/

# uvicorn 이 듣는 컨테이너 포트. 외부에 publish 되지 않더라도 K8s 가
# Service.targetPort 와 매칭하는 데 활용된다 (문서적 의미 + image 메타데이터).
EXPOSE 8000

# root 에서 appuser 로 권한 강하. 이 시점 이후의 RUN/CMD 는 모두 appuser 로 실행.
USER appuser

# 컨테이너 시작 명령. exec form([..]) 을 쓰면 PID 1 이 uvicorn 이 되어
# K8s 가 보내는 SIGTERM 을 직접 수신해 graceful shutdown 가능.
# shell form (= "uvicorn ...") 을 쓰면 PID 1 이 sh 가 되어 시그널 전파가 깨진다.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]

# HEALTHCHECK 는 K8s Probe 로 대체하므로 Dockerfile 에는 의도적으로 두지 않는다
# (K8s 환경에서 Docker HEALTHCHECK 는 무시되며 중복 부담만 됨).
