# USB 패치 업데이트 파일 생성 가이드

이 문서는 HyperPoly 임베디드 기기에 USB로 전달할 **패치 업데이트 파일(`.deb`)**을 만드는 방법을 설명한다.

기기의 업데이트 UI는 USB가 `/usb_flash`에 마운트된 상태에서 루트의 `.deb` 파일을 찾아 다음 방식으로 설치한다.

```bash
sudo /usr/bin/polyoverlayroot-chroot \
  dpkg -i -E -G /usb_flash/*.deb \
  && sync \
  && sudo shutdown -h now
```

따라서 일반적인 코드·UI·LV2 변경은 전체 이미지를 만드는 것이 아니라, 변경 파일을 실제 설치 경로대로 담은 Debian 패키지를 생성해 USB 루트에 복사하면 된다.

## 1. 패치에 포함할 파일 정하기

먼저 기준 버전과 새 버전 사이의 변경 파일을 확인한다.

```bash
git diff --name-status <BASE_TAG_OR_COMMIT>..<NEW_TAG_OR_COMMIT>
```

패키지에는 소스 경로가 아니라 **기기에서의 최종 설치 경로**를 기준으로 파일을 배치한다.

대표적인 매핑 예시는 다음과 같다.

| 저장소 파일 | 패키지 내부 설치 경로 |
| --- | --- |
| `digit_ui/...` | `/home/debian/UI/...` |
| UI 모듈 캐시 | `/home/debian/UI/qml/module_info.js` |
| LV2 bundle | 기기에서 사용하는 `/usr/lib/lv2/<name>.lv2/...` |
| 실행 파일 | 기존 설치 위치인 `/usr/bin/...` 또는 `/usr/lib/...` |
| 설정·서비스 파일 | 기존 기기에서 사용 중인 `/etc/...` 또는 systemd 경로 |

기존 파일의 실제 경로와 권한은 패키지를 만들기 전에 기기에서 확인한다.

```bash
readlink -f /path/to/file
stat /path/to/file
file /path/to/binary
```

핵심 패키지들은 `apt`가 아니라 소스에서 빌드해 `--prefix=/usr`로 설치된 경우가 많다. 빌드 산출물을 넣을 때 기존 설치 위치와 ABI를 그대로 유지한다.

## 2. 패키지 작업 디렉터리 만들기

예를 들어 버전 `1.2.3` 패치를 다음과 같이 준비한다.

```text
update/work/hyperpoly-patch-1.2.3/
├── DEBIAN/
│   ├── control
│   └── postinst          # 필요한 경우만
├── home/
│   └── debian/
│       └── UI/
│           └── ...
└── usr/
    └── lib/
        └── lv2/
            └── ...
```

`DEBIAN` 바깥의 디렉터리는 기기의 `/` 아래에 그대로 설치된다. 예를 들어 다음 파일은:

```text
update/work/hyperpoly-patch-1.2.3/home/debian/UI/show_widget.py
```

기기에서 다음 위치에 설치된다.

```text
/home/debian/UI/show_widget.py
```

작업 디렉터리를 생성한다.

```bash
VERSION=1.2.3
PKGROOT="update/work/hyperpoly-patch-${VERSION}"

rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/DEBIAN"
```

## 3. 변경 파일 복사하기

`install`을 사용하면 파일 모드를 명시적으로 지정할 수 있다.

```bash
install -Dm644 digit_ui/show_widget.py \
  "$PKGROOT/home/debian/UI/show_widget.py"

install -Dm644 digit_ui/qml/SomeWidget.qml \
  "$PKGROOT/home/debian/UI/qml/SomeWidget.qml"
```

실행 파일은 실행 권한을 유지한다.

```bash
install -Dm755 build/my_binary \
  "$PKGROOT/usr/bin/my_binary"
```

디렉터리 전체, 심볼릭 링크 또는 LV2 bundle을 복사할 때는 속성을 보존한다.

```bash
mkdir -p "$PKGROOT/usr/lib/lv2"
cp -a build/my_module.lv2 "$PKGROOT/usr/lib/lv2/"
```

