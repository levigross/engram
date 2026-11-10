# zvec's Python binding uses its C++ API, not the exported C interface. Build
# upstream's _zvec target with the same sources, patches and offline dependencies
# as zvec-c, then package the Python files without invoking the native build again.
{
  lib,
  buildPythonPackage,
  python,
  setuptools,
  tomli,
  tomli-w,
  pybind11,
  numpy,
  zvec-c,
}:

let
  binding = zvec-c.overrideAttrs (old: {
    pname = "zvec-python-binding-python${python.pythonVersion}";
    buildInputs = (old.buildInputs or [ ]) ++ [
      python
      pybind11
    ];
    cmakeFlags = old.cmakeFlags ++ [
      (lib.cmakeBool "BUILD_PYTHON_BINDINGS" true)
      (lib.cmakeFeature "Python_EXECUTABLE" python.interpreter)
      (lib.cmakeBool "PYBIND11_FINDPYTHON" true)
      (lib.cmakeFeature "SKBUILD_PLATLIB_DIR" "${placeholder "out"}/lib")
    ];
    ninjaFlags = [ "_zvec" ];
    installPhase = ''
      runHook preInstall
      cmake --install . --component python
      runHook postInstall
    '';
    meta = old.meta // {
      description = "The native zvec binding for Python ${python.pythonVersion}";
      pkgConfigModules = [ ];
    };
  });
in
buildPythonPackage {
  pname = "zvec";
  inherit (zvec-c) version src;
  disabled = python.isPyPy || lib.versionOlder python.version "3.9";
  pyproject = true;

  # Native compilation is done by `binding`. Keep upstream's project metadata
  # while replacing the backend that would invoke CMake a second time.
  postPatch = ''
    ${python.interpreter} - <<'PY'
    from pathlib import Path
    try:
        import tomllib
    except ModuleNotFoundError:
        import tomli as tomllib
    import tomli_w

    path = Path("pyproject.toml")
    config = tomllib.loads(path.read_text())
    assert config["project"].pop("dynamic") == ["version"]
    config["project"]["version"] = "${zvec-c.version}"
    config["build-system"] = {
        "requires": ["setuptools"],
        "build-backend": "setuptools.build_meta",
    }
    config["tool"].pop("scikit-build")
    config["tool"]["setuptools"] = {
        "packages": {"find": {"where": ["python"], "include": ["zvec*"]}},
        "package-data": {"zvec": ["py.typed", "**/*.pyi", "*.so"]},
    }
    path.write_text(tomli_w.dumps(config))
    PY

    # Include the prebuilt extension in the wheel and its RECORD, with a native
    # platform tag even though setuptools has no compilation left to perform.
    cat > setup.py <<'PY'
    from setuptools import Distribution, setup

    class BinaryDistribution(Distribution):
        def has_ext_modules(self):
            return True

    setup(distclass=BinaryDistribution)
    PY
  '';

  build-system = [
    setuptools
    tomli-w
  ]
  ++ lib.optional (lib.versionOlder python.version "3.11") tomli;
  dependencies = [ numpy ];

  preBuild = ''
    cp ${binding}/lib/zvec/_zvec*.so python/zvec/
  '';

  pythonImportsCheck = [ "zvec" ];
  passthru = { inherit binding; };

  meta = {
    description = "zvec in-process vector database for Python";
    homepage = "https://github.com/alibaba/zvec";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
}
