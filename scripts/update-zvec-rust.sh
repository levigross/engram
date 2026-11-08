#!/usr/bin/env bash
# Pin zvec-rust, the Rust bindings that the zvec team publishes for the C interface of zvec:
# zvec-rust-sys (the raw bindings) and zvec-rust (the safe ones). pkgs/zvec-rust/pin.json gets
# the version, the hash of each crate, and the commit and the source hash of the repository
# they are published from (zvec-ai/zvec-rust), with the commit of zvec that the repository has
# as its submodule; pkgs/zvec-rust/Cargo.lock gets a copy of the lock file of that repository
# (a checked-in copy, because reading it from the fetched source inside Nix would be
# import-from-derivation); and the lock file of the consumer, examples/zvec-rust-consumer, is
# made again for the version:
#
#   scripts/update-zvec-rust.sh [version]    # default: the newest release on crates.io
#
# Nothing is taken on trust, and the run fails before it writes anything unless:
#   - each crate hashes, here, to the checksum that crates.io records;
#   - both crates were packaged from one commit, and it is the commit that the tag v<version>
#     of the repository names, and every file of each crate is the file of that commit;
#   - the repository has the crates, at the version, as members of its workspace;
#   - the hash of the sources is the one of the archive that fetchFromGitHub downloads;
#   - the lock files, the copy and the consumer's, name no crate of TLS or of HTTP and no source
#     from git (the consumer links the library that Nix builds and has no use for either), and
#     the consumer's has the two crates, with the checksums verified above, and its own crate.
# The files downloaded are only read (tar -xO, grep, jq, cmp); nothing from them is run.
#
# The library the crates link is not part of them: the crate zvec-rust has `bundled` as a
# default feature, which makes the build script of zvec-rust-sys download or build it, so the
# consumer turns the default features off.
#
# Needs: curl, gh, jq, nix (cargo comes from nixpkgs).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo=zvec-ai/zvec-rust
agent="engram update-zvec-rust.sh"
example="$root/examples/zvec-rust-consumer"

fail() {
  echo "$*" >&2
  exit 1
}

# crates.io asks for a descriptive User-Agent, and for no more than a request a second
crates_api() {
  sleep 1
  curl -fsSL -A "$agent" "https://crates.io/api/v1/crates/$1"
}

version="${1:-}"
if [ -z "$version" ]; then
  # the highest release that is neither yanked nor a pre-release
  version="$(crates_api zvec-rust | jq -r '.crate.max_stable_version // empty')"
  [ -n "$version" ] || fail "crates.io has no release of zvec-rust that is not yanked"
  echo "newest release of zvec-rust on crates.io: $version"
fi
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.0-9A-Za-z]*)$ ]] || fail "not a version: $version"
tag="v$version"

# 1. the crates, hashed here against what crates.io records
crates='{}'
for name in zvec-rust-sys zvec-rust; do
  crate="$work/$name-$version.crate"
  meta="$(crates_api "$name/$version")" || fail "$name $version: crates.io does not know it"
  [ "$(jq -r .version.yanked <<<"$meta")" = false ] || fail "$name $version is yanked"
  curl -fsSL -A "$agent" -o "$crate" "https://static.crates.io/crates/$name/$name-$version.crate"
  expected="$(jq -r .version.checksum <<<"$meta")"
  actual="$(sha256sum "$crate" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || fail "$name-$version.crate hashes to $actual, crates.io says $expected"
  echo "OK  $name-$version.crate: sha256 $actual is the checksum of crates.io"
  crates="$(jq -c --arg name "$name" \
    --arg sha256 "$(nix hash convert --hash-algo sha256 --to sri "$actual")" \
    '. + {($name): {sha256: $sha256}}' <<<"$crates")"
done

# 2. the commit they were packaged from is the one the tag names
vcs_info() { tar -xzOf "$work/$1-$version.crate" "$1-$version/.cargo_vcs_info.json"; }
rev="$(vcs_info zvec-rust-sys | jq -r .git.sha1)"
[ "$rev" = "$(vcs_info zvec-rust | jq -r .git.sha1)" ] || fail "the two crates were packaged from different commits"
for name in zvec-rust-sys zvec-rust; do
  [ "$(vcs_info "$name" | jq -r '.git.dirty // false')" = false ] || fail "$name-$version was packaged from a dirty tree"
