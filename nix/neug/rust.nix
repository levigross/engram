# The repository's NeuG bindings and example share a pinned Cargo toolchain.
# The native library is always supplied by Nix; Cargo never downloads or builds it.
{ pkgs, craneLib }:

let
  inherit (pkgs) lib neug-c;
  example = ../../examples/neug-rust-consumer;
  lockFile = example + "/Cargo.lock";
  lock = builtins.readFile lockFile;

  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../bindings/rust/neug
      example
    ];
  };
  environment = {
    NEUG_LIB_DIR = "${neug-c}/lib";
    NEUG_INCLUDE_DIR = "${neug-c}/include";
    NEUG_DB_TMP_DIR = "/tmp";
    GLOG_minloglevel = "2";
  };
  mentions = names: lib.any (name: lib.hasInfix "name = \"${name}\"" lock) names;

  commonArgs = {
    src = source;
    pname = "neug-rust-consumer";
    version = "0.1.0";
    cargoLock = lockFile;
    cargoToml = example + "/Cargo.toml";
    cargoExtraArgs = "--locked --offline";
    # Keep the path dependency between the two workspaces intact in real and dummy sources.
    postUnpack = ''
      sourceRoot="$sourceRoot/examples/neug-rust-consumer"
    '';
    extraDummyScript = ''
      cp ${lockFile} $out/examples/neug-rust-consumer/Cargo.lock
      cp ${../../bindings/rust/neug/Cargo.lock} $out/bindings/rust/neug/Cargo.lock
    '';
    strictDeps = true;
    buildInputs = [ neug-c ];
    env = environment;
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  bindingsArgs = {
    pname = "neug-rust-bindings";
    version = "0.1.0";
    src = craneLib.cleanCargoSource ../../bindings/rust/neug;
    cargoExtraArgs = "--locked --offline --workspace";
    strictDeps = true;
    buildInputs = [ neug-c ];
    env = environment;
  };
  bindingsArtifacts = craneLib.buildDepsOnly bindingsArgs;

  program =
    {
      tls ? "none",
    }:
    assert lib.assertMsg (lib.elem tls [
      "none"
      "openssl"
      "rustls"
    ]) "tls is none, openssl or rustls";
    assert lib.assertMsg (
      tls != "none"
      || !(mentions [
        "openssl-sys"
        "native-tls"
        "rustls"
      ])
    ) "tls = none, and the lock file has a crate of TLS";
    assert lib.assertMsg (
      tls != "rustls"
      || !(mentions [
        "openssl-sys"
        "native-tls"
      ])
    ) "tls = rustls, and the lock file has openssl-sys or native-tls";
    let
      args = commonArgs // {
        nativeBuildInputs = lib.optional (tls == "openssl") pkgs.pkg-config;
        buildInputs = commonArgs.buildInputs ++ lib.optional (tls == "openssl") pkgs.openssl;
      };
    in
    craneLib.buildPackage (
      args
      // {
        cargoArtifacts = craneLib.buildDepsOnly args;
        doCheck = true;
      }
    );

  checks = {
    rust-bindings-tests = craneLib.cargoTest (bindingsArgs // { cargoArtifacts = bindingsArtifacts; });
    rust-bindings-clippy = craneLib.cargoClippy (
      bindingsArgs
      // {
        cargoArtifacts = bindingsArtifacts;
        cargoClippyExtraArgs = "--all-targets -- --deny warnings";
      }
    );
    rust-consumer-clippy = craneLib.cargoClippy (
      commonArgs
      // {
        inherit cargoArtifacts;
        cargoClippyExtraArgs = "--all-targets -- --deny warnings";
      }
    );
    rust-bindings-fmt = craneLib.cargoFmt {
      inherit (bindingsArgs) src pname version;
      cargoExtraArgs = "--all";
    };
    rust-consumer-fmt = craneLib.cargoFmt {
      inherit (commonArgs)
        src
        pname
        version
        postUnpack
        ;
      cargoExtraArgs = "--all";
    };
  };
in
{
  inherit program checks environment;
}
