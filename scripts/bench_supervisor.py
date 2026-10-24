# SPDX-License-Identifier: GPL-2.0-only
"""A control process that never touches the mounted filesystem."""
import os
import signal
import sys
import time

class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum

def supervise(revoke, description, timeout, authorize=None):
    """Return only in a worker released by the supervising parent's go-pipe.

    Only the parent authorizes. Startup signals stay blocked until the child
    group and cleanup scope exist; a pending signal is delivered before either
    authorization or release. Every parent exit revokes before signaling its
    owned group, without a blocking reap, forced unmount or device cleanup.
    """
    if timeout <= 0:
        raise ValueError('benchmark timeout must be positive')
    signals = {signal.SIGINT, signal.SIGTERM}
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    previous = {}
    def interrupted(signum, frame):
        raise Interrupted(signum)
    for signum in signals:
        previous[signum] = signal.signal(signum, interrupted)
    read_fd, write_fd = os.pipe()
    pid = None
    worker = False
    status = None
    code = 124
    reason = 'deadline exceeded'
    deadline = time.monotonic() + timeout
    try:
        pid = os.fork()
        if pid == 0:
            worker = True
            os.close(write_fd)
            os.setpgid(0, 0)
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            token = os.read(read_fd, 1)
            os.close(read_fd)
            if token != b'G':
                os._exit(125)
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            return
        os.close(read_fd)
        read_fd = None
        try:
            os.setpgid(pid, pid)
        except (ProcessLookupError, PermissionError):
            pass
        # Pending startup termination is caught by this try before release.
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        if authorize is not None:
            authorize()
        os.write(write_fd, b'G')
        released_fd = write_fd
        write_fd = None
        os.close(released_fd)
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
        if not worker:
            signal.pthread_sigmask(signal.SIG_BLOCK, signals)
            for fd in (read_fd, write_fd):
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            revoked = False
            try:
                revoke()
                revoked = True
            finally:
                if pid is not None and status is None:
                    authorization = 'authorization revoked FIRST' if revoked else 'authorization revocation attempted FIRST'
                    print(f'benchmark {reason}; {authorization}; worker PID/PGID={pid}; attachment may survive: {description}. No forced cleanup or blocking reap attempted.', file=sys.stderr, flush=True)
                    try:
                        os.killpg(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    except PermissionError as error:
                        print(f'SIGTERM could not be delivered to owned worker group {pid}: {error}; worker may survive. No blocking reap or force cleanup attempted.', file=sys.stderr, flush=True)
    raise SystemExit(code if code >= 0 else 128 - code)
