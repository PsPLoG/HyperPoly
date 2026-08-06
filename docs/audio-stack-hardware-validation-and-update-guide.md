# HyperPoly 오디오 스택 실기기 측정·장애 복구 검증·업데이트 가이드

## 1. 목적

이 문서는 `docs/audio-stack-failure-recovery-plan.md`를 구현하기 전에 실기기에서 수집해야 할 정보, 구현 후 장애 복구를 검증하는 방법, 오디오 스택을 안전하게 업데이트하고 롤백하는 절차를 정의한다.

목표는 다음과 같다.

- NAM과 리버브 동시 사용 중 발생하는 CPU deadline miss, xrun, JACK shutdown, Ingen/LV2 crash, OOM, UI socket 단절을 구분한다.
- 장비의 실제 systemd unit, JACK 설정, package와 updater 동작을 추측하지 않고 증거로 확정한다.
- 모든 AUR 구현 PR이 같은 시나리오, 지표, 판정 기준으로 비교되게 한다.
- Ingen 또는 UI 장애 뒤 두 서비스가 정상 복구되고 `/main`, `/engine` 상태가 동기화되는지 검증한다.
- update 실패 또는 bad preset 반복 crash 시 이전 정상 상태로 되돌릴 수 있게 한다.

`SIGSEGV`, JACK 중단, 반복 crash, 잘못된 model/IR 시험은 백업된 실험 장비에서만 수행한다.

---

## 2. 시험 전 안전 조건

### 필수 준비

- 안정적인 전원과 SSH 또는 serial console을 확보한다.
- master output을 mute하거나 안전한 level로 낮춘다.
- 현재 정상 image, package, preset, service unit을 백업한다.
- storage free space, filesystem 오류, 장비 시간과 timezone을 확인한다.
- crash 시험 장비가 production 공연·녹음 경로와 분리됐는지 확인한다.
- update USB와 rollback payload의 SHA-256을 확보한다.

### 즉시 중단 조건

- thermal shutdown 또는 심한 throttling
- 지속적인 full-scale noise나 DC 의심 출력
- filesystem I/O error 또는 read-only 전환
- 반복 reboot로 console 접근 불가
- rollback artifact 미확보
- package maintainer script 또는 panel hardware revision 미확인

실시간 callback에 측정을 위한 logging, file I/O, lock, allocation, subprocess를 추가하지 않는다. 측정 중 JACK sample rate, period, scheduler priority, nice, CPU affinity를 바꾸지 않는다.

---

## 3. 측정 세션 식별 정보

모든 세션은 다음을 기록한다.

| 분류 | 필수 항목 |
|---|---|
| 장비 | device/asset ID, serial, PCB·panel revision, display type |
| firmware | image/firmware version, build ID, Git commit 또는 package version |
| 오디오 | backend/device, sample rate, period size/count, input/output port |
| preset | preset ID, 파일 hash, module 수, connection 수 |
| NAM | model 익명 ID, 파일 크기/hash, metadata |
| reverb | module 종류, IR channel/sample rate/sample 수/길이/크기/hash |
| 환경 | ambient temperature, 전원, USB/MIDI 연결, 입력 신호와 level |
| 결과 | 수행자, 시각/timezone, diagnostics bundle 경로와 SHA-256 |

proprietary NAM model, IR, 사용자 preset은 Git에 첨부하지 않는다. 익명 ID와 hash만 기록한다.

---

## 4. Read-only 진단 수집

PR에 포함된 수집기를 root로 실행한다.

```bash
sudo bash tools/collect-audio-stack-diagnostics.sh
```

출력 위치 지정:

```bash
sudo bash tools/collect-audio-stack-diagnostics.sh \
  /tmp/hyperpoly-audio-diagnostics-before
```

수집기는 service를 stop, restart, signal하거나 설정을 수정하지 않는다. 다음을 수집한다.

- OS, kernel, uptime, mount, storage, memory
- CPU governor/frequency, thermal zone
- systemd service 목록, unit 본문과 주요 속성
- process/thread scheduler, CPU, memory와 limits
- 설치 package version
- JACK port/connection/CPU load
- `/tmp/ingen.sock`과 UNIX socket 상태
- Ingen/UI journal, OOM, segfault, xrun, thermal 관련 로그
- coredump 목록
- updater와 `/pedal_state` 파일 inventory

root가 아니거나 장비에 command가 없어서 누락된 정보는 숨기지 않고 결과에 기록한다.

---

