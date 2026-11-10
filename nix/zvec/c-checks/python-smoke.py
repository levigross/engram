"""Exercise the installed Python module, including persistence and bad input."""

import sys
import tempfile
from importlib.metadata import distribution
from pathlib import Path

import zvec


assert zvec.__version__ == sys.argv[1], (zvec.__version__, sys.argv[1])
metadata = distribution("zvec")
assert {"test", "docs", "dev"} <= set(metadata.metadata.get_all("Provides-Extra", []))
assert "Root-Is-Purelib: false" in metadata.read_text("WHEEL")
assert any(path.name.startswith("_zvec") and path.suffix == ".so" for path in metadata.files)
zvec.init(log_type=zvec.LogType.CONSOLE, log_level=zvec.LogLevel.ERROR)

with tempfile.TemporaryDirectory() as directory:
    path = str(Path(directory) / "collection")
    schema = zvec.CollectionSchema(
        name="python_smoke",
        vectors=[
            zvec.VectorSchema(
                "embedding",
                zvec.DataType.VECTOR_FP32,
                dimension=4,
                index_param=zvec.FlatIndexParam(metric_type=zvec.MetricType.L2),
            )
        ],
    )
    collection = zvec.create_and_open(path, schema)
    for doc in [
        zvec.Doc(id="nearest", vectors={"embedding": [1.0, 0.0, 0.0, 0.0]}),
        zvec.Doc(id="far", vectors={"embedding": [0.0, 1.0, 0.0, 0.0]}),
    ]:
        assert collection.insert(doc).ok()
    collection.flush()
    collection.close()

    collection = zvec.open(path)
    results = collection.query(
        zvec.Query(field_name="embedding", vector=[1.0, 0.0, 0.0, 0.0]), topk=2
    )
    assert [doc.id for doc in results] == ["nearest", "far"], results
    try:
        collection.query(zvec.Query(field_name="missing", vector=[1.0] * 4), topk=1)
    except Exception:
        pass
    else:
        raise AssertionError("querying an absent vector field succeeded")
    collection.close()
