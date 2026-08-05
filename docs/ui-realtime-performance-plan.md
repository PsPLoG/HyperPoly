# HyperPoly UI 성능 개선 계획 — 실시간 오디오 안전 우선

## 1. 목적

HyperPoly의 Qt Quick/Python UI에서 발생하는 끊김과 입력 지연을 줄이되, **JACK/Ingen/LV2 실시간 오디오 처리의 레이턴시와 안정성을 절대 악화시키지 않는다.**

이 문서는 구현 코드가 아니라 후속 작업을 여러 서브에이전트가 독립적으로 수행할 수 있도록 범위, 의존성, 금지사항, 검증 기준을 정의한다. 각 작업은 별도 브랜치와 별도 PR로 진행한다.

## 2. 최상위 원칙

1. 오디오 deadline이 UI 프레임보다 항상 우선이다.
2. UI를 빠르게 만들기 위해 프레임 수나 스레드 우선순위를 올리지 않는다. 같은 결과를 더 적은 signal, repaint, Python 작업으로 만든다.
3. JACK sample rate, period size/count, Ingen/LV2 오디오 처리 구조, RT priority, CPU affinity는 이 계획의 범위 밖이다.
4. UI 프로세스나 Qt render thread에 `SCHED_FIFO`, 음수 nice, 오디오보다 높은 우선순위를 부여하지 않는다.
5. 오디오 callback 또는 오디오와 공유되는 경로에 lock, 파일 IO, 로그, subprocess, sleep, 동적 메모리 할당을 추가하지 않는다.
6. **UI → Ingen 파라미터 명령, 풋스위치, 엔코더, MIDI, 프리셋 명령의 순서와 즉시성은 변경하지 않는다.**
7. 메시지 병합은 명시적으로 분류된 **Ingen → UI 표시용 telemetry**에만 적용한다.
8. 모든 동작 변경 PR은 장비 기준 전후 계측 결과 없이는 병합하지 않는다.

## 3. 현재 확인된 병목 후보

아래 항목은 구현 전에 장비에서 다시 계측해야 한다.

- `digit_ui/show_widget.py`
  - `app.exec_()` 대신 `app.processEvents()`, UI 메시지 처리, 하드웨어 입력 처리, `sleep(0.01)`을 반복하는 수동 메인 루프를 사용한다.
  - `process_ui_messages()`가 큐를 빌 때까지 처리하여 한 번의 호출 시간이 제한되지 않는다.
  - 실행 중 `currentEffects`, `portConnections` 같은 큰 객체를 `setContextProperty()`로 다시 설정한다.
  - 일부 Slot에서 `sleep`, subprocess, `os.sync()` 등 블로킹 작업을 수행한다.
- `digit_ui/pedal_hardware.py`
  - 입력 큐를 빌 때까지 한 번에 처리한다.
- `digit_ui/properties.py` 및 `show_widget.py`의 프로퍼티 클래스
  - 값이 동일해도 notify signal을 발생시키는 경로가 있다.
- `digit_ui/ingen_wrapper.py`
  - Ingen 응답을 받을 때마다 `/tmp/ingen.json`을 기록하는 디버그성 파일 IO가 있다.
  - 수신된 상태를 여러 개의 UI 큐 메시지로 변환한다.
- `digit_ui/qml/PatchBay.qml`
  - 큰 `Canvas`에서 배경과 모든 연결선을 JavaScript로 다시 그리는 경로가 있다.
- 튜너, 루퍼, 미터 화면
  - 고빈도 값이 다수의 QML 바인딩, 색상, 위치, 텍스트 갱신으로 전파될 수 있다.

## 4. 실시간 경로 경계

```text
[오디오 경로 — 변경 금지]
JACK RT thread -> Ingen engine -> LV2 DSP -> audio output

[명령 경로 — 순서/즉시성 보존]
footswitch / encoder / MIDI / QML action
    -> UI command handling
    -> Ingen outbound queue/socket
    -> engine parameter/state change

[표시 경로 — 최적화 가능]
Ingen receive thread
    -> ordered state events + latest telemetry
    -> GUI thread
    -> QML bindings / renderer
```