패키지 내부에 빌드 캐시, 테스트 파일, `.git`, 오브젝트 파일 등 런타임에 필요하지 않은 파일이 들어가지 않도록 확인한다.

## 4. `DEBIAN/control` 작성하기

아키텍처는 대상 기기에서 확인한다.

```bash
dpkg --print-architecture
```

컴파일된 바이너리가 없는 UI·설정 전용 패치는 `Architecture: all`을 사용할 수 있다. 대상용 바이너리나 LV2 `.so`가 포함되면 기기 아키텍처를 지정한다.

`update/work/hyperpoly-patch-1.2.3/DEBIAN/control` 예시:

```debcontrol
Package: hyperpoly-patch
Version: 1.2.3
Section: misc
Priority: optional
Architecture: arm64
Maintainer: HyperPoly Maintainers
Description: HyperPoly USB patch update 1.2.3
```

필요하면 시작 펌웨어를 패키지 의존성이나 `preinst` 검사로 제한한다. 서로 강하게 연관된 변경은 가능하면 하나의 패키지로 묶어 부분 설치 가능성을 줄인다.

## 5. 설치 후 작업이 필요할 때

파일 복사만으로 충분하면 maintainer script를 만들지 않는다.

캐시 정리, 기존 파일 삭제, systemd 갱신 등이 필요하면 `DEBIAN/postinst`를 추가한다. 스크립트는 여러 번 실행돼도 문제가 없도록 작성한다.

```sh
#!/bin/sh
set -e

case "$1" in
  configure)
    systemctl daemon-reload || true
    ;;
esac

exit 0
```

실행 권한을 준다.

```bash
chmod 0755 "$PKGROOT/DEBIAN/postinst"
```

업데이트 UI가 패키지 설치 후 `sync`와 종료를 수행하므로 `postinst`에서 다시 종료하거나 `overlayroot-chroot`를 실행하지 않는다. 서비스 재시작도 업데이트 도중 UI나 오디오 호스트와 충돌할 수 있으므로, 특별한 이유가 없다면 다음 부팅에 맡긴다.

기존 패키지에 없던 파일을 제거해야 한다면 삭제 경로를 명시적으로 관리한다.

```sh
rm -f /old/obsolete/file
```

와일드카드나 넓은 디렉터리 삭제는 피한다.

## 6. 새 LV2 모듈을 포함하는 패치

새 LV2 모듈을 추가하거나 UI에 보이는 모듈 정보를 변경했다면 패키지를 만들기 전에 UI 캐시를 다시 생성한다.

```bash
cd digit_ui
python3 effect_proto_to_js.py
cd ..
```

생성된 파일:

```text
digit_ui/qml/module_info.js
```

패치에는 최소한 다음 변경을 함께 넣는다.

- LV2 bundle 전체: binary, `manifest.ttl`, 모듈 TTL과 필요한 리소스
- 변경된 `digit_ui/module_info.py`
- 재생성된 `digit_ui/qml/module_info.js`
- 모듈 전용 UI 파일이 있다면 해당 QML·이미지 리소스

예시:

```bash
mkdir -p "$PKGROOT/usr/lib/lv2"
cp -a build/my_module.lv2 "$PKGROOT/usr/lib/lv2/"

install -Dm644 digit_ui/module_info.py \
  "$PKGROOT/home/debian/UI/module_info.py"

install -Dm644 digit_ui/qml/module_info.js \
  "$PKGROOT/home/debian/UI/qml/module_info.js"
```

대상 바이너리를 검사한다.

```bash
file "$PKGROOT/usr/lib/lv2/my_module.lv2/my_module.so"
```

가능하면 동일한 기기 이미지나 sysroot에서 `ldd`를 실행해 누락된 공유 라이브러리가 없는지도 확인한다.

## 7. 패키지 빌드하기

출력 디렉터리를 만들고 패키지를 빌드한다.

