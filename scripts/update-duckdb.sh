#!/usr/bin/env bash
# Regenerate every pin from an upstream DuckDB release, computing all hashes
# here rather than copying them from anywhere:
#
#   pkgs/duckdb/versions/<version>/version.json   DuckDB itself: version, commit, hash
#   pkgs/duckdb/versions/<version>/pins.json      each extension (and the submodules it
#                                                 needs) at the commit that release pins
#                                                 in .github/config/extensions/*.cmake,
#                                                 and the community ones named below
#   pkgs/duckdb/versions/<version>/python.json    duckdb-python at the same tag, for the Python module
#   pkgs/duckdb/versions/<version>/rust-consumer.json  before 2.0, the duckdb crate that goes with the
#                                                 release, with the lock file of the example program
#   pkgs/duckdb/versions/<version>/unavailable.json  the community extensions the registry
#                                                 published no build of for that release
#   pkgs/duckdb/versions/<version>/loadable.json  a community extension that cannot be linked in: its sources,
#                                                 and the registry's own build, for each system
#
#   scripts/update-duckdb.sh [tag]     # default: the latest DuckDB release
#
# Needs: gh, jq, nix. Submodules other than extension-ci-tools (which only CI
# uses) are pinned too, since GitHub tarballs do not include submodules.
#
# Everything is built in a temporary directory and replaces the version's
# directory only once the whole run has succeeded, so a failure leaves the
# previous state alone. What a release does not have is skipped with a message:
# lance and delta in the releases before they were added, for one. A community
# extension is pinned only if the registry published a build of it for exactly
# this release, at the descriptor the registry had while it built that release.
# COMMUNITY_REV=<commit of duckdb/community-extensions> overrides which.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

raw() { gh api -H "Accept: application/vnd.github.raw" "$1"; }
prefetch() { nix flake prefetch "github:$1/$2" --json | jq -r .hash; }

tag="${1:-$(gh release list -R duckdb/duckdb --exclude-pre-releases --limit 1 --json tagName --jq '.[].tagName')}"

# one directory of state for each DuckDB version, which is written last
dir="$root/pkgs/duckdb/versions/${tag#v}"
# what the previous run of this release left, for the parts that should not change with the day
previous="$dir"
stage="$work/stage"
mkdir -p "$stage/rust"
versions="$stage/version.json"
out="$stage/pins.json"

# DuckDB itself. An annotated tag points at a tag object, not the commit.
read -r type sha < <(gh api "repos/duckdb/duckdb/git/ref/tags/$tag" --jq '"\(.object.type) \(.object.sha)"')
if [ "$type" = tag ]; then
  sha="$(gh api "repos/duckdb/duckdb/git/tags/$sha" --jq .object.sha)"
fi
jq -n --arg version "${tag#v}" --arg rev "$sha" --arg hash "$(prefetch duckdb/duckdb "$tag")" \
  '{version: $version, rev: $rev, hash: $hash}' >"$versions"
echo "version.json: duckdb $tag @ ${sha:0:10}" >&2

# The submodules of a repository at a commit, as the commit the pin records for each:
# a JSON object of path to {owner, repo, rev, hash}. GitHub tarballs have none.
pin_submodules() { # repo  commit  path...
  local repo="$1" sha="$2" subs='{}' path gm_url sub_sha sub_repo
  shift 2
  for path in "$@"; do
    gm_url="$(raw "repos/$repo/contents/.gitmodules?ref=$sha" |
      awk -v p="$path" '$1=="path"{cur=$3} $1=="url" && cur==p {print $3}')"
    sub_repo="${gm_url#https://github.com/}"
    sub_repo="${sub_repo%.git}"
    sub_sha="$(gh api "repos/$repo/git/trees/$sha?recursive=1" \
      --jq ".tree[]|select(.mode==\"160000\" and .path==\"$path\")|.sha")"
    subs="$(jq -c --arg p "$path" --arg o "${sub_repo%%/*}" --arg r "${sub_repo##*/}" \
      --arg v "$sub_sha" --arg h "$(prefetch "$sub_repo" "$sub_sha")" \
      '. + {($p): {owner:$o, repo:$r, rev:$v, hash:$h}}' <<<"$subs")"
  done
  echo "$subs"
}

