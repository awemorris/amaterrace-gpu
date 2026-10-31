# tools/py_limit.py: Process concurrency limiter for Amaterrace GPU
# Strictly limits concurrent Python executions to max_procs (default: 3)
# and flushes filesystem buffers (os.sync) on exit.
import atexit
import fcntl
import os
import time

_lock_file = None
_sync_registered = False

def _sync_on_exit():
    try:
        os.sync()
    except Exception:
        pass

def limit_concurrency(max_procs=3, group="amaterrace_py"):
    """
    Acquires one of `max_procs` file lock slots in /tmp/{group}_locks/.
    If all slots are busy, sleeps 100ms and retries.
    When the process terminates, flushes disk buffers (sync) and releases the lock.
    """
    global _lock_file, _sync_registered
    if not _sync_registered:
        atexit.register(_sync_on_exit)
        _sync_registered = True

    if os.environ.get("AMATERRACE_NO_LIMIT") == "1":
        return
    if os.environ.get("AMATERRACE_PY_LOCK_PID") in (str(os.getpid()), str(os.getppid())):
        return

    lock_dir = f"/tmp/{group}_locks"
    try:
        os.makedirs(lock_dir, exist_ok=True)
    except OSError:
        pass

    while True:
        for i in range(max_procs):
            fpath = os.path.join(lock_dir, f"slot_{i}.lock")
            try:
                f = open(fpath, "w")
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                _lock_file = f
                os.environ["AMATERRACE_PY_LOCK_PID"] = str(os.getpid())
                return
            except (IOError, OSError):
                try:
                    f.close()
                except Exception:
                    pass
                continue
        time.sleep(0.1)
