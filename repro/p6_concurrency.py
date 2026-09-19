from __future__ import annotations

import ctypes
import hashlib
import io
import json
import sqlite3
import sys
import sysconfig
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image


def require_free_threaded() -> None:
    if sysconfig.get_config_var("Py_GIL_DISABLED") != 1:
        raise RuntimeError("Expected a CPython free-threaded build.")
    probe = getattr(sys, "_is_gil_enabled", None)
    if probe is None:
        raise RuntimeError("CPython does not expose sys._is_gil_enabled().")
    if probe():
        raise RuntimeError("The GIL is enabled before the stress run.")


def native_module_inventory() -> dict[str, str]:
    import _ctypes
    import _hashlib
    import _sqlite3
    import PIL._imaging

    modules = {
        "_ctypes": _ctypes,
        "_hashlib": _hashlib,
        "_sqlite3": _sqlite3,
        "PIL._imaging": PIL._imaging,
    }
    return {name: str(Path(module.__file__ or "").suffix).lower() for name, module in modules.items()}


def pillow_stress(worker: int) -> int:
    total = 0
    for index in range(96):
        image = Image.new("RGB", (96, 64), (worker % 255, index % 255, (worker + index) % 255))
        resized = image.resize((48, 32))
        payload = io.BytesIO()
        resized.save(payload, format="PNG")
        data = payload.getvalue()
        total ^= int.from_bytes(hashlib.sha256(data).digest()[:8], "big")
    return total


def ctypes_hash_stress(worker: int) -> int:
    total = 0
    for index in range(3000):
        raw = f"{worker}:{index}".encode("ascii")
        buffer = ctypes.create_string_buffer(raw)
        total ^= int.from_bytes(hashlib.sha256(buffer.raw).digest()[:8], "big")
    return total


def sqlite_writer(database: Path, worker: int) -> int:
    committed = 0
    connection = sqlite3.connect(database, timeout=30.0, isolation_level=None)
    try:
        connection.execute("PRAGMA busy_timeout=30000")
        for index in range(80):
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    "INSERT INTO stress(worker_id, item_id, payload) VALUES (?, ?, ?)",
                    (worker, index, f"{worker}:{index}"),
                )
                connection.execute("COMMIT")
                committed += 1
            except BaseException:
                connection.execute("ROLLBACK")
                raise
    finally:
        connection.close()
    return committed


def run() -> dict[str, object]:
    require_free_threaded()
    native_modules = native_module_inventory()
    if getattr(sys, "_is_gil_enabled")():
        raise RuntimeError("A native-module import enabled the GIL.")

    with ThreadPoolExecutor(max_workers=16) as pool:
        pillow_results = list(pool.map(pillow_stress, range(16)))
        ctypes_results = list(pool.map(ctypes_hash_stress, range(16)))

    with tempfile.TemporaryDirectory(prefix="p6-sqlite-") as temp:
        database = Path(temp) / "stress.sqlite3"
        with sqlite3.connect(database) as connection:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute(
                "CREATE TABLE stress ("
                "worker_id INTEGER NOT NULL, "
                "item_id INTEGER NOT NULL, "
                "payload TEXT NOT NULL, "
                "UNIQUE(worker_id, item_id)"
                ")"
            )
        with ThreadPoolExecutor(max_workers=12) as pool:
            sqlite_results = list(pool.map(lambda worker: sqlite_writer(database, worker), range(12)))
        with sqlite3.connect(database) as connection:
            row_count = connection.execute("SELECT COUNT(*) FROM stress").fetchone()[0]

    if row_count != 12 * 80:
        raise RuntimeError(f"SQLite row-count mismatch: {row_count}")
    if sqlite_results != [80] * 12:
        raise RuntimeError(f"SQLite worker result mismatch: {sqlite_results}")
    if getattr(sys, "_is_gil_enabled")():
        raise RuntimeError("The GIL became enabled during the stress run.")

    return {
        "python": sys.version.split()[0],
        "py_gil_disabled": sysconfig.get_config_var("Py_GIL_DISABLED"),
        "gil_enabled_after": bool(getattr(sys, "_is_gil_enabled")()),
        "native_modules": native_modules,
        "pillow_workers": len(pillow_results),
        "ctypes_workers": len(ctypes_results),
        "sqlite_workers": len(sqlite_results),
        "sqlite_rows": row_count,
    }


if __name__ == "__main__":
    print(json.dumps(run(), sort_keys=True))
