# What the library is made of and what it exports: only its C interface, all of it, in a shared
# object that needs nothing but the C library of the system.
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;

  # What the library may need: the C library, and nothing else. (glibc has had libdl, librt and
  # libpthread inside libc since 2.34, and keeps the names for programs that ask for them.)
  allowedNeeded = [
    "ld-linux-x86-64\\.so\\.2"
    "libc\\.so\\.6"
    "libdl\\.so\\.2"
    "libm\\.so\\.6"
    "libpthread\\.so\\.0"
    "librt\\.so\\.1"
  ];
in
pkgs.runCommandCC "zvec-c-library-check"
  {
    nativeBuildInputs = [
      pkgs.patchelf
      pkgs.pkg-config
    ];
  }
  ''
    export HOME=$TMPDIR
    cd $TMPDIR
    lib=${zvec-c}/lib/libzvec_c_api.so

    # the files of the package
    (cd ${zvec-c} && find . -type f | sort) > files
    printf '%s\n' ./include/zvec/c_api.h ./lib/libzvec_c_api.so ./lib/pkgconfig/zvec_c_api.pc | sort > files.expected
    diff files.expected files

    # it needs the C library and nothing else. Its C++ runtime is inside it, so a program that
    # links it needs no libstdc++, and cannot bring one that disagrees. (<file>)
    needed_ok() {
      readelf -d "$1" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort > "needed-$(basename "$1")"
      cat "needed-$(basename "$1")"
      ! grep -vxE '${lib.concatStringsSep "|" allowedNeeded}' "needed-$(basename "$1")"
    }
    needed_ok $lib || { echo "the library needs more than the C library" >&2; exit 1; }
    # the control: a library that needs the C++ runtime
    cp $lib extra.so
    chmod +w extra.so
    patchelf --add-needed libstdc++.so.6 extra.so
    if needed_ok extra.so >/dev/null 2>&1; then
      echo "a library that needs libstdc++ was accepted" >&2
      exit 1
    fi

    # the functions of the header, those of zvec's own list of exports, and those the shared
    # object defines are the same set
    header_names() { tr '\n' ' ' < "$1" | grep -oE 'ZVEC_CALL +zvec_[a-z0-9_]+' | sed -E 's/^ZVEC_CALL +//' | sort -u; }
    header_names ${zvec-c}/include/zvec/c_api.h > header
    sed -n '/global:/,/local:/p' ${zvec-c.src}/src/binding/c/exported_symbols.lds \
      | grep -oE 'zvec_[a-z0-9_]+' | sort -u > script
    nm -D --defined-only $lib | awk '{ print $3 }' | sort -u > defined
    echo "the header declares $(wc -l < header) functions, zvec's list exports $(wc -l < script), the library defines $(wc -l < defined) symbols"
    [ -s header ]
    cmp header script
    cmp header defined
    # the control: a header with one declaration less is not the same set
    grep -v '^zvec_collection_flush$' header > header.fewer
    if cmp -s header.fewer defined; then
      echo "a header with a declaration less was accepted" >&2
      exit 1
    fi
    # and the header is the one of the source
    cmp ${zvec-c}/include/zvec/c_api.h ${zvec-c.src}/src/include/zvec/c_api.h

    # what the library says it is
    cc -Wall -Wextra -Werror -I${zvec-c}/include -o version_check ${./version_check.c} \
      -L${zvec-c}/lib -lzvec_c_api
    ./version_check v${zvec-c.version}
    # the control: another version expected
    if ./version_check v${zvec-c.version}.1 >/dev/null 2>&1 || ./version_check v0.0.1 2>/dev/null; then
      echo "a version that is not the library's was accepted" >&2
      exit 1
    fi

    # a program that is linked to it finds it by its RUNPATH
    readelf -d version_check | grep -F RUNPATH | grep -F '${zvec-c}/lib'
    cp version_check stripped
    chmod +w stripped
    patchelf --remove-rpath stripped
    if ./stripped v${zvec-c.version} 2>stripped.err; then
      echo "the program ran without its RUNPATH" >&2
      exit 1
    fi
    cat stripped.err
    grep -q 'libzvec_c_api.so' stripped.err

    # pkg-config says how to use it
    PKG_CONFIG_PATH=${zvec-c}/lib/pkgconfig pkg-config --exists --exact-version=${zvec-c.version} zvec_c_api
    # shellcheck disable=SC2046
    cc -Wall -Wextra -Werror -o version_check_pc ${./version_check.c} \
      $(PKG_CONFIG_PATH=${zvec-c}/lib/pkgconfig pkg-config --cflags --libs zvec_c_api)
    ./version_check_pc v${zvec-c.version}
    # the control: without the package in the path there is nothing to find
    if pkg-config --exists zvec_c_api; then
      echo "pkg-config found zvec_c_api without the package" >&2
      exit 1
    fi

    touch $out
  ''
