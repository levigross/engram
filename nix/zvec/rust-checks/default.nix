# What must work with the Rust crates of zvec (zvec-rust-sys and zvec-rust 0.8.0, the zvec
# team's own) and the library they link (pkgs/zvec-c, zvec 0.8.1): a program that uses them,
# the tests of the crates themselves, that they ask for nothing the library lacks, and that no
# lock file has a crate that talks to a network.
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;
  policy = import ../rust-policy.nix { inherit lib; };
  rust = import ../rust.nix { inherit pkgs; };
  pin = lib.importJSON ../../../pkgs/zvec-rust/pin.json;

  program = rust.program { };

  # the crates and their tests, as the zvec team keeps them (the repository, at the tag that
  # the crates of crates.io were made from: scripts/update-zvec-rust.sh checks that every file
  # of both is the same). Its submodule, which is zvec itself, is not fetched: the library is
  # the package zvec-c.
  src = pkgs.fetchFromGitHub {
    owner = "zvec-ai";
    repo = "zvec-rust";
    inherit (pin) rev hash;
  };

  # the copy of the lock file of the repository that the tests are built with (a build cannot
  # read one from a fetched source), and the one of the example
  testsLockFile = ../../../pkgs/zvec-rust/Cargo.lock;
  testsLock = policy.assertClean "pkgs/zvec-rust/Cargo.lock" (builtins.readFile testsLockFile);
  exampleLock = builtins.readFile ../../../examples/zvec-rust-consumer/Cargo.lock;

  packages =
    lock: lib.length (lib.filter (line: lib.hasPrefix "name = " line) (lib.splitString "\n" lock));

  # What the C API has that the crates do not bind, as of zvec-rust 0.8.0, which was made for
  # an earlier version of zvec than the library here (v0.8.0-beta2, 30 commits before v0.8.1):
  # grouped queries (and the results of them), the product quantizer, and a function to add a
  # field by a structure. A newer crate that binds one fails the check `abi` until the list is
  # changed.
  unbound = [
    "zvec_collection_group_by_query"
    "zvec_doc_add_field_by_struct"
    "zvec_group_results_free"
    "zvec_index_params_get_quantizer_pq"
    "zvec_index_params_set_quantizer_pq"
  ];
in
{
  # The lock files have no crate of TLS or HTTP and none from git: the function that says so
  # (nix/zvec/rust-policy.nix) refuses a lock file that has one, which is shown here with a
  # made-up one, at evaluation.
  lock-policy =
    let
      control = builtins.tryEval (
        policy.assertClean "the control" ''
          [[package]]
          name = "openssl-sys"
          version = "0.9.0"
        ''
      );
    in
    assert lib.assertMsg (!control.success) "the policy accepted a lock file with openssl-sys";
    assert lib.assertMsg (packages exampleLock == 3) "the lock file of the example is not 3 crates";
    pkgs.runCommand "zvec-rust-lock-policy-check" { } ''
      echo "the lock file of the example: ${toString (packages exampleLock)} crates"
      echo "the lock file of the tests of the crates: ${toString (packages testsLock)} crates"
      echo "refused: a lock file with openssl-sys"
      touch $out
    '';

  # The program of examples/zvec-rust-consumer, which makes a collection with an index of
  # vectors in its own process, writes to it, searches it, closes it and opens it again.
  consumer =
    pkgs.runCommand "zvec-rust-consumer-check"
      {
        nativeBuildInputs = [
          pkgs.binutils
          pkgs.patchelf
        ];
      }
      ''
        export HOME=$TMPDIR
        cd $TMPDIR

        # it is linked to the library of the package, found by its RUNPATH
        readelf -d ${program}/bin/zvec-rust-consumer | grep -F 'RUNPATH' | grep -F '${zvec-c}/lib'

        ${program}/bin/zvec-rust-consumer v${zvec-c.version} $TMPDIR/data

        # a program that expects another version of the library must fail
        if ${program}/bin/zvec-rust-consumer v0.0.0 $TMPDIR/data-other 2>other.err; then
          echo "the program accepted a library of another version" >&2
          exit 1
        fi
        cat other.err

        # without the RUNPATH it does not find the library: a program that ran only because of
        # something else (a library path in the environment) would show nothing of this
        cp ${program}/bin/zvec-rust-consumer stripped
        chmod +w stripped
        patchelf --remove-rpath stripped
        if ./stripped v${zvec-c.version} $TMPDIR/data-stripped 2>stripped.err; then
          echo "the program ran without its RUNPATH" >&2
          exit 1
        fi
        cat stripped.err
        grep -q 'libzvec_c_api.so' stripped.err

        touch $out
      '';

  # Everything the crates declare must be a function of the library, and what the library has
  # that they do not bind is the list above.
  abi =
    pkgs.runCommand "zvec-rust-abi-check"
      {
        nativeBuildInputs = [ pkgs.binutils ];
      }
      ''
        cd $TMPDIR

        # the functions that the crate declares, and those that the library exports
        grep -oE 'pub fn zvec_[a-z0-9_]+' ${src}/zvec-sys/src/lib.rs | sed 's/^pub fn //' | sort -u > bound
        nm -D --defined-only ${zvec-c}/lib/libzvec_c_api.so | awk '$2 ~ /^[A-Za-z]$/ { print $3 }' | sort -u > exported
        printf '%s\n' ${lib.concatStringsSep " " unbound} | sort -u > unbound.expected
        echo "the crate declares $(wc -l < bound) functions, the library exports $(wc -l < exported)"

        # <bound> <unbound that is expected>
        compare() {
          comm -23 "$1" exported > "$1.missing"
          if [ -s "$1.missing" ]; then
            echo "declared by the crate, and not exported by the library:" >&2
            cat "$1.missing" >&2
            return 1
          fi
          comm -13 "$1" exported > "$1.unbound"
          if ! cmp -s "$1.unbound" "$2"; then
            echo "exported by the library, and not declared by the crate, other than expected:" >&2
            diff "$2" "$1.unbound" >&2 || true
            return 1
          fi
        }
        compare bound unbound.expected

        # controls: a function the library lacks, a function the crate would bind that this check
        # does not know, and one that it expects to be unbound that is bound
        { cat bound; echo zvec_not_in_the_library; } | sort -u > bound-extra
        if compare bound-extra unbound.expected 2>/dev/null; then
          echo "a function that the library lacks was accepted" >&2
          exit 1
        fi
        grep -v '^zvec_group_results_free$' unbound.expected > expected-fewer
        if compare bound expected-fewer 2>/dev/null; then
          echo "a function that is not bound was not noticed" >&2
          exit 1
        fi
        { cat bound; echo zvec_group_results_free; } | sort -u > bound-more
        if compare bound-more unbound.expected 2>/dev/null; then
          echo "a function that is bound, and expected not to be, was accepted" >&2
          exit 1
        fi

        touch $out
      '';

  # The tests of the crates, the zvec team's own, run against the library of zvec-c
  tests = import ./tests.nix {
    inherit
      pkgs
      src
      testsLockFile
      ;
  };
}