## 5. AUR-00에서 반드시 확정할 정보

### 5.1 service와 dependency

```bash
systemctl list-units --type=service --all --no-pager \
  | grep -Ei 'ingen|polyui|jack|audio|update|usb|panel'

systemctl list-unit-files --type=service --no-pager \
  | grep -Ei 'ingen|polyui|jack|audio|update|usb|panel'

systemctl cat ingen.service
systemctl cat polyui.service

systemctl show ingen.service polyui.service \
  -p FragmentPath -p DropInPaths \
  -p ExecStart -p ExecStop -p User -p Group \
  -p WorkingDirectory -p Environment \
  -p Restart -p RestartUSec -p NRestarts \
  -p StartLimitIntervalUSec -p StartLimitBurst \
  -p OOMPolicy -p KillMode \
  -p TimeoutStartUSec -p TimeoutStopUSec \
  -p After -p Before -p Requires -p Wants -p PartOf -p BindsTo
```

JACK unit 이름은 추측하지 말고 목록에서 먼저 식별한다. 다음 질문에 답해야 한다.

1. JACK은 system unit, user unit, 직접 실행 중 어느 방식인가?
2. Ingen은 JACK readiness를 어떻게 기다리는가?
3. UI는 socket 존재만 기다리는가, 상태 응답까지 확인하는가?
4. Ingen failure가 UI stop/restart로 전파되는가?
5. maintenance stop이 crash counter와 restart policy에 포함되는가?
6. `Restart=`와 start limit은 무엇인가?
7. overlay filesystem에서 package와 unit 변경은 어디에 지속되는가?

### 5.2 package와 maintainer script

설치 전에 모든 `.deb`를 조사한다.

```bash
mkdir -p /tmp/hyperpoly-package-inspection

for package in /usb_flash/*.deb; do
  name=$(basename "$package")
  dpkg-deb --info "$package" \
    > "/tmp/hyperpoly-package-inspection/${name}.info.txt"
  dpkg-deb --contents "$package" \
    > "/tmp/hyperpoly-package-inspection/${name}.contents.txt"
  mkdir -p "/tmp/hyperpoly-package-inspection/${name}.control"
  dpkg-deb --control "$package" \
    "/tmp/hyperpoly-package-inspection/${name}.control"
done

sha256sum /usb_flash/*.deb \
  > /tmp/hyperpoly-package-inspection/SHA256SUMS

grep -RniE \
  'systemctl|service |invoke-rc.d|start-stop-daemon|reboot|shutdown|/boot|overlay' \
  /tmp/hyperpoly-package-inspection/*.control
```

`preinst`, `postinst`, `prerm`, `postrm`이 service를 직접 restart하는지 확인한다. package 파일명만 보고 설치 순서를 정하지 않는다.

### 5.3 updater entrypoint

```bash
systemctl list-unit-files --no-pager | grep -Ei 'update|usb|panel'
journalctl -b --no-pager | grep -Ei 'usb_flash|dpkg|update|panel'
```

updater unit/script, package 설치 순서, 중간 실패 처리, reboot 조건, persistent marker 위치를 확정한다.

---

## 6. 현재 저장소 update artifact 검토

### 전체 USB package 묶음

`update/beebo_hector_338_unzip_copy_to_usb/`에는 frontend, Ingen, module, content, startup fix package가 함께 있다. 폴더 자체에는 설치 순서, checksum manifest, transaction, rollback 설명이 없다. 실제 장비 updater가 이를 어떻게 처리하는지 AUR-00에서 확인하기 전에는 production update 절차로 간주하지 않는다.

### panel-only update

`update/panel_update_only_04052026/`의 script는 firmware와 panel version을 확인하고 DTB를 복사한 뒤 reboot한다. 현재 script에는 source/destination checksum, 기존 DTB backup, atomic replace, 실패 rollback, hardware allowlist가 명시돼 있지 않다.

panel DTB update는 audio service update와 같은 transaction에 묶지 않는다. panel update는 boot 불능 위험이 있으므로 별도 recovery media와 offline rollback 절차가 필요하다.

---

## 7. 기준선 측정 matrix

각 시나리오는 2분 warm-up 후 최소 10분 smoke, 30분 baseline, 필요한 경우 2시간 soak를 수행한다. cold boot와 동일 boot 내 warm start를 구분한다.

