# The Python API operates on a persistent collection and rejects a bad query.
# Upstream's tests run against the installed module, outside its source tree.
{ pkgs }:

let
  zvecPython = pkgs.zvec-c.pythonModule pkgs.python3Packages;
  withZvec = pkgs.python3.withPackages (_: [ zvecPython ]);
  testsPython = pkgs.python3.withPackages (ps: [
    zvecPython
    ps.pytest
    ps.pytest-xdist
  ]);
  withoutZvec = pkgs.python3.withPackages (ps: [
    ps.pytest
    ps.pytest-xdist
    ps.numpy
  ]);
  # lib.zvec-c callers can pass their original Python scope without the overlay.
  originalPkgs = import pkgs.path { system = pkgs.stdenv.hostPlatform.system; };
  originalScopeModule = pkgs.zvec-c.pythonModule originalPkgs.python3Packages;
in
{
  python-api =
    assert pkgs.lib.assertMsg (
      originalScopeModule.version == pkgs.zvec-c.version && builtins.isString originalScopeModule.drvPath
    ) "pythonModule could not use an overlay-free Python package set";
    pkgs.runCommand "zvec-python-api-check" { } ''
      touch $out
    '';

  python = pkgs.runCommand "zvec-python-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR
    ${withZvec}/bin/python ${./python-smoke.py} ${zvecPython.version}
    if ${withZvec}/bin/python ${./python-smoke.py} 0.0.0 >wrong-version.log 2>&1; then
      echo "the Python module accepted an incorrect version" >&2
      exit 1
    fi
    if ${pkgs.python3}/bin/python -c 'import zvec' >/dev/null 2>&1; then
      echo "zvec imported without the package on the Python path" >&2
      exit 1
    fi
    touch $out
  '';

  python-tests = pkgs.runCommand "zvec-python-tests" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR
    cp -r ${pkgs.zvec-c.src}/python/tests tests
    cp ${pkgs.zvec-c.src}/pyproject.toml .
    chmod -R u+w tests
    # Upstream's opt-in API/model integration tests require credentials or model
    # downloads; keep its default skips. All offline tests, including mocks, run.
    export ZVEC_RUN_INTEGRATION_TESTS=0
    # Some tests start pytest subprocesses. Keep upstream's strict configuration
    # in those too, but run serially: several cases use fixed paths under /tmp.
    export PYTEST_ADDOPTS=-n0
    export PYTHONPATH=${testsPython}/${pkgs.python3.sitePackages}
    ${testsPython}/bin/python -m pytest --junitxml=results.xml tests
    if PYTHONPATH= ${withoutZvec}/bin/python -m pytest -o addopts= tests/test_collection.py >without.log 2>&1; then
      echo "the suite passed without the module" >&2
      exit 1
    fi
    grep -q "No module named 'zvec'" without.log
    mkdir -p $out
    cp results.xml $out/
  '';
}