서브에이전트는 작업 전에 자신이 수정하는 코드가 세 경로 중 어디에 속하는지 PR 본문에 명시해야 한다. 경계가 불명확하면 구현하지 않고 조사 결과만 제출한다.

## 5. 공통 병합 게이트

### 오디오 불변 조건

- JACK sample rate와 period 설정이 기준 버전과 동일하다.
- Ingen/JACK/LV2 프로세스와 스레드의 scheduler class, RT priority, nice, CPU affinity가 변경되지 않는다.
- UI 수정 전후 round-trip audio latency가 측정 도구의 오차 범위 안에서 동일하다.
- 기준 스트레스 시나리오에서 xrun이 증가하지 않는다.
- DSP load의 최대값이 기준 대비 2 percentage points 이상 악화되지 않는다. 기준 변동폭이 더 크면 반복 측정 후 허용 범위를 문서화한다.

### 컨트롤 불변 조건

- 풋스위치, 엔코더, MIDI, 프리셋, QML 조작에서 명령 유실 또는 순서 변경이 없어야 한다.
- 입력 발생부터 Ingen outbound enqueue 또는 socket write까지의 p99 지연이 기준 대비 악화되지 않아야 한다.
- 임시 허용치는 동일 장비 timestamp 기준 `+1 ms`이다. 측정 해상도가 더 낮으면 해상도를 기록하고, 한 audio period 이상의 회귀는 허용하지 않는다.

### UI 목표

- 대상 시나리오의 UI 프로세스 CPU 사용량과 p95 frame time을 기록한다.
- 단순히 FPS 상한을 올리는 방식은 금지한다.
- 각 PR은 자신이 겨냥한 병목에서 측정 가능한 작업량 감소를 보여야 한다.

## 6. 기준 스트레스 시나리오

모든 동작 변경 PR은 가능한 한 동일한 프리셋과 동일한 입력으로 아래를 수행한다.

1. DSP load를 실제 운용 상한에 가깝게 구성한다. 목표 범위는 70–90%이며 장비가 안정적으로 재현 가능한 값을 기록한다.
2. 연결선이 많은 PatchBay를 표시하고 모듈을 이동한다.
3. 튜너 broadcast를 활성화한다.
4. 루퍼/미터 화면을 활성화한다.
5. 엔코더를 빠르게 회전하고 풋스위치를 반복 입력한다.
6. 프리셋을 로드하고 화면을 전환한다.
7. 최소 30분 동안 xrun, DSP load, UI CPU, frame time, control dispatch latency를 기록한다.

권장 관찰 명령 예시:

```bash
ps -eLo pid,tid,cls,rtprio,pri,ni,psr,comm,args \
  | grep -E 'jack|ingen|python|Xorg'

QSG_INFO=1 /usr/bin/python3 /home/debian/UI/show_widget.py \
  2>&1 | tee /tmp/hyperpoly-qsg.log

glxinfo -B
```

장비 이미지에 `jack_iodelay`, `perf`, `pidstat` 등이 없으면 사용 가능한 도구와 측정 한계를 결과 문서에 남긴다.

## 7. 작업 분할과 의존성

```text
RTUI-00 Baseline / instrumentation
  ├─ RTUI-01 동일 값 notify 억제
  ├─ RTUI-02 Ingen 수신 hot-path 파일 IO 제거
  └─ RTUI-03 QML visibility/repaint 억제
       └─ RTUI-04 표시용 telemetry 분리 및 병합
            ├─ RTUI-05 Qt 이벤트 루프 전환
            └─ RTUI-06 안정적인 Qt model/context 구조
                 └─ RTUI-07 PatchBay renderer 개선
RTUI-08 GUI 블로킹 작업 분리 — RTUI-00 이후 독립 진행 가능
RTUI-09 통합 스트레스/롤아웃 — 각 단계 후 반복
```

