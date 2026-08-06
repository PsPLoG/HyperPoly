# HyperPoly 오디오 스택 장애 복구 계획

## 1. 목적

NAM과 convolution reverb 등 고부하 플러그인을 동시에 사용할 때 CPU deadline miss, JACK shutdown, LV2 플러그인 crash, OOM 또는 socket 단절이 발생하더라도 장비가 사용자 개입 없이 다시 연주 가능한 상태로 복구되도록 한다.

이 문서는 구현 코드가 아니라 후속 작업을 여러 서브에이전트가 독립 PR로 수행할 수 있도록 실패 모델, 서비스 관계, 복구 순서, 금지사항, 검증 기준을 정의한다.

복구 목표는 다음과 같다.

1. Ingen/JACK 오디오 경로의 치명적 장애를 확실히 감지한다.
2. 반쯤 살아 있는 Ingen 프로세스를 남기지 않는다.
3. systemd가 Ingen과 UI를 하나의 복구 단위로 다시 시작한다.
4. UI 재시작 후 저장된 프리셋을 기준으로 graph와 화면을 다시 동기화한다.
5. 재시작 루프를 제한하고 안전한 fallback을 제공한다.
6. JACK buffer, sample rate, RT priority 또는 CPU affinity를 변경하지 않는다.

## 2. 현재 코드에서 확인된 실패 공백

### 2.1 JACK shutdown 뒤 Ingen이 계속 실행될 수 있음

`ingen-main/src/server/JackDriver.cpp`의 shutdown callback은 `_is_activated = false`, `_client = nullptr`만 설정한다. Engine quit 또는 non-zero process exit로 이어지지 않는다.

결과적으로 JACK client는 사라졌지만 Ingen main loop, socket, systemd unit은 살아 있는 반고장 상태가 가능하다. 이 상태에서는 `Restart=on-failure`도 동작하지 않는다.

### 2.2 activation 실패가 상위로 전달되지 않음

- `JackDriver::activate()`는 `jack_activate()` 실패를 반환하지만 내부 상태를 완전히 되돌리지 않는다.
- `Engine::activate()`는 driver activation 결과를 확인하지 않는다.
- `ingen` main은 `Engine::activate()` 결과를 확인하지 않는다.

따라서 오디오가 실제로 활성화되지 않았는데 프로세스는 정상 실행 상태가 될 수 있다.

### 2.3 LV2 plugin fault가 Ingen 전체 프로세스를 종료할 수 있음

`LV2Block::run()`은 `lilv_instance_run()`을 프로세스 내부에서 직접 호출한다. SIGSEGV, abort, assertion, 메모리 손상은 Ingen 전체를 종료시킬 수 있다.

이 계획은 RT callback에서 신호를 잡아 계속 실행하는 위험한 복구를 시도하지 않는다. 프로세스 격리가 없는 현재 구조에서는 깨끗한 process restart가 안전한 복구 경계다.

### 2.4 UI socket 스레드가 단절 후 복구되지 않음

`digit_ui/ingen_wrapper.py`의 송수신 스레드는 socket 오류가 발생하면 traceback을 남기고 종료될 수 있다.

- `ingen_started`를 `False`로 되돌리지 않는다.
- 새 `Remote` 객체를 생성하지 않는다.
- 종료된 스레드를 재시작하지 않는다.
- stale outbound queue를 처리하는 정책이 없다.
- `/main`, `/engine` snapshot을 다시 요청하지 않는다.

따라서 Ingen만 재시작하는 방식은 현재 UI와 자동 동기화되지 않는다.

### 2.5 서비스 unit 파일은 저장소에서 검증할 수 없음

저장소에는 배포된 `ingen.service`, `polyui.service` 원본이 펼쳐진 텍스트 형태로 포함돼 있지 않다. 구현 전 실제 장비에서 아래 결과를 증거로 PR에 첨부해야 한다.

```bash
systemctl cat ingen
systemctl cat polyui
systemctl show ingen polyui \
  -p FragmentPath -p DropInPaths -p Restart -p RestartUSec \
  -p StartLimitIntervalUSec -p StartLimitBurst \
  -p After -p Requires -p Wants -p PartOf -p BindsTo
```

unit 이름이 이미지별로 다르면 실제 이름을 사용하고 문서에 차이를 기록한다.

## 3. 복구 아키텍처 결정

### 3.1 systemd가 복구 오케스트레이터가 됨

