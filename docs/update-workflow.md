# HyperPoly 업데이트 구조와 작업 절차

이 문서는 HyperPoly에 포함된 업데이트 관련 코드의 동작을 정리한다. 저장소에서 실제 업데이트 로직은 주로 `digit_ui/show_widget.py`와 `digit_ui/dist/iso/` 아래의 셸 스크립트에 있으며, 업데이트 USB의 내용은 실행 시 `/usb_flash`에 마운트된다고 가정한다.

> **중요:** 전체 이미지 업데이트는 `/dev/mmcblk0`에 직접 기록한다. 전원 중단, 잘못된 이미지 또는 잘못된 장치 선택은 부팅 불가와 데이터 손실로 이어질 수 있다. 작업 전 `/pedal_state`, 프리셋, 사용자 파일과 정상 부팅 가능한 이미지를 백업한다.

## 1. 업데이트 방식 개요

HyperPoly에는 성격이 다른 두 가지 업데이트 경로가 있다.

### 1.1 일반 패키지 업데이트 (`.deb`)

UI의 `ui_update_firmware()`는 `/usb_flash/*.deb`를 찾은 뒤 다음 형태로 설치한다.

```bash
sudo /usr/bin/polyoverlayroot-chroot \
  dpkg -i -E -G /usb_flash/*.deb \
  && sync \
  && sudo shutdown -h 'now'
```

이 경로의 특징은 다음과 같다.

- 업데이트 파일은 압축을 풀어 USB 루트에 직접 둔다.
- 설치는 overlay의 임시 상위 계층이 아니라 영구 루트에 반영되도록 `polyoverlayroot-chroot` 안에서 실행한다.
- 성공 시 `sync` 후 자동 종료한다.
- `.deb`가 없으면 `/dev/sda`, `/dev/sda1`, `/dev/sda2` 존재 여부로 USB 미인식, 파티션 없음, 예상보다 많은 파티션, 파일 배치 오류를 구분해 UI에 표시한다.
- 설치 중 표준 출력과 표준 오류는 UI의 상태 메시지로 전달된다.

### 1.2 시스템 이미지·파일시스템 전환 업데이트

`digit_ui/dist/iso/`의 세 스크립트가 이 경로를 담당한다.

| 파일 | 역할 |
| --- | --- |
| `debug.sh` | 현재 펌웨어, overlay 사용 여부, Btrfs 여부를 확인하고 적절한 업데이트 경로를 선택하는 진입점 |
| `install_update.sh` | 부트 설정과 initramfs를 수정해 다음 부팅에서 전체 이미지를 eMMC/SD에 기록하도록 준비 |
| `copy_panel.sh` | 하드웨어 패널 버전에 맞는 DTB를 설치하고 패널 업데이트 상태를 기록 |

## 2. `debug.sh` 흐름

`debug.sh`는 업데이트 USB에서 실행되는 디스패처다.

1. `qml/Settings.qml`에서 현재 펌웨어 버전을 읽는다.
2. `overlayroot-chroot` 위치, overlay 마운트 여부와 lower root의 Btrfs 여부를 확인한다.
3. 로그를 `/usb_flash/debugrun`에 기록한다.
4. 현재 버전이 403 이상이면 이미 새 업데이트 기반이 설치된 것으로 처리한다.
   - `/pedal_state/panel_updated4`가 없으면 `copy_panel.sh`를 실행한다.
   - 버전이 408 미만이면 영구 루트에 `/usb_flash/beebo_update_408.tar.gz`를 풀고 동기화한 뒤 재부팅한다.
5. 현재 버전이 403 미만이면 Ingen, Poly UI, 디스플레이 매니저를 정지한 뒤 `install_update.sh`를 실행한다.
   - overlay와 Btrfs 조합에 따라 `/dev`, `/usb_flash`, 부트 파티션을 영구 lower root에 bind mount한다.
   - overlay가 있으면 `overlayroot-chroot` 안에서 실행하고, 없으면 직접 실행한다.

즉, `debug.sh`는 장치 상태에 따라 **기존 시스템 위 파일 배포** 또는 **다음 부팅에서 전체 이미지 재기록** 중 하나를 선택한다.

## 3. `install_update.sh` 흐름

`install_update.sh`는 전체 이미지 업데이트를 위한 initramfs를 만든다.

### 3.1 사전 준비

- 특정 Btrfs lower-root 상태를 감지하면 종료 코드 `100`으로 빠져나오는 보호 조건이 있다.
- `boot.cmd`에 `skipoverlay overlayroot=disabled`를 추가해 다음 부팅의 overlay 사용을 막는다.
- 현재 DTB에서 패널 식별 문자열을 찾아 패널 버전을 결정한다.
- `/pedal_state/hardware_info.json`이 있으면 USB에 보존한다.
- 진행 표시 도구 `fbtextdemo`를 initramfs에서 사용할 수 있게 복사한다.

### 3.2 initramfs hook

스크립트는 `/etc/initramfs-tools/hooks/flash_iso`를 만들고 다음 항목을 initramfs에 포함한다.

