# tools/py_limit.py: Process concurrency limiter for Amaterrace GPU
# Strictly limits concurrent Python executions to max_procs (default: 3).
import fcntl
import os
import time

_lock_file = None

def limit_concurrency(max_procs=3, group="amaterrace_py"):
    """
    Acquires one of `max_procs` file lock slots in /tmp/{group}_locks/.
    If all slots are busy, sleeps 100ms and retries.
    When the process terminates, the OS automatically releases the lock.
    """
    global _lock_file
    if os.environ.get("AMATERRACE_NO_LIMIT") == "1":
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
                return
            except (IOError, OSError):
                try:
                    f.close()
                except Exception:
                    pass
                continue
        time.sleep(0.1)