UI Python 프로세스가 `systemctl restart ingen`을 직접 호출하지 않는다. 권한, 경쟁 조건, 재시작 루프, 종료 순서 문제를 피하기 위해 서비스 관리 책임은 systemd에 둔다.

권장 구조는 별도 target을 두는 방식이다.

```text
hyperpoly-audio.target
  ├─ ingen.service
  └─ polyui.service
```

두 서비스가 장비에서 이미 다른 target에 묶여 있다면 새 target 대신 drop-in으로 동일한 의미를 구현할 수 있다. 구현 PR은 실제 장비 unit을 조사한 후 가장 작은 변경을 선택한다.

### 3.2 실패 시 두 프로세스를 같이 재시작

목표 동작:

```text
JACK shutdown / Ingen crash / Ingen activation failure
    -> ingen.service non-zero exit
    -> polyui.service stop
    -> Ingen과 UI가 정해진 순서로 재시작
    -> Ingen readiness 확인
    -> UI 시작
    -> 저장된 프리셋 복원
    -> UI snapshot 동기화 완료
    -> 사용자 입력 활성화
```

단순히 `PartOf=ingen.service`만 추가하면 start/stop 전파 방향을 잘못 이해할 수 있으므로 실제 unit dependency를 `systemctl show`와 fault injection으로 검증해야 한다.

권장 구현 후보:

- `polyui.service`
  - `Requires=ingen.service`
  - `After=ingen.service`
  - `PartOf=hyperpoly-audio.target`
- `ingen.service`
  - `PartOf=hyperpoly-audio.target`
- target 또는 복구 helper
  - 두 unit의 restart를 한 transaction으로 수행

`BindsTo=`는 unit이 inactive가 되는 모든 경우 UI까지 강제로 내릴 필요가 검증된 경우에만 사용한다. 의도적인 Ingen stop, 업데이트, 진단 작업에 미치는 영향을 확인하지 않고 적용하지 않는다.

### 3.3 readiness는 `/tmp/ingen.sock` 존재만으로 판정하지 않음

오래된 socket 파일이 남아 있을 수 있으므로 다음 단계로 readiness를 판정한다.

1. Ingen process active
2. Unix socket connect 성공
3. `/main` 또는 별도 ping 요청 전송 성공
4. 유효한 응답 수신
5. graph restore가 필요한 경우 restore 완료 event 수신

systemd `Type=notify` 지원을 추가할 수 있다면 Ingen이 JACK activation과 socket listen 완료 후 `READY=1`을 보내는 방식이 가장 명확하다. 변경 범위가 크면 첫 단계에서는 별도 readiness helper를 사용한다.

고정 sleep만으로 readiness를 판정하지 않는다.

## 4. 상태 복원 정책

### 4.1 source of truth

장애 복구 후 source of truth는 재시작 전 UI 메모리가 아니라 영속 저장된 상태다.

우선순위:

1. 마지막으로 성공적으로 로드 또는 저장된 preset 경로
2. 영속 pedal state에 기록된 마지막 정상 preset index/path
3. 안전 preset
4. Empty preset

UI 메모리에만 존재하고 저장되지 않은 knob 변경은 process crash 후 보장하지 않는다. 향후 journal 방식 상태 저장은 별도 기능으로 분리한다.

### 4.2 마지막 정상 상태 기록

다음 두 상태를 구분한다.

- `requested_preset`: 사용자가 로드를 요청한 preset
- `last_known_good_preset`: Ingen에서 preset load 완료 event를 받은 preset

복구 시 `last_known_good_preset`만 자동 로드한다. 로드 중 crash한 preset을 다시 자동 로드하면 무한 crash loop가 생길 수 있다.

기록은 atomic replace로 수행한다.

```text
write temporary file
fsync temporary file when required
rename temporary -> final
```

GUI thread에서 `os.sync()`를 호출하지 않는다.

### 4.3 crash-loop 방지와 safe mode

다음 정보를 영속 또는 systemd 상태로 관리한다.

- 최근 복구 시각
- 연속 실패 횟수
- 실패 중 로드 중이던 preset
- 마지막 정상 preset
- safe mode 진입 여부

예시 정책:

- 60초 안에 3회 실패하면 해당 preset 자동 복원을 중단
- 안전 preset 또는 Empty preset으로 부팅
- UI에 "Audio recovered in safe mode" 표시
- 사용자가 명시적으로 preset을 선택하기 전 문제 preset을 자동 재로드하지 않음

정확한 횟수와 시간은 장비 재현 결과로 결정한다. systemd `StartLimitIntervalSec`와 `StartLimitBurst`도 함께 설정해 무한 restart와 CPU/스토리지 소모를 막는다.