- `fbtextdemo`, 글꼴
- `gzip`, `xargs`, `pv`, `mount`, `cat`
- 화면, USB, 전원, GPU 등에 필요한 커널 모듈

### 3.3 다음 부팅의 이미지 기록

`/etc/initramfs-tools/scripts/init-premount/flash_poly`가 루트 파일시스템 마운트 전에 실행된다.

1. `/dev/sda1`이 생길 때까지 USB 장치를 기다린다.
2. USB를 `/usb_flash`에 마운트한다.
3. 분할된 압축 이미지 `/usb_flash/beebo_407.img.gz.*`를 이어 붙인다.
4. 압축을 해제하면서 `/dev/mmcblk0`에 직접 기록한다.
5. `pv`의 진행률을 `fbtextdemo`로 화면에 표시한다.
6. 기록 후 장치를 동기화하고 재시작 안내를 표시한다.

현재 스크립트에는 다음 값이 하드코딩되어 있다.

```text
이미지 패턴: /usb_flash/beebo_407.img.gz.*
예상 이미지 크기: 15619604992 bytes
대상 블록 장치: /dev/mmcblk0
initrd 파일: /boot/uInitrd-5.4.2-rt5-001
```

새 릴리스를 만들 때는 파일명, 이미지 크기, 커널/initrd 이름과 실제 대상 장치를 반드시 함께 검토해야 한다.

### 3.4 패널 DTB 적용

`local-bottom/copy_panel`은 새 루트가 마운트된 뒤 실행된다.

- `panel_version > 24`: `tsd_panel.dtb`
- `panel_version < 24`: `23_panel.dtb`
- `panel_version < 20`: `18_panel.dtb`가 마지막으로 덮어써짐

`hardware_info.json`과 `panel_version`을 `/pedal_state`에 복원한 뒤 부트 파티션을 동기화한다.

### 3.5 부트 산출물 갱신

- `update-initramfs`로 initramfs를 다시 만든다.
- `mkimage`로 `boot.scr`를 갱신한다.
- 생성된 initrd, `boot.cmd`, `boot.scr`를 overlay lower의 부트 영역에 복사한다.
- 임시 hook과 initramfs 스크립트를 삭제하고 동기화한다.

## 4. `copy_panel.sh` 흐름

`copy_panel.sh`는 전체 이미지를 다시 쓰지 않고 패널 관련 파일만 보정할 때 사용한다.

1. `/dev/mmcblk0p1`을 `/boot`에 마운트한다.
2. `/usb_flash/panel_version`을 읽는다.
3. `hardware_info.json`과 패널 버전을 `/pedal_state`에 보존한다.
4. 버전 구간에 맞는 DTB를 `/boot/boot/dtb/allwinner/sun50i-a64-sopine-baseboard.dtb`로 복사한다.
5. `/pedal_state/panel_updated4`를 만들어 중복 처리를 방지한다.
6. 블록 장치를 동기화한다.

## 5. 업데이트 USB 구성

시스템 이미지 업데이트에서 참조하는 파일을 기준으로 하면 USB 루트에는 다음 항목이 필요하다. 릴리스 방식에 따라 일부만 사용할 수 있다.

```text
/usb_flash/
├── debug.sh
├── install_update.sh
├── copy_panel.sh
├── fbtextdemo
├── beebo_407.img.gz.*
├── beebo_update_408.tar.gz
├── 18_panel.dtb
├── 23_panel.dtb
├── tsd_panel.dtb
└── *.deb
```

운영 시 확인 사항:

- 압축 파일 안에 한 단계 더 들어간 폴더가 생기지 않도록 파일을 USB 루트에 둔다.
- UI 패키지 업데이트는 일반적으로 예상된 단일 파티션의 USB를 전제로 한다.
- 이미지 조각의 개수, 순서, 합계 크기와 체크섬을 배포 전에 검증한다.
- `debugrun` 로그를 보존해 실패 지점을 확인한다.

## 6. 개발 중 영구 변경하기

장치는 기본적으로 overlay 기반의 읽기 전용 환경을 사용한다. 일반 셸에서 `/usr` 등을 변경하면 재부팅 뒤 유지되지 않거나 의도한 lower root에 반영되지 않을 수 있다.

영구 루트에서 작업하려면 다음 명령으로 읽기/쓰기 셸을 연다.

```bash
sudo overlayroot-chroot /bin/bash
```

또는 부팅 설정 자체를 읽기/쓰기 모드로 바꿀 수 있지만, 이는 제품의 기본 보호 모델을 변경하므로 개발 이미지에서만 사용한다.

### 패키지 설치 주의사항

`apt`로 패키지를 설치할 수 있지만 이 장치는 임베디드 시스템이다. 핵심 패키지는 배포판 패키지 대신 소스에서 빌드되어 `--prefix=/usr` 형태로 설치된 경우가 많다.