`RTUI-05`, `RTUI-06`, `RTUI-07`을 하나의 PR에 묶지 않는다. 회귀가 생겼을 때 원인을 분리하고 쉽게 롤백하기 위해서다.

---

## RTUI-00 — 기준선과 계측 도구

**위험도:** 없음 또는 매우 낮음  
**목적:** 이후 PR을 동일한 조건으로 검증할 수 있는 기준을 만든다.

### 범위

- 장비의 JACK/Ingen/UI/Xorg 프로세스 및 thread scheduling 정보 수집
- QSG renderer/backend 확인
- xrun, DSP load, UI CPU, frame time, control dispatch latency 수집 방법 정의
- 재현 가능한 stress preset과 조작 절차 문서화
- 가능하면 실행 시 production 동작을 변경하지 않는 계측 스크립트 추가

### 권장 파일

- `tools/ui-rt-benchmark.sh` 또는 저장소 관례에 맞는 도구 경로
- `docs/ui-realtime-benchmark.md`

### 금지사항

- 서비스 우선순위, affinity, JACK 설정 변경
- production 코드에 상시 로그 추가
- 오디오 callback 계측을 위해 lock 또는 파일 IO 추가

### 완료 조건

- 기준 commit, 장비 이미지/version, 프리셋, sample rate/period, 측정 시간을 기록한다.
- 최소 3회 반복 결과와 변동폭을 남긴다.
- 후속 PR에서 그대로 재사용할 수 있는 명령과 판정 기준을 제공한다.

---

## RTUI-01 — 동일 값 프로퍼티 notify 억제

**위험도:** 낮음  
**의존성:** RTUI-00

### 대상

- `digit_ui/properties.py`
- `digit_ui/show_widget.py`의 `PolyBool`, `PolyStr`, `PolyValue` 및 유사 클래스
- 같은 패턴이 있는 Python QObject 프로퍼티

### 구현 지침

- setter가 실제 값 변경 시에만 notify signal을 emit하도록 한다.
- 첫 단계에서는 float epsilon을 도입하지 않고 정확히 동일한 값만 제거한다.
- setter가 반복 호출 자체를 트리거로 사용하는 예외가 있는지 호출처를 조사한다.
- 리스트/딕셔너리 wrapper는 실제 mutation 여부를 판단할 수 있을 때만 signal을 생략한다.

### 금지사항

- UI → Ingen outbound 파라미터 전송률 또는 순서 변경
- 튜너/미터 값에 임의의 quantization 적용

### 테스트

- 동일 값 설정 시 signal 0회, 변경 값 설정 시 signal 1회
- bool/string/float/list/dict에 대한 단위 테스트
- 기존 QML 화면의 값 갱신이 누락되지 않는 장비 테스트

### 완료 조건

- 오디오/컨트롤 병합 게이트 통과
- 대상 화면에서 notify 및 binding reevaluation 횟수가 감소함을 증명

---

## RTUI-02 — Ingen 수신 hot-path 파일 IO 제거

**위험도:** 낮음  
**의존성:** RTUI-00

### 대상

- `digit_ui/ingen_wrapper.py`

### 구현 지침

- 매 수신마다 `/tmp/ingen.json`을 기록하는 동작을 제거한다.
- 디버깅에 필요하면 기본 OFF인 환경 변수 또는 명시적 debug option으로만 활성화한다.
- debug dump가 활성화돼도 rate limit 또는 ring buffer 방식으로 수신 thread를 장시간 막지 않게 한다.
- `json.loads()` 이후의 parse 순서와 UI event 생성 의미는 유지한다.

### 테스트

- 동일한 Ingen payload에서 생성되는 논리 이벤트가 변경 전후 동일한지 fixture 테스트
- 파일 dump 기본 비활성 확인
- malformed payload 처리와 thread 생존 확인

### 완료 조건

- 정상 실행에서 수신당 파일 open/write가 발생하지 않는다.
- xrun과 control latency가 기준보다 악화되지 않는다.

---

## RTUI-03 — 보이지 않는 화면과 불필요한 repaint 억제