```bash
VERSION=1.2.3
ARCH=arm64
PKGROOT="update/work/hyperpoly-patch-${VERSION}"
OUT="update/dist/hyperpoly-patch_${VERSION}_${ARCH}.deb"

mkdir -p update/dist
fakeroot dpkg-deb --build "$PKGROOT" "$OUT"
```

지원되는 환경에서는 다음 명령을 사용할 수도 있다.

```bash
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT"
```

패키지 안의 일반 파일은 기본적으로 `root:root` 소유가 되도록 만든다. 특정 런타임 사용자의 소유권이 반드시 필요한 데이터 파일은 `postinst`에서 정확한 경로만 `chown`한다.

## 8. 산출물 검증하기

패키지 메타데이터와 파일 목록을 확인한다.

```bash
dpkg-deb --info "$OUT"
dpkg-deb --contents "$OUT"
```

특히 다음을 확인한다.

- 경로가 `/home/debian/UI`, `/usr/lib/lv2` 등 실제 설치 위치와 일치하는가
- 실행 파일과 maintainer script에 실행 권한이 있는가
- 대상과 다른 CPU 아키텍처의 바이너리가 들어가지 않았는가
- `module_info.js`가 재생성된 최신 파일인가
- 불필요한 빌드 파일과 비밀정보가 없는가

체크섬도 함께 생성한다.

```bash
sha256sum "$OUT" > "${OUT}.sha256"
```

테스트용 임시 디렉터리에 풀어 최종 파일 구조를 검토할 수 있다.

```bash
rm -rf update/test-root
mkdir -p update/test-root
dpkg-deb -x "$OUT" update/test-root
find update/test-root -type f -o -type l
```

## 9. USB에 넣기

기기가 지원하는 형식의 **단일 파티션 USB**를 준비하고, `.deb` 파일을 압축하지 않은 상태로 USB 최상위 경로에 복사한다.

```text
USB_ROOT/
├── hyperpoly-patch_1.2.3_arm64.deb
└── hyperpoly-patch_1.2.3_arm64.deb.sha256   # 검증·배포용, 설치기는 무시
```

다음처럼 하위 폴더에 넣으면 현재 UI의 `/usb_flash/*.deb` 검색에 잡히지 않는다.

```text
USB_ROOT/update/hyperpoly-patch_1.2.3_arm64.deb  # 사용하지 않음
```

USB를 안전하게 제거하기 전에 동기화한다.

```bash
sync
```

## 10. 기기에서 검증하기

릴리스 전 개발 기기에서 최소한 다음을 확인한다.

1. 현재 상태와 사용자 데이터를 백업한다.
2. 패치 `.deb`를 USB 루트에 넣는다.
3. 기기의 업데이트 UI에서 업데이트를 실행한다.
4. 설치 성공 후 기기가 종료되는지 확인한다.
5. 다시 부팅한 뒤 패키지와 파일을 확인한다.

```bash
dpkg -s hyperpoly-patch
dpkg -L hyperpoly-patch
systemctl --failed
```

LV2 패치라면 Ingen이 bundle을 발견하는지, UI에서 모듈 추가·연결·저장·재로딩이 되는지 확인한다.

## 11. 배포 체크리스트

- [ ] 기준 버전과 변경 범위가 명확하다.
- [ ] 패키지 경로가 기기의 실제 설치 경로와 일치한다.
- [ ] 대상 아키텍처로 빌드한 파일만 포함한다.
- [ ] 새 LV2 모듈 추가 시 `python3 effect_proto_to_js.py`를 실행했다.
- [ ] `module_info.py`와 생성된 `qml/module_info.js`를 함께 포함했다.
- [ ] `dpkg-deb --info`와 `dpkg-deb --contents`를 검토했다.
- [ ] SHA-256을 생성하고 보관했다.
- [ ] USB 루트에 `.deb`를 직접 배치했다.
- [ ] 실제 개발 기기에서 설치와 재부팅 후 동작을 검증했다.
- [ ] 기존 라이선스 헤더를 유지하고 필요한 GPL·제3자 라이선스 문서를 패키지에 포함했다.