pin_one() {
  local file="$1" cfg name url sha subm incl patches repo
  cfg="$(raw "repos/duckdb/duckdb/contents/.github/config/extensions/$file?ref=$tag")"
  name="$(sed -n 's/^[[:space:]]*duckdb_extension_load([[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' <<<"$cfg" | head -1)"
  url="$(awk '$1=="GIT_URL"{print $2; exit}' <<<"$cfg")"
  sha="$(awk '$1=="GIT_TAG"{print $2; exit}' <<<"$cfg")"
  [ -n "$name" ] && [ -n "$url" ] && [ -n "$sha" ] || { echo "skip $file (no git source)" >&2; return 0; }
  subm="$(awk '$1=="SUBMODULES"{print $2; exit}' <<<"$cfg" | tr -d '"')"
  incl="$(awk '$1=="INCLUDE_DIR"{print $2; exit}' <<<"$cfg")"
  patches=false
  grep -q APPLY_PATCHES <<<"$cfg" && patches=true
  repo="${url#https://github.com/}"
  repo="${repo%.git}"

  local hash
  hash="$(prefetch "$repo" "$sha")"

  # the submodules the build needs, which is none of the ones CI uses
  local subs='{}' paths=() path
  for path in $subm; do
    [ "$path" = extension-ci-tools ] || paths+=("$path")
  done
  if [ "${#paths[@]}" -gt 0 ]; then
    subs="$(pin_submodules "$repo" "$sha" "${paths[@]}")"
  fi

  jq -n --arg name "$name" --arg o "${repo%%/*}" --arg r "${repo##*/}" --arg rev "$sha" \
    --arg hash "$hash" --arg incl "$incl" --argjson patches "$patches" --argjson subs "$subs" \
    '{($name): ({owner:$o, repo:$r, rev:$rev, hash:$hash, patches:$patches}
      + (if $incl == "" then {} else {include:$incl} end)
      + (if $subs == {} then {} else {submodules:$subs} end))}' >"$work/$name.json"
  echo "pinned $name" >&2
}

export -f pin_one pin_submodules raw prefetch
export tag work

# test-utils is an internal backwards-compatibility test extension. Each pin_one
# runs in a shell of its own, which must stop at the first failure as this one does.
gh api "repos/duckdb/duckdb/contents/.github/config/extensions?ref=$tag" --jq '.[].name' |
  grep -v '^test-utils' |
  xargs -P 8 -I{} bash -e -o pipefail -c 'pin_one {}'

# Community extensions are not in DuckDB's own config. Their descriptors in
# duckdb/community-extensions name the commit to build, and the registry builds
# each DuckDB release it supports from the descriptors it has while it targets
# that release. So for a release the descriptors to read are the registry's last
# commit while it targeted exactly this release, and an extension is only pinned
# if the registry published a build of it for the release: the descriptor of one
# that failed to build, or was added later, says nothing about this release. The
# DuckDB submodule of the extension's own repository is not part of that: the
# registry builds against the release tag whatever it points at.
#
# A descriptor is not proof that the repository has the extension: for DuckDB 2.0
# the Query.Farm ones (datasketches, hashfuncs, crypto, ...) are stubs that load
# a build from Query.Farm's own repository, or fail saying how to install it, and
# linked in they would fail at startup. Read src/ before adding one.
community=(
  duckpgq
  psql
  sheetreader
  webbed
  zipfs
)