- `apt upgrade`로 핵심 라이브러리를 일괄 교체하지 않는다.
- Ingen, LV2, 오디오 및 UI 관련 핵심 구성요소는 기존 빌드 옵션과 ABI를 먼저 확인한다.
- 소스 빌드 산출물을 `/usr`에 설치할 때는 반드시 영구 chroot 안에서 실행한다.
- 변경 전 파일 목록과 버전을 기록하고 복구 가능한 패키지 또는 이미지 사본을 유지한다.

## 7. 새 LV2 모듈 추가 절차

새 LV2 모듈을 설치한 뒤에는 UI가 사용하는 캐시를 다시 생성해야 한다.

```bash
cd /home/debian/UI
python3 effect_proto_to_js.py
```

저장소에서 작업할 때는 `digit_ui/`에서 실행해도 된다.

이 스크립트는 `module_info.py`의 모듈 메타데이터를 읽어 CV 입력 수와 기본 입출력 모듈을 보강한 뒤 다음 파일을 다시 쓴다.

```text
digit_ui/qml/module_info.js
```

권장 순서:

1. LV2 bundle을 영구 루트의 적절한 LV2 검색 경로에 설치한다.
2. 모듈 URI, 포트, 타입과 UI 분류가 `module_info.py`에 반영되었는지 확인한다.
3. `python3 effect_proto_to_js.py`를 실행한다.
4. 생성된 `qml/module_info.js` 변경을 함께 커밋한다.
5. Ingen과 UI를 재시작해 모듈 탐색, 추가, 저장, 재로딩을 확인한다.

개발용 실행 명령:

```bash
/usr/bin/ingen -e -p 3 -a /home/debian/start_up.ingen
```

```bash
cd /home/debian/UI
export DISPLAY=:0.0
/usr/bin/python3 show_widget.py
```

Ingen은 프런트엔드 재시작을 안정적으로 처리하지 못할 수 있으므로 UI를 다시 띄우기 전에 실행 중인 UI와 Ingen을 모두 종료한다.

## 8. 검증 체크리스트

### 패키지 업데이트

- [ ] USB가 장치에서 인식되고 예상 파티션 하나를 가진다.
- [ ] `.deb` 파일이 USB 루트에 있다.
- [ ] 설치 대상과 의존성 버전이 현재 펌웨어와 호환된다.
- [ ] `dpkg` 출력에 실패 또는 미설정 패키지가 없다.
- [ ] 종료 전 `sync`가 완료된다.
- [ ] 재부팅 후 서비스, UI, 오디오와 프리셋 로딩을 확인한다.

### 전체 이미지 업데이트

- [ ] `/pedal_state`, 프리셋과 사용자 데이터를 별도 저장한다.
- [ ] 이미지 조각의 체크섬과 합계 크기를 확인한다.
- [ ] 대상 장치가 실제로 `/dev/mmcblk0`인지 확인한다.
- [ ] 안정적인 전원을 연결하고 기록 중 USB와 전원을 제거하지 않는다.
- [ ] `debugrun` 로그와 화면 메시지를 확인한다.
- [ ] 업데이트 후 패널 터치, 화면 방향, 하드웨어 revision과 DTB를 확인한다.
- [ ] 정상 부팅 가능한 복구 이미지를 준비한다.

### LV2 모듈 업데이트

- [ ] LV2 호스트가 bundle을 탐색한다.
- [ ] `effect_proto_to_js.py`를 실행했다.
- [ ] `qml/module_info.js`가 갱신되었다.
- [ ] 모듈 추가/삭제, 프리셋 저장/복원과 포트 연결을 테스트했다.

## 9. 알려진 위험과 개선 권장사항

- 전체 이미지 경로는 버전 번호, 이미지 크기, 커널 파일명과 블록 장치가 하드코딩되어 있다.
- tar 업데이트는 영구 루트 `/`에 직접 풀리므로 트랜잭션이나 자동 롤백이 없다.
- `dpkg -i` 도중 실패하면 일부 패키지만 설치된 상태가 될 수 있다.
- 패널 DTB 선택은 숫자 경계 조건에 의존하므로 새 패널 revision을 추가할 때 조건 순서를 검토해야 한다.
- 배포 패키지에는 체크섬 manifest와 최소/최대 지원 펌웨어 버전을 포함하는 것이 좋다.
- 장기적으로는 업데이트 전 사전 검사, 원자적 배포, A/B 파티션 또는 스냅샷 기반 롤백을 도입하는 것이 안전하다.

## 10. 라이선스

저장소 루트와 각 모듈에는 GPLv2, GPLv3 등 서로 다른 라이선스 파일이 존재할 수 있으며, `install_update.sh`에는 기반 코드의 MIT 라이선스 표기가 있다. 명시적인 헤더가 없는 코드는 유지관리자의 안내에 따라 GPL 코드로 취급한다.

- 각 파일과 하위 프로젝트의 기존 라이선스 헤더를 유지한다.
- 저장소 전체가 단일 라이선스라고 가정하지 않는다.
- 외부 코드나 생성물을 추가할 때 원 저작권과 호환 라이선스를 함께 기록한다.
