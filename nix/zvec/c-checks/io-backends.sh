# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation
# Which I/O backend zvec's library selects when the kernel has no io_uring, and that no-iouring
# does what it says. Attributes: noIouring, ioProbe, modeLibraries, modeBackend, modeDescription
# (io.attrs); ioProbe is built by this repository (../io/io_probe.c).
set -u
export HOME=$TMPDIR
cd "$TMPDIR" || exit
unset LD_LIBRARY_PATH

# <field> <file>: what the probe printed after "field: "
field() { sed -n "s/^$1: //p" "$2"; }

# <file> <io_uring_setup> <backend> <part of the description>: the probe said that
expect() {
  [ "$(field io_uring_setup "$1")" = "$2" ] \
    && [ "$(field backend "$1")" = "$3" ] \
    && [[ "$(field description "$1")" == *"$4"* ]]
}
expect_or_fail() {
  expect "$@" && return 0
  nixErrorLog "expected io_uring_setup '$2', backend '$3', and '$4' in the description, got:"
  cat "$1" >&2
  exit 1
}

# Where the kernel has io_uring, the call works and the library uses it
"$ioProbe" >plain.out
cat plain.out
if [ "$(field io_uring_setup plain.out)" = ok ]; then
  expect_or_fail plain.out ok io_uring "io_uring async I/O backend"
else
  echo "this machine has no io_uring ($(field io_uring_setup plain.out))"
fi

# Without it, whatever the error: libaio if it is on the library path, pread if not
for errno in ENOSYS EPERM; do
  for mode in libaio pread; do
    echo "=== $errno, $mode"
    env LD_LIBRARY_PATH="${modeLibraries[$mode]}" "$noIouring" --errno "$errno" "$ioProbe" >"$errno-$mode.out"
    cat "$errno-$mode.out"
    expect_or_fail "$errno-$mode.out" "$errno" "${modeBackend[$mode]}" "${modeDescription[$mode]}"
  done
done

# Something must be able to fail, each clause of `expect` by itself: the output of the ENOSYS
# libaio run with another error, another backend, or another description is not accepted
good=ENOSYS-libaio.out
if expect $good EPERM libaio "${modeDescription[libaio]}" \
  || expect $good ENOSYS pread "${modeDescription[libaio]}" \
  || expect $good ENOSYS libaio "${modeDescription[pread]}"; then
  nixErrorLog "a probe was accepted for what it did not say"
  exit 1
fi
if [ "$(field io_uring_setup plain.out)" = ok ] && expect plain.out ENOSYS libaio "${modeDescription[libaio]}"; then
  nixErrorLog "the probe without the wrapper was taken for one with it"
  exit 1
fi

# the children of the command are under the filter too
"$noIouring" --errno EPERM bash -c "\"$ioProbe\"; true" >nested.out
expect_or_fail nested.out EPERM pread "${modeDescription[pread]}"

# <argument...>: the wrapper is used wrongly, says so with exit status 2, and runs nothing
wrong() {
  local status=0
  rm -f ran
  "$noIouring" "$@" 2>usage.err || status=$?
  [ "$status" = 2 ] || { nixErrorLog "$* gave exit status $status, and not the 2 of a wrong use"; exit 1; }
  [ ! -e ran ] || { nixErrorLog "the command ran although the wrapper was used wrongly"; exit 1; }
}
wrong touch ran
wrong --errno touch ran
wrong --errno EINVAL touch ran
wrong --errno ENOSYS
wrong ENOSYS touch ran
cat usage.err
status=0
"$noIouring" --errno EPERM ./does-not-exist 2>missing.err || status=$?
[ "$status" = 127 ] || { nixErrorLog "a command that does not exist gave exit status $status"; exit 1; }

touch "$out"