## 5. Ingen 내부 수정 계획

## AUR-00 — 장애 기준선과 실제 unit 조사

**위험도:** 없음

### 작업

- 실제 장비 unit 전체 내용과 dependency graph 수집
- NAM + 각 reverb 유형별 CPU/xrun/crash 재현
- fault가 JACK shutdown, process crash, OOM, UI socket 단절 중 무엇인지 분류
- exit code, signal, coredump, `NRestarts`, JACK port 변화를 기록

### 필수 로그

```bash
systemctl status ingen polyui --no-pager -l
systemctl show ingen polyui -p ActiveState -p SubState -p Result \
  -p ExecMainCode -p ExecMainStatus -p NRestarts
journalctl -b -u ingen -u polyui --no-pager
journalctl -b -k --no-pager | grep -Ei 'oom|killed process|segfault|thermal'
coredumpctl list --no-pager
jack_lsp
```

### 완료 조건

- 최소 하나의 실제 장애를 재현하고 failure class를 확정
- unit 파일과 배포 위치 확인
- 복구 시간 측정 기준 정의

---

## AUR-01 — JACK shutdown과 activation 실패를 process failure로 승격

**의존성:** AUR-00

### 대상

- `ingen-main/src/server/JackDriver.cpp`
- `ingen-main/src/server/JackDriver.hpp`
- `ingen-main/src/server/Engine.cpp`
- `ingen-main/src/ingen/ingen.cpp`

### 구현 지침

- JACK callback에서는 atomic failure flag와 최소한의 상태만 기록
- callback 내부에서 일반 logging, allocation, lock, cleanup, systemd 호출 금지
- main/non-RT thread가 failure flag를 감지해 engine quit 수행
- JACK shutdown은 최종적으로 non-zero exit
- `jack_activate()` 성공 후에만 activated 상태 설정
- `Engine::activate()`가 driver 결과를 전파
- `ingen` main이 activation 실패 시 `EXIT_FAILURE` 반환
- 가능하면 shutdown status/reason을 non-RT 경로에서 기록

### 금지사항

- RT callback 안에서 재연결
- RT callback 안에서 plugin 제거
- signal handler로 plugin crash를 잡고 처리를 계속하는 방식
- JACK period/sample rate 변경

### 테스트

- JACK server 강제 종료
- Ingen 시작 시 JACK unavailable
- socket listener 생성 실패
- 정상 종료와 장애 종료의 exit code 구분

### 완료 조건

- 반고장 Ingen 프로세스가 남지 않음
- systemd가 failure로 인식 가능한 exit status 제공

---

## AUR-02 — systemd 공동 재시작 단위 구성

**의존성:** AUR-00, AUR-01

### 대상

실제 패키지/이미지에서 확인된 unit 소스 또는 drop-in 설치 경로.

### 구현 지침

- Ingen failure 시 UI도 종료하고 두 서비스를 순서대로 재시작
- Ingen readiness 전 UI 시작 금지
- 정상 사용자 stop과 failure restart를 구분
- `Restart=on-failure` 또는 실제 운영 정책을 명시
- 적절한 `RestartSec` 부여
- `StartLimitIntervalSec`, `StartLimitBurst` 설정
- update script가 unit 변경을 설치하고 daemon-reload하도록 구성
- 기존 부팅 target과 enable 상태 유지

### 권장 테스트 matrix

| 상황 | 기대 결과 |
|---|---|
| Ingen SIGSEGV | UI stop 후 두 서비스 복구 |
| Ingen exit 1 | 동일 |
| JACK shutdown | Ingen failure exit 후 동일 |
| UI SIGSEGV | UI만 재시작하거나 정책에 따라 전체 재시작 |
| 관리자가 `systemctl stop hyperpoly-audio.target` | 재시작하지 않고 둘 다 정지 |
| update 중 service stop | restart loop 없음 |
| 연속 3회 crash | start limit 또는 safe mode 작동 |

### 완료 조건

- 서비스 재시작 transaction이 결정적
- zombie socket/process 없음
- 업데이트와 수동 stop 동작이 손상되지 않음

---

## AUR-03 — Ingen readiness 제공

**의존성:** AUR-01

### 선택지 A: `Type=notify`

- socket listen 완료
- JACK activation 성공
- 초기 graph 준비 완료
- 이후 `READY=1`

### 선택지 B: readiness helper

- socket connect
- 상태 요청
- 유효 응답 확인
- timeout 시 non-zero

