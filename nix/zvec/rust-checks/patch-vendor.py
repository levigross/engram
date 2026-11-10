"""Apply local bindings to pinned crates while retaining Cargo integrity checks."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tomllib

vendor = Path(sys.argv[1])
patches = {"zvec-rust-sys": Path(sys.argv[2]), "zvec-rust": Path(sys.argv[3])}
patched = set()
for checksum in vendor.rglob(".cargo-checksum.json"):
    manifest = checksum.parent / "Cargo.toml"
    if not manifest.exists():
        continue
    package = tomllib.loads(manifest.read_text())["package"]
    name = package.get("name")
    if name not in patches:
        continue
    if package.get("version") != "0.8.0" or name in patched:
        raise RuntimeError(f"Unexpected or duplicate {name} version in {manifest}")
    metadata = json.loads(checksum.read_text())
    # Validate the original vendor files before changing them. Keep the package
    # checksum, which identifies the original archive pinned by Cargo.lock.
    for filename, expected in metadata["files"].items():
        actual = hashlib.sha256((checksum.parent / filename).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Original vendor checksum differs: {name}/{filename}")
    subprocess.run(
        ["patch", "--fuzz=0", "-d", str(checksum.parent), "-p1", "-i", str(patches[name])],
        check=True,
    )
    metadata["files"] = {
        str(path.relative_to(checksum.parent)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(checksum.parent.rglob("*"))
        if path.is_file() and path != checksum
    }
    checksum.write_text(json.dumps(metadata, sort_keys=True) + "\n")
    patched.add(name)
if patched != patches.keys():
    raise RuntimeError(f"Expected both pinned zvec crates; found {sorted(patched)}")
