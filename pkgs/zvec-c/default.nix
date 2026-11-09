# zvec's C API as a shared library, libzvec_c_api.so, built from a release of zvec (pin.json).
# What its build needs, and why: docs/zvec.md#how-zvec-c-is-built.
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

  # the archives that Arrow's CMake would download, by hash (pin.json)
  arrowSources = lib.mapAttrs (_: d: fetchurl { inherit (d) name url hash; }) pin.arrow;

  # GCC >= 15 loses small values stored in a Cube (docs/zvec.md#the-header-repair); same change as ../zvec
  cubePatch = ./cube-storage.patch;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zvec-c";
  inherit (pin) version;

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "zvec";
    inherit (pin) rev hash;
    fetchSubmodules = true;
  };

  patches = [
    cubePatch
    ./arrow-build-cores.patch
  ];

  strictDeps = true;
  __structuredAttrs = true;
  nativeBuildInputs = [
    cmake
    ninja
    # zvec applies the patches of its thirdparty projects with `git apply`
    git
  ];

  env = {
    # nested CMake projects see only the environment
    CMAKE_POLICY_VERSION_MINIMUM = "3.5";

    # RocksDB 8.1.1 lacks #include <cstdint>; in env so that Arrow's nested build gets it too
    NIX_CFLAGS_COMPILE = "-include stdint.h";
  }
  // lib.mapAttrs' (n: src: lib.nameValuePair "ARROW_${lib.toUpper n}_URL" "${src}") arrowSources;

  cmakeFlags = [
    # the version the library reports; the source has no git history
    (lib.cmakeFeature "OVERRIDE_GIT_DESCRIBE" "v${finalAttrs.version}")
    (lib.cmakeBool "BUILD_C_BINDINGS" true)
    (lib.cmakeBool "BUILD_PYTHON_BINDINGS" false)
    (lib.cmakeBool "BUILD_TOOLS" false)
    (lib.cmakeBool "BUILD_ZVEC_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_CORE_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_AILEGO_SHARED" false)
    (lib.cmakeBool "AUTO_DETECT_ARCH" stdenv.hostPlatform.isx86_64)
    # RocksDB would use liburing if it found it
    (lib.cmakeBool "WITH_LIBURING" false)
  ];

  # without the thirdparty patches the build fails late and obscurely
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
    Version: ${finalAttrs.version}
    Libs: -L\''${libdir} -lzvec_c_api
    Cflags: -I\''${includedir}
    EOF

    runHook postInstall
  '';

  passthru = {
    inherit cubePatch;
    # for programs using the crates zvec-rust(-sys), whose build script would otherwise
    # download a library or build zvec
    rustEnv = {
      ZVEC_AUTO_BUILD = "0";
    };
  };

  meta = {
    description = "In-process vector database, as a shared library with a C API";
    homepage = "https://github.com/alibaba/zvec";
    changelog = "https://github.com/alibaba/zvec/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    maintainers = [ lib.maintainers.levigross ];
    # FastPFOR fetches simde with FetchContent outside x86
    platforms = [ "x86_64-linux" ];
    pkgConfigModules = [ "zvec_c_api" ];
  };
})
