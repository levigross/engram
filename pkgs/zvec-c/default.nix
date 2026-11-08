# zvec's C API, libzvec_c_api.so, built from source at a release of zvec (pin.json): the library
# that the Rust crates zvec-rust-sys and zvec-rust, and any other language binding of zvec,
# link. It is a second package of zvec next to ../zvec, which has the static core libraries at
# the commit that NeuG's vector_search extension is compiled against and no C API.
#
# The C API is the whole database: collections, schemas, scalar fields and filters, vector
# indexes. That needs the library of zvec's database layer, which the other package never
# builds: Arrow with Parquet and its compute kernels, RocksDB, the ANTLR runtime, protobuf.
# Everything but Arrow is a thirdparty directory of the tree, compiled with it. Arrow is
# built by an ExternalProject whose own CMake downloads seven archives (boost, thrift, zlib,
# rapidjson, re2, utf8proc, xsimd) when the build runs; each is given here, by hash, in the
# environment variable that Arrow reads (ARROW_<NAME>_URL), and Arrow checks the hash again.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  cmake,
  ninja,
  git,
}:

let
  pin = lib.importJSON ./pin.json;

  arrowSources = lib.mapAttrs (_: d: fetchurl { inherit (d) name url hash; }) pin.arrow;

  # A Cube (the value of a parameter) keeps a small value in the storage of a pointer, which it
  # writes as the value and reads as a pointer when it is moved. GCC 15 and later, which go by
  # the types of the accesses, then take the value for not written: every parameter of a type
  # that small (an int, a float, a bool) reads back as 0. v0.8.1 still has it. The patch is
  # ../zvec/cube-storage.patch with the context of this version (docs/zvec.md).
  cubePatch = ./cube-storage.patch;
in
stdenv.mkDerivation {
  pname = "zvec-c";
  inherit (pin) version;

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "zvec";
    inherit (pin) rev hash;
    fetchSubmodules = true;
  };

  patches = [ cubePatch ];

  # headers as upstream has them are the ones the patch repairs
  passthru = {
    inherit cubePatch;
    # for a program that links the library with the crates zvec-rust-sys and zvec-rust, whose
    # build script otherwise downloads a library, or clones zvec and builds it
    rustEnv = {
      ZVEC_AUTO_BUILD = "0";
    };
  };

  postPatch = ''
    # Arrow is built by a CMake of its own, inside one job of this build, with as many jobs as
    # the machine has processors whatever this build was told, and its compute kernels need
    # gigabytes each. Half the cores of the build.
    substituteInPlace thirdparty/arrow/CMakeLists.txt --replace-fail \
      'ProcessorCount(NPROC)' \
      'ProcessorCount(NPROC)
    if(DEFINED ENV{NIX_BUILD_CORES} AND NOT "$ENV{NIX_BUILD_CORES}" STREQUAL "0")
      math(EXPR NPROC "($ENV{NIX_BUILD_CORES} + 1) / 2")
    endif()'
  '';

  strictDeps = true;
  # git: zvec applies the patches of its thirdparty projects with `git apply`, and keeps a
  # marker file for each that is done
  nativeBuildInputs = [
    cmake
    ninja
    git
  ];

  env = {
    # The nested CMake projects (Arrow and what it builds) see only the environment
    CMAKE_POLICY_VERSION_MINIMUM = "3.5";

    # RocksDB 8.1.1 uses uint64_t and the like without including <cstdint>, which the headers
    # it includes used to bring in. In the environment, because that reaches Arrow's build too,
    # and as stdint.h, which C and C++ both have.
    NIX_CFLAGS_COMPILE = "-include stdint.h";
  }
  // lib.mapAttrs' (n: src: lib.nameValuePair "ARROW_${lib.toUpper n}_URL" "${src}") arrowSources;

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
    # the version that the library reports, which a tree without a git history cannot tell
    (lib.cmakeFeature "OVERRIDE_GIT_DESCRIBE" "v${pin.version}")
    (lib.cmakeBool "BUILD_C_BINDINGS" true)
    (lib.cmakeBool "BUILD_PYTHON_BINDINGS" false)
    (lib.cmakeBool "BUILD_TOOLS" false)
    (lib.cmakeBool "BUILD_ZVEC_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_CORE_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_AILEGO_SHARED" false)
    (lib.cmakeBool "AUTO_DETECT_ARCH" stdenv.hostPlatform.isx86_64)
    # RocksDB looks for liburing and uses it if it finds it
    (lib.cmakeBool "WITH_LIBURING" false)
  ];

  # configuring applies the patches of the thirdparty projects; none having been applied would
  # build, and fail later in a way that does not say so
  postConfigure = ''
    for marker in \
      thirdparty/antlr/antlr4/.antlr4_fix_patched \
      thirdparty/glog/glog-0.5.0/.glog_fix_patched \
      thirdparty/arrow/apache-arrow-21.0.0/.arrow_fix_patched \
      thirdparty/arrow/apache-arrow-21.0.0/.arrow_slim_compute_patched; do
      if [ ! -e "../$marker" ]; then
        echo "zvec-c: $marker was not made: a patch of a thirdparty project was not applied" >&2
        exit 1
      fi
    done
  '';

  ninjaFlags = [ "zvec_c_api" ];

  installPhase = ''
    runHook preInstall

    # configuring wrote the CMake files of a thirdparty project into the prefix
    rm -rf "$out"
    mkdir -p $out/lib/pkgconfig $out/include/zvec
    install -m755 lib/libzvec_c_api.so $out/lib/
    install -m644 ../src/include/zvec/c_api.h $out/include/zvec/
    cat > $out/lib/pkgconfig/zvec_c_api.pc <<EOF
    prefix=$out
    libdir=\''${prefix}/lib
    includedir=\''${prefix}/include

    Name: zvec_c_api
    Description: the C API of zvec, an in-process vector database
    Version: ${pin.version}
    Libs: -L\''${libdir} -lzvec_c_api
    Cflags: -I\''${includedir}
    EOF

    runHook postInstall
  '';

  meta = {
    description = "zvec, an in-process vector database: its C API as a shared library";
    homepage = "https://github.com/alibaba/zvec";
    license = lib.licenses.asl20;
    # FastPFOR fetches simde with FetchContent where it is not x86: no build without a network
    platforms = [ "x86_64-linux" ];
  };
}
