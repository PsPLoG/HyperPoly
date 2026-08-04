# NAMv2 USB 업데이트 패키지

이 디렉터리는 이미 빌드된 NAMv2 LV2 `.deb`와 HyperPoly UI 변경분을 묶어, 기기 업데이트 화면에서 설치할 수 있는 USB 구성을 만든다.

기존 NAM은 그대로 유지하고 NAMv2의 플러그인, 모델 파일과 import 동작을 별도로 구성한다.

| 항목 | 기존 NAM | NAMv2 |
| --- | --- | --- |
| UI 모듈 ID | `amp_nam` | `amp_namv2` |
| LV2 URI | 기존 URI | NAMv2 `.deb`의 별도 URI |
| 프리셋 식별 | 기존 URI로 저장 | NAMv2 URI로 별도 저장 |
| USB 모델 폴더 | `/usb_flash/amps` | `/usb_flash/amps_v2` |
| 모델 저장 경로 | `/mnt/audio/amp_nam` | `/mnt/audio/amp_namv2` |
| UI·프리셋 경로 | `/audio/amp_nam` | `/audio/amp_namv2` |
| 설정 버튼 | `COPY AMPS` | `COPY NAMV2 AMPS` |
| 모델 로딩 함수 | `set_json_nam()` | `set_json_namv2()` |

## 1. NAMv2 패키지 검사

```bash
cd update/namv2
python3 inspect-deb.py /path/to/namv2.deb --extract-to work/extracted \
  > work/inspection.json
```

확인할 값:

- Debian package 이름, 버전과 아키텍처
- LV2 bundle 설치 경로
- 기존 NAM과 다른 NAMv2 plugin URI
- NAMv2 모델을 로드하는 `patch:writable` property URI
- patch 메시지를 받는 Atom input port symbol
- audio input/output와 input/output level port symbol

자동 검출 결과가 둘 이상이면 추측하지 말고 압축 해제된 TTL을 직접 확인한다.

```bash
grep -R "lv2:Plugin\|patch:writable\|lv2:symbol" work/extracted/usr/lib/lv2
```

NAMv2의 plugin URI가 기존 URI와 같으면 두 플러그인을 UI와 프리셋에서 독립적으로 구분할 수 없다. 그 경우 NAMv2 bundle의 URI를 변경해 다시 빌드해야 한다.

## 2. 설정 작성

```bash
cp config.example.env config.env
$EDITOR config.env
```

`inspection.json`과 TTL을 기준으로 `REQUIRED` 값을 채운다. 포트 symbol은 이름(label)이 아니라 `lv2:symbol` 값을 사용한다.

NAMv2 모델은 기존 NAM 폴더를 공유하지 않는다.

```bash
NAMV2_DEFAULT_MODEL="/audio/amp_namv2/<actual-v2-model-file>"
NAMV2_MODEL_ROOT="/audio/amp_namv2"
NAMV2_MODEL_STORAGE_ROOT="/mnt/audio/amp_namv2"
NAMV2_USB_MODEL_FOLDER="amps_v2"
```

`NAMV2_DEFAULT_MODEL`은 실제 NAMv2 모델 확장자와 파일명으로 지정해야 한다. 기존 `.nam` 기본 파일을 넣으면 안 된다.

## 3. USB 업데이트 생성

저장소 루트에서 실행한다.

```bash
bash update/namv2/build-update.sh /path/to/namv2.deb update/namv2/config.env
```

빌드 과정:

1. NAMv2 `.deb`의 package metadata와 LV2 TTL을 검사한다.
2. NAMv2 URI와 모델 경로가 기존 NAM과 분리됐는지 검사한다.
3. 현재 checkout의 `digit_ui`를 임시 작업 디렉터리에 복사한다.
4. `amp_namv2`, 전용 model setter와 별도 Amp Browser root를 적용한다.
5. 설정 화면에 `COPY NAMV2 AMPS` 버튼과 별도 USB import 함수를 추가한다.
6. `python3 effect_proto_to_js.py`로 `qml/module_info.js`를 재생성한다.
7. 변경된 UI 파일만 담은 `hyperpoly-namv2-ui` 패키지를 만든다.
8. NAMv2 원본 `.deb`, UI `.deb`와 `SHA256SUMS`를 USB용 디렉터리에 모은다.

산출물:

```text
update/namv2/dist/usb/
├── <기존 NAMv2 패키지>.deb
├── zz-hyperpoly-namv2-ui_<version>_all.deb
└── SHA256SUMS
```

이 파일들을 하위 폴더 없이 USB 루트에 복사한다. UI 패키지는 NAMv2 원본 패키지의 정확한 버전에 의존하도록 생성된다.

## 4. NAMv2 모델 파일 가져오기

모델 파일은 업데이트 `.deb`와 분리해서 USB에 준비한다.

