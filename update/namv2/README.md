# NAMv2 USB 업데이트 패키지

이 디렉터리는 이미 빌드된 NAMv2 LV2 `.deb`와 HyperPoly UI 변경분을 묶어, 기기 업데이트 화면에서 설치할 수 있는 USB 구성을 만든다.

기존 NAM은 그대로 유지한다.

| 항목 | 기존 NAM | NAMv2 |
| --- | --- | --- |
| UI 모듈 ID | `amp_nam` | `amp_namv2` |
| LV2 URI | 기존 URI | NAMv2 `.deb`의 별도 URI |
| 프리셋 식별 | 기존 URI로 저장 | NAMv2 URI로 별도 저장 |
| 캡처 파일 | `/audio/amp_nam` | 기본적으로 같은 라이브러리 사용 |
| 모델 로딩 property | 기존 `#model` | NAMv2 TTL에서 확인한 property |

캡처 라이브러리를 공유해도 플러그인 인스턴스와 프리셋은 LV2 URI가 다르므로 서로 덮어쓰지 않는다. NAMv2가 기존 `.nam` 파일 형식과 호환되지 않는 경우 `NAMV2_MODEL_ROOT`와 import 경로를 별도로 분리해야 한다.

## 1. NAMv2 패키지 검사

```bash
cd update/namv2
python3 inspect-deb.py /path/to/namv2.deb --extract-to work/extracted \
  > work/inspection.json
```

확인할 값:

- Debian package 이름, 버전, 아키텍처
- LV2 bundle 설치 경로
- 기존 NAM과 다른 NAMv2 plugin URI
- `.nam` 파일을 로드하는 `patch:writable` property URI
- patch 메시지를 받는 Atom input port symbol
- audio input/output, input/output level port symbol

자동 검출 결과가 둘 이상이면 추측하지 말고 압축 해제된 TTL을 직접 확인한다.

```bash
grep -R "lv2:Plugin\|patch:writable\|lv2:symbol" work/extracted/usr/lib/lv2
```

NAMv2의 plugin URI가 기존 URI와 같으면 두 플러그인을 UI와 프리셋에서 독립적으로 구분할 수 없다. 그 경우 NAMv2 bundle의 URI를 먼저 변경해 다시 빌드해야 한다.

## 2. 설정 작성

```bash
cp config.example.env config.env
$EDITOR config.env
```

`inspection.json`과 TTL을 기준으로 `REQUIRED` 값을 채운다. 포트 symbol은 이름(label)이 아니라 `lv2:symbol` 값을 사용한다.

기본 설정은 기존 NAM 캡처 폴더 `/audio/amp_nam`을 공유한다. 별도 저장소가 필요하면 `NAMV2_MODEL_ROOT`와 `NAMV2_DEFAULT_MODEL`을 함께 변경하고, 기기의 import 동작도 별도 폴더로 확장해야 한다.

## 3. USB 업데이트 생성

저장소 루트에서 실행한다.

```bash
update/namv2/build-update.sh /path/to/namv2.deb update/namv2/config.env
```

빌드 과정:

1. NAMv2 `.deb`의 package metadata와 LV2 TTL을 검사한다.
2. 현재 checkout의 `digit_ui`를 임시 작업 디렉터리에 복사한다.
3. `amp_namv2` 등록 패치를 적용한다.
4. `python3 effect_proto_to_js.py`로 `qml/module_info.js`를 재생성한다.
5. 변경된 UI 파일만 담은 `hyperpoly-namv2-ui` 패키지를 만든다.
6. NAMv2 원본 `.deb`, UI `.deb`, `SHA256SUMS`를 USB용 디렉터리에 모은다.

산출물:

```text
update/namv2/dist/usb/
├── <기존 NAMv2 패키지>.deb
├── zz-hyperpoly-namv2-ui_<version>_all.deb
└── SHA256SUMS
```

이 파일들을 하위 폴더 없이 USB 루트에 복사한다. UI 패키지는 NAMv2 원본 패키지의 정확한 버전에 의존하도록 생성된다.

## 4. UI에 추가되는 내용

패치가 적용하는 변경은 다음과 같다.

- `module_info.py`
  - `amp_namv2` → NAMv2 plugin URI 매핑
  - NAMv2의 실제 port symbol로 입력·출력·레벨 control 등록
- `qml/module_info.js`
  - 패치된 metadata로 재생성
- `ingen_wrapper.py`
  - NAMv2 model property를 사용하는 별도 `set_json_namv2()` 추가
- `show_widget.py`
  - `amp_nam`과 `amp_namv2`의 model update를 명시적으로 분기
  - 프리셋에서 model path가 복원될 때 NAMv2도 patch:Set 전송
- `qml/PatchBayEffect.qml`
  - `amp_namv2` 상세 화면을 기존 Amp Browser에 연결

기존 `amp_nam` URI, metadata와 model setter는 변경하지 않는다.

## 5. 검증

패키지 생성 후:

```bash
cd update/namv2/dist/usb
sha256sum -c SHA256SUMS
dpkg-deb --info zz-hyperpoly-namv2-ui_*_all.deb
dpkg-deb --contents zz-hyperpoly-namv2-ui_*_all.deb
```

개발 기기에서 확인:

1. USB 업데이트 후 정상 종료와 재부팅
2. `lilv-bench` 또는 사용 중인 LV2 검사 도구에서 기존 NAM과 NAMv2 URI가 모두 표시
3. 모듈 브라우저에서 기존 NAM과 NAMv2가 별도로 표시
4. 두 모듈을 한 패치에 동시에 추가 가능
5. 같은 `.nam` 캡처를 각각 로드 가능
6. 저장 후 재부팅·프리셋 재로드 시 각 플러그인 URI와 model path가 유지
7. input/output level control이 실제 포트와 일치
8. 기존 NAM 프리셋이 변경 없이 로드

## 6. 주의사항

- UI 패키지는 **현재 checkout의 전체 대상 UI 파일**을 패키징한다. 반드시 대상 펌웨어와 일치하는 tag/commit에서 빌드한다.
- NAMv2 원본 `.deb`가 대화나 저장소에 포함되지 않았으므로 이 PR에는 바이너리를 커밋하지 않는다.
- NAMv2 라이선스와 대응 소스 제공 의무를 원본 `.deb` 배포 전에 확인한다.
- plugin URI, model property나 port symbol을 추측해서 릴리스하지 않는다.
