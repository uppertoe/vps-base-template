#!/usr/bin/env python3
"""sqlite-snapshot — consistent copies of the SQLite databases under some paths.

restic reads a live database, its -wal and its -shm at different moments, so a
copy of a busy database can be torn and fail to open. This finds every SQLite
database under the given paths (by its file header) and copies it with
SQLite's online backup API, which reads one consistent state, into
STAGE/<original absolute path>. It prints each live database's path, one per
line, so the caller can leave the live files out of the snapshot and back up
the staged copies instead. restore.sh moves the copies back into place, and the
restore drill runs an integrity check on them.

    sqlite-snapshot STAGE PATH [PATH ...]

Exits non-zero if any copy fails or fails its quick check.
"""

import os
import sqlite3
import sys
import urllib.parse

HEADER = b"SQLite format 3\x00"
SIDE = ("-wal", "-shm", "-journal")


def databases(path):
    """Yield every SQLite database file at or under path."""
    if os.path.islink(path):
        return
    if os.path.isfile(path):
        candidates = [path]
    else:
        candidates = []
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
            candidates.extend(os.path.join(root, f) for f in files)
    for p in candidates:
        if p.endswith(SIDE) or os.path.islink(p) or not os.path.isfile(p):
            continue
        try:
            with open(p, "rb") as f:
                if f.read(16) == HEADER:
                    yield os.path.abspath(p)
        except OSError:
            continue


def snapshot(src_path, dest):
    os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
    tmp = dest + ".partial"
    if os.path.exists(tmp):
        os.remove(tmp)
    # Read-only: the copy never writes to the live database.
    src = sqlite3.connect("file:" + urllib.parse.quote(src_path) + "?mode=ro", uri=True, timeout=30)
    dst = sqlite3.connect(tmp)
    try:
        src.backup(dst)
        ok = dst.execute("PRAGMA quick_check").fetchone()[0]
        if ok != "ok":
            raise RuntimeError("quick_check on the copy said: " + str(ok)[:200])
    finally:
        dst.close()
        src.close()
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-3])
    stage = os.path.abspath(sys.argv[1])
    failed = 0
    for path in sys.argv[2:]:
        for db in databases(path):
            dest = stage + db
            try:
                snapshot(db, dest)
                print(db)
            except Exception as e:  # report every database, then fail
                print(f"sqlite-snapshot: could not copy {db}: {e}", file=sys.stderr)
                failed += 1
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