| ID | 구성 | 목적 |
|---|---|---|
| `HW-B00` | empty 또는 bypass graph | OS/JACK/UI 최소 기준 |
| `HW-B01` | NAM only | model별 CPU·memory 기준 |
| `HW-B02` | short/internal reverb only | 내부 convolution 기준 |
| `HW-B03` | stereo/zeroconvolv reverb only | 외부 convolution 기준 |
| `HW-B04` | NAM + short reverb | 중간 조합 |
| `HW-B05` | NAM + stereo reverb | 주요 장애 재현 조합 |
| `HW-B06` | NAM + 최대 지원 IR | worst supported 조합 |
| `HW-B07` | preset 전환 반복 | load/unload, memory 회수 |
| `HW-B08` | encoder/footswitch/MIDI 집중 입력 | control latency와 sync |
| `HW-B09` | 2시간 soak | thermal, leak, 누적 xrun |

NAM과 IR은 작은·중간·최대 크기로 분류하고 파일 크기뿐 아니라 model metadata, IR channel과 sample 수도 기록한다.

---

## 8. 측정 지표

### 오디오/realtime

- JACK sample rate, period size/count
- xrun 시작/종료값과 count/min
- DSP load min/mean/p95/p99/max
- audio dropout 횟수와 최대 길이
- round-trip latency
- JACK port 이름, 수와 connection

UI 표시용으로 변환된 DSP 값이 아니라 가능한 원천 값과 timestamp를 사용한다.

### process/system

- 전체와 per-core CPU
- JACK, Ingen, UI process CPU
- thread scheduler class, RT priority, nice, CPU 번호
- RSS/PSS, available memory, swap
- page fault, context switch, load average
- CPU governor/frequency, 온도와 throttling
- storage free space, I/O error
- cgroup limit, OOM score와 OOM kill 여부

### UI/Ingen 동기화

READY 전에 다음을 비교한다.

- preset ID
- module type·수와 connection endpoint
- bypass와 주요 control 값
- NAM model과 reverb IR ID
- `/main`, `/engine` snapshot 완료
- 장애 전 stale outbound command가 남지 않음
- sync 중 hardware/MIDI/QML command가 전송되지 않음

UI 화면이 보인다는 사실만으로 READY로 판정하지 않는다. Ingen graph와 UI model을 비교한다.

---

## 9. 복구 시간 T0–T5

모든 장애 시험은 monotonic clock으로 기록한다.

| 시각 | 정의 |
|---|---|
| `T0` | fault를 적용한 시각 |
| `T1` | supervisor 또는 UI가 장애를 감지한 시각 |
| `T2` | 실패한 Ingen process가 종료된 시각 |
| `T3` | 새 Ingen이 socket 연결과 상태 응답이 가능한 시각 |
| `T4` | 새 UI가 `/main`, `/engine` snapshot을 마치고 READY가 된 시각 |
| `T5` | 실제 input에서 정상 output이 확인된 시각 |

계산 항목:

- 감지: `T1 - T0`
- 종료: `T2 - T1`
- Ingen 재가동: `T3 - T2`
- UI sync: `T4 - T3`
- 실제 audio 복구: `T5 - T0`

일반 process crash의 초기 목표는 `T5 - T0 <= 10초`다. 실기기 기준선상 불가능하면 근거를 남기고 조정한다. 목표를 맞추기 위해 audio buffer를 키우거나 readiness 검증을 생략하지 않는다.

---

## 10. 장애 주입 시험

모든 시험은 lab 장비에서 수행하고 시험 전후 diagnostics bundle을 저장한다.

### Ingen 강제 종료

```bash
sudo systemctl kill --signal=SIGKILL --kill-who=main ingen.service
```

검증:

- systemd가 failure로 기록한다.
- UI도 설계대로 stop/restart된다.
- Ingen/UI PID와 socket이 새로 생성된다.
- last-known-good 또는 safe preset으로 READY가 된다.

### Ingen crash/coredump 경로

```bash
sudo systemctl kill --signal=SIGSEGV --kill-who=main ingen.service
```

exit code, coredump ID, restart 횟수, state 복원을 기록한다. coredump는 model 정보가 포함될 수 있으므로 공유 전에 검토한다.

### JACK shutdown

실제 unit을 확인한 뒤 실행한다.

```bash
sudo systemctl stop <confirmed-jack-unit>
```

JACK callback은 atomic flag 또는 nonblocking notification만 수행해야 한다. Ingen이 port 없이 `active`로 남으면 실패다.

### activation failure

```bash
sudo systemctl stop <confirmed-jack-unit>
sudo systemctl start ingen.service
systemctl status ingen.service --no-pager -l
```