done
[ "$(vcs_info zvec-rust-sys | jq -r .path_in_vcs)" = zvec-sys ] || fail "zvec-rust-sys is not in zvec-sys"
[ "$(vcs_info zvec-rust | jq -r .path_in_vcs)" = zvec ] || fail "zvec-rust is not in zvec"

# an annotated tag points at a tag object, not at the commit
ref="$(gh api "repos/$repo/git/ref/tags/$tag")"
kind="$(jq -r .object.type <<<"$ref")"
sha="$(jq -r .object.sha <<<"$ref")"
while [ "$kind" = tag ]; do
  object="$(gh api "repos/$repo/git/tags/$sha")"
  kind="$(jq -r .object.type <<<"$object")"
  sha="$(jq -r .object.sha <<<"$object")"
done
[ "$kind" = commit ] || fail "the tag $tag of $repo points at a $kind"
[ "$sha" = "$rev" ] || fail "the crates were packaged from $rev, the tag $tag of $repo is $sha"
echo "OK  the tag $tag of $repo is $rev, the commit both crates were packaged from"

# 3. the sources of that commit, as fetchFromGitHub fetches them (no submodules)
nix run nixpkgs#nix-prefetch-git -- \
  --url "https://github.com/$repo" --rev "$rev" --quiet >"$work/prefetch.json"
tree="$(jq -r .path "$work/prefetch.json")"
hash="$(nix hash convert --hash-algo sha256 --to sri "$(jq -r .sha256 "$work/prefetch.json")")"
archive="$(nix store prefetch-file --unpack --json "https://github.com/$repo/archive/$rev.tar.gz" | jq -r .hash)"
[ "$hash" = "$archive" ] || fail "the checkout of $rev hashes to $hash, the archive that fetchFromGitHub downloads to $archive"
echo "OK  sources of $rev: $hash is the hash of the archive of fetchFromGitHub too"

# the manifests are read as text: the tables of these are plain enough for it
toml_string() { # file section key
  awk -v section="[$2]" -v key="$3" '
    /^\[/ { in_section = ($0 == section); next }
    in_section && $1 == key && $2 == "=" { gsub(/"/, "", $3); print $3; exit }
  ' "$1"
}
members="$(awk '/^members[[:space:]]*=/ {p = 1} p {print} p && /\]/ {exit}' "$tree/Cargo.toml" | grep -o '"[^"]*"' | tr -d '"')"
for member in "zvec-sys zvec-rust-sys" "zvec zvec-rust"; do
  read -r dir name <<<"$member"
  manifest="$tree/$dir/Cargo.toml"
  grep -qx "$dir" <<<"$members" || fail "$dir is not a member of the workspace of $rev"
  [ "$(toml_string "$manifest" package name)" = "$name" ] || fail "$dir is not the package $name"
  if grep -qx 'version.workspace = true' "$manifest"; then
    member_version="$(toml_string "$tree/Cargo.toml" workspace.package version)"
  else
    member_version="$(toml_string "$manifest" package version)"
  fi
  [ "$member_version" = "$version" ] || fail "$name is at version $member_version in $rev, not at $version"

  # every file of the crate is the file of the commit (cargo writes the other three itself)
  crate="$work/$name-$version.crate"
  while IFS= read -r file; do
    rel="${file#"$name-$version/"}"
    case "$rel" in
      .cargo_vcs_info.json | Cargo.toml | Cargo.lock) continue ;;
      Cargo.toml.orig) want="$manifest" ;;
      *) want="$tree/$dir/$rel" ;;
    esac
    # (the readme of zvec-rust is the one of the repository: readme = "../README.md")
    if [ "$rel" = README.md ] && [ ! -e "$want" ]; then
      want="$tree/README.md"
    fi
    tar -xzOf "$crate" "$file" | cmp -s - "$want" || fail "$name-$version: $rel is not the file of $rev"
  done < <(tar -tzf "$crate")
  echo "OK  $name-$version: its files are those of $dir at $rev"
done
echo "    workspace members: $(tr '\n' ' ' <<<"$members")"

install -m 0644 "$tree/Cargo.lock" "$work/Cargo.lock"

# 4. the commit of zvec that the repository has as vendor/zvec, and the tag of zvec at it
submodule="$(gh api "repos/$repo/contents/vendor/zvec?ref=$rev")"
[ "$(jq -r .type <<<"$submodule")" = submodule ] || fail "vendor/zvec of $rev is not a submodule"
zvec_rev="$(jq -r .sha <<<"$submodule")"
zvec_tag="$(gh api repos/alibaba/zvec/tags --paginate |
  jq -rs --arg rev "$zvec_rev" 'add | [.[] | select(.commit.sha == $rev) | .name] | sort | first // empty')"
