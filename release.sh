#!/bin/sh
# 配布用の zip を作る。dist/One-<版>.zip に出る。
#
# 受け取った人は Xcode も証明書も要らない。zip を解いて /Applications に置くだけ
# （README の「zip から入れる」）。
#
# 公証（notarization）はしていない。Developer ID の証明書、つまり有料の
# Apple Developer Program が要るため。なので受け取った人は、ブラウザが付けた
# 「インターネットから来た」印をターミナルで外してから開く（README の「zip から入れる」）。
# 印を付けたまま開くと Gatekeeper に止められ、試したときはシステム設定の
# 「このまま開く」も出なかった。
set -e
cd "$(dirname "$0")"

BUILT=build/Build/Products/Release/One.app

# 配る版はいつも同じ証明書で署名する。
#
# 受け取った人のアクセシビリティ許可は、署名した証明書に結び付いている
# （designated requirement の certificate root）。別の証明書で署名した版を配ると、
# 受け取った人の手元で「スイッチは ON なのに一切動かない」が起きる。自分の端末なら
# install.sh が記録を消して直すが、人の端末には手が届かない。
#
# install.sh と違って、証明書が無くても作らない。作った証明書は今までのものとは
# 別物なので、どのみち下の突き合わせで止まる。
CERT_ROOT=7146da4016873ab463b014b4668e70fc11a1b9c2

if ! security find-identity -p codesigning 2>/dev/null | grep -q "LR Code Signing"; then
  echo "署名用の証明書「LR Code Signing」がこの端末に無い。" >&2
  echo "今まで配った版と同じ証明書で署名しないと、受け取った人の許可が壊れる。" >&2
  echo "前に配布物を作った端末から書き出して取り込む（README の「配る」）。" >&2
  exit 1
fi

# README などは .app に入らないので、アプリの中身になるものだけを見る。
if [ -n "$(git status --porcelain -- One One.xcodeproj 2>/dev/null)" ]; then
  echo "注意: One/ か One.xcodeproj にコミットしていない変更がある。それも zip に入る。"
  echo
fi

# 前のビルドの残り物（消したはずの画像など）を持ち込まないよう、まっさらから作る。
xcodebuild -project One.xcodeproj -scheme One -configuration Release \
  -derivedDataPath build -quiet clean build

req=$(codesign -d -r- "$BUILT" 2>/dev/null | grep '^designated' || true)
case "$req" in
  *"certificate root = H\"$CERT_ROOT\""*) ;;
  *)
    echo "署名の条件が今まで配った版と違うので、zip を作らずに止めた。" >&2
    echo "  期待: certificate root = H\"$CERT_ROOT\"" >&2
    echo "  今回: $req" >&2
    echo >&2
    echo "証明書を本当に入れ替えるなら CERT_ROOT を書き換える。" >&2
    echo "そのときは受け取った人全員が、許可の記録を消して与え直すことになる。" >&2
    exit 1 ;;
esac

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")
zip="dist/One-$version.zip"

# 拡張属性を zip に入れない。
#
# ビルドした .app のファイルには com.apple.provenance などの拡張属性が付いていて、
# ditto は既定でこれを ._One のような別のファイルにして zip に入れる。Finder で解けば
# 属性に戻るので害は無いが、unzip などで解くと .app の中に ._ のファイルが増えて
# 署名が壊れる（a sealed resource is missing or invalid）。
#
# zip -r ではなく ditto なのは、zip -r が .app の中のシンボリックリンクを辿って
# 実体を詰めてしまうから。フレームワークを足すとそれで署名が壊れる。
mkdir -p dist
rm -f "$zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$BUILT" "$zip"

# 受け取った人と同じように解いて、署名が通ることを確かめる。
# Finder と同じ ditto と、Mac の外の道具の代わりに unzip の両方で。
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check/ditto"
unzip -q "$zip" -d "$check/unzip"
for how in ditto unzip; do
  if ! codesign --verify --deep --strict "$check/$how/One.app"; then
    rm -f "$zip"
    echo "$how で解いた .app の署名が通らないので、zip を消して止めた。" >&2
    exit 1
  fi
done

echo "作った: $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
echo "sha256: $(shasum -a 256 "$zip" | cut -d' ' -f1)"
echo "署名:   $req"