JACK activation이 실패했는데 Ingen이 성공으로 표시되거나 socket만 가진 채 살아 있으면 실패다.

### UI crash와 socket 단절

```bash
sudo systemctl kill --signal=SIGSEGV --kill-who=main polyui.service
```

Ingen 중단으로 socket도 끊어 본다. disconnect 상태 표시, command 차단, stale queue 폐기, full snapshot 재동기화를 확인한다.

### 반복 crash와 bad preset

NAM + stereo reverb 문제 preset으로 제한 시간 내 반복 장애를 발생시킨다.

- `requested`와 `last-known-good`이 분리돼야 한다.
- 임계치 이후 safe/empty preset으로 시작해야 한다.
- 같은 bad preset을 자동 반복 로드하지 않아야 한다.
- restart storm은 start limit으로 bounded돼야 한다.
- 정상 maintenance stop은 crash counter를 증가시키지 않아야 한다.

20회 반복에서 reboot loop, journal 폭증, stale command replay가 없어야 한다.

### OOM

production 장비에서 memory bomb를 사용하지 않는다. 실제 OOM log와 RSS/PSS 추이를 우선 분석한다. 인위적 OOM은 별도 lab image와 제한 cgroup에서 설계 리뷰 후 수행한다.

---

## 11. 원인 판정표

| 관찰 | 우선 의심 | 증거 |
|---|---|---|
| Ingen active, JACK port 없음 | JACK shutdown 후 main loop 생존 | PID, service state, `jack_lsp` |
| exit code 11/coredump | host 또는 LV2 SIGSEGV | journal, backtrace |
| kernel OOM kill | model/IR memory 또는 leak | dmesg, cgroup, RSS/PSS |
| xrun만 증가, process/port 생존 | CPU deadline miss | xrun timestamp, DSP max, per-core CPU |
| audio 지속, control만 정지 | UI socket thread 종료 | UI log, socket, queue |
| Ingen만 새 PID, UI state 과거 값 | startup resync 부재 | snapshot과 graph 비교 |
| 복구 직후 동일 preset 반복 crash | LKG 분리 부재 | crash counter, preset audit |
| update 후 version 일부만 변경 | transaction 불완전 | dpkg log, version/unit hash |

---

## 12. 통과 기준

- JACK shutdown과 activation failure가 non-zero Ingen 종료로 전파된다.
- Ingen과 UI가 하나의 recovery unit으로 재시작된다.
- 새 Ingen이 실제 상태 요청에 응답하기 전 UI가 READY가 되지 않는다.
- `/main`, `/engine` snapshot 완료 전 사용자/MIDI/hardware command 전송은 0건이다.
- stale socket과 command queue 재사용은 0건이다.
- safe-mode 임계치 이후 bad preset 자동 재로드는 0건이다.
- service가 active인데 JACK port가 없는 상태는 readiness window 밖에서 0초다.
- 일반 crash의 초기 `T5 - T0` 목표는 10초 이하이다.
- 20회 반복 복구가 모두 READY 또는 정책대로 bounded safe failure가 된다.
- update 전후 sample rate, period, scheduler/priority/affinity가 동일하다.
- xrun, DSP p99/max, round-trip latency가 승인된 허용 범위 안이다.
- 실제 input/output audio, footswitch, encoder, MIDI가 복구된다.

---

## 13. 결과 artifact 형식

```text
results/<device-id>/<date>-<build-id>/
  session.md
  before/diagnostics.tar.gz
  scenarios/<scenario>-run-<n>/
    timeline.csv
    measurements.csv
    journal.txt
    notes.md
  after/diagnostics.tar.gz
  update/package-inspection/
  update/unit-hashes.txt
  rollback/result.md
```

`timeline.csv` 권장 column:

```text
run_id,event,monotonic_ms,wall_time_iso8601,detail
```

`measurements.csv` 권장 column:

```text
run_id,timestamp,scenario,preset_id,nam_id,ir_id,
dsp_min,dsp_mean,dsp_p95,dsp_p99,dsp_max,
xrun_total,xrun_delta,ingen_cpu,ui_cpu,jack_cpu,system_cpu,
ingen_rss_kb,ui_rss_kb,available_mem_kb,cpu_temp_millic,
frequency_khz,audio_ok,ui_ready,notes
```

대용량 coredump와 proprietary model/IR은 Git에 넣지 않고 artifact 위치와 hash만 남긴다.

---

## 14. Release bundle 요구사항

오디오 스택 release는 최소 다음을 포함한다.

