#!/usr/bin/env bash
# The style checks that CI runs. Needs the tools of the dev shell:
#
#   nix develop --command scripts/lint.sh
set -euxo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

nix_files="$(git ls-files '*.nix')"
# shellcheck disable=SC2086 # one argument for each file
{
  nixfmt --check $nix_files
  deadnix --fail $nix_files
}
statix check .
# shellcheck disable=SC2046 # one argument for each file
shellcheck $(git ls-files "*.sh")
actionlint