**위험도:** 낮음–중간  
**의존성:** RTUI-00

### 대상 후보

- `digit_ui/qml/PatchBay.qml`
- `digit_ui/qml/Tuner.qml`
- `digit_ui/qml/Loopler.qml`
- 미터, animation, broadcast를 사용하는 화면

### 구현 지침

- 화면이 보이지 않을 때 표시 전용 animation, repaint, broadcast 구독을 중지한다.
- PatchBay는 연결 또는 geometry가 변하지 않았으면 `requestPaint()`를 호출하지 않는다.
- 정적 배경과 동적 연결선을 분리하고, 좌표 계산 결과를 재사용한다.
- 기존 FPS 상한을 높이지 않는다.
- visibility 전환 시 현재 상태를 한 번 동기화해 stale 화면을 방지한다.

### 금지사항

- 오디오 분석 자체 또는 DSP broadcast 생성 로직 변경
- 표시 중인 튜너/미터의 의미 있는 최종 값 누락
- animation을 부드럽게 보이게 하기 위한 무제한 timer 사용

### 완료 조건

- 숨겨진 화면의 repaint/binding 작업이 중지됨을 확인
- 다시 표시할 때 즉시 최신 상태가 나타남
- 오디오/컨트롤 병합 게이트 통과

---

## RTUI-04 — ordered event와 표시용 telemetry 분리

**위험도:** 중간  
**의존성:** RTUI-01, RTUI-02, RTUI-03 권장

### 목적

현재 UI queue를 모두 동일하게 처리하지 않고, 순서를 반드시 보존해야 하는 event와 마지막 값만 필요로 하는 표시용 telemetry를 분리한다.

### 반드시 순서 보존할 event

- plugin/module add/remove
- connection add/remove
- pedalboard/preset loaded
- MIDI program change
- 풋스위치, 엔코더, 사용자 action
- UI → Ingen outbound command 전체

### 병합 가능한 후보

명시적인 검증 후 다음과 같은 **Ingen → UI 표시 전용 값**만 `(object, parameter)`별 latest value로 병합한다.

- 튜너 `cent`, `freq_out`, `rms`
- level meter
- DSP load 표시
- 화면에만 사용되는 고빈도 broadcast 값

### 구현 지침

- `ordered_events`와 `latest_telemetry`를 별도 자료구조로 둔다.
- telemetry flush는 GUI refresh cadence에 맞추되 30–60 Hz 범위에서 장비 화면 주사율과 CPU 결과로 결정한다.
- ordered event는 starvation되지 않도록 우선 처리한다.
- 한 번의 GUI 처리 시간에 budget을 두되, 남은 ordered event를 버리지 않는다.
- event 분류표와 이유를 코드 주석 또는 문서로 유지한다.

### 금지사항

- outbound queue coalescing
- 구조 event 삭제, 재정렬 또는 latest-only 처리
- 입력 event를 frame timer까지 지연

### 테스트

- 구조 event 순서 보존 property test
- telemetry burst에서 마지막 값 보존
- 서로 다른 object/parameter가 잘못 합쳐지지 않음
- ordered event가 telemetry 폭주 중에도 처리됨

### 완료 조건

- telemetry burst 시 GUI thread의 최대 처리 시간이 줄어든다.
- control dispatch latency와 xrun이 기준보다 악화되지 않는다.

---

## RTUI-05 — 표준 Qt 이벤트 루프로 전환

**위험도:** 높음  
**의존성:** RTUI-04, 장비 기준 계측 필수

### 대상

- `digit_ui/show_widget.py`
- `digit_ui/pedal_hardware.py`
- 관련 thread/queue 연결 코드

### 구현 지침

- 수동 `while` + `app.processEvents()` + `sleep(0.01)` 루프를 `app.exec_()` 기반으로 전환한다.
- 하드웨어 입력은 read thread 또는 notifier에서 Qt queued signal/invoke로 즉시 전달한다.
- ordered event 도착 시 event-driven wakeup을 사용한다.
- 표시용 telemetry만 제한된 cadence로 flush한다.
- shutdown 순서와 background thread join을 명시한다.
- GUI thread에서 큐를 무제한 drain하지 않는다.

