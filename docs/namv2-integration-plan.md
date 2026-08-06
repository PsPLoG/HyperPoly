# NAMv2 독립 모듈 추가 계획

## 목표

이미 설치된 기존 NAM(`amp_nam`)을 유지하면서 NAMv2를 `amp_namv2`라는 별도 LV2/UI 모듈로 추가한다. 두 모듈은 LV2 URI와 model-loading property뿐 아니라 모델 파일 저장소와 USB import 동작도 분리한다.

## 기존 NAM 연결 구조

현재 UI에서 NAM은 다음 경로로 연결된다.

1. `module_info.py`의 `amp_nam`이 기존 LV2 plugin URI에 매핑된다.
2. `AmpBrowser.qml`과 `amp_browser_model.py`가 `/mnt/audio/amp_nam`의 metadata와 모델 파일을 표시한다.
3. 설정 화면의 `COPY AMPS` 버튼이 `/usb_flash/amps` 내용을 `/mnt/audio/amp_nam`으로 가져온다.
4. `show_widget.py`의 `update_json()`이 선택된 파일을 `ingen_wrapper.set_json_nam()`으로 보낸다.
5. `set_json_nam()`은 기존 NAM의 model property URI로 `patch:Set`을 보낸다.
6. `effect_proto_to_js.py`가 Python metadata를 QML 캐시로 변환한다.

따라서 NAMv2는 plugin URI만 등록해서는 충분하지 않다. 실제 TTL의 plugin URI, model property, Atom control port, audio/control port symbol, 모델 파일 형식과 저장 경로까지 한 세트로 분리해야 한다.

## 구현 선택

### 플러그인 독립성

- 기존 모듈 ID: `amp_nam`
- 신규 모듈 ID: `amp_namv2`
- 기존 NAM URI와 `set_json_nam()`은 유지한다.
- NAMv2 전용 `set_json_namv2()`를 추가한다.
- 프리셋에는 NAMv2의 별도 LV2 URI와 모델 경로가 저장된다.

### 모델 파일 독립성

기존 NAM과 NAMv2는 서로 다른 모델 파일을 사용하므로 다음처럼 분리한다.

| 항목 | 기존 NAM | NAMv2 |
| --- | --- | --- |
| USB import 폴더 | `/usb_flash/amps` | `/usb_flash/amps_v2` |
| 실제 저장 경로 | `/mnt/audio/amp_nam` | `/mnt/audio/amp_namv2` |
| UI·프리셋 경로 | `/audio/amp_nam` | `/audio/amp_namv2` |
| 설정 버튼 | `COPY AMPS` | `COPY NAMV2 AMPS` |
| model setter | `set_json_nam()` | `set_json_namv2()` |

NAMv2 import는 특정 확장자를 `.nam`으로 가정하지 않는다. USB의 `amps_v2` 폴더 내용을 그대로 별도 저장소에 복사하고, zip 파일이 있으면 복사 후 압축을 해제한다.

### Amp Browser UI

보이는 `AmpBrowser.qml` 화면은 재사용하지만 데이터 root는 모듈별로 전환한다.

- `amp_nam`을 열면 `/mnt/audio/amp_nam`
- `amp_namv2`를 열면 `/mnt/audio/amp_namv2`

`amp_browser_model.py`는 root가 바뀔 때 기존 metadata cache를 비우고 새 저장소의 `metadata.json`만 다시 읽는다. 따라서 두 형식의 목록과 선택 상태가 섞이지 않는다.

NAMv2 모델 패키지가 기존 Amp Browser의 `metadata.json`, 이미지와 `file_names` 구조를 사용하지 않는다면 해당 형식에 맞는 별도 parser 또는 browser model을 추가해야 한다. 현재 구현은 모델 바이너리 확장자는 제한하지 않지만 metadata 구조는 기존 브라우저 형식을 전제로 한다.

## 배포 구조

USB에는 두 패키지를 함께 넣는다.

1. 사용자가 이미 빌드한 NAMv2 LV2 `.deb`
2. 이 저장소에서 생성하는 `hyperpoly-namv2-ui` `.deb`

UI 패키지는 원본 NAMv2 package의 정확한 버전을 `Depends`에 넣는다. 업데이트 화면의 `dpkg -i /usb_flash/*.deb` 실행에서 두 패키지가 함께 설치된다.

모델 파일은 업데이트 `.deb`와 별도로 USB의 `amps_v2` 폴더에 넣고, 업데이트 후 설정 화면의 `COPY NAMV2 AMPS`를 사용해 가져온다.

## 작업 단계

1. NAMv2 `.deb` 압축 해제 및 TTL 검사
2. 기존 NAM과 다른 plugin URI 확인
3. model property와 patch control port 확인
4. audio/control port symbol과 범위 확인
5. NAMv2 모델 확장자와 metadata 구조 확인
6. `config.env`에 별도 모델 경로와 USB 폴더 작성
7. UI patch 적용 및 `module_info.js` 재생성
8. UI `.deb` 생성
9. USB root용 두 패키지와 체크섬 생성
10. `USB_ROOT/amps_v2`에 NAMv2 모델 파일 준비
11. 실제 기기에서 두 import 버튼, 두 browser 목록과 프리셋을 각각 검증

## 완료 조건

- 기존 NAM과 NAMv2가 모듈 브라우저에 동시에 표시된다.
- 동일 패치에 두 모듈을 동시에 생성할 수 있다.
- `COPY AMPS`는 기존 NAM 저장소만 변경한다.
- `COPY NAMV2 AMPS`는 NAMv2 저장소만 변경한다.
- 각 Amp Browser가 자기 모델 목록만 표시한다.
- 각 모듈의 model selection이 올바른 patch property로 전송된다.
- 프리셋 저장/로드 후 두 LV2 URI와 서로 다른 model path가 유지된다.
- 기존 NAM 프리셋과 import 동작이 변하지 않는다.
- USB 업데이트용 산출물이 재현 가능한 명령으로 생성된다.

## 현재 검증 제한

NAMv2 `.deb`와 실제 NAMv2 모델 파일이 이 저장소나 대화에 제공되지 않아 실제 URI, property, port symbol, 모델 확장자, metadata schema와 바이너리 의존성은 아직 검증할 수 없다. 빌드 도구는 필수 값이 채워지지 않거나 기존 NAM 경로를 재사용하면 실패하도록 설계하며, PR은 실제 패키지와 모델을 넣어 검증하기 전까지 draft 상태로 유지한다.
