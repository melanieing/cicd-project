# kind 클러스터 부팅 실패 — 윈도우 호스트의 Bitnami WAMP Apache 가 80 점유

## Summary

`Docker Desktop` 을 제거하고 WSL2 Ubuntu 24.04 에 native docker CLI 를 설치한 직후, `./scripts/bootstrap.sh` 가 첫 노드 컨테이너 생성 단계에서 `failed to bind host port 0.0.0.0:80/tcp: address already in use` 로 실패했다. WSL2 안에서는 `ss -tlnp` / `lsof -i :80` / `docker ps -a` 모두 비어 있었지만, Windows 호스트의 `netstat -ano | findstr :80` 가 PID 7312 의 `httpd.exe` 를 LISTENING 상태로 잡고 있었다. 이 프로세스의 정체는 사용자가 과거에 설치한 **Bitnami WAMP stack 8.0.11** 의 `wampstackApache` 윈도우 서비스 (Auto-start) 였고, Docker Desktop 시절에는 자체 네트워크 layer 가 이 충돌을 우회시켜 줬는데 native docker 로 바꾸면서 충돌이 처음으로 표면화됐다. 해당 서비스를 `Stop-Service` + `Set-Service -StartupType Manual` 로 중지·자동시작 해제하니 80 포트가 비고 kind 부팅이 정상 진행됐다.

## Symptom

```
melan@LAPTOP-4A5QH4PB:~/cicd-project$ ./scripts/bootstrap.sh
[*] Checking prerequisites
[OK] All prerequisites present
[*] Creating kind cluster 'payment' from /home/melan/cicd-project/kind-config.yaml
Creating cluster "payment" ...
 ✓ Ensuring node image (kindest/node:v1.33.0) 🖼
 ✗ Preparing nodes 📦 📦 📦
Deleted nodes: ["payment-control-plane" "payment-worker2" "payment-worker"]
ERROR: failed to create cluster: command "docker run --name payment-control-plane ...
  --publish=0.0.0.0:80:80/TCP --publish=0.0.0.0:443:443/TCP ...
" failed with error: exit status 125
Command Output: ...
docker: Error response from daemon: failed to set up container networking:
  driver failed programming external connectivity on endpoint payment-control-plane (...):
  failed to bind host port 0.0.0.0:80/tcp: address already in use
```

WSL2 안에서 본 모든 진단 결과가 "80 을 쓰는 프로세스 없음" 이었다.

```bash
sudo ss -tlnp | grep ':80 '         # 비어있음
sudo lsof -i :80                     # 비어있음
docker ps -a                         # 컨테이너 0개
sudo systemctl list-units --type=service --state=active | grep -iE 'apache|nginx|httpd|caddy'
                                     # 비어있음
```

테스트 차원에서 단순 컨테이너 한 개를 띄우는 명령에서도 같은 에러가 재현되었다.

```bash
docker run --rm -d --name test80 -p 80:8080 nginx:alpine
# Error response from daemon: ... failed to bind host port 0.0.0.0:80/tcp: address already in use
```

`docker info` 상단에는 Docker Desktop 잔재로 추정되는 dangling cli-plugin symlink 들이 다수 (`docker-desktop`, `docker-extension`, `docker-buildx` 등 14 개) `input/output error` 로 경고 출력 중이었다. `sudo systemctl restart docker` 로 daemon 을 재시작했지만 동일 증상.

## Investigation & Root cause

### 가설 1 (오답): WSL2 내부의 좀비 프로세스가 80 점유

`ss -tlnp`, `lsof`, `ps aux | grep docker-proxy` 모두 비어 있어서 WSL2 안에는 80 을 잡고 있는 프로세스가 없음을 확인. 가설 기각.

### 가설 2 (오답): Docker Desktop 잔재 (dangling cli-plugin) 가 daemon 동작을 방해

`docker info` 의 cli-plugin warning 은 분명히 잔재이지만, 그건 docker CLI 의 부가 기능 layer 이고 daemon 자체의 네트워크 동작에는 영향이 없다. daemon 재시작 후에도 동일 증상이라 가설 기각.

### 가설 3 (정답): Windows 호스트가 80 을 점유

WSL2 의 docker 가 `--publish 0.0.0.0:80:80` 으로 host port 를 잡으려 할 때, WSL2 의 host network namespace 는 Windows 호스트의 네트워크 스택과 일정 수준 공유된다 (특히 IPv4 의 `0.0.0.0` 바인딩). Windows 측이 80 을 이미 잡고 있으면 WSL2 docker 는 `EADDRINUSE` 를 받고 `address already in use` 로 보고한다.

Windows PowerShell 에서 진단:

```powershell
PS> netsh http show iplisten
# 비어있음 — 즉 Windows 의 HTTP.sys 커널 리스너가 점유한 건 아님

PS> netstat -ano | findstr :80
TCP    0.0.0.0:80             0.0.0.0:0              LISTENING       7312
TCP    [::]:80                [::]:0                 LISTENING       7312

PS> tasklist /FI "PID eq 7312"
이미지 이름           PID 세션 이름        세션#   메모리 사용
==================  ====  ==============  ====    ==========
httpd.exe           7312  Services           0        108 K
```

`httpd.exe` 는 Apache HTTP Server 의 표준 바이너리 이름. PID 의 세션이 `Services / 0` 인 것은 Windows 서비스로 등록되어 자동 기동되었다는 신호.

해당 PID 가 어떤 서비스인지 정확히 식별:

