# zvec, Alibaba's in-process vector database: the static libraries of its core, built the way
# NeuG builds them for its vector_search extension (cmake/BuildZVecAsThirdParty.cmake of
# NeuG: the same targets, the same flags), with the headers of its public interface.
#
# The commit is the one that the release of NeuG in this repository has as its submodule,
# not the latest zvec (pin.json, scripts/update-zvec.sh): the extension is compiled against
# exactly its headers. What zvec's own releases have beyond that, such as the Python module, is
# not built here.
#
# Of everything zvec carries, Arrow and RocksDB among it, the four libraries need none: the
# rest is configured and not built. The tree has no git checkout, so what zvec asks of one is
# done in postPatch.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
}:

let
  pin = lib.importJSON ./pin.json;

  # A Cube (the value of a parameter) keeps a small value in the storage of a pointer, which it
  # writes as the value and reads as a pointer when it is moved. GCC 15 and later, which go by
  # the types of the accesses, then take the value for not written: every parameter of a type
  # that small (an int, a float, a bool) read back as 0. See cube-storage.patch.
  cubePatch = ./cube-storage.patch;
in
stdenv.mkDerivation {
  pname = "zvec";
  inherit (pin) version;

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "zvec";
    inherit (pin) rev hash;
    fetchSubmodules = true;
  };

  patches = [ cubePatch ];

  # headers as the extension of NeuG, which has its own copy of them, must have them too
  passthru = { inherit cubePatch; };

  postPatch = ''
    # The patches of its thirdparty that zvec applies with `git apply`, which does nothing
    # outside a checkout, and the markers with which its CMake is told they are done
    patch -p1 -d thirdparty/antlr/antlr4 -i ../antlr4.patch
    patch -p1 -d thirdparty/glog/glog-0.5.0 -i ../glog.patch
    patch -p1 -d thirdparty/arrow/apache-arrow-21.0.0 -i ../arrow.patch
    echo patched > thirdparty/antlr/antlr4/.antlr4_fix_patched
    echo patched > thirdparty/glog/glog-0.5.0/.glog_fix_patched
    echo patched > thirdparty/arrow/apache-arrow-21.0.0/.arrow_fix_patched

    # git, to stamp a version that nothing reads
    substituteInPlace cmake/bazel.cmake --replace-fail \
      'function(git_version _RESULT _SOURCES_DIR)' \
      'function(git_version _RESULT _SOURCES_DIR)
      set(''${_RESULT} "" PARENT_SCOPE)
      return()'

    # librt, which glibc has had inside libc since 2.34
    substituteInPlace src/ailego/CMakeLists.txt --replace-fail \
      'find_library(LIB_RT NAMES rt)' 'set(LIB_RT "")'
  '';

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    ninja
  ];

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
    (lib.cmakeBool "BUILD_ZVEC_CORE_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_SHARED" false)
    (lib.cmakeBool "BUILD_ZVEC_AILEGO_SHARED" false)
    (lib.cmakeBool "BUILD_PYTHON_BINDINGS" false)
    (lib.cmakeBool "BUILD_C_BINDINGS" false)
    (lib.cmakeBool "AUTO_DETECT_ARCH" stdenv.hostPlatform.isx86_64)
    (lib.cmakeBool "BUILD_TOOLS" false)
  ];

  ninjaFlags = [
    "zvec_core"
    "zvec_ailego"
    "zvec_turbo"
    "roaring"
  ];

  installPhase = ''
    runHook preInstall

    # configuring wrote the CMake files of a thirdparty project into the prefix
    rm -rf "$out"
    mkdir -p $out/lib $out/include
    cp lib/libzvec_core.a lib/libzvec_ailego.a lib/libzvec_turbo.a $out/lib/
    cp external/usr/local/lib/libroaring.a $out/lib/

    # The headers of the libraries that are built. What else the tree has under src/include (db,
    # c_api.h) is of libraries that are not, and the public headers include nothing else of
    # zvec's thirdparty than CRoaring's, which a user of roaring needs.
    cp -r ../src/include/zvec $out/include/zvec
    rm -rf $out/include/zvec/db $out/include/zvec/c_api.h $out/include/zvec/version.h.in
    install -m644 ../thirdparty/CRoaring/CRoaring-2.0.4/roaring.h \
      ../thirdparty/CRoaring/CRoaring-2.0.4/roaring.hh \
      ../thirdparty/CRoaring/CRoaring-2.0.4/roaring64map.hh $out/include/

    runHook postInstall
  '';

  meta = {
    description = "Static libraries of the core of zvec, an in-process vector database, as NeuG links them";
    homepage = "https://github.com/alibaba/zvec";
    license = lib.licenses.asl20;
    maintainers = [ lib.maintainers.levigross ];
    platforms = lib.platforms.linux;
  };
}