echo "    vendor/zvec is alibaba/zvec $zvec_rev (${zvec_tag:-no tag})"

# 5. the policy on the lock files
forbidden='openssl|openssl-sys|native-tls|rustls|ring|reqwest|ureq|hyper|curl|isahc|tokio'
check_lock() { # file label
  local count tls git
  count="$(grep -c '^name = ' "$1")"
  tls="$(grep -E "^name = \"($forbidden)\"\$" "$1" || true)"
  git="$(grep -cE '^source = "git\+' "$1" || true)"
  [ -z "$tls" ] || fail "$2 has a crate of TLS or of HTTP: $tls"
  [ "$git" = 0 ] || fail "$2 has $git sources from git"
  echo "OK  $2: $count packages, none of the 11 crates of TLS or HTTP, $git from git"
}
check_lock "$work/Cargo.lock" "pkgs/zvec-rust/Cargo.lock"

# the consumer, made again for the version in a copy, in which cargo writes its lock file
mkdir "$work/consumer"
cp -r "$example/Cargo.toml" "$example/src" "$work/consumer/"
sed -i "s/^\(zvec-rust = { version = \"=\)[^\"]*\"/\1$version\"/" "$work/consumer/Cargo.toml"
grep -qxF "zvec-rust = { version = \"=$version\", default-features = false }" "$work/consumer/Cargo.toml" ||
  fail "examples/zvec-rust-consumer/Cargo.toml: no line 'zvec-rust = { version = \"=$version\", default-features = false }'"
(cd "$work/consumer" && nix shell nixpkgs#cargo nixpkgs#rustc --command cargo generate-lockfile)
check_lock "$work/consumer/Cargo.lock" "examples/zvec-rust-consumer/Cargo.lock"

packages="$(sed -n 's/^name = "\(.*\)"$/\1/p' "$work/consumer/Cargo.lock" | tr '\n' ' ')"
[ "$packages" = "zvec-rust zvec-rust-consumer zvec-rust-sys " ] ||
  fail "examples/zvec-rust-consumer/Cargo.lock has the packages: $packages"
for name in zvec-rust-sys zvec-rust; do
  locked="$(awk -v name="$name" '
    /^\[\[package\]\]/ { found = 0 }
    $0 == "name = \"" name "\"" { found = 1 }
    found && $1 == "checksum" { gsub(/"/, "", $3); print $3; exit }
  ' "$work/consumer/Cargo.lock")"
  [ "$locked" = "$(sha256sum "$work/$name-$version.crate" | cut -d' ' -f1)" ] ||
    fail "examples/zvec-rust-consumer/Cargo.lock: the checksum of $name is not the one of the crate checked above"
done
echo "OK  examples/zvec-rust-consumer/Cargo.lock: the checksums of both crates are the ones checked above"

# everything holds: write
jq -S -n \
  --arg version "$version" \
  --arg tag "$tag" \
  --arg rev "$rev" \
  --arg hash "$hash" \
  --argjson crates "$crates" \
  --arg zvecRev "$zvec_rev" \
  --arg zvecTag "$zvec_tag" \
  '{version: $version, tag: $tag, rev: $rev, hash: $hash, crates: $crates,
    zvecSubmodule: {rev: $zvecRev, tag: (if $zvecTag == "" then null else $zvecTag end)}}' >"$work/pin.json"

mkdir -p "$root/pkgs/zvec-rust"
mv "$work/pin.json" "$root/pkgs/zvec-rust/pin.json"
mv "$work/Cargo.lock" "$root/pkgs/zvec-rust/Cargo.lock"
cp "$work/consumer/Cargo.toml" "$work/consumer/Cargo.lock" "$example/"
echo "pinned zvec-rust $version ($rev) in pkgs/zvec-rust/pin.json"
