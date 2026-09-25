#!/usr/bin/env bash
# Commit the working tree and push it to origin.
# --release: also build the release APK and upload it to a GitHub release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

do_release=0
message=""
message_given=0

usage() {
  cat <<'EOF'
用法：./scripts/push-github.sh [--release] [提交說明]

沒有參數：把目前的改動提交，並推到 origin。
--release：另外建置 release APK，上傳到 GitHub Release。
          標籤用 pubspec.yaml 的版本，例如 v0.1.0+1。
          同一個版本再跑一次會換掉那個 Release 上的 APK。
提交說明省略時，用 Update。
EOF
}

for arg in "$@"; do
  case "$arg" in
    --release) do_release=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -n "$message" ]]; then
        echo "不明的參數：$arg" >&2
        usage >&2
        exit 1
      fi
      message="$arg"
      message_given=1
      ;;
  esac
done

if [[ -z "$message" ]]; then
  message="Update"
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "還沒有 origin。先在 GitHub 建立這個專案的遠端。" >&2
  exit 1
fi

# This machine has no git user.name. Use the logged-in GitHub account for this commit only.
if [[ -z "$(git config --get user.email || true)" || -z "$(git config --get user.name || true)" ]]; then
  login="$(gh api user --jq .login)"
  id="$(gh api user --jq .id)"
  export GIT_AUTHOR_NAME="$login"
  export GIT_AUTHOR_EMAIL="${id}+${login}@users.noreply.github.com"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "$message"
fi

branch="$(git branch --show-current)"
git push -u origin "$branch"
echo "已推到 origin/$branch"

if [[ "$do_release" -ne 1 ]]; then
  exit 0
fi

# The SSD holds the sandbox Gradle cache. A normal terminal build uses ~/.gradle, so a missing disk does not stop the release.
"$root/scripts/sandbox-cache-on-ssd.sh"
disk=/run/media/hocti/92C4A6B3C4A698CD
if [[ -d "$disk" ]]; then
  export GRADLE_USER_HOME="$disk/cursor-sandbox-cache/gradle"
  mkdir -p "$GRADLE_USER_HOME"
fi

flutter_bin="${FLUTTER_ROOT:-/home/hocti/sdk/flutter}/bin/flutter"
if [[ ! -x "$flutter_bin" ]]; then
  flutter_bin="$(command -v flutter || true)"
fi
if [[ -z "${flutter_bin}" || ! -x "$flutter_bin" ]]; then
  echo "找不到 Flutter。預設路徑是 /home/hocti/sdk/flutter。" >&2
  exit 1
fi

echo "建置 release…"
"$flutter_bin" build apk --release
release_apk="$root/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$release_apk" ]]; then
  echo "找不到 release APK：$release_apk" >&2
  exit 1
fi

version="$(sed -n 's/^version:[[:space:]]*//p' "$root/pubspec.yaml" | head -n 1)"
version="${version%%#*}"
version="${version// /}"
if [[ -z "$version" ]]; then
  echo "pubspec.yaml 沒有 version。" >&2
  exit 1
fi

tag="v$version"
asset_name="t-reader-${version%%+*}.apk"
if [[ "$message_given" -eq 1 ]]; then
  notes="$message"
else
  notes="Release APK for T Reader $version."
fi

if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$release_apk#$asset_name" --clobber
  echo "已更新 GitHub Release $tag"
else
  gh release create "$tag" "$release_apk#$asset_name" \
    --title "T Reader $version" \
    --notes "$notes"
  echo "已建立 GitHub Release $tag"
fi

gh release view "$tag" --json url --jq .url
