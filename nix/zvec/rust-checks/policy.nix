# What the lock files of the Rust programs of zvec may contain: no crate of HTTP or TLS, and none
# from git (docs/zvec.md#rust). The check zvec-rust-lock-policy shows that it can say no.
{ lib }:

let
  # crates that make a program speak HTTP or TLS
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

  # what is wrong with a lock file, as a list of reasons; empty if nothing is
  problems =
    lock:
    let
      packages = (fromTOML lock).package or [ ];
    in
    map (name: "it has the crate ${name}") (
      lib.filter (name: lib.elem name forbidden) (map (p: p.name) packages)
    )
    ++ lib.optional (lib.any (
      p: lib.hasPrefix "git+" (p.source or "")
    ) packages) "it has a crate from git";
in
{
  inherit forbidden problems;

  assertClean =
    what: lock:
    assert lib.assertMsg (problems lock == [ ]) "${what}: ${lib.concatStringsSep "; " (problems lock)}";
    lock;
}
