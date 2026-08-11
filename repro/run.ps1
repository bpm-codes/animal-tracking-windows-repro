$ErrorActionPreference = "Stop"

$source = @'
from __future__ import annotations

import ctypes
import hashlib
import json
import msvcrt
import os
import stat
import subprocess
import tempfile
import threading
from pathlib import Path


class ReproError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def fail(code: str, message: str) -> None:
    raise ReproError(code, message)


def output_matches(path: Path, data: bytes) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return False
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return False
        with os.fdopen(fd, "rb", closefd=False) as handle:
            return handle.read() == data
    finally:
        os.close(fd)


def atomic_write(path: Path, data: bytes) -> Path:
    parent = path.parent
    parent_info = os.lstat(parent)
    parent_attrs = getattr(parent_info, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x0400)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or stat.S_ISLNK(parent_info.st_mode)
        or bool(parent_attrs & reparse_flag)
    ):
        fail("OUTPUT_DIRECTORY_INVALID", "output directory is unsafe")
    if path.exists() or path.is_symlink():
        if output_matches(path, data):
            return path
        fail("OUTPUT_CONFLICT", "target exists with different bytes")

    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if output_matches(path, data):
                return path
            fail("OUTPUT_CONFLICT", "target exists with different bytes")
        except OSError as exc:
            raise ReproError("OUTPUT_PUBLISH_FAILED", str(exc)) from exc
        return path
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def relative_parts(relative_path: str) -> tuple[str, ...]:
    normalized = relative_path.replace("\\", "/")
    parts = tuple(normalized.split("/"))
    if not parts or any(part in {"", ".", ".."} for part in parts):
        fail("PATH_UNSAFE", "unsafe relative component")
    return parts


def normalize_windows_final_path(value: str) -> str:
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return os.path.normcase(os.path.normpath(value))


def windows_final_path_for_fd(fd: int) -> str:
    handle = msvcrt.get_osfhandle(fd)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    get_final_path = kernel32.GetFinalPathNameByHandleW
    get_final_path.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
    get_final_path.restype = ctypes.c_uint32
    required = get_final_path(handle, None, 0, 0)
    if required == 0:
        raise OSError(ctypes.get_last_error(), "GetFinalPathNameByHandleW failed")
    buffer = ctypes.create_unicode_buffer(required + 1)
    written = get_final_path(handle, buffer, len(buffer), 0)
    if written == 0 or written >= len(buffer):
        raise OSError(ctypes.get_last_error(), "GetFinalPathNameByHandleW failed")
    return normalize_windows_final_path(buffer.value)


def hash_open_fd(fd: int) -> tuple[str, int]:
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        fail("NOT_REGULAR", "file is not regular")
    digest = hashlib.sha256()
    with os.fdopen(fd, "rb", closefd=False) as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    after = os.fstat(fd)
    attrs = ("st_dev", "st_ino", "st_size", "st_mtime_ns")
    if any(getattr(before, name, None) != getattr(after, name, None) for name in attrs):
        fail("CHANGED", "file changed during hashing")
    return digest.hexdigest(), after.st_size


def hash_file_windows(root: Path, relative_path: str) -> tuple[str, int]:
    parts = relative_parts(relative_path)
    root_info = os.lstat(root)
    root_attributes = getattr(root_info, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x0400)
    if (
        not stat.S_ISDIR(root_info.st_mode)
        or stat.S_ISLNK(root_info.st_mode)
        or bool(root_attributes & reparse_flag)
    ):
        fail("PATH_UNSAFE", "staging root is unsafe")
    resolved_root = normalize_windows_final_path(str(root.resolve(strict=True)))
    candidate = root.joinpath(*parts)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOINHERIT", 0)
    try:
        fd = os.open(candidate, flags)
    except OSError as exc:
        raise ReproError("OPEN_FAILED", str(exc)) from exc
    try:
        resolved_file = windows_final_path_for_fd(fd)
        try:
            common = os.path.commonpath([resolved_root, resolved_file])
        except ValueError as exc:
            raise ReproError("PATH_UNSAFE", str(exc)) from exc
        if os.path.normcase(common) != os.path.normcase(resolved_root):
            fail("PATH_UNSAFE", "file resolved outside staging root")
        return hash_open_fd(fd)
    finally:
        os.close(fd)


