# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation
# The examples of zvec's C API (examples/c), compiled against the installed library the way an
# application is and run in every mode of the I/O (../io/modes.sh).
# Attributes: zvecC, version, examples (the directory), names (the examples, sorted).
set -u
export HOME=$TMPDIR
cd "$TMPDIR" || exit
mkdir "$out"

# the examples are the ones this check knows, in the directory and in upstream's CMakeLists
known="${names[*]} "
found="$(cd "$examples" && find . -maxdepth 1 -name '*.c' -printf '%f\n' | sed 's/\.c$//' | sort | tr '\n' ' ')"
built="$(sed -nE 's/^add_executable\(c_api_[a-z_]+ ([a-z_]+)\.c\)$/\1/p' "$examples/CMakeLists.txt" | sort | tr '\n' ' ')"
if [ "$found" != "$known" ] || [ "$built" != "$known" ]; then
  nixErrorLog "examples/c has the sources: $found; CMakeLists.txt builds: $built; this check was written for: $known"
  exit 1
fi

for name in "${names[@]}"; do
  # C99 as the examples are written (upstream asks for it, and CMake adds the GNU extensions)
  cc -O2 -std=c99 -Wall -Wextra -Werror -I"$zvecC/include" "$examples/$name.c" \
    -L"$zvecC/lib" -lzvec_c_api -pthread -ldl -o "$name"
  patchelf --print-needed "$name" | grep -qx libzvec_c_api.so
  patchelf --print-rpath "$name" | tr : '\n' | grep -qx "$zvecC/lib"
done

# <mode>: every example in a directory of its own (each makes its collection in the current
# one). An example returns 0 even where it prints that a step failed, so a pass is also: nothing
# on stderr, none of the marks of failure on stdout, and the last line each ends with.
run_examples() {
  local mode=$1 name status line want
  for name in "${names[@]}"; do
    mkdir "run-$mode-$name"
    status=0
    (cd "run-$mode-$name" && "${launch[@]}" "../$name") >"$mode.$name.out" 2>"$mode.$name.err" || status=$?
    echo "--- $mode: $name (exit $status)"
    cat "$mode.$name.out"
    cat "$mode.$name.err" >&2
    [ "$status" = 0 ] || { nixErrorLog "$name exited with $status"; exit 1; }
    # nothing on stderr but the line of the wrapper, which is there if and only if the mode takes
    # io_uring away
    grep -v '^no-iouring: ' "$mode.$name.err" >"$mode.$name.err.rest" || true
    [ ! -s "$mode.$name.err.rest" ] || { nixErrorLog "$name wrote to stderr"; exit 1; }
    [ "$(grep -c '^no-iouring: ' "$mode.$name.err")" = "$([ "$mode" = default ] && echo 0 || echo 1)" ] \
      || { nixErrorLog "$mode: $name was not run as the mode says"; exit 1; }
    if grep -E '✗|⚠|Warning|Failed: [1-9]|, [1-9][0-9]* failed' "$mode.$name.out"; then
      nixErrorLog "$name reports a failure"
      exit 1
    fi
    grep -qi 'example completed' "$mode.$name.out"
    cp "$mode.$name.out" "$out/$mode.$name.log"
  done

  # diskann_example says which backend reads its index; it is the one of the mode
  line="$(grep '^DiskANN I/O backend: ' "$mode.diskann_example.out")"
  want="DiskANN I/O backend: $(sed -n 's/^description: //p' <<<"$modeProbe")"
  if [ "$line" != "$want" ]; then
    nixErrorLog "$mode: diskann_example says '$line', and the probe '$want'"
    exit 1
  fi
  grep -v '^DiskANN I/O backend: ' "$mode.diskann_example.out" >"$mode.diskann_example.results"
}
in_every_mode run_examples

# What the search returns is the same whichever backend reads the index (a list_size of 200 for
# 100 documents makes it exhaustive)
for mode in "${modeNames[@]}"; do
  cmp default.diskann_example.results "$mode.diskann_example.results"
done

# the library is the version of the package, as optimized_example prints it
grep -qx "ZVec Version: v$version" default.optimized_example.out

# Something must be able to fail. An example in a directory it cannot write to, where it makes
# its collection, must fail and say why. Permissions do not stop root, so the directory is first
# shown to stop this user.
mkdir read-only
chmod 555 read-only
if touch read-only/probe 2>/dev/null; then
  nixErrorLog "a directory without write permission can be written to here, so this check shows nothing of it"
  exit 1
fi
status=0
(cd read-only && ../basic_example) >read-only.out 2>read-only.err || status=$?
cat read-only.out read-only.err
echo "exit $status"
[ "$status" != 0 ] || { nixErrorLog "an example made its collection in a directory that cannot be written to"; exit 1; }
grep -q '^Error in creating collection: ' read-only.err

# The examples need the library: without the path the linker recorded they do not start.
cp basic_example no-rpath
patchelf --remove-rpath no-rpath
mkdir run-no-rpath
status=0
unset LD_LIBRARY_PATH
(cd run-no-rpath && ../no-rpath) >no-rpath.log 2>&1 || status=$?
cat no-rpath.log
[ "$status" != 0 ] || { nixErrorLog "an example started without the path of the library"; exit 1; }
grep -q 'libzvec_c_api.so: cannot open shared object file' no-rpath.log