### 금지사항

- `/tmp/ingen.sock` 파일 존재만 확인
- 고정 0.2초/2초 sleep만 사용
- readiness 검사를 RT thread에 추가

### 완료 조건

- UI가 준비 전 Ingen에 연결을 시도하지 않음
- stale socket을 정상으로 오인하지 않음

---

## AUR-04 — UI startup 동기화 상태 머신

**의존성:** AUR-02, AUR-03

### 대상

- `digit_ui/show_widget.py`
- `digit_ui/ingen_wrapper.py`
- 필요 시 작은 전용 connection state 모듈

### 상태

```text
STARTING
  -> CONNECTING
  -> SYNCING
  -> RESTORING_PRESET
  -> READY

실패 시
  -> DEGRADED
  -> process exit 또는 제한된 reconnect 정책
```

systemd가 UI를 같이 재시작하는 것이 기본이므로 첫 구현에서는 복잡한 무한 in-process reconnect를 만들지 않는다. 시작 중 일시적 연결 실패에는 제한된 retry만 허용하고, deadline 초과 시 UI도 non-zero exit하여 systemd transaction으로 복구한다.

### 동기화 절차

1. 새 `ingen.Remote` 객체 생성
2. socket connect
3. `/main`과 `/engine` 상태 요청
4. snapshot 시작 전 UI graph 모델 초기화
5. ordered snapshot event 적용
6. snapshot 완료 marker 확인
7. last-known-good preset 복원이 필요하면 요청
8. `pedalboard_loaded` 확인
9. `/main` 재조회 또는 최종 consistency check
10. 사용자 입력과 MIDI preset 변경 활성화

### 중요 정책

- SYNCING 동안 knob/footswitch command를 보내지 않음
- 입력을 무한 queue하지 않음
- stale outbound queue는 폐기
- UI 모델과 Ingen graph가 일치한 후 READY
- 화면에는 복구 상태를 표시하되 오디오 RT path에 로그를 추가하지 않음

### 완료 조건

- Ingen/UI 공동 재시작 후 stale module이 화면에 남지 않음
- graph, 연결선, enabled 상태, file/model 상태가 일치
- READY 이전 명령 유실/역재생 없음

---

## AUR-05 — last-known-good preset과 safe mode

**의존성:** AUR-04

### 대상

- `digit_ui/show_widget.py`
- 영속 pedal state helper
- 필요 시 QML recovery banner

### 구현 지침

- preset 요청 시 requested 기록
- `pedalboard_loaded` 성공 후 last-known-good 갱신
- startup 시 last-known-good 복원
- 동일 preset 로드 중 반복 crash 감지
- 임계 초과 시 Empty 또는 안전 preset 로드
- safe mode 진입 이유를 UI와 journal에 기록

### 금지사항

- load 완료 전에 last-known-good 갱신
- 모든 knob 조작마다 동기 파일 쓰기
- GUI thread에서 `os.sync()`
- crash한 preset을 무한 자동 재로드

### 완료 조건

- 정상 preset은 자동 복원
- 문제 preset은 반복 crash 후 격리
- power loss로 상태 파일이 손상되지 않음

---

## AUR-06 — UI socket 오류 처리 강화

**의존성:** AUR-04

### 구현 지침

- `sendall`, `recv`, EOF에서 socket error 분류
- 송수신 스레드 종료를 main thread에 전달
- silent thread death 금지
- connection generation ID로 이전 socket event 폐기
- process 종료 중 발생한 expected error와 runtime failure 구분
- UI main이 READY 상태에서 connection을 잃으면 제한 시간 내 clean non-zero exit

공동 systemd restart가 기본 복구이므로, reconnect와 service restart를 동시에 경쟁시키지 않는다. 향후 무중단 reconnect는 별도 PR로 분리한다.

### 완료 조건

- Ingen 단절 후 UI가 stale 상태로 계속 실행되지 않음
- systemd가 UI failure도 관찰 가능

---

## AUR-07 — 통합 fault injection과 장시간 검증

**의존성:** AUR-01~06

### fault injection

- `kill -SEGV`로 Ingen crash
- `kill -KILL`로 비정상 종료
- JACK server stop
- socket 파일 삭제가 아닌 실제 socket 단절
- UI process crash
- 잘못된 NAM model path
- NAM + stereo/quad convolution reverb 고부하
- OOM은 안전한 시험 환경에서만 제한적으로 수행

### 합격 기준