# The registry bumps the DuckDB it builds with in generate_docs.yml, among others.
# The last commit before the bump that left this release is the one to read; for
# the release it is on now, the latest.
registry_workflow=.github/workflows/generate_docs.yml
registry_rev() { # tag
  local sha newer='' found=''
  while read -r sha; do
    if raw "repos/duckdb/community-extensions/contents/$registry_workflow?ref=$sha" | grep -q "releases/download/$1/"; then
      found="$sha"
      break
    fi
    newer="$sha"
  done < <(gh api --paginate "repos/duckdb/community-extensions/commits?path=$registry_workflow&per_page=100" --jq '.[].sha')
  [ -n "$found" ] || { echo "the community-extensions registry never built with DuckDB $1" >&2; return 1; }
  if [ -z "$newer" ]; then
    gh api repos/duckdb/community-extensions/commits/main --jq .sha
  else
    gh api "repos/duckdb/community-extensions/commits/$newer" --jq '.parents[0].sha'
  fi
}
if [ -n "${COMMUNITY_REV:-}" ]; then
  community_rev="$COMMUNITY_REV"
else
  community_rev="$(registry_rev "$tag")"
  raw "repos/duckdb/community-extensions/contents/$registry_workflow?ref=$community_rev" | grep -q "releases/download/$tag/" ||
    { echo "the registry at ${community_rev:0:10} does not build with DuckDB $tag" >&2; exit 1; }
fi
echo "community extensions as of duckdb/community-extensions@${community_rev:0:10}" >&2

