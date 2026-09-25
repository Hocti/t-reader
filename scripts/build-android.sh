#!/usr/bin/env bash
# Default: build the debug APK and install it on the connected device.
# --release: also build the release APK.
# --dl: build the release APK and copy it to the download site.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Gradle's sandbox cache must stay on the Samsung SSD, not tmpfs /tmp.
"$root/scripts/sandbox-cache-on-ssd.sh"
if [[ -d /run/media/hocti/92C4A6B3C4A698CD ]]; then
  export GRADLE_USER_HOME=/run/media/hocti/92C4A6B3C4A698CD/cursor-sandbox-cache/gradle
  mkdir -p "$GRADLE_USER_HOME"
fi

do_release=0
do_dl=0

usage() {
  cat <<'EOF'
用法：./scripts/build-android.sh [--release] [--dl]

沒有參數：建置 debug，並安裝到目前連接的裝置。
--release：另外建置 release，留在 build/app/outputs/flutter-apk/app-release.apk。
--dl：建置 release，並複製到下載站。會一併建置 release。
EOF
}

for arg in "$@"; do
  case "$arg" in
    --release) do_release=1 ;;
    --dl) do_dl=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "不明的參數：$arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$do_dl" -eq 1 ]]; then
  do_release=1
fi

flutter_bin="${FLUTTER_ROOT:-/home/hocti/sdk/flutter}/bin/flutter"
if [[ ! -x "$flutter_bin" ]]; then
  flutter_bin="$(command -v flutter || true)"
fi
if [[ -z "${flutter_bin}" || ! -x "$flutter_bin" ]]; then
  echo "找不到 Flutter。預設路徑是 /home/hocti/sdk/flutter。" >&2
  exit 1
fi

debug_apk="$root/build/app/outputs/flutter-apk/app-debug.apk"
release_apk="$root/build/app/outputs/flutter-apk/app-release.apk"

find_adb() {
  local sdk="" props="$root/android/local.properties"
  if [[ -f "$props" ]]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' "$props" | head -n 1)"
    sdk="${sdk//\\:/:}"
    if [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]]; then
      echo "$sdk/platform-tools/adb"
      return
    fi
  fi
  if [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    echo "${ANDROID_HOME}/platform-tools/adb"
    return
  fi
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]]; then
    echo "${ANDROID_SDK_ROOT}/platform-tools/adb"
    return
  fi
  command -v adb || true
}

install_debug() {
  local adb_bin device
  adb_bin="$(find_adb)"
  if [[ -z "$adb_bin" || ! -x "$adb_bin" ]]; then
    echo "找不到 adb，無法安裝 debug。" >&2
    exit 1
  fi

  mapfile -t devices < <("$adb_bin" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "沒有已連接的裝置。" >&2
    exit 1
  fi

  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    device="$ANDROID_SERIAL"
  elif [[ ${#devices[@]} -eq 1 ]]; then
    device="${devices[0]}"
  else
    echo "有多個裝置。請設定 ANDROID_SERIAL 再安裝：" >&2
    printf '  %s\n' "${devices[@]}" >&2
    exit 1
  fi

  echo "安裝 debug 到 $device…"
  "$adb_bin" -s "$device" install -r -t "$debug_apk"
}

echo "建置 debug…"
"$flutter_bin" build apk --debug
if [[ ! -f "$debug_apk" ]]; then
  echo "找不到 debug APK：$debug_apk" >&2
  exit 1
fi
install_debug
echo "debug：$debug_apk"

if [[ "$do_release" -eq 1 ]]; then
  echo "建置 release…"
  "$flutter_bin" build apk --release
  if [[ ! -f "$release_apk" ]]; then
    echo "找不到 release APK：$release_apk" >&2
    exit 1
  fi
  echo "release：$release_apk"
fi

if [[ "$do_dl" -eq 1 ]]; then
  dl_dir="/mnt/nas4/web/subdomains/dl"
  release_dest="$dl_dir/epub-reader-release.apk"
  mkdir -p "$dl_dir"
  cp -f "$release_apk" "$release_dest"
  echo "已複製：$release_dest"
  echo "下載：https://dl.sitepreview.cc/epub-reader-release.apk"
fi
