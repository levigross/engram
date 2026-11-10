{ pkgs }:

let
  inherit (pkgs) lib duckdb;

  withHttpfs = duckdb.withExtensions (e: [ e.httpfs ]);

  linkable = duckdb.linkableExtensions;
  withAll = duckdb.withExtensions (_: linkable);
in
{
  extension-pins = import ./extension-pins.nix { inherit pkgs; };

  # Evaluate the public extension API without compiling DuckDB or Rust. Archives
  # must come from the selected values, including custom names and overrides.
  rust-extension-api =
    let
      extension =
        name: archive:
        duckdb.mkExtension {
          inherit name;
          version = "0.1.0";
          src = ../../../templates/extension;
          rust = {
            package = "/custom-rust";
            inherit archive;
            cmakeVariable = "${name}_RUST_LIBRARY";
          };
        };
      custom = extension "custom" "libcustom.a";
      other = extension "other" "libother.a";
      bundledName = extension "delta" "libreplacement.a";
      single = ext: duckdb.withExtensions (_: [ ext ]);
      multiple =
        ext:
        duckdb.withExtensions (_: [
          ext
          other
        ]);
      expectedFlag =
        ext: lib.cmakeFeature ext.rust.cmakeVariable "${ext.rust.package}/${ext.rust.archive}";
      usesSelectedArchive =
        ext:
        lib.elem (expectedFlag ext) (single ext).cmakeFlags
        && lib.elem (expectedFlag ext) (single ext).pythonBuild.extensionFlags;
    in
    assert lib.assertMsg (usesSelectedArchive custom) "custom Rust archive was not selected";
    assert lib.assertMsg (usesSelectedArchive bundledName) "replacement Rust archive was not selected";
    assert lib.assertMsg (
      lib.any (lib.hasSuffix "/lib/custom.a") (multiple custom).cmakeFlags
      && lib.any (lib.hasSuffix "/lib/other.a") (multiple custom).pythonBuild.extensionFlags
    ) "custom Rust archives were not isolated";
    assert lib.assertMsg (
      (multiple custom).cmakeFlags != (multiple (extension "custom" "libchanged.a")).cmakeFlags
    ) "isolation ignored the selected Rust archive";
    pkgs.runCommand "duckdb-rust-extension-api-check" { } ''
      touch $out
    '';

  # Reads a CSV over HTTP, which needs httpfs. The same query must fail
  # without it, so the check cannot pass by accident.
  httpfs = pkgs.runCommand "duckdb-httpfs-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    export HOME=$TMPDIR
    mkdir www
    printf 'a,b\n1,2\n3,4\n' > www/t.csv
    python3 -m http.server 18765 --bind 127.0.0.1 --directory www >/dev/null 2>&1 &
    server=$!
    trap 'kill $server' EXIT
    for _ in $(seq 100); do
      (exec 3<>/dev/tcp/127.0.0.1/18765) 2>/dev/null && break
      sleep 0.1
    done

    query="SELECT sum(b) FROM read_csv('http://127.0.0.1:18765/t.csv')"

    if ${lib.getExe duckdb} -c "$query" >/dev/null 2>&1; then
      echo "plain duckdb read over http, so this check proves nothing" >&2
      exit 1
    fi

    sum=$(${lib.getExe withHttpfs} -noheader -list -c "$query")
    [ "$sum" = 6 ] || { echo "expected 6, got '$sum'" >&2; exit 1; }

    ${lib.getExe withHttpfs} -noheader -list \
      -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded AND extension_name = 'httpfs'" |
      grep -qx httpfs
    touch $out
  '';

  all-extensions = import ./all-extensions.nix {
    inherit pkgs;
    duckdb = withAll;
    extensions = linkable;
  };

  # A Rust program linked against libduckdb finds the extensions.
  rust-consumer = import ./rust-consumer.nix {
    inherit pkgs;
    duckdb = withAll;
    extensions = linkable;
  };
}
# the extensions that only come as the registry's build load, and work
// lib.optionalAttrs (duckdb.loadableExtensions != { }) {
  loadable-extensions = import ./loadable-extensions.nix {
    inherit pkgs;
    duckdb = withAll;
    loadables = duckdb.loadableExtensions;
  };
}
