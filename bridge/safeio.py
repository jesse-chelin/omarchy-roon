"""Reading and writing the plugin's own state, defensively.

A plugin's state directory is a trust boundary. It holds an auth token and a
listening history, it sits in a world-traversable parent, and anything with a
local foothold can plant a symlink or a very large file in it before we open
one. The marketplace's human reviewers check exactly this, and the plugin got
three of the four wrong on its first pass: a directory that was 0755 because
`os.makedirs(mode=0o700)` is masked by umask, history and favourites at 0644,
and a predictable `.tmp` name with no fsync.

Stdlib only, so the endpoint prober can use it too.
"""

from __future__ import annotations

import errno
import json
import os
import tempfile

# A state file is a few hundred rows of track metadata. Anything larger is a
# planted file or a corrupted one, and either way we are not parsing megabytes
# into memory to find out.
MAX_STATE_BYTES = 4 * 1024 * 1024


class UnsafePath(Exception):
    """The path is not the ordinary file we expected to find there."""


def ensure_private_dir(path: str) -> None:
    """Create a directory that is really 0700, not 0700 minus the umask."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        # makedirs applies the umask, so a fresh directory is usually 0755 and
        # an existing one is whatever it already was. Say what we mean.
        os.chmod(path, 0o700)
    except OSError:
        pass


def read_json(path: str, default=None, limit: int = MAX_STATE_BYTES):
    """Read our own JSON without following a symlink and without unbounded reads.

    Returns `default` for anything that is missing, too large, not a regular
    file, or not parseable. A corrupt history is not worth an exception at
    startup; it is worth starting empty.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.EMLINK):
            raise UnsafePath("%s is a symlink" % path) from exc
        return default

    try:
        info = os.fstat(fd)
        if not os.path.stat.S_ISREG(info.st_mode):
            raise UnsafePath("%s is not a regular file" % path)
        # Hardening the write path does nothing for the files already on disk.
        # Anyone who ran an earlier version has a 0644 history sitting in a
        # directory that was 0755, so repair it the first time we open it.
        if info.st_mode & 0o077:
            try:
                os.fchmod(fd, 0o600)
            except OSError:
                pass
        if info.st_size > limit:
            raise UnsafePath("%s is %d bytes, over the %d limit"
                             % (path, info.st_size, limit))
        # Read one byte past the limit so a file that grows between fstat and
        # read cannot slip through.
        with os.fdopen(fd, "rb", closefd=True) as handle:
            fd = -1
            raw = handle.read(limit + 1)
        if len(raw) > limit:
            raise UnsafePath("%s exceeded the %d byte limit while reading"
                             % (path, limit))
    finally:
        if fd >= 0:
            os.close(fd)

    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return default


def write_json_private(path: str, payload) -> None:
    """Replace a state file atomically, privately, and durably.

    Unpredictable name, exclusive creation, 0600 set at creation rather than by
    a later chmod, flushed and fsynced before it is named, then the directory
    fsynced so the rename survives a power cut.
    """
    directory = os.path.dirname(path) or "."
    ensure_private_dir(directory)

    handle = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".", suffix=".tmp")
        os.fchmod(fd, 0o600)
        handle = os.fdopen(fd, "w", encoding="utf-8")
        json.dump(payload, handle)
        handle.flush()
        os.fsync(handle.fileno())
        handle.close()
        handle = None
        os.replace(tmp, path)
        tmp = None
    finally:
        if handle is not None:
            handle.close()
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    # The rename itself is only durable once the directory entry is.
    try:
        dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError:
        pass