- release ID, 생성 일시, target hardware/image 범위
- package 목록과 설치 순서
- `SHA256SUMS`
- package version matrix
- 변경 unit과 expected hash
- preset/state schema compatibility와 migration
- update 전 최소 free space
- success 판정 명령
- rollback package와 rollback 순서
- known issue와 safe-mode 조건

파일명에 version이 있다는 이유로 manifest를 생략하지 않는다.

---

## 15. Update 전 snapshot과 preflight

```bash
sudo bash tools/collect-audio-stack-diagnostics.sh \
  /tmp/hyperpoly-audio-diagnostics-pre-update

mkdir -p /tmp/hyperpoly-update-backup

dpkg-query -W > /tmp/hyperpoly-update-backup/packages-before.txt
systemctl cat ingen.service \
  > /tmp/hyperpoly-update-backup/ingen.service.txt
systemctl cat polyui.service \
  > /tmp/hyperpoly-update-backup/polyui.service.txt
sha256sum /usb_flash/* \
  > /tmp/hyperpoly-update-backup/usb-SHA256SUMS.txt
```

실제 JACK/updater unit, preset database, `/pedal_state`, hardware metadata, custom model/IR index와 hash, service drop-in을 함께 보존한다.

다음을 모두 통과해야 update한다.

- bundle hash와 target hardware/image 일치
- maintainer script 조사 완료
- rollback bundle과 console 접근 확보
- diagnostics pre-update bundle 생성
- storage/temperature/filesystem 정상
- current last-known-good preset 확인
- maintenance가 crash counter와 구분됨

---

## 16. 권장 Update transaction

AUR-00에서 실제 updater가 확정되기 전에는 아래를 production 명령으로 그대로 사용하지 않는다. updater가 보장해야 할 동작 기준이다.

### U0 — staging

- USB payload를 local staging에 복사한다.
- USB와 staging SHA-256을 비교한다.
- manifest, package metadata, maintainer script를 검사한다.
- rollback payload를 local 또는 recovery media에 준비한다.

### U1 — maintenance 진입

- 사용자 입력과 preset 저장을 차단한다.
- current state를 정상 경로로 flush한다.
- UI, Ingen 순으로 정상 종료한다.
- JACK은 변경 범위에 포함될 때만 종료한다.
- restart policy가 update 중 서비스를 다시 띄우지 않게 한다.
- maintenance stop은 crash counter에 포함하지 않는다.

Python UI가 직접 `sudo systemctl`을 실행하지 않는다. 실제 unit dependency가 확정된 후 systemd target 또는 updater helper로 구현한다.

### U2 — backup과 marker

- package version과 변경 대상 executable/unit hash 저장
- persistent recovery state backup
- `update-in-progress` marker에 release ID, 수행자, 시작 시각 기록
- crash-loop state와 update marker를 분리

### U3 — package 적용

- manifest 순서대로 적용한다.
- 실행 중인 Ingen/UI binary와 unit을 부분 교체하지 않는다.
- maintainer script의 암묵적 restart를 제거하거나 차단한다.
- 중간 실패에서 UI와 Ingen 중 하나만 새 버전으로 시작하지 않는다.
- unit 변경 시에만 `daemon-reload`한다.
- 설치 log와 exit code를 보존한다.

### U4 — 시작 순서와 readiness

```text
JACK start and ready
  -> Ingen start
  -> socket connect
  -> /engine state request succeeds
  -> required JACK ports visible
  -> UI start
  -> /main and /engine snapshot complete
  -> READY
  -> user/MIDI/hardware command enable
```

socket 파일 존재만으로 Ingen READY를 판정하지 않는다.

### U5 — post-update smoke

```bash
systemctl --failed --no-pager
systemctl status ingen.service polyui.service --no-pager -l
jack_lsp -c
```

다음을 확인한다.

- empty/bypass audio
- NAM only, reverb only, NAM + stereo reverb
- preset load/save
- footswitch, encoder, MIDI
- UI graph와 Ingen graph 일치
- 10분 xrun/DSP/temperature
- post-update diagnostics bundle
- package version과 unit hash 일치

### U6 — recovery smoke

recovery 코드나 unit이 변경됐다면 lab 장비에서 다음을 수행한다.

1. Ingen `SIGKILL`
2. UI crash
3. JACK activation failure
4. 정상 maintenance stop/start
5. bad preset safe-mode 진입

출하 전 20회 반복 시험과 2시간 soak를 통과한다.

