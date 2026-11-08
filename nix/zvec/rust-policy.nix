# What the lock files of the Rust programs of zvec may have in them. The crates of zvec
# (zvec-rust and zvec-rust-sys) speak to no network, and the program that links them should not
# either: the lock file has no crate of HTTP or TLS, so that no `tls` choice (nix/chdb/rust.nix
# has it, where it matters) is needed, and no crate from git, which a build would have to fetch
# by other means than a hash. The same function says it for the example and for the lock file
# of the crates' tests, and the check `zvec-rust-lock-policy` shows that it can say no.
{ lib }:

let
  # the crates that make a program speak HTTP or TLS, or fetch something
  forbidden = [
    "openssl"
    "openssl-sys"
    "native-tls"
    "rustls"
    "ring"
    "reqwest"
    "ureq"
    "hyper"
    "curl"
    "isahc"
    "tokio"
  ];

  mentions = lock: lib.filter (name: lib.hasInfix "name = \"${name}\"\n" lock) forbidden;
  fromGit = lock: lib.hasInfix "source = \"git+" lock;

  # what is wrong with a lock file: a list of reasons, empty if nothing is
  problems =
    lock:
    map (name: "it has the crate ${name}") (mentions lock)
    ++ lib.optional (fromGit lock) "it has a crate from git";
in
{
  inherit forbidden problems;

  # the lock file, or a failure that says what is wrong with it
  assertClean =
    what: lock:
    assert lib.assertMsg (problems lock == [ ]) "${what}: ${lib.concatStringsSep "; " (problems lock)}";
    lock;
}
