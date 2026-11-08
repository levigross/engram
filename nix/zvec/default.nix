# zvec: its packages (pkgs/zvec, the static core libraries NeuG links, and pkgs/zvec-c, the C
# API library) and their checks.
_:

{
  imports = [
    ./packages.nix
    ./checks.nix
  ];
}