# the registry's published build of an extension for this release
published() { # name
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 60 \
    "https://community-extensions.duckdb.org/$tag/linux_amd64/$1.duckdb_extension.gz")"
  case "$code" in
    200) return 0 ;;
    403 | 404) return 1 ;;
    *) echo "$1: HTTP $code asking whether the registry published it for $tag" >&2; exit 1 ;;
  esac
}
mkdir -p "$work/unavailable" "$work/loadable"
unavailable() { # name  reason
  echo "skip $1: $2" >&2
  jq -n --arg n "$1" --arg r "$2" '{($n): $r}' >"$work/unavailable/$1.json"
}
# What was built against a fork cannot be linked in, but it can be built on its own, as the
# registry builds it: the extension and the fork it names as its DuckDB, loaded with LOAD.
# That build is not signed. The registry's own build is signed, so it is pinned as well,
# as the files for each system it published.
loadable() { # name  extension repo  commit  fork URL
  local platforms='{}' pair system platform url fork fork_sha
  fork="${4#https://github.com/}"
  fork="${fork#git@github.com:}"
  fork="${fork%.git}"
  fork_sha="$(gh api "repos/$2/git/trees/$3" --jq '.tree[] | select(.path == "duckdb") | .sha')"
  for pair in x86_64-linux:linux_amd64 aarch64-linux:linux_arm64 x86_64-darwin:osx_amd64 aarch64-darwin:osx_arm64; do
    system="${pair%%:*}"
    platform="${pair##*:}"
    url="https://community-extensions.duckdb.org/$tag/$platform/$1.duckdb_extension.gz"
    if curl -sfI --max-time 60 "$url" >/dev/null; then
      platforms="$(jq -c --arg s "$system" --arg u "$url" --arg h "$(nix store prefetch-file --json "$url" | jq -r .hash)" \
        '. + {($s): {url: $u, hash: $h}}' <<<"$platforms")"
    fi
  done
  jq -n --arg n "$1" --argjson p "$platforms" \
    --arg eo "${2%%/*}" --arg er "${2##*/}" --arg erev "$3" --arg eh "$(prefetch "$2" "$3")" \
    --arg fo "${fork%%/*}" --arg fr "${fork##*/}" --arg frev "$fork_sha" --arg fh "$(prefetch "$fork" "$fork_sha")" \
    '{($n): {platforms: $p,
             source: {extension: {owner: $eo, repo: $er, rev: $erev, hash: $eh},
                      duckdb: {owner: $fo, repo: $fr, rev: $frev, hash: $fh}}}}' >"$work/loadable/$1.json"
  echo "pinned $1 (the registry's build, loadable)" >&2
}
for name in "${community[@]}"; do
  if ! published "$name"; then
    unavailable "$name" "the community-extensions registry published no build of it for DuckDB $tag"
    continue
  fi
  descriptor="https://raw.githubusercontent.com/duckdb/community-extensions/$community_rev/extensions/$name/description.yml"
  repo="$(curl -fsSL "$descriptor" | awk '/^repo:/ {in_repo = 1; next} in_repo && $1 == "github:" {print $2; exit}')"
  # the ref may be quoted
  sha="$(curl -fsSL "$descriptor" | awk '/^repo:/ {in_repo = 1; next} in_repo && $1 == "ref:" {print $2; exit}' | tr -d "'\"")"
  [ -n "$repo" ] && [ -n "$sha" ] || { echo "$name: no repository and ref in $descriptor" >&2; exit 1; }
  # One whose repository builds against a fork of DuckDB needs what the fork changed:
  # duckpgq before 2.0 has its property graph parser in the fork's core, and its
  # headers are not in DuckDB.
  duckdb_url="$(raw "repos/$repo/contents/.gitmodules?ref=$sha" |
    awk '$1 == "path" {cur = $3} $1 == "url" && cur == "duckdb" {print $3}')"
  case "$duckdb_url" in
    "" | *duckdb/duckdb | *duckdb/duckdb.git) ;;
    *)
      unavailable "$name" "its repository builds against a fork of DuckDB ($duckdb_url), whose changes to the parser DuckDB $tag does not have, so it cannot be linked in; it is offered in loadableExtensions"
      loadable "$name" "$repo" "$sha" "$duckdb_url"
      continue
      ;;
  esac
  # an extension repository has DuckDB and the CI tools as submodules, which the
  # build does not use; any other is part of the extension
  submodule_paths="$(gh api "repos/$repo/git/trees/$sha?recursive=1" --jq '.tree[] | select(.mode == "160000") | .path')"
  mapfile -t paths < <(grep -v -x -e duckdb -e extension-ci-tools <<<"$submodule_paths" || true)
  subs='{}'
  if [ "${#paths[@]}" -gt 0 ]; then
    subs="$(pin_submodules "$repo" "$sha" "${paths[@]}")"
  fi
  jq -n --arg name "$name" --arg o "${repo%%/*}" --arg r "${repo##*/}" --arg rev "$sha" \
    --arg hash "$(prefetch "$repo" "$sha")" --arg crev "$community_rev" \
    --arg dhash "$(nix store prefetch-file --json "$descriptor" | jq -r .hash)" \
    --argjson subs "$subs" \
    '{($name): ({owner: $o, repo: $r, rev: $rev, hash: $hash, patches: false,
                 community: {rev: $crev, descriptorHash: $dhash}}
      + (if $subs == {} then {} else {submodules: $subs} end))}' >"$work/$name.json"
  echo "pinned $name (community)" >&2
done

# whether the release has an extension, after pin_one
pinned() { [ -f "$work/$1.json" ]; }

# The delta extension clones delta-kernel-rs and builds it with cargo. Pin the
# repository and tag its own CMake names, so Nix can build it instead.
if pinned delta; then
  delta_rev="$(jq -r .delta.rev "$work/delta.json")"
  kernel_cmake="$(raw "repos/duckdb/duckdb-delta/contents/CMakeLists.txt?ref=$delta_rev")"
  kernel_repo="$(awk '$1=="GIT_REPOSITORY"{gsub(/"/,"",$2); print $2; exit}' <<<"$kernel_cmake")"
  kernel_repo="${kernel_repo#https://github.com/}"
  kernel_tag="$(awk '$1=="GIT_TAG"{print $2; exit}' <<<"$kernel_cmake")"
  [ -n "$kernel_repo" ] && [ -n "$kernel_tag" ] || { echo "no delta-kernel-rs in duckdb-delta's CMake" >&2; exit 1; }
  jq --arg o "${kernel_repo%%/*}" --arg r "${kernel_repo##*/}" --arg t "$kernel_tag" \
    --arg h "$(prefetch "$kernel_repo" "$kernel_tag")" \
    '.delta.kernel = {owner: $o, repo: $r, rev: $t, hash: $h}' "$work/delta.json" >"$work/delta.json.new"
  mv "$work/delta.json.new" "$work/delta.json"
  echo "pinned delta-kernel-rs $kernel_tag" >&2
