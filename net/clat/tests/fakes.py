"""
    Copyright (C) 2026 os-clat contributors
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
"""


class FakeSystem:
    """ Stand-in for lib.sysif.System: the same methods and attributes, on state a test sets and reads.

        clock         monotonic time; advance() and sleep() move it, time() is epoch + clock
        files         path -> text; write() and put() give the file a new stat tuple. modes has the mode
                      of each write(), dirs the mode of each mkdir()
        commands      every argv passed to run(), in order; reply() sets what a command returns
        ifindex       device -> index, for if_index()
        ra_queue      discovery.RaPacket tuples that ra_recv() hands out once
        route_flag    what the next route_changed() returns
        dns_outcome   what dns_aaaa() returns; the queries are in dns_queries
        pids          live process ids, for pid_alive(); kill() records (pid, signo) in signals
        spawned       every argv passed to spawn(); spawn_fails makes it return None, tayga_fails keeps
                      the child from printing the line that reports the tun
        logs          (priority, message) of every log() call
        rs_sent       device of every rs_send() call
    """
    SIGTERM = 15
    SIGKILL = 9
    SIGUSR1 = 30
    SIGUSR2 = 31

    def __init__(self) -> None:
        self.clock = 1000.0
        self.epoch = 1760000000.0
        self.files = {}
        self.modes = {}
        self.dirs = {}
        self.commands = []
        self.logs = []
        self.ifindex = {}
        self.ra_queue = []
        self.rs_sent = []
        self.route_flag = False
        self.dns_outcome = ('fail', 'timeout', None)
        self.dns_queries = []
        self.pids = set()
        self.signals = []
        self.spawned = []
        self.spawn_fails = False
        self.tayga_fails = False
        self.child_pid = None
        self.child_status = None
        self.child_output = []
        self._replies = {}
        self._stats = {}
        self._serial = 0
        self._last_pid = 4242

    # clocks

    def monotonic(self) -> float:
        return self.clock

    def time(self) -> float:
        return self.epoch + self.clock

    def sleep(self, seconds: float) -> None:
        self.advance(seconds)

    def advance(self, seconds: float) -> None:
        """ Let time pass on both clocks. """
        self.clock += seconds

    # files

    def put(self, path: str, text: str) -> None:
        """ Create or rewrite a file, as something other than the code under test would. """
        self._serial += 1
        self.files[path] = text
        self._stats[path] = self._serial

    def read(self, path: str) -> str | None:
        return self.files.get(path)

    def write(self, path: str, text: str, mode: int = 0o644) -> bool:
        self.put(path, text)
        self.modes[path] = mode
        return True

    def remove(self, path: str) -> bool:
        self.files.pop(path, None)
        return True

    def stat(self, path: str) -> tuple[int, int, int] | None:
        """ (st_mtime_ns, st_size, st_ino); a file placed in files directly gets a stat when first asked. """
        if path not in self.files:
            return None
        if path not in self._stats:
            self._serial += 1
            self._stats[path] = self._serial
        serial = self._stats[path]
        return (serial, len(self.files[path].encode('utf-8')), serial)

    def mkdir(self, path: str, mode: int = 0o755) -> bool:
        self.dirs[path] = mode
        return True

    # commands

    def reply(self, prefix: list[str], rc: int = 0, out: str = '', err: str = '') -> None:
        """ Answer of every command whose argv starts with prefix. The longest matching prefix wins; a
            command without one returns (0, '', ''), and configctl answers OK.
        """
        self._replies[tuple(prefix)] = (rc, out, err)

    def run(self, argv: list[str], timeout: float = 10.0) -> tuple[int, str, str]:
        self._check(argv)
        self.commands.append(list(argv))
        for length in range(len(argv), 0, -1):
            if tuple(argv[:length]) in self._replies:
                return self._replies[tuple(argv[:length])]
        if argv and argv[0].endswith('/configctl'):
            return (0, 'OK\n', '')
        return (0, '', '')

    @staticmethod
    def _check(argv) -> None:
        """ subprocess raises TypeError for an argument that is not a string. """
        for word in argv:
            if not isinstance(word, str):
                raise TypeError('expected str, not %s: %r' % (type(word).__name__, word))

    # the rest of the system

    def log(self, priority: int, message: str) -> None:
        self.logs.append((priority, message))

    def if_index(self, dev: str) -> int | None:
        return self.ifindex.get(dev)

    def random(self, n: int) -> bytes:
        return bytes((index * 7 + 1) % 256 for index in range(n))

    def pid_alive(self, pid: int) -> bool:
        return pid in self.pids

    def kill(self, pid: int, signo: int) -> bool:
        self.signals.append((pid, signo))
        return pid in self.pids

    # daemon side

    def open(self) -> None:
        pass

    def close(self) -> None:
        pass

    def wait(self, timeout: float | None) -> set[str]:
        """ Nothing ever happens by itself: the time-out passes. """
        if timeout:
            self.advance(timeout)
        return set()

    def ra_recv(self) -> list:
        packets = self.ra_queue
        self.ra_queue = []
        return packets

    def rs_send(self, dev: str) -> bool:
        self.rs_sent.append(dev)
        return True

    def route_changed(self) -> bool:
        changed = self.route_flag
        self.route_flag = False
        return changed

    def dns_aaaa(self, server: str, name: str, timeout: float) -> tuple:
        self.dns_queries.append((server, name))
        return self.dns_outcome

    # the supervised child

    def spawn(self, argv: list[str]) -> int | None:
        """ Start the child. Like tayga it reports the tun with the MTU the device has at that moment:
            the one of the last "ifconfig tun464 mtu <n>" command.
        """
        self._check(argv)
        self.spawned.append(list(argv))
        if self.spawn_fails:
            return None
        self._last_pid += 1
        self.child_pid = self._last_pid
        self.child_status = None
        self.child_output = []
        self.pids.add(self.child_pid)
        if not self.tayga_fails:
            mtu = 1500
            for command in self.commands:
                if command[1:3] == ['tun464', 'mtu'] and command[0].endswith('/ifconfig'):
                    mtu = int(command[3])
            self.child_output.append('Using tun device tun464 with MTU %d' % mtu)
        return self.child_pid

    def child_lines(self) -> list[str]:
        lines = self.child_output
        self.child_output = []
        return lines

    def child_exit(self) -> int | None:
        return self.child_status

    def child_stop(self, timeout: float = 5.0) -> None:
        self.pids.discard(self.child_pid)
        self.child_pid = None
        self.child_status = None
        self.child_output = []

    def exit_child(self, code: int) -> None:
        """ The child exits by itself with this status. """
        if self.child_pid is not None:
            self.pids.discard(self.child_pid)
            self.child_status = code