### 금지사항

- 모든 입력을 16 ms/33 ms timer 하나에 묶기
- busy loop
- GUI/render thread priority 상승
- audio/Ingen RT thread와 공유 lock 추가

### 테스트

- 시작, 정상 종료, 강제 종료, Ingen disconnect/reconnect
- 풋스위치/엔코더/MIDI burst
- telemetry 폭주와 plugin graph 변경 동시 수행
- 기존 기능의 callback 순서 회귀 테스트

### 완료 조건

- control p99가 기준보다 악화되지 않는다.
- UI frame pacing이 개선되고 xrun 증가가 없다.
- 문제 발생 시 이전 루프로 쉽게 되돌릴 수 있는 작은 diff 또는 임시 feature flag를 제공한다.

---

## RTUI-06 — runtime context reset을 안정적인 Qt model로 교체

**위험도:** 중간–높음  
**의존성:** RTUI-04. RTUI-05와 같은 PR에 포함하지 않는다.

### 대상

- `digit_ui/show_widget.py`의 runtime `setContextProperty()` 호출
- `currentEffects`, `portConnections` 및 관련 QML 소비 코드

### 구현 지침

- startup 시 context object를 한 번 등록하고 런타임에는 object signal 또는 `QAbstractListModel`의 `rowsInserted`, `rowsRemoved`, `dataChanged`를 사용한다.
- model 변경은 GUI thread에서만 수행한다.
- model이 Ingen/audio thread와 lock을 공유하지 않게 한다.
- 한 PR에서는 하나의 model만 전환하여 회귀 범위를 제한한다. 권장 순서는 `portConnections` 후 `currentEffects`이다.

### 금지사항

- 전체 QML context를 주기적으로 재등록
- model 갱신을 위해 audio thread 대기
- model refactor와 PatchBay renderer 전체 교체를 동일 PR에 포함

### 완료 조건

- 대상 데이터 변경 시 관련 row/object만 갱신된다.
- plugin/connection add/remove 기능과 순서가 유지된다.
- binding reevaluation과 GUI CPU가 감소한다.

---

## RTUI-07 — PatchBay renderer 개선

**위험도:** 높음  
**의존성:** RTUI-03, RTUI-06 권장

### 조사 순서

1. 기존 Canvas에서 불필요한 full repaint와 JS 계산을 먼저 제거한다.
2. 결과가 부족하면 QML `Shape` 또는 segment object 방식의 prototype을 비교한다.
3. 그래도 부족할 때만 C++ `QQuickItem`/scene graph geometry 구현을 검토한다.

### 구현 지침

- 연결선 geometry를 변경 시에만 계산한다.
- 정적 배경은 별도 item/cache로 분리한다.
- module 이동 중 필요한 연결만 갱신한다.
- renderer 선택은 A/B 계측 결과로 결정한다.

### 금지사항

- 근거 없이 전체 UI를 C++로 재작성
- 모든 frame에서 전체 connection graph 재생성
- antialias/sample 수를 증가시켜 CPU/GPU load 악화

### 완료 조건

- 대표 graph 크기별 frame time 결과 제공
- 시각적 결과 비교 screenshot 또는 영상 제공
- xrun/DSP load/control gate 통과

---

## RTUI-08 — GUI thread의 블로킹 작업 분리

**위험도:** 중간  
**의존성:** RTUI-00 이후 독립 가능

### 대상 후보

- `digit_ui/show_widget.py`의 `sleep`, subprocess, 파일 복사/삭제, `os.sync()` 호출 Slot
- 프리셋 저장/내보내기, 모델 변경, 입력 레벨 설정 등

### 구현 지침

- 작업을 worker thread/process로 이동하고 완료/error를 queued signal로 GUI에 전달한다.
- worker가 QML/QObject를 직접 수정하지 않게 한다.
- 동작 중 중복 실행 방지와 UI 상태를 제공한다.
- 오디오 엔진 상태 변경이 필요한 작업은 명령 순서를 유지하고 완료 조건을 명확히 한다.