else
  echo "skip delta-kernel-rs: $tag has no delta extension" >&2
fi

# Before 2.0 the avro extension finds avro-c as a library that vcpkg builds, from
# DuckDB's fork of it, at the revision that the port in the registry names. Pin that
# fork too, so Nix can build it. From 2.0 the fork is a submodule, pinned with the rest.
if pinned avro && ! jq -e '.avro.submodules["third_party/avro-c"]' "$work/avro.json" >/dev/null; then
  avro_repo="$(jq -r '.avro | "\(.owner)/\(.repo)"' "$work/avro.json")"
  avro_rev="$(jq -r .avro.rev "$work/avro.json")"
  baseline="$(raw "repos/$avro_repo/contents/vcpkg.json?ref=$avro_rev" | jq -r '.["vcpkg-configuration"].registries[0].baseline')"
  avro_c_rev="$(raw "repos/duckdb/vcpkg-duckdb-ports/contents/ports/avro-c/portfile.cmake?ref=$baseline" | awk '$1=="REF"{print $2; exit}')"
  [ -n "$baseline" ] && [ -n "$avro_c_rev" ] || { echo "no avro-c in the vcpkg registry of $avro_repo" >&2; exit 1; }
  jq --arg r "$avro_c_rev" --arg h "$(prefetch duckdb/duckdb-avro-c "$avro_c_rev")" \
    '.avro.avroC = {owner: "duckdb", repo: "duckdb-avro-c", rev: $r, hash: $h}' "$work/avro.json" >"$work/avro.json.new"
  mv "$work/avro.json.new" "$work/avro.json"
  echo "pinned duckdb-avro-c ${avro_c_rev:0:10}" >&2
fi

