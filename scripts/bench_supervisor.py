# SPDX-License-Identifier: GPL-2.0-only
"""A control process that never touches the mounted filesystem."""
import os
import signal
import sys
import time

class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum

def supervise(revoke, description, timeout):
    """Return only in the owned worker; the parent revokes before termination.

    The deadline includes attachment, workload and ordinary teardown. A stuck
    worker or descendant is never synchronously reaped, force-unmounted or
    detached after timeout. Only this worker's process group receives SIGTERM.
    """
    if timeout <= 0:
        raise ValueError('benchmark timeout must be positive')
    previous = {}
    def interrupted(signum, frame):
        raise Interrupted(signum)
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, interrupted)
    pid = os.fork()
    if pid == 0:
        os.setpgid(0, 0)
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        return
    try:
        os.setpgid(pid, pid)
    except (ProcessLookupError, PermissionError):
        pass
    deadline = time.monotonic() + timeout
    status = None
    code = 124
    reason = 'deadline exceeded'
    try:
        while time.monotonic() < deadline:
            result, child_status = os.waitpid(pid, os.WNOHANG)
            if result:
                status = child_status
                code = os.waitstatus_to_exitcode(status)
                break
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    except Interrupted as interruption:
        code = 128 + interruption.signum
        reason = f'signal {interruption.signum}'
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        revoke()
    if status is None:
        print(f'benchmark {reason}; authorization revoked FIRST; worker PID/PGID={pid}; attachment may survive: {description}. No forced cleanup or blocking reap attempted.', file=sys.stderr, flush=True)
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    raise SystemExit(code if code >= 0 else 128 - code)