```text
USB_ROOT/
├── <NAMv2 package>.deb
├── zz-hyperpoly-namv2-ui_<version>_all.deb
├── SHA256SUMS
└── amps_v2/
    └── <NAMv2 model files or archives>
```

업데이트 후 기기를 다시 부팅하고 설정 화면에서 `COPY NAMv2 AMPS`를 실행한다.

- `COPY AMPS`는 기존 `/usb_flash/amps`만 읽고 `/mnt/audio/amp_nam`에 저장한다.
- `COPY NAMv2 AMPS`는 `/usb_flash/amps_v2`만 읽고 `/mnt/audio/amp_namv2`에 저장한다.
- NAMv2 import는 특정 모델 확장자를 필터링하지 않고 폴더의 모든 파일을 복사한다.
- zip 파일이 있으면 NAMv2 저장소에서 압축을 풀고 zip 원본을 제거한다.

## 5. UI에 추가되는 내용

패치가 적용하는 변경은 다음과 같다.

- `module_info.py`
  - `amp_namv2` → NAMv2 plugin URI 매핑
  - NAMv2의 실제 port symbol로 입력·출력·레벨 control 등록
  - NAMv2 전용 기본 모델 경로 등록
- `qml/module_info.js`
  - 패치된 metadata로 재생성
- `ingen_wrapper.py`
  - NAMv2 model property를 사용하는 `set_json_namv2()` 추가
- `show_widget.py`
  - 기존 NAM과 NAMv2 model update를 명시적으로 분기
  - `ui_copy_amps_v2()`와 NAMv2 USB 용량 표시 추가
- `amp_browser_model.py`
  - 모듈을 열 때 model root를 전환하고 metadata cache를 다시 구성
- `qml/AmpBrowser.qml`
  - 전달받은 root로 browser model을 초기화
- `qml/PatchBayEffect.qml`
  - 기존 NAM은 `/audio/amp_nam`, NAMv2는 `/audio/amp_namv2`를 사용
- `qml/Settings.qml`
  - `COPY NAMV2 AMPS` 버튼과 `amps_v2` 안내 추가

보이는 Amp Browser 레이아웃은 재사용하지만 두 모듈의 모델 목록과 저장 경로는 섞이지 않는다.

## 6. 모델 metadata 호환성

현재 Amp Browser는 각 모델 디렉터리의 `metadata.json`, 이미지와 `file_names` 목록을 사용한다. NAMv2 모델 바이너리의 확장자는 달라도 되지만, 브라우저용 metadata 구조가 기존 형식과 호환되어야 목록과 이미지가 표시된다.

NAMv2가 다른 metadata schema를 사용하거나 raw 모델 파일만 제공한다면 NAMv2 전용 parser 또는 별도 browser model이 필요하다. 이 PR은 모델 저장소와 import 버튼을 먼저 분리하며, 실제 NAMv2 모델 샘플 없이 schema를 임의로 추측하지 않는다.

## 7. 검증

패키지 생성 후:

```bash
cd update/namv2/dist/usb
sha256sum -c SHA256SUMS
dpkg-deb --info zz-hyperpoly-namv2-ui_*_all.deb
dpkg-deb --contents zz-hyperpoly-namv2-ui_*_all.deb
```

개발 기기에서 확인:

1. USB 업데이트 후 정상 종료와 재부팅
2. 기존 NAM과 NAMv2 URI가 모두 LV2 host에 표시
3. 모듈 브라우저에서 기존 NAM과 NAMv2가 별도로 표시
4. `COPY AMPS` 실행 시 기존 NAM 저장소만 변경
5. `COPY NAMV2 AMPS` 실행 시 NAMv2 저장소만 변경
6. 각 Amp Browser가 자기 저장소의 모델만 표시
7. 서로 다른 모델 파일을 각각 로드 가능
8. 저장 후 재부팅·프리셋 재로드 시 각 plugin URI와 model path 유지
9. input/output level control이 실제 NAMv2 포트와 일치
10. 기존 NAM 프리셋과 import 동작에 회귀가 없음

## 8. 주의사항

- UI 패키지는 현재 checkout의 전체 대상 UI 파일을 패키징한다. 반드시 대상 펌웨어와 일치하는 tag/commit에서 빌드한다.
- NAMv2 원본 `.deb`와 실제 모델 파일이 대화나 저장소에 포함되지 않았으므로 이 PR에는 바이너리를 커밋하지 않는다.
- 실제 모델 확장자와 metadata schema를 확인하기 전까지 PR을 draft로 유지한다.
- NAMv2 라이선스와 대응 소스 제공 의무를 원본 `.deb` 배포 전에 확인한다.
- plugin URI, model property, port symbol 또는 모델 형식을 추측해서 릴리스하지 않는다.