### U7 — 성공 확정

service와 audio READY, version/hash 일치, diagnostics 생성, rollback 가능 상태를 확인한 뒤에만 marker를 success로 전환한다.

---

## 17. Rollback

### trigger

- Ingen/UI 공동 복구 실패
- 정상 preset 반복 crash
- JACK port 또는 실제 audio 미복구
- UI/Ingen state 불일치
- xrun, DSP, latency 회귀
- package/version mismatch
- unit dependency loop 또는 start limit 반복 도달
- state migration 실패
- boot 또는 panel 비정상

### software rollback 순서

1. maintenance 진입
2. 실패 상태 diagnostics, journal, package/unit hash 보존
3. 이전 bundle hash 검증
4. previous package를 명시된 rollback 순서로 적용
5. 이전 unit/drop-in 복원 후 `daemon-reload`
6. JACK readiness → Ingen readiness → UI sync 순서로 시작
7. last-known-good preset 복원
8. baseline smoke와 recovery smoke 수행
9. rollback diagnostics bundle 생성

Ingen만 이전 버전이고 UI가 새 버전인 상태를 허용하지 않는다.

### panel rollback

panel DTB rollback은 audio package rollback과 분리한다. 기존 DTB byte-for-byte backup, hardware revision 확인, recovery SD/USB 또는 offline boot partition 접근이 필요하다. 현재 panel script에 기존 DTB backup이 없으므로 production panel update 전에 보강해야 한다.

---

## 18. Update 결과 보고서

```markdown
# HyperPoly update result

- Device ID:
- Hardware/panel revision:
- Previous build:
- Target build:
- Release ID:
- Operator:
- Result: PASS / ROLLED BACK / FAILED SAFE

## Payload
- Manifest SHA-256:
- Package SHA-256 result:
- Maintainer scripts reviewed:

## Pre-update
- Diagnostics bundle:
- JACK config:
- Last-known-good preset:
- Service unit hashes:

## Update
- Maintenance entry:
- Service stop/start order:
- Package order:
- Errors/warnings:

## Measurement
- T0-T5:
- DSP p95/p99/max:
- xrun delta:
- CPU/memory/max temperature:
- Audio verified:
- UI/Ingen state verified:

## Fault injection
- Ingen SIGKILL:
- UI crash:
- JACK activation failure:
- Safe mode:

## Rollback
- Required:
- Trigger:
- Result:

## Artifacts
- Diagnostics:
- Journals/coredumps:
- Package/unit hashes:
```

---

## 19. 구현 PR 제출 규칙

AUR-00부터 AUR-07까지 각 PR은 다음을 포함한다.

- 장비 ID와 build
- 수정 전후 diagnostics bundle hash
- test matrix ID
- NAM/IR/preset 익명 ID와 hash
- JACK 설정
- T0–T5 timeline
- DSP/xrun/CPU/memory/thermal 결과
- UI와 Ingen state 비교
- fault injection 결과
- update/rollback 영향
- 실패 run을 포함한 원자료 위치
- 실시간 path에 I/O, lock, logging, allocation을 추가하지 않았다는 분석
- rollback 방법

---

## 20. 실기기에서 아직 확정해야 할 항목

1. 실제 `ingen.service`, `polyui.service`, JACK unit 원문
2. USB updater entrypoint와 package 설치 순서
3. package maintainer script의 restart 동작
4. overlay filesystem persistence 경계
5. Ingen readiness endpoint 또는 검증 방법
6. preset 저장 위치와 last-known-good 확정 시점
7. panel update와 firmware update 호출 관계
8. coredump/journal retention
9. production 장비 최소 free space
10. hardware revision별 DTB allowlist

AUR-00이 이 항목을 실기기 증거로 채우기 전에는 production service dependency와 update command를 확정하지 않는다.

---

## 21. 완료 정의

- 최소 두 hardware/panel revision에서 AUR-00 수집 완료
- 실제 unit과 updater가 version 관리됨
- diagnostics script가 장비에서 bundle을 생성함
- NAM + stereo reverb 장애가 재현되거나 명확히 부정됨
- 일반 crash, JACK shutdown, UI crash의 T0–T5가 측정됨
- 20회 반복 복구와 2시간 soak 통과
- safe mode와 last-known-good 복원 검증
- full audio-stack update와 rollback을 lab 장비에서 각각 1회 이상 성공
- panel rollback 경로 확인
- 다른 운영자가 문서만 보고 같은 측정과 update를 재현할 수 있음
