# The Python module (duckdb-python) with the extensions of a DuckDB linked into it.
# The module builds its own copy of DuckDB, as a part of itself, so it is given the
# same sources, extensions and flags as the DuckDB it belongs to (`build`, from the
# passthru of that DuckDB) instead of libduckdb.
#
# nixpkgs has a module for the DuckDB it ships, but it is tied to that version, links
# the source of DuckDB read-only, and cannot take extensions; so this is a module of its
# own for every release.
{
  lib,
  stdenv,
  buildPythonPackage,
  fetchFromGitHub,
  cmake,
  ninja,
  openssl,
  python,
  runtimeShell,
  # the client library mysql_scanner of 1.4 links
  mysql84 ? null,
  callPackage,
  pybind11,
  scikit-build-core,
  setuptools-scm,
  # 2.0 is written with nanobind 3; the nixpkgs that lack it get a copy
  nanobind_3 ? callPackage ./nanobind.nix { },
  fsspec,
  google-cloud-storage,
  ipython,
  numpy,
  pandas,
  polars,
  psutil,
  pyarrow,
  pytest-reraise,
  pytestCheckHook,
  pytz,
  # { version, rev, src, python (the pin of duckdb-python), selected (the extensions),
  #   extensionConfig, extensionFlags, inTreeExtensions }
  build,
}:

let
  names = map (ext: ext.name) build.selected;

  # In-tree extensions are listed in pyproject.toml, as CORE_EXTENSIONS before 1.5 and as
  # BUILD_EXTENSIONS from then on. DuckDB's own CMake adds jemalloc to them on Linux.
  inTree = lib.concatStringsSep ";" build.inTreeExtensions;
  # In 2.0 the module links the extensions it is told to, in this order: the in-tree ones,
  # then each of ours after the extensions it needs
  linked = lib.concatStringsSep ";" (build.inTreeExtensions ++ names);
  isV2 = lib.versionAtLeast build.version "2";
  variable = if lib.versionOlder build.version "1.5" then "CORE_EXTENSIONS" else "BUILD_EXTENSIONS";
  hasAny = exts: lib.any (ext: lib.elem ext names) exts;

  # The tests of duckdb-python 2.0 that do not pass here. Each fails in the same way in a module
  # with no extensions at all, except the last groups, which are written for a DuckDB without
  # any: they need the extension named. The ids have no spaces, as the hook splits flags on
  # them, and a -k expression in parentheses stands for the variants of a test that fail.
  v2DisabledTests = [
    # fail as well with nixpkgs' polars (not looked into)
    "test_a_lazy_polars_frame_scanned_on_its_own_connection_errors"
    "(test_a_pushed_predicate_selects_what_the_engine_selects and lazyframe and IS and NULL and not NOT)"
    "(test_is_pushed_and_matches_native and struct_is_null)"
    "test_nanosecond_zoned_literal_outside_session_zone_raises_like_polars"
    # pyarrow cannot write a list_view column to Parquet (ArrowNotImplementedError)
    "(test_rows_equal_an_independent_reference and list_view)"
    # "utcoffset returned an invalid timedelta (days)", and two others that were not looked into
    "test_native_python_time_timezone"
    "test_8522"
    "test_fetch_arrow_reader"
    # Hang when the file runs, as the interrupt tests nixpkgs already leaves out do: each passes alone
    "test_streaming_fetch_interruption"
    "test_materializing_fetch_interruption"
  ]
  # The aws extension registers two default secrets, __aws_default and __aws_default_s3, and
  # the SDK keeps threads that outlive a closed database
  ++ lib.optionals (lib.elem "aws" names) [
    "test_secret_manager_option"
    "(test_eight_threads_share_one_default_connection and duplicates_torn_down)"
  ]
  # A jemalloc background thread starts when the module is imported, with spatial, mysql_scanner,
  # postgres_scanner or sqlite_scanner linked in (not with aws, httpfs or azure alone)
  ++ lib.optional (hasAny [
    "spatial"
    "mysql_scanner"
    "postgres_scanner"
    "sqlite_scanner"
  ]) "test_import_starts_no_threads";

  # These crash the interpreter (a segmentation fault in the scan of Arrow string_view and
  # binary_view with pyarrow 24, or "remaining threads" when it finalizes with daemon threads
  # scanning), whether or not extensions are linked in, so they are left out by id.
  v2Deselected = [
    "tests/fast/arrow/scan/test_arrow_scan_row_ranges.py::TestLayouts::test_nested_layouts_read_the_same_whole_and_split[string_view"
    "tests/fast/arrow/test_arrow_string_view.py::test_join_on_a_view_typed_key_matches_native"
    "tests/slow/test_interpreter_shutdown.py::test_ordinary_shutdown[daemon_threads_scanning"
  ];

  # ipython and adbc_driver_manager are left out, as in nixpkgs
  allDependencies = [
    ipython
    fsspec
    numpy
  ]
  ++ [
    pandas
    pyarrow
  ];