### 금지사항

- worker thread priority 상승
- audio/Ingen RT thread와 lock 공유
- subprocess 완료를 GUI thread에서 polling하는 busy loop

### 완료 조건

- 해당 기능 실행 중 GUI event loop가 장시간 멈추지 않는다.
- 저장/내보내기 결과와 오류 처리가 기존 의미를 유지한다.
- 오디오 gate 통과

---

## RTUI-09 — 통합 검증과 단계적 롤아웃

각 동작 변경 PR 직후 기준 스트레스 시나리오를 반복한다. 여러 변경을 한꺼번에 쌓은 뒤 마지막에만 측정하지 않는다.

### 롤아웃 원칙

- 저위험 PR: RTUI-01 → RTUI-02 → RTUI-03 순으로 먼저 배포 가능
- 중위험 PR: 장비 A/B 검증 후 제한 배포
- 고위험 PR: feature flag 또는 즉시 되돌릴 수 있는 패키지 준비
- xrun, control 지연, 명령 유실이 한 번이라도 재현되면 해당 단계 배포 중단

### 배포 패키지

장비 USB 패치 생성과 설치는 `docs/update-workflow.md`를 따른다. UI-only 변경은 실제 설치 경로 `/home/debian/UI/...`와 기존 파일 권한을 유지한다.

## 8. 서브에이전트 작업 계약

각 서브에이전트는 한 Task ID만 맡고 다음 형식을 PR 본문에 작성한다.

```markdown
## Task
RTUI-XX

## 경로 분류
- Audio RT path: 변경 없음
- Command path: 변경/변경 없음과 이유
- Display path: 변경 내용

## 변경 범위
- 수정 파일
- 의도적으로 수정하지 않은 파일

## 실시간 안전성
- 새 lock/IO/subprocess/sleep 여부
- scheduler/priority/affinity 영향 여부
- event ordering 영향 여부

## 검증
- 기준 commit 및 장비 정보
- JACK 설정
- xrun / DSP load
- control latency median/p99
- UI CPU / frame time
- 반복 횟수와 원시 로그 위치

## 롤백
- revert 방법
- feature flag가 있다면 이름과 기본값
```

### 브랜치와 PR 규칙

- 브랜치: `agent/ui-rt-<task-id>-<short-description>`
- 한 PR에는 한 Task ID만 포함한다.
- PR은 처음에는 Draft로 연다.
- 기능 변경과 광범위한 포맷팅/이름 변경을 섞지 않는다.
- 테스트할 실제 장비가 없으면 코드 구현을 완료했다고 주장하지 않고, `hardware validation required` 상태로 유지한다.

## 9. 완료 정의

다음 조건을 모두 만족하면 전체 계획을 완료한 것으로 본다.

- 기준 시나리오에서 오디오 round-trip latency와 JACK 설정이 유지된다.
- xrun이 기준보다 증가하지 않는다.
- 풋스위치/엔코더/MIDI/프리셋 명령의 유실과 순서 회귀가 없다.
- PatchBay, 튜너, 루퍼의 p95 frame time과 UI CPU가 개선된다.
- 고빈도 telemetry가 구조 event나 사용자 입력을 starvation시키지 않는다.
- 실시간 경로에 새 blocking operation이나 shared lock이 없다.
- 각 변경은 독립 PR과 측정 자료가 있어 개별 롤백 가능하다.

## 10. 이 계획에서 명시적으로 제외하는 작업

- JACK buffer를 키워 xrun을 숨기는 변경
- sample rate 변경
- LV2 DSP 알고리즘 최적화 또는 음질 변경
- Ingen 엔진 구조 변경
- 커널 RT patch, CPU governor, IRQ affinity 변경
- UI를 다른 framework로 전면 재작성
- UI → Ingen 명령 coalescing 또는 automation 해상도 축소

위 항목은 필요하면 별도 RFC와 별도 오디오 측정 계획으로 다룬다.
