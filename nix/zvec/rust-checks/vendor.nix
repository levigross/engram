# Patch the same pinned sources in a Cargo vendor tree that source.nix patches
# in the upstream workspace. Cargo still validates every file of both crates.
{
  runCommand,
  python3,
  patch,
  cargoDeps,
}:

# importCargoLock's config names this directory relative to the build root.
# Preserve the name so cargoSetupHook stages it at the same location.
runCommand cargoDeps.name
  {
    nativeBuildInputs = [
      python3
      patch
    ];
  }
  ''
    cp -rL ${cargoDeps} $out
    chmod -R u+w $out
    python3 ${./patch-vendor.py} $out ${./sys-api.patch} ${./safe-api.patch}
  ''