def precheck(root: Path, relative_path: str) -> None:
    candidate = root.joinpath(*relative_parts(relative_path))
    resolved_root = root.resolve(strict=True)
    resolved_candidate = candidate.resolve(strict=True)
    if resolved_candidate != resolved_root and resolved_root not in resolved_candidate.parents:
        fail("PATH_UNSAFE", "precheck escaped root")


def run_atomic_stress() -> dict[str, int]:
    same_rounds = 0
    conflict_rounds = 0
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        for round_index in range(40):
            root = base / f"round-{round_index}"
            root.mkdir()
            target = root / "receipt.json"
            same = round_index % 2 == 0
            payloads = (
                (b'{"same":"bytes"}', b'{"same":"bytes"}')
                if same
                else (b'{"writer":1}', b'{"writer":2}')
            )
            barrier = threading.Barrier(2)
            successes: list[bytes] = []
            errors: list[ReproError] = []

            def writer(data: bytes) -> None:
                barrier.wait(timeout=5)
                try:
                    atomic_write(target, data)
                    successes.append(data)
                except ReproError as exc:
                    errors.append(exc)

            threads = [threading.Thread(target=writer, args=(data,)) for data in payloads]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
            if any(thread.is_alive() for thread in threads):
                fail("THREAD_TIMEOUT", "concurrent writer did not terminate")
            if same:
                if errors or len(successes) != 2 or target.read_bytes() != payloads[0]:
                    fail("ATOMIC_SAME_FAILED", f"round {round_index}")
                same_rounds += 1
            else:
                if len(successes) != 1 or [item.code for item in errors] != ["OUTPUT_CONFLICT"]:
                    fail("ATOMIC_CONFLICT_FAILED", f"round {round_index}")
                if target.read_bytes() != successes[0]:
                    fail("ATOMIC_CLOBBER", f"round {round_index}")
                conflict_rounds += 1
            if list(root.glob("*.tmp")):
                fail("TEMP_RESIDUE", f"round {round_index}")
    return {"same_rounds": same_rounds, "conflict_rounds": conflict_rounds}


def run_junction_escape() -> dict[str, str]:
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        root = base / "root"
        outside = base / "outside"
        safe_parent = root / "sub"
        safe_parent.mkdir(parents=True)
        outside.mkdir()
        (safe_parent / "report.md").write_text("safe", encoding="utf-8")
        (outside / "report.md").write_text("outside", encoding="utf-8")

        precheck(root, "sub/report.md")
        safe_parent.rename(root / "sub-original")
        substituted = root / "sub"
        completed = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(substituted), str(outside)],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            fail("JUNCTION_CREATE_FAILED", completed.stderr or completed.stdout)
        try:
            try:
                hash_file_windows(root, "sub/report.md")
            except ReproError as exc:
                if exc.code not in {"PATH_UNSAFE", "OPEN_FAILED"}:
                    raise
                return {"junction_escape": "REJECTED", "code": exc.code}
            fail("JUNCTION_ESCAPE_ACCEPTED", "outside file was accepted after parent substitution")
        finally:
            if substituted.exists():
                os.rmdir(substituted)


def run_safe_hash() -> dict[str, object]:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        target = root / "report.md"
        target.write_text("safe evidence", encoding="utf-8")
        digest, size = hash_file_windows(root, "report.md")
        expected = hashlib.sha256(b"safe evidence").hexdigest()
        if digest != expected or size != len(b"safe evidence"):
            fail("SAFE_HASH_FAILED", "safe file hash mismatch")
        return {"safe_hash": "PASS", "size": size}


def main() -> int:
    if os.name != "nt":
        raise SystemExit("This bounded reproducer requires Windows.")
    result = {
        "platform": "windows",
        "atomic": run_atomic_stress(),
        "safe_file": run_safe_hash(),
        "parent_junction_substitution": run_junction_escape(),
    }
    print(json.dumps(result, sort_keys=True))
    print("WORK_RECEIPT_FILESYSTEM_REPRO=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

python -c $source
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