in
buildPythonPackage {
  pname = "duckdb";
  inherit (build) version;
  pyproject = true;

  src = fetchFromGitHub {
    inherit (build.python)
      owner
      repo
      rev
      hash
      ;
  };

  postPatch = ''
    # The build depends on a duckdb git submodule. It is copied, since the extensions
    # are put into it: CMake loads them from there.
    rm -r external/duckdb
    cp -R ${build.src} external/duckdb
    chmod -R u+w external/duckdb
    mkdir external/duckdb/extension_external
    ${lib.concatMapStrings (ext: ''
      cp -R ${ext.src} external/duckdb/extension_external/${ext.name}
      chmod -R u+w external/duckdb/extension_external/${ext.name}
    '') build.selected}

    # replace custom build backend with standard scikit-build-core
    substituteInPlace pyproject.toml \
      --replace-fail 'build-backend = "duckdb_packaging.build_backend"' \
                     'build-backend = "scikit_build_core.build"' \
      --replace-fail 'backend-path = ["./"]' \
                     '# backend-path removed'
  ''
  + (
    if isV2 then
      ''
        # The version comes from git or from a source distribution, by a provider that is
        # part of the backend that was replaced: give it.
        substituteInPlace pyproject.toml \
          --replace-fail 'dynamic = ["version"]' 'version = "${build.version}"' \
          --replace-fail 'metadata.version.provider = "duckdb_packaging.build_info"' "" \
          --replace-fail 'BUILD_EXTENSIONS = "core_functions;json;parquet;icu"' 'BUILD_EXTENSIONS = "${inTree}"' \
          --replace-fail 'LINK_EXTENSIONS = ""' 'LINK_EXTENSIONS = "${linked}"'
      ''
      + lib.optionalString (lib.elem "aws" names) ''
        # The aws extension calls Aws::InitAPI() and sets the SDK's process-wide HTTP client
        # factory every time a database loads it, with nothing to keep two databases that load it
        # at once apart. Two threads that open the default connection together corrupt the heap
        # (double free, unaligned tcache chunk): test_two_threads_open_the_default_connection
        # failed in 14 of 60 runs, each in its own process, of a module with only this
        # extension linked in, and in none of 60 with a module without any extension or with
        # the loads serialized as below.
        # The CLI and the Rust library load the same code and are not patched; the race was only
        # observed through Python.
        f=external/duckdb/extension_external/aws/src/aws_extension.cpp
        substituteInPlace $f \
          --replace-fail '#include <aws/core/Aws.h>' $'#include <aws/core/Aws.h>\n#include <mutex>' \
          --replace-fail 'static void LoadInternal(ExtensionLoader &loader) {' $'static void LoadInternal(ExtensionLoader &loader) {\n\tstatic std::mutex aws_sdk_mutex;\n\tstd::lock_guard<std::mutex> aws_sdk_guard(aws_sdk_mutex);'
      ''
    else
      ''
        # replace pybind11[global] with pybind11
        substituteInPlace pyproject.toml \
          --replace-fail "pybind11[global]" "pybind11"

        # the in-tree extensions of the DuckDB this module belongs to
        sed -i 's/^${variable} = ".*"/${variable} = "${inTree}"/' pyproject.toml
        grep -q '^${variable} = "${inTree}"' pyproject.toml
      ''
      + lib.optionalString (lib.versionAtLeast build.version "1.5") ''
        # The module links only the extensions that BUILD_EXTENSIONS names, and those of this
        # flake are loaded through DUCKDB_EXTENSION_CONFIGS: naming them in BUILD_EXTENSIONS
        # would load them from DuckDB's own tree, before their configs. So the loop that
        # links them is given the names as well.
        substituteInPlace cmake/duckdb_loader.cmake \
          --replace-fail 'foreach(ext IN LISTS BUILD_EXTENSIONS)' \
                         'foreach(ext IN LISTS BUILD_EXTENSIONS FLAKE_LINK_EXTENSIONS)'
      ''
      +
        lib.optionalString
          (lib.versionOlder build.version "1.5" && mysql84 != null && lib.elem "mysql_scanner" names)
          ''
            # mysql_scanner of 1.4 links libmysqlclient.a, which is built for programs and keeps
            # my_errno in thread-local storage of the initial-exec kind. That puts the whole block
            # of thread-local storage of this module (about 10 KB) into the static block, which
            # Python's dlopen has no room for: `import duckdb` fails with "cannot allocate memory
            # in static TLS block". The shared library is built for this and has 4 bytes of it.
            substituteInPlace external/duckdb/extension_external/mysql_scanner/CMakeLists.txt \
              --replace-fail "${mysql84.static}/lib/libmysqlclient.a" "${mysql84}/lib/libmysqlclient.so"
          ''
  );

  nativeBuildInputs = [
    cmake
    ninja
  ]
  ++ lib.concatMap (ext: ext.nativeBuildInputs) build.selected;

  dontUseCmakeConfigure = true;

  build-system =
    if isV2 then
      [
        nanobind_3
        scikit-build-core
        numpy
      ]
    else
      [
        pybind11
        scikit-build-core
        setuptools-scm
      ];

  # libduckdb is not linked: the module has its own DuckDB, with the extensions.
  buildInputs = [ openssl ] ++ lib.concatMap (ext: ext.buildInputs) build.selected;

  optional-dependencies.all = allDependencies;

  env = {
    DUCKDB_BUILD_UNITY = 1;
    # default to disabled extension autoload/autoinstall
    CMAKE_DEFINE_DUCKDB_EXTENSION_AUTOLOAD_DEFAULT = "0";
    CMAKE_DEFINE_DUCKDB_EXTENSION_AUTOINSTALL_DEFAULT = "0";
    # The flags go through the environment, since scikit-build-core splits the flags it is
    # given as settings at every ;, and the lists in these are separated by it.
    CMAKE_ARGS = lib.escapeShellArgs (
      (
        if isV2 then
          [
            "-DDUCKDB_EXPLICIT_VERSION=v${build.version}"
            "-DGIT_COMMIT_HASH=${build.rev}"
          ]
        else
          [
            "-DOVERRIDE_GIT_DESCRIBE=v${build.version}-0-g${build.rev}"
            # DuckDB's CMake adds jemalloc on Linux. Left out, as the 1.5 module was built and
            # checked; it is not what stops the 1.4 module from loading (see docs/duckdb.md, "Evidence: import duckdb fails in the 1.4 module").
            "-DSKIP_EXTENSIONS=jemalloc"
          ]
          ++ lib.optional (lib.versionAtLeast build.version "1.5") (
            lib.cmakeFeature "FLAKE_LINK_EXTENSIONS" (lib.concatStringsSep ";" names)
          )
      )
      ++ [
        (lib.cmakeFeature "DUCKDB_EXTENSION_CONFIGS" "${build.extensionConfig}")
      ]
      ++ build.extensionFlags
    );
  };

  nativeCheckInputs = [
    fsspec
    google-cloud-storage
    psutil
    pytest-reraise
    pytestCheckHook
    pytz
  ]
  ++ lib.optional isV2 polars
  ++ allDependencies;

  # test flags from .github/workflows/Python.yml
  pytestFlags = [
    "--verbose"
    "-Wignore::DeprecationWarning"
  ]
  ++ lib.optionals isV2 (map (id: "--deselect=${id}") v2Deselected);
  enabledTestPaths = if stdenv.hostPlatform.isDarwin then [ "tests/fast" ] else [ "tests" ];

  disabledTestPaths = [
    # avoid dependency on adbc_driver_manager
    "tests/fast/adbc"
    # avoid dependency on pyotp
    "tests/fast/test_pypi_cleanup.py"
    # avoid test data download requiring network access
    "tests/slow/test_h2oai_arrow.py"
  ]
  # these read the duckdb/ directory of the sources, which preCheck removes
  ++ lib.optional isV2 "tests/fast/expression/test_expression_generated.py";

  disabledTests = [
    # tries to make http request
    "test_install_non_existent_extension"

    # test is flaky https://github.com/duckdb/duckdb/issues/11961
    "test_fetchmany"

    # https://github.com/duckdb/duckdb/issues/10702
    # tests are racy and interrupt can be delivered before or after target point
    # causing a later test to fail with a spurious KeyboardInterrupt
    "test_connection_interrupt"
    "test_query_interruption"

    # flaky due to a race condition in checking whether a thread is alive
    "test_query_progress"
  ]
  ++ lib.optionals isV2 v2DisabledTests;

  # remove duckdb dir to prevent import confusion by pytest
  preCheck = ''
    export HOME="$(mktemp -d)"
    rm -rf duckdb
  ''
  # Tests of 2.0 start children with `python -I`. Such a child ignores PYTHONPATH, and the
  # interpreter takes NIX_PYTHONPATH out of the environment as it starts, so the child would not
  # find this module. sys.executable is a wrapper that puts the paths back for it.
  + lib.optionalString isV2 ''
    mkdir -p "$TMPDIR/pybin"
    cat > "$TMPDIR/pybin/python" <<EOF
    #!${runtimeShell}
    export NIX_PYTHONPATH="$out/${python.sitePackages}:$NIX_PYTHONPATH:$PYTHONPATH"
    export NIX_PYTHONEXECUTABLE="$TMPDIR/pybin/python"
    exec "$(command -v python)" "\$@"
    EOF
    chmod +x "$TMPDIR/pybin/python"
    export NIX_PYTHONEXECUTABLE="$TMPDIR/pybin/python"
  '';

  pythonImportsCheck = [ "duckdb" ];

  # Every extension that was asked for is loaded, without INSTALL or LOAD. It is a hook and
  # not the installCheckPhase itself: pytestCheckHook runs the tests of duckdb-python only
  # when no installCheckPhase is defined. In a subshell, so the tests still run in the sources.
  postInstallCheck = ''
    (
      cd "$(mktemp -d)"
      HOME=$PWD python - <<'PY'
    import duckdb
    names = ${builtins.toJSON names}
    loaded = {row[0] for row in duckdb.sql("SELECT extension_name FROM duckdb_extensions() WHERE loaded").fetchall()}
    missing = [name for name in names if name not in loaded]
    assert not missing, f"not loaded: {missing}"
    print("loaded:", ", ".join(names))
    PY
    )
  '';

  meta = {
    description = "Python binding for DuckDB, with extensions linked in";
    homepage = "https://duckdb.org/";
    license = lib.licenses.mit;
  };
}
