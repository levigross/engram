# shellcheck shell=bash
# shellcheck disable=SC2154 # the variables are attributes of the derivation, or default.nix's data
# Run a check in every mode of the I/O of zvec's library: "default" is what the machine has
# (io_uring, where its kernel has it), the others take io_uring away. default.nix generates the
# variables this uses: modeNames, modeLaunch, modeLibraries, modeBackend, modeDescription,
# ioProbe and noIouring.

# in_every_mode <function> [argument...]
#
# Calls <function> <mode> [argument...] once per mode, with LD_LIBRARY_PATH set for the mode
# ($libraryBase first, if the check sets it), the array `launch` with the words that start a
# program in the mode (empty for "default"), and modeProbe with the output of the probe (below).
in_every_mode() {
  local function=$1 mode path
  shift

  # a mode with a datum missing would run with an empty one, here unwrapped
  [ "${#modeNames[@]}" -ge 1 ] || { nixErrorLog "no modes are defined"; exit 1; }
  [[ -v modeLibraries[default] ]] || { nixErrorLog "modeLibraries has no default"; exit 1; }
  for mode in "${modeNames[@]}"; do
    [[ -v modeLaunch[$mode] && -v modeLibraries[$mode] && -v modeBackend[$mode] && -v modeDescription[$mode] ]] \
      || { nixErrorLog "the mode $mode is not defined completely"; exit 1; }
  done

  for mode in default "${modeNames[@]}"; do
    launch=()
    [ "$mode" = default ] || read -ra launch <<<"${modeLaunch[$mode]}"
    path=${libraryBase:-}
    if [ -n "${modeLibraries[$mode]}" ]; then
      path=${path:+$path:}${modeLibraries[$mode]}
    fi
    if [ -n "$path" ]; then
      export LD_LIBRARY_PATH="$path"
    else
      unset LD_LIBRARY_PATH
    fi
    echo "=== $mode"
    check_mode "$mode"
    "$function" "$mode" "$@"
  done
}

# check_mode <mode>: the probe, started the way the check starts a program, selects the backend
# of the mode (io_uring for "default", if the machine lets the probe make a ring). Its output is
# left in modeProbe.
check_mode() {
  local mode=$1 selected expected=${modeBackend[$1]:-io_uring}
  modeProbe="$("${launch[@]}" "$ioProbe")"
  selected="$(sed -n 's/^backend: //p' <<<"$modeProbe")"
  if [ "$mode" = default ] && ! grep -qx 'io_uring_setup: ok' <<<"$modeProbe"; then
    echo "this machine has no io_uring: the library selects $selected in the mode default"
    return 0
  fi
  if [ "$selected" != "$expected" ]; then
    nixErrorLog "mode $mode: the library selects '$selected' and not '$expected'"
    exit 1
  fi
}
