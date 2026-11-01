#!/bin/sh
# Publishes a release from this Mac: builds and signs Parappa.app, packs
# Parappa.dmg, signs it for Sparkle, uploads it to a GitHub release and adds
# it to docs/appcast.xml, which installed copies check for updates.
# The code-signing certificate and Sparkle's EdDSA key (account
# com.marierie.parappa) stay in this Mac's login keychain.
#
# Everything is built and signed before the tag is pushed, so a failure
# leaves nothing published; run it again once fixed.
#
# usage: scripts/release.sh 1.0.0
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=${1:?usage: scripts/release.sh VERSION}
tag="v$version"
repo=devuterian/parappa
sparkle_sha=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

git diff --quiet && git diff --cached --quiet || { echo "Commit or stash changes first."; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Release from main."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Log in with gh auth login first."; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main isn't the same as origin/main; push or pull first."; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag already exists."; exit 1; }

# The version comes from the tag, so tag locally first; it's only pushed at the end.
git tag "$tag"
trap 'git tag -d "$tag" >/dev/null 2>&1 || true' EXIT
REQUIRE_IDENTITY=1 sh scripts/build-app.sh
sh scripts/make-dmg.sh

tools="$root/build/sparkle"
if [ ! -x "$tools/bin/sign_update" ]; then
    mkdir -p "$tools"
    curl -fsSL -o "$tools/sparkle.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
    echo "$sparkle_sha  $tools/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "Sparkle download doesn't match its checksum."; exit 1; }
    tar xJf "$tools/sparkle.tar.xz" -C "$tools"
fi
signature=$("$tools/bin/sign_update" --account com.marierie.parappa build/Parappa.dmg)
build=$(git rev-list --count "$tag")

git push -q origin "$tag"
trap - EXIT
gh release create "$tag" build/Parappa.dmg --repo "$repo" --verify-tag --title "Parappa $version" --notes "$(cat <<'EOF'
## 설치

1. `Parappa.dmg`를 열고 **Parappa**를 **응용 프로그램** 폴더로 끌어다 놓습니다.
2. Parappa를 엽니다. Apple 공증을 받지 않은 앱이라 처음에는 macOS가 실행을 막습니다.
3. **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누른 뒤 다시 엽니다.

이미 설치했다면 Parappa가 알아서 업데이트합니다.
EOF
)"

python3 scripts/appcast.py "$version" "$build" "https://github.com/$repo/releases/download/$tag/Parappa.dmg" "$signature"
git commit -qam "Appcast: $tag"
git push -q origin main
echo "Released $tag"