- 치명적 장애 감지부터 READY까지 목표 시간 기록
- 20회 연속 fault injection 모두 자동 복구
- 복구 후 실제 audio I/O 확인
- last-known-good preset 일치
- UI graph와 Ingen graph 일치
- footswitch/encoder/MIDI 정상
- restart storm 없음
- journal 및 persistent storage 폭증 없음
- sample rate, JACK period, RT priority, affinity 변화 없음

### 권장 초기 목표

- 일반 process crash: 10초 이내 READY
- JACK restart가 필요한 장애: 장비 실제 부팅 구조를 측정해 별도 목표 설정
- 연속 장애 임계 초과 시 1분 안에 safe mode 도달

수치는 AUR-00 기준 측정 후 조정한다.

## 6. 작업 의존성

```text
AUR-00 baseline / unit investigation
  └─ AUR-01 Ingen failure propagation
       ├─ AUR-02 systemd joint restart
       └─ AUR-03 readiness
            └─ AUR-04 UI startup synchronization
                 ├─ AUR-05 last-known-good / safe mode
                 └─ AUR-06 socket failure handling
                      └─ AUR-07 integrated fault injection
```

각 Task ID는 별도 Draft PR로 구현한다. AUR-02와 AUR-04를 하나의 PR로 묶지 않는다. unit dependency 문제와 UI state 문제를 독립적으로 롤백할 수 있어야 한다.

## 7. 공통 실시간 안전 규칙

- JACK callback에서는 atomic flag 또는 async-safe notification만 허용
- RT callback에 파일 IO, logging, allocation, mutex, subprocess, sleep 추가 금지
- UI 또는 service 복구를 위해 JACK buffer/sample rate를 늘리지 않음
- UI priority를 올리지 않음
- 플러그인 run을 RT thread에서 try/catch로 감싸면 SIGSEGV가 해결된다고 가정하지 않음
- 자동 bypass 또는 graph mutation은 RT callback에서 수행하지 않음
- 복구용 상태 저장은 non-RT worker에서 수행

## 8. 서브에이전트 PR 계약

각 PR 본문은 다음 내용을 포함한다.

```markdown
## Task ID
AUR-XX

## Failure class
JACK shutdown / process crash / activation failure / socket disconnect / state restore

## Scope
수정 파일과 unit/drop-in 경로

## State transitions
변경 전후 상태 전이

## Real-time safety
RT callback에 추가된 작업이 없는지 설명

## Service semantics
정상 stop, failure, update, boot에서의 동작

## Fault injection
사용한 명령과 결과

## Measurements
failure detection, process restart, readiness, UI sync, audio-ready 시간

## Persistent state
last-known-good, crash counter, atomic write 방식

## Rollback
unit drop-in 제거, feature flag 또는 commit revert 절차

## Hardware validation
장비/image/version과 결과
```

장비 검증이 불가능하면 `hardware validation required` 상태로 유지하고 완료를 주장하지 않는다.

## 9. 브랜치와 PR 규칙

- 브랜치: `agent/audio-recovery-aur-XX-<description>`
- 하나의 PR에는 하나의 Task ID만 포함
- 모든 PR은 Draft로 시작
- unit 변경 PR은 설치·업데이트·롤백 스크립트를 함께 검증
- Ingen C++ 변경과 UI Python 변경을 한 PR에 섞지 않음

## 10. 명시적 제외 범위

- JACK sample rate/period 변경
- RT priority, nice, CPU affinity 변경
- NAM 또는 reverb DSP 알고리즘 최적화
- LV2 plugin process isolation 구현
- 커널 watchdog, 하드웨어 watchdog 전체 설계
- 모든 실시간 UI 상태의 영속 journal
- 사용자 미저장 knob 변경의 완전 복원

이 항목들은 별도 프로젝트로 다룬다.

## 11. 권장 구현 순서

1. AUR-00으로 실제 failure와 unit을 확정
2. AUR-01로 반고장 Ingen을 제거
3. AUR-02로 Ingen/UI 공동 restart를 구현
4. AUR-03으로 readiness를 보장
5. AUR-04로 UI 초기 동기화를 결정적으로 변경
6. AUR-05로 문제 preset crash loop를 차단
7. AUR-06으로 silent socket thread death를 제거
8. AUR-07으로 반복 fault injection 후 단계별 rollout

첫 배포 단계에서는 기능 flag 또는 쉽게 제거 가능한 systemd drop-in을 사용한다. 복구가 오히려 restart storm을 만들면 즉시 기존 부팅 정책으로 롤백할 수 있어야 한다.