```powershell
PS> Get-CimInstance -ClassName Win32_Service |
    Where-Object { $_.ProcessId -eq 7312 } |
    Select-Object Name, DisplayName, StartMode, PathName

Name            DisplayName     StartMode PathName
----            -----------     --------- --------
wampstackApache wampstackApache Auto      "C:\Bitnami\wampstack-8.0.11-0\apache2\bin\httpd.exe" -k runservice
```

→ 사용자가 과거 PHP/MySQL 로컬 개발용으로 설치한 **Bitnami WAMP stack 8.0.11** 의 Apache 가 부팅 시 자동 기동되어 80 을 점유 중이었다. 사용자는 본 도구의 존재 자체를 한참 잊고 있었던 상태.

#### Docker Desktop 시절에는 왜 충돌이 안 났는가

Docker Desktop 은 Windows 호스트에서 Hyper-V VM 으로 분리된 자체 Linux VM 안에서 docker daemon 을 띄우고, **포트 publish 를 자기 Windows 측 named pipe / vmsproxy 로 우회** 시킨다. 그 결과 Windows 호스트의 80 이 이미 다른 프로세스에 점유 중이어도, Docker Desktop 의 publish layer 가 `192.168.1.x:80` 같은 별도 IP 에 매핑하거나 충돌을 silently 무시했을 것으로 추정. 이는 documented 동작은 아니지만 다수의 user report 에서 일치하는 패턴.

native docker on WSL2 는 그런 우회 layer 가 없어, host port 점유 충돌이 그대로 표면화된다.

## Fix

### 즉시 복구 (Windows PowerShell **관리자 권한**)

```powershell
# 1. 정확한 서비스 이름으로 즉시 중지
Stop-Service -Name wampstackApache -Force

# 2. 부팅 시 자동 시작 안 하도록 변경 (Manual 로 둠 — 필요할 때 수동 기동 가능)
Set-Service -Name wampstackApache -StartupType Manual

# 3. 80 점유 해제 확인
netstat -ano | findstr ":80 "
# 출력이 비어있으면 성공
```

### 검증 (WSL2 셸)

```bash
docker run --rm -d --name test80 -p 80:8080 nginx:alpine
# 정상 기동되어야 함
docker rm -f test80

./scripts/bootstrap.sh
# kind 클러스터 정상 생성
```

### 사용자가 빠진 함정

`Stop-Service -Name "<SVC>"` 의 `<SVC>` 자리에 `httpd.exe` 같은 프로세스 바이너리 이름을 넣으려고 시도해서 `NoServiceFoundForGivenName` 에러가 두 번 났다. `Stop-Service` 의 `-Name` 인자는 **Windows 서비스의 정식 이름** (예: `wampstackApache`) 이어야 하고, 프로세스 이미지 이름과 다를 수 있다. PID → 서비스 이름 매핑은 `Get-CimInstance Win32_Service | Where-Object ProcessId -eq <PID>` 로 얻어야 함.

## Lessons learned

1. **WSL2 docker 의 host port 충돌 진단은 양쪽 OS 를 모두 봐야 한다.** WSL2 셸의 `ss -tlnp`, `lsof`, `docker ps` 가 모두 비어 있어도 Windows 호스트가 같은 포트를 점유하고 있으면 docker 의 `-p` 바인딩은 실패한다. 진단 순서는 (a) WSL2 안 → (b) docker daemon state → (c) Windows 호스트 (`netstat -ano | findstr ":<port> "`) 까지 가야 완결.

2. **`docker run -p <port>:...` 한 줄 테스트로 kind 와의 분리 진단을 빨리 해야 한다.** kind 의 에러 메시지만 보면 kind 특유의 문제처럼 느껴지는데, `docker run -p 80:8080 nginx:alpine` 한 줄에서 같은 에러가 재현되면 그 즉시 "kind 와 무관한 docker/host 문제" 로 가설 공간을 좁힐 수 있다. 진단 비용이 매우 낮다.

3. **Docker Desktop 의 layer 가 가려주던 호스트 포트 충돌은 native docker 로 바꾸면 표면화된다.** 익숙한 환경이 바뀐 직후의 첫 실행에서 새로운 종류의 문제가 나타나면, "전 환경이 가려주던 문제가 드러난 것" 이라는 가설을 항상 후보에 둬야 한다. Docker Desktop 의 unique behavior 한 두 개를 정리해두면 다음에 비슷한 상황에서 빨리 인식할 수 있다.

4. **PID → Windows 서비스 이름 매핑은 `tasklist` 가 아닌 `Get-CimInstance Win32_Service` 가 필요.** `tasklist /FI "PID eq <pid>"` 는 프로세스 바이너리 이름만 알려주고, `Stop-Service` 가 받아야 하는 서비스 이름은 별개. 이 두 단계를 한 명령으로 합치는 것이 다음에 같은 일을 할 때의 가속 포인트.

5. **방어 장치: bootstrap.sh 에 호스트 포트 사전 점검을 추가하는 것이 가능.** kind-config.yaml 이 publish 하려는 포트 목록 (현재 80, 443, 30080-30082, 36515) 을 클러스터 생성 전에 `nc -z` 또는 `ss -tln` 로 점검해 사용 중인 포트가 있으면 명확한 메시지로 abort 하면, 다음번에 누가 같은 함정에 빠져도 30 초 안에 진단된다. 본 사건 후 `scripts/bootstrap.sh` 의 prerequisite check 단계 보강을 백로그에 추가하면 좋다 (별도 follow-up task — 본 사건 fix 와 분리해 별도 commit 으로).
