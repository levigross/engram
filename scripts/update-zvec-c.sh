#!/usr/bin/env bash
# Pin the C interface of zvec, Alibaba's embedded vector search library: pkgs/zvec-c/pin.json
# gets a release of alibaba/zvec, the hash of its sources with every submodule (as
# fetchFromGitHub with fetchSubmodules fetches them), and the archives that the build of Arrow,
# one of those submodules, downloads while it is configured:
#
#   scripts/update-zvec-c.sh [tag]    # default: the latest release
#
# The build runs in a sandbox with no network, so each of the archives is a fixed-output
# derivation of its own. They are not pinned by hand: the file versions.txt of the Arrow in the
# tree names the version and the sha256 of each. The run downloads the archive from its
# upstream and fails unless its hash is that sha256, so that what is pinned is what Arrow itself
# would have accepted. The mirrors that Arrow falls back on are not used.
#
# It also checks the tree against what the build relies on: the functions that c_api.h
# declares are the ones that the version script exports (they are the library), the version
# can be given to CMake in place of git, and the submodules are all there.
#
# Needs: gh, jq, nix.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo=alibaba/zvec

fail() {
  echo "$*" >&2
  exit 1
}

if [ -n "${1:-}" ]; then
  tag="$1"
  echo "tag: $tag (given)"
else
  tag="$(gh release list -R "$repo" --exclude-pre-releases --limit 1 --json tagName --jq '.[].tagName')"
  echo "tag: $tag (the latest release)"
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the tag $tag is not vX.Y.Z"
version="${tag#v}"

# an annotated tag points at a tag object, which points at the commit
ref="$(gh api "repos/$repo/git/ref/tags/$tag")"
type="$(jq -r .object.type <<<"$ref")"
rev="$(jq -r .object.sha <<<"$ref")"
while [ "$type" = tag ]; do
  object="$(gh api "repos/$repo/git/tags/$rev")"
  type="$(jq -r .object.type <<<"$object")"
  rev="$(jq -r .object.sha <<<"$object")"
done
[ "$type" = commit ] || fail "the tag $tag points at a $type, not at a commit"
echo "rev: $rev"

# the sources with every submodule, as the fetcher gets them; the path is the one in the Nix
# store, which is only read from here on
nix run nixpkgs#nix-prefetch-git -- \
  --url "https://github.com/$repo" --rev "$rev" --fetch-submodules --quiet >"$work/prefetch.json"
src_hash="$(nix hash convert --hash-algo sha256 --to sri "$(jq -r .sha256 "$work/prefetch.json")")"
src="$(jq -r .path "$work/prefetch.json")"
[ -d "$src" ] || fail "nix-prefetch-git printed $src, which is not a directory"
echo "hash: $src_hash ($src)"

# the interface: the functions that c_api.h declares and the ones that the version script
# exports (the others stay out of the library), name by name
header="$src/src/include/zvec/c_api.h"
symbols="$src/src/binding/c/exported_symbols.lds"
declared="$(tr '\n' ' ' <"$header" | grep -oE 'ZVEC_EXPORT[^();]*\(' | grep -oE 'zvec_[a-z0-9_]+\($' | tr -d '(' | sort || true)"
exported="$(sed -n '/global:/,/local:/p' "$symbols" | grep -oE '[A-Za-z_][A-Za-z0-9_]*;' | tr -d ';' | sort || true)"
[ -n "$declared" ] || fail "$header: no ZVEC_EXPORT function declarations found"
[ -n "$exported" ] || fail "$symbols: no symbols found in global:"
if [ "$declared" != "$exported" ]; then
  echo "c_api.h declares (<) and exported_symbols.lds exports (>) different functions:" >&2
  diff <(echo "$declared") <(echo "$exported") >&2 || true
  exit 1
fi
echo "interface: $(wc -l <<<"$declared") functions declared and exported"

# the version, which zvec takes from git unless it is given
grep -q OVERRIDE_GIT_DESCRIBE "$src/cmake/version.cmake" ||
  fail "cmake/version.cmake does not mention OVERRIDE_GIT_DESCRIBE"

# the submodules: .gitmodules may name more than the tree has (it does at v0.8.1, for libaio),
# so the ones to be there are the commits that the tree itself links, and each of them must
# have been fetched
modules="$(sed -n 's/^[[:space:]]*path = //p' "$src/.gitmodules" | sort)"
[ -n "$modules" ] || fail ".gitmodules names no submodule"
tree="$(gh api "repos/$repo/git/trees/$rev?recursive=1")"
[ "$(jq -r .truncated <<<"$tree")" = false ] || fail "the listing of the tree of $rev is truncated"
links="$(jq -r '.tree[] | select(.type == "commit") | .path' <<<"$tree" | sort)"
[ -n "$links" ] || fail "the tree of $rev links no submodule"
while read -r path; do
  [ -n "$(ls -A "$src/$path" 2>/dev/null)" ] || fail "the submodule $path is missing or empty"