jq -S -s 'add' "$work"/*.json >"$out"
echo "pins.json: $(jq 'length' "$out") extensions, duckdb $tag" >&2

# Rust extensions build offline from their Cargo.lock. It is copied in here so
# that evaluating the flake needs no network and no import from derivation.
locks="$stage/rust"
# A repository that does not commit its Cargo.lock (delta-kernel-rs does not, in
# the tags DuckDB 1.x pins) gets one resolved here against crates.io, with the
# same cargo as relock_vortex. The result is as pinned as a committed one.
generate_lock() { # name  owner/repo  rev
  local src="$work/lockgen-$1"
  cp -R "$(nix flake prefetch "github:$2/$3" --json | jq -r .storePath)" "$src"
  chmod -R u+w "$src"
  (cd "$src" && nix shell nixpkgs#cargo nixpkgs#rustc -c cargo generate-lockfile >&2)
  cp "$src/Cargo.lock" "$locks/$1.Cargo.lock"
}
vendor_lock() { # name  jq path of its source in pins.json  Cargo.lock path in that repo
  local repo rev err="$work/vendor_lock.err" how=
  repo="$(jq -r "$2 | \"\(.owner)/\(.repo)\"" "$out")"
  rev="$(jq -r "$2.rev" "$out")"
  # A lock resolved against crates.io depends on the day it was resolved, so one kept
  # from the previous run of the same revision is not resolved again.
  if [ -f "$previous/pins.json" ] && [ -f "$previous/rust/$1.Cargo.lock" ] && [ "$(jq -r "$2.rev // empty" "$previous/pins.json")" = "$rev" ]; then
    cp "$previous/rust/$1.Cargo.lock" "$locks/$1.Cargo.lock"
    echo "kept $1.Cargo.lock of the previous run ($repo@${rev:0:10} is unchanged)" >&2
    return 0
  fi
  if ! raw "repos/$repo/contents/$3?ref=$rev" >"$locks/$1.Cargo.lock" 2>"$err"; then
    # only a missing file is not an error
    grep -q 'HTTP 404' "$err" || { cat "$err" >&2; return 1; }
    generate_lock "$1" "$repo" "$rev"
    how=", generated: $repo@$rev has no $3"
  fi
  echo "vendored $1.Cargo.lock ($(grep -c '^\[\[package\]\]' "$locks/$1.Cargo.lock") crates$how)" >&2
}
# A crate in a lock that does not compile with the Rust toolchain used here is raised
# to the first release that does. ethnum before 1.5.3 transmutes `()` into a
# TryFromIntError, which is no longer the size of nothing.
bump_crate() { # name  jq path of its source in pins.json  crate  version
  local current repo rev src
  current="$(grep -A1 "^name = \"$3\"\$" "$locks/$1.Cargo.lock" | sed -n 's/^version = "\(.*\)"$/\1/p' | head -n 1)"
  # nothing to do if the lock has no such crate or has this release or a later one
  [ -n "$current" ] || return 0
  [ "$(printf '%s\n%s\n' "$current" "$4" | sort -V | head -n 1)" = "$current" ] && [ "$current" != "$4" ] || return 0
  repo="$(jq -r "$2 | \"\(.owner)/\(.repo)\"" "$out")"
  rev="$(jq -r "$2.rev" "$out")"
  src="$work/bump-$1"
  cp -R "$(nix flake prefetch "github:$repo/$rev" --json | jq -r .storePath)" "$src"
  chmod -R u+w "$src"
  cp "$locks/$1.Cargo.lock" "$src/Cargo.lock"
  (cd "$src" && nix shell nixpkgs#cargo nixpkgs#rustc -c cargo update -p "$3" --precise "$4" >&2)
  cp "$src/Cargo.lock" "$locks/$1.Cargo.lock"
  echo "raised $3 in $1.Cargo.lock from $current to $4" >&2
}
if pinned lance; then
  vendor_lock lance .lance Cargo.lock
  bump_crate lance .lance ethnum 1.5.3
else
  echo "skip lance.Cargo.lock: $tag has no lance extension" >&2
fi
if pinned delta; then
  vendor_lock delta .delta.kernel Cargo.lock
fi

# The Cargo.lock that duckdb-vortex commits does not match its own Cargo.toml: it
# pins an older vortex revision than the manifest asks for. Upstream never
# notices, since its CMake runs a plain `cargo build`, which re-resolves online.
# Do that here, touching only vortex-duckdb and what depends on it, so the
# offline Nix build can use --locked.
relock_vortex() {
  local repo rev dir f
  repo="$(jq -r '.vortex | "\(.owner)/\(.repo)"' "$out")"
  rev="$(jq -r '.vortex.rev' "$out")"
  if [ -f "$previous/pins.json" ] && [ -f "$previous/rust/vortex.Cargo.lock" ] && [ "$(jq -r '.vortex.rev // empty' "$previous/pins.json")" = "$rev" ]; then
    cp "$previous/rust/vortex.Cargo.lock" "$locks/vortex.Cargo.lock"
    echo "kept vortex.Cargo.lock of the previous run ($repo@${rev:0:10} is unchanged)" >&2
    return 0
  fi
  dir="$work/vortex-relock/vortex-extension"
  mkdir -p "$dir/src"
  for f in Cargo.toml Cargo.lock; do
    raw "repos/$repo/contents/vortex-extension/$f?ref=$rev" >"$dir/$f"
  done
  for f in $(gh api "repos/$repo/contents/vortex-extension/src?ref=$rev" --jq '.[].name'); do
    raw "repos/$repo/contents/vortex-extension/src/$f?ref=$rev" >"$dir/src/$f"
  done
  (cd "$dir" && nix shell nixpkgs#cargo nixpkgs#rustc -c cargo update -p vortex-duckdb >&2)
  cp "$dir/Cargo.lock" "$locks/vortex.Cargo.lock"
  echo "vendored vortex.Cargo.lock, re-resolved ($(grep -c '^\[\[package\]\]' "$locks/vortex.Cargo.lock") crates)" >&2
}
if pinned vortex; then
  if jq -e '.vortex.submodules.vortex' "$out" >/dev/null; then
    # Before 2.0 the Rust is the vortex repository itself, a submodule (SUBMODULES
    # in the config), and its Cargo.lock is in step with its own sources.
    vendor_lock vortex .vortex.submodules.vortex Cargo.lock
  else
    relock_vortex
  fi
else
  echo "skip vortex.Cargo.lock: vortex is not pinned for $tag" >&2
fi

# Some of vortex's Rust dependencies come from git. Nix wants a hash for each
# `source` string in the lock, of the checkout as fetchgit makes it: with submodules
# (its default) and without LFS. One prefetch per repository and commit, shared by
# every crate from it.
#
# Prefetching also puts the checkout in the store, at the path its hash names. A hash
# computed with options that differ from fetchgit's therefore builds on this machine,
# since nothing is fetched, and fails everywhere else. Check a change with
# `nix build .#rust-vortex.cargoDeps --rebuild`, or let CI do it on a clean store.
git_hashes() { # Cargo.lock -> JSON object of lock source string to hash
  local lock="$1" source url rev key json='{}'
  declare -A hashes=()
  while IFS= read -r source; do
    url="${source#git+}"
    url="${url%%\?*}"
    url="${url%%#*}"
    rev="${source##*#}"
    key="$url $rev"
    if [ -z "${hashes[$key]:-}" ]; then
      hashes[$key]="$(nix run nixpkgs#nix-prefetch-git -- --quiet --fetch-submodules --url "$url" --rev "$rev" | jq -r .hash)"
      echo "prefetched $url @ ${rev:0:10}" >&2
    fi
    json="$(jq -c --arg s "$source" --arg h "${hashes[$key]}" '. + {($s): $h}' <<<"$json")"
  done < <(grep -o 'source = "git+[^"]*"' "$lock" | sed 's/^source = "//; s/"$//' | sort -u)
  echo "$json"
}
if pinned vortex; then
  jq -S --argjson hashes "$(git_hashes "$locks/vortex.Cargo.lock")" '.vortex.gitHashes = $hashes' "$out" >"$work/pins.json"
  mv "$work/pins.json" "$out"
fi

# The Rust program of examples/rust-consumer is written for the `duckdb` crate of DuckDB 2.0.
# For an older release it is built with the crate of that release, and its Cargo.lock is
# resolved here. The crate is numbered as the release up to 1.4, and from 1.5 as
# 1.<major * 10000 + minor * 100 + patch>.<n>, with the highest n published.
crate_for() { # version
  local major minor patch code
  IFS=. read -r major minor patch <<<"$1"
  if [ "$major" -eq 1 ] && [ "$minor" -le 4 ]; then
    echo "$1"
    return
  fi
  code=$((major * 10000 + minor * 100 + patch))
  curl -fsSL -A "engram update-duckdb.sh" "https://crates.io/api/v1/crates/duckdb/versions?per_page=100" |
    jq -r --arg p "1.$code." '[.versions[].num | select(startswith($p))] | sort_by(split(".") | map(tonumber)) | last // empty'
}
release_major="${tag#v}"
release_major="${release_major%%.*}"
if [ "$release_major" -lt 2 ]; then
  crate="$(crate_for "${tag#v}")"
  [ -n "$crate" ] || { echo "no duckdb crate for DuckDB $tag" >&2; exit 1; }
  jq -n --arg c "$crate" '{crate: $c}' >"$stage/rust-consumer.json"
  if [ -f "$previous/rust-consumer.json" ] && [ "$(jq -r .crate "$previous/rust-consumer.json")" = "$crate" ] &&
    [ -f "$previous/rust/rust-consumer.Cargo.lock" ]; then
    cp "$previous/rust/rust-consumer.Cargo.lock" "$locks/rust-consumer.Cargo.lock"
    echo "kept rust-consumer.Cargo.lock of the previous run (duckdb crate $crate is unchanged)" >&2
  else
    consumer="$work/rust-consumer"
    cp -R "$root/examples/rust-consumer" "$consumer"
    chmod -R u+w "$consumer"
    rm -f "$consumer/Cargo.lock"
    sed -i "s/=1\.20000\.1/=$crate/" "$consumer/Cargo.toml"
    grep -q "=$crate" "$consumer/Cargo.toml"
    (cd "$consumer" && nix shell nixpkgs#cargo nixpkgs#rustc -c cargo generate-lockfile >&2)
    cp "$consumer/Cargo.lock" "$locks/rust-consumer.Cargo.lock"
    echo "resolved rust-consumer.Cargo.lock for the duckdb crate $crate" >&2
  fi
fi

# The Python module is the duckdb-python repository at the same tag. It builds DuckDB from its
# external/duckdb submodule, which has to be this release for the module to be this DuckDB's.
python_sha="$(gh api "repos/duckdb/duckdb-python/git/ref/tags/$tag" --jq '"\(.object.type) \(.object.sha)"')"
read -r python_type python_sha <<<"$python_sha"
if [ "$python_type" = tag ]; then
  python_sha="$(gh api "repos/duckdb/duckdb-python/git/tags/$python_sha" --jq .object.sha)"
fi
python_duckdb="$(gh api "repos/duckdb/duckdb-python/git/trees/$python_sha?recursive=1" \
  --jq '.tree[] | select(.path == "external/duckdb") | .sha')"
[ "$python_duckdb" = "$(jq -r .rev "$versions")" ] ||
  { echo "duckdb-python $tag builds DuckDB ${python_duckdb:0:10}, not $tag" >&2; exit 1; }
jq -n --arg rev "$python_sha" --arg hash "$(prefetch duckdb/duckdb-python "$tag")" \
  '{owner: "duckdb", repo: "duckdb-python", rev: $rev, hash: $hash}' >"$stage/python.json"
echo "python.json: duckdb-python $tag @ ${python_sha:0:10}" >&2

# What the registry did not publish for this release, so the flake can say why.
if [ -n "$(find "$work/unavailable" -name '*.json' -print -quit)" ]; then
  jq -S -s add "$work"/unavailable/*.json >"$stage/unavailable.json"
fi
if [ -n "$(find "$work/loadable" -name '*.json' -print -quit)" ]; then
  jq -S -s add "$work"/loadable/*.json >"$stage/loadable.json"
fi

# A failed command substitution in an argument does not stop the script, and would
# leave an empty hash behind.
jq -e -s '[.. | objects | select(has("hash")) | .hash | select(startswith("sha256-") | not)] | length == 0' \
  "$versions" "$out" >/dev/null || { echo "a hash is missing from version.json or pins.json, nothing written" >&2; exit 1; }

# Everything worked: replace the previous state of the release with the new one,
# including the lock files of extensions it no longer pins.
mkdir -p "$dir"
rm -rf "$dir/version.json" "$dir/pins.json" "$dir/unavailable.json" "$dir/loadable.json" "$dir/python.json" "$dir/rust-consumer.json" "$dir/rust"
cp -R "$stage"/. "$dir"/
echo "wrote $dir (duckdb $tag, $(jq 'length' "$out") extensions, $(find "$locks" -type f | wc -l) Cargo.lock files)" >&2
