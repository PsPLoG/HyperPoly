# NAMv2 독립 모듈 추가 계획

## 목표

이미 설치된 기존 NAM(`amp_nam`)을 유지하면서 NAMv2를 `amp_namv2`라는 별도 LV2/UI 모듈로 추가한다. 두 모듈은 같은 캡처 파일을 사용할 수 있지만, LV2 URI와 model-loading property는 각각의 구현에 맞게 분리한다.

## 기존 NAM 연결 구조

현재 UI에서 NAM은 다음 경로로 연결된다.

1. `module_info.py`의 `amp_nam`이 LV2 plugin URI에 매핑된다.
2. `AmpBrowser.qml`과 `amp_browser_model.py`가 `/mnt/audio/amp_nam`의 metadata와 `.nam` 파일을 선택한다.
3. `show_widget.py`의 `update_json()`이 선택된 파일을 `ingen_wrapper.set_json_nam()`으로 보낸다.
4. `set_json_nam()`은 기존 NAM의 model property URI로 `patch:Set`을 보낸다.
5. `effect_proto_to_js.py`가 Python metadata를 QML 캐시로 변환한다.

따라서 NAMv2는 plugin URI만 등록해서는 충분하지 않다. 실제 TTL의 plugin URI, model property, Atom control port와 audio/control port symbol까지 한 세트로 맞춰야 한다.

## 구현 선택

### 독립성

- 기존 모듈 ID: `amp_nam`
- 신규 모듈 ID: `amp_namv2`
- 기존 NAM 코드와 setter는 수정하지 않는다.
- NAMv2 전용 `set_json_namv2()`를 추가한다.
- 프리셋에는 NAMv2의 별도 LV2 URI가 저장된다.

### 모델 파일

1차 구현은 `/audio/amp_nam` 캡처 라이브러리를 공유한다. 이유:

- Amp Browser가 현재 단일 Python model/singleton과 고정된 metadata root를 사용한다.
- 동일한 `.nam` 형식을 지원한다면 파일을 중복 저장할 필요가 없다.
- 플러그인 독립성은 파일 경로가 아니라 LV2 URI와 module ID로 보장된다.

NAMv2가 다른 모델 형식을 요구하면 후속 변경으로 `AmpBrowserModel`을 root별 인스턴스로 바꾸고 `/audio/amp_namv2`를 분리한다.

## 배포 구조

USB에는 두 패키지를 함께 넣는다.

1. 사용자가 이미 빌드한 NAMv2 LV2 `.deb`
2. 이 저장소에서 생성하는 `hyperpoly-namv2-ui` `.deb`

UI 패키지는 원본 NAMv2 package의 정확한 버전을 `Depends`에 넣는다. 업데이트 화면의 `dpkg -i /usb_flash/*.deb` 실행에서 두 패키지가 함께 설치된다.

## 작업 단계

1. NAMv2 `.deb` 압축 해제 및 TTL 검사
2. 기존 NAM과 다른 plugin URI 확인
3. model property와 patch control port 확인
4. audio/control port symbol과 범위 확인
5. `config.env` 작성
6. UI patch 적용 및 `module_info.js` 재생성
7. UI `.deb` 생성
8. USB root용 두 패키지와 체크섬 생성
9. 실제 기기에서 기존 NAM 회귀 테스트와 NAMv2 동시 사용 테스트

## 완료 조건

- 기존 NAM과 NAMv2가 모듈 브라우저에 동시에 표시된다.
- 동일 패치에 두 모듈을 동시에 생성할 수 있다.
- 각 모듈의 model selection이 올바른 patch property로 전송된다.
- 프리셋 저장/로드 후 두 LV2 URI와 model path가 유지된다.
- 기존 NAM 프리셋 동작이 변하지 않는다.
- USB 업데이트용 산출물이 재현 가능한 명령으로 생성된다.

## 현재 검증 제한

NAMv2 `.deb`가 이 저장소나 대화에 제공되지 않아 실제 URI, property, port symbol과 바이너리 의존성은 아직 검증할 수 없다. 빌드 도구는 이 값이 채워지지 않으면 실패하도록 설계하며, PR은 실제 패키지를 넣어 검증하기 전까지 draft 상태로 유지한다.