done <<<"$links"
echo "submodules: $(wc -l <<<"$modules") in .gitmodules, $(wc -l <<<"$links") linked by the tree, all of those fetched"
unlinked="$(comm -23 <(echo "$modules") <(echo "$links"))"
[ -z "$unlinked" ] || echo "submodules: in .gitmodules but not linked, so not fetched: $(tr '\n' ' ' <<<"$unlinked")"

# Arrow, which the name of its directory says the version of
candidates=("$src"/thirdparty/arrow/apache-arrow-*/cpp/thirdparty/versions.txt)
[ "${#candidates[@]}" = 1 ] && [ -f "${candidates[0]}" ] ||
  fail "expected one thirdparty/arrow/apache-arrow-*/cpp/thirdparty/versions.txt, found: ${candidates[*]}"
versions="${candidates[0]}"
echo "arrow: ${versions#"$src"/}"

# the value of a line of versions.txt that appears exactly once, matched as text (the file is
# the shell script that Arrow's own tools source, and it is not run here)
versions_line() { # <sed expression that prints the value>
  local found
  found="$(sed -n "$1" "$versions")"
  if [ -z "$found" ] || [ "$(wc -l <<<"$found")" != 1 ]; then
    fail "$versions: expected exactly one match of $1, found: ${found:-none}"
  fi
  echo "$found"
}

# the dependencies that Arrow downloads for the configuration of zvec (thirdparty/arrow/
# CMakeLists.txt: bundled dependencies, Parquet, no OpenSSL), the Arrow variable of each and
# where the archive comes from (@V@ is the version)
dependencies=(
  "boost BOOST https://github.com/boostorg/boost/releases/download/boost-@V@/boost-@V@-cmake.tar.gz"
  "thrift THRIFT https://archive.apache.org/dist/thrift/@V@/thrift-@V@.tar.gz"
  "rapidjson RAPIDJSON https://github.com/miloyip/rapidjson/archive/@V@.tar.gz"
  "re2 RE2 https://github.com/google/re2/archive/@V@.tar.gz"
  "utf8proc UTF8PROC https://github.com/JuliaStrings/utf8proc/archive/@V@.tar.gz"
  "xsimd XSIMD https://github.com/xtensor-stack/xsimd/archive/@V@.tar.gz"
  "zlib ZLIB https://zlib.net/fossils/zlib-@V@.tar.gz"
)

arrow='{}'
for dependency in "${dependencies[@]}"; do
  read -r key var template <<<"$dependency"

  dep_version="$(versions_line "s/^ARROW_${var}_BUILD_VERSION=//p")"
  [[ "$dep_version" =~ ^[A-Za-z0-9._-]+$ ]] || fail "ARROW_${var}_BUILD_VERSION=$dep_version is not a version"
  expected_hex="$(versions_line "s/^ARROW_${var}_BUILD_SHA256_CHECKSUM=//p")"
  [[ "$expected_hex" =~ ^[0-9a-f]{64}$ ]] || fail "ARROW_${var}_BUILD_SHA256_CHECKSUM=$expected_hex is not a sha256"
  expected="$(nix hash convert --hash-algo sha256 --from base16 --to sri "$expected_hex")"

  # the name that Arrow gives the file it downloads, from its list of dependencies
  # ("ARROW_BOOST_URL boost-${ARROW_BOOST_BUILD_VERSION}-cmake.tar.gz https://..."), which the
  # derivation of the archive takes so that the file is the one Arrow looks for
  placeholder="\${ARROW_${var}_BUILD_VERSION}"
  name="$(versions_line "s/^[[:space:]]*\"ARROW_${var}_URL \([^ ]*\) .*/\1/p")"
  name="${name//"$placeholder"/$dep_version}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$key: Arrow names the file $name"

  url="${template//@V@/$dep_version}"
  dep_hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"
  if [ "$dep_hash" != "$expected" ]; then
    fail "$key: $url hashes to $dep_hash, versions.txt of Arrow says $expected ($expected_hex)"
  fi
  echo "ok: $key $dep_version $name $dep_hash"

  arrow="$(jq -c --arg key "$key" --arg name "$name" --arg url "$url" --arg hash "$dep_hash" --arg version "$dep_version" \
    '. + {($key): {name: $name, url: $url, hash: $hash, version: $version}}' <<<"$arrow")"
done

mkdir -p "$root/pkgs/zvec-c"
jq -S -n \
  --arg version "$version" \
  --arg tag "$tag" \
  --arg rev "$rev" \
  --arg hash "$src_hash" \
  --argjson arrow "$arrow" \
  '{version: $version, tag: $tag, rev: $rev, hash: $hash, arrow: $arrow}' >"$work/pin.json"
mv "$work/pin.json" "$root/pkgs/zvec-c/pin.json"
echo "pinned $repo $tag ($rev) in pkgs/zvec-c/pin.json"
