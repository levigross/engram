# The examples of zvec's C API that zvec itself ships (examples/c), compiled against the installed
# library the way an application is, and run: the header of the package, -lzvec_c_api, no other
# path to the library than the one the linker records. Upstream builds them as a CMake project of
# their own (examples/c/CMakeLists.txt), as C99 linked with the library, threads and libdl, and
# its workflows run six of the seven: diskann_example is not among them (workflows 03, 07 and 09).
# It is run here like the others. It passes: the library falls back to synchronous reads when the
# kernel has no io_uring (src/ailego/io/iouring_loader.h), so no kernel makes it fail, and the
# I/O backend that it prints is not something to assert.
#
# An example returns 0 even where it prints that a step failed (doc_example does, for the flush),
# so a pass is also: nothing on stderr, none of the marks for a failure that the examples print
# on stdout, and the last line each ends with. doc_example filters its query with
# 'string_field_0' where its documents have 'test_string_0', so that query returns nothing and
# the loop over its results checks nothing; that is in the example, not in the library (the test
# of the C API filters, and checks what comes back).
{ pkgs }:

let
  inherit (pkgs) lib zvec-c;
  inherit (zvec-c) version;
  examples = "${zvec-c.src}/examples/c";

  # the sources of examples/c; upstream's CMakeLists builds each as c_api_<name>. The check
  # compares them with the directory and with that file, so that an example that upstream adds
  # is not left out unnoticed.
  names = [
    "basic_example"
    "collection_schema_example"
    "diskann_example"
    "doc_example"
    "field_schema_example"
    "index_example"
    "optimized_example"
  ];
in
pkgs.runCommandCC "zvec-c-examples"
  {
    nativeBuildInputs = [ pkgs.patchelf ];
  }
  ''
    export HOME=$TMPDIR
    # the library is to be found by the path that the linker recorded, and by no other
    unset LD_LIBRARY_PATH
    cd $TMPDIR
    mkdir $out

    found="$(cd ${examples} && ls *.c | sed 's/\.c$//' | sort | tr '\n' ' ')"
    built="$(sed -nE 's/^add_executable\(c_api_[a-z_]+ ([a-z_]+)\.c\)$/\1/p' ${examples}/CMakeLists.txt | sort | tr '\n' ' ')"
    known="${lib.concatStringsSep " " (lib.sort (a: b: a < b) names)} "
    [ "$found" = "$known" ] || {
      echo "examples/c has the sources: $found" >&2
      echo "this check was written for: $known" >&2
      exit 1
    }
    [ "$built" = "$known" ] || {
      echo "examples/c/CMakeLists.txt builds: $built" >&2
      echo "this check was written for:       $known" >&2
      exit 1
    }

    for name in $known; do
      # C99 as the examples are written (upstream asks for C99 and CMake adds the extensions of GNU)
      cc -O2 -std=c99 -Wall -Wextra -Werror -I${zvec-c}/include ${examples}/$name.c \
        -L${zvec-c}/lib -lzvec_c_api -pthread -ldl -o $name
      patchelf --print-needed $name | grep -qx libzvec_c_api.so
      patchelf --print-rpath $name | tr : '\n' | grep -qx ${zvec-c}/lib

      # each example makes a collection in a directory of its own name in the current one, which
      # has to be one that has none: a directory for each
      mkdir run-$name
      status=0
      (cd run-$name && ../$name) > $name.out 2> $name.err || status=$?
      echo "=== $name (exit $status)"
      cat $name.out
      cat $name.err >&2
      [ "$status" = 0 ] || { echo "$name exited with $status" >&2; exit 1; }
      [ ! -s $name.err ] || { echo "$name wrote to stderr" >&2; exit 1; }
      if grep -E '✗|⚠|Warning|Failed: [1-9]|, [1-9][0-9]* failed' $name.out; then
        echo "$name reports a failure" >&2
        exit 1
      fi
      grep -qi 'example completed' $name.out
      cp $name.out $out/$name.log
    done

    # the library is the version of the package, as optimized_example prints it
    grep -qx 'ZVec Version: v${version}' optimized_example.out

    # Something must be able to fail. An example in a directory that it cannot write to, where it
    # makes its collection, must fail and say why. Permissions do not stop root, so the directory
    # is first shown to be one that stops this user.
    mkdir read-only
    chmod 555 read-only
    if touch read-only/probe 2> /dev/null; then
      echo "a directory without write permission can be written to here, so this check shows nothing of it" >&2
      exit 1
    fi
    status=0
    (cd read-only && ../basic_example) > read-only.out 2> read-only.err || status=$?
    cat read-only.out read-only.err
    echo "exit $status"
    [ "$status" != 0 ] || { echo "an example made its collection in a directory that cannot be written to" >&2; exit 1; }
    grep -q '^Error in creating collection: ' read-only.err

    # And an example must need the library: without the path that the linker recorded it does
    # not start, and the loader says which library it looked for.
    cp basic_example no-rpath
    patchelf --remove-rpath no-rpath
    mkdir run-no-rpath
    status=0
    (cd run-no-rpath && ../no-rpath) > no-rpath.log 2>&1 || status=$?
    cat no-rpath.log
    [ "$status" != 0 ] || { echo "an example started without the path of the library" >&2; exit 1; }
    grep -q 'libzvec_c_api.so: cannot open shared object file' no-rpath.log
  ''
