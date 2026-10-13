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

import ctypes
import errno
import os
import pty
import selectors
import signal
import socket
import struct
import subprocess
import syslog
import time

from . import discovery
from . import facts

# environment of every command and of the supervised child (no STATE_DIRECTORY for tayga)
PATH = '/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin'

# FreeBSD values; the socket module does not export ICMP6_FILTER
ICMP6_FILTER = 18
IPV6_MULTICAST_IF = getattr(socket, 'IPV6_MULTICAST_IF', 9)
IPV6_MULTICAST_HOPS = getattr(socket, 'IPV6_MULTICAST_HOPS', 10)
IPV6_RECVPKTINFO = getattr(socket, 'IPV6_RECVPKTINFO', 36)
IPV6_RECVHOPLIMIT = getattr(socket, 'IPV6_RECVHOPLIMIT', 37)
IPV6_PKTINFO = getattr(socket, 'IPV6_PKTINFO', 46)
IPV6_HOPLIMIT = getattr(socket, 'IPV6_HOPLIMIT', 47)
AF_ROUTE = getattr(socket, 'AF_ROUTE', 17)
ND_ROUTER_SOLICIT = 133
ND_ROUTER_ADVERT = 134
P_PID = 0
PROC_PDEATHSIG_CTL = 11

# signals that wake the main loop, and the event name System.wait() reports for each
SIGNAL_EVENTS = (
    (signal.SIGTERM, 'term'),
    (signal.SIGINT, 'term'),
    (signal.SIGHUP, 'hup'),
    (signal.SIGUSR1, 'usr1'),
    (signal.SIGUSR2, 'usr2'),
    (signal.SIGCHLD, 'chld'),
)


def ignore_signals() -> None:
    """ Ignore HUP, USR1 and USR2. Called before daemonising: until System.open() installs its
        handlers the default action of these signals would terminate the process.
    """
    for signo in (signal.SIGHUP, signal.SIGUSR1, signal.SIGUSR2):
        signal.signal(signo, signal.SIG_IGN)


def _wake(_signo, _frame) -> None:
    """ Signal handler. A Python handler must exist for the wake-up descriptor to get its byte. """


def _text(data) -> str:
    return data.decode('utf-8', errors='replace') if data else ''


def _ra_socket() -> socket.socket:
    """ Raw ICMPv6 socket that receives Router Advertisements only (from every interface: FreeBSD
        cannot bind it to a device) and sends Router Solicitations with hop limit 255.
    """
    sock = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    passed = [0] * 8
    passed[ND_ROUTER_ADVERT >> 5] |= 1 << (ND_ROUTER_ADVERT & 31)
    sock.setsockopt(socket.IPPROTO_ICMPV6, ICMP6_FILTER, struct.pack('@8I', *passed))
    sock.setsockopt(socket.IPPROTO_IPV6, IPV6_RECVPKTINFO, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, IPV6_RECVHOPLIMIT, 1)
    sock.setsockopt(socket.IPPROTO_IPV6, IPV6_MULTICAST_HOPS, 255)
    sock.setblocking(False)
    return sock


def _procctl():
    """ procctl(2) of the C library, or None when it cannot be resolved. """
    try:
        func = ctypes.CDLL(None, use_errno=True).procctl
    except (OSError, AttributeError):
        return None
    func.argtypes = [ctypes.c_int, ctypes.c_int64, ctypes.c_int, ctypes.c_void_p]
    func.restype = ctypes.c_int
    return func


class System:
    """ The operating system as the supervisor and the command line tool see it. Everything that
        touches files, processes, sockets, signals or syslog goes through one object of this class,
        so that the rest of the package runs against a fake in the unit tests.
    """
    SIGTERM = int(signal.SIGTERM)
    SIGKILL = int(signal.SIGKILL)
    SIGUSR1 = int(signal.SIGUSR1)
    SIGUSR2 = int(signal.SIGUSR2)

    def __init__(self):
        syslog.openlog('clat', facility=syslog.LOG_LOCAL4)
        self._signals = {int(signo): name for signo, name in SIGNAL_EVENTS}
        self._selector = None
        self._ra = None
        self._route = None
        self._rsig = None
        self._wsig = None
        self._procctl = None
        self._proc = None
        self._pty = None
        self._pty_live = False
        self._pending = b''

    # clocks

    def monotonic(self) -> float:
        return time.monotonic()

    def time(self) -> float:
        return time.time()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)

    # files

    def read(self, path: str) -> str | None:
        """ File content; None when the file is missing or unreadable. """
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as handle:
                return handle.read()
        except OSError:
            return None

    def write(self, path: str, text: str, mode: int = 0o644) -> bool:
        """ Replace the file atomically: readers see the old or the new content. """
        tmp = '%s.%d.tmp' % (path, os.getpid())
        try:
            fileno = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fileno, 'w', encoding='utf-8') as handle:
                os.fchmod(fileno, mode)
                handle.write(text)
            os.replace(tmp, path)
        except OSError as exc:
            self.log(4, 'unable to write %s: %s' % (path, exc))
            self.remove(tmp)
            return False
        return True

    def remove(self, path: str) -> bool:
        """ True when the file is gone afterwards, also when it did not exist. """
        try:
            os.unlink(path)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return True

    def stat(self, path: str) -> tuple[int, int, int] | None:
        """ (st_mtime_ns, st_size, st_ino); None when the file is missing. """
        try:
            result = os.stat(path)
        except OSError:
            return None
        return (result.st_mtime_ns, result.st_size, result.st_ino)

    def mkdir(self, path: str, mode: int = 0o755) -> bool:
        """ Create the directory when needed. The mode is set explicitly: the daemon's umask is 027. """
        try:
            os.makedirs(path, exist_ok=True)
            os.chmod(path, mode)
        except OSError as exc:
            self.log(4, 'unable to create %s: %s' % (path, exc))
            return False
        return True

    # processes

    def run(self, argv: list[str], timeout: float = 10.0) -> tuple[int, str, str]:
        """ Run a command without a shell. Returns (returncode, stdout, stderr): 124 on time-out,
            127 when the program cannot be started.
        """
        try:
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                                  timeout=timeout, env={'PATH': PATH})
        except subprocess.TimeoutExpired as exc:
            return 124, _text(exc.stdout), _text(exc.stderr)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            return 127, '', str(exc)
        return done.returncode, _text(done.stdout), _text(done.stderr)

    def pid_alive(self, pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    def kill(self, pid: int, signo: int) -> bool:
        """ False when the process is gone. Never signals a process group. """
        if pid <= 0:
            return False
        try:
            os.kill(pid, signo)
        except OSError:
            return False
        return True

    # misc

    def log(self, priority: int, message: str) -> None:
        """ priority: 3 (err), 4 (warning), 5 (notice) or 6 (info). """
        syslog.syslog(priority, message)

    def if_index(self, dev: str) -> int | None:
        """ Interface index; None when the device does not exist. """
        try:
            return socket.if_nametoindex(dev)
        except OSError:
            return None

    def random(self, n: int) -> bytes:
        return os.urandom(n)

    # main loop (daemon only)

    def open(self) -> None:
        """ Open the Router Advertisement socket, the routing socket and the selector, and route the
            signals into the selector. The handlers replace the dispositions of ignore_signals().
        """
        self._selector = selectors.DefaultSelector()
        self._ra = _ra_socket()
        self._route = socket.socket(AF_ROUTE, socket.SOCK_RAW, 0)
        self._route.setblocking(False)
        self._rsig, self._wsig = socket.socketpair()
        self._rsig.setblocking(False)
        self._wsig.setblocking(False)
        signal.set_wakeup_fd(self._wsig.fileno(), warn_on_full_buffer=False)
        for signo, _name in SIGNAL_EVENTS:
            signal.signal(signo, _wake)
        self._selector.register(self._rsig, selectors.EVENT_READ, 'signal')
        self._selector.register(self._ra, selectors.EVENT_READ, 'ra')
        self._selector.register(self._route, selectors.EVENT_READ, 'route')
        self._procctl = _procctl()

    def close(self) -> None:
        """ Stop a child that is still there, then close the sockets and the selector. """
        self.child_stop()
        if self._wsig is not None:
            signal.set_wakeup_fd(-1)
        for name in ('_selector', '_ra', '_route', '_rsig', '_wsig'):
            if getattr(self, name) is not None:
                getattr(self, name).close()
                setattr(self, name, None)

    def wait(self, timeout: float | None) -> set[str]:
        """ Block until something is readable or the time-out passes. Returns a subset of
            {'term', 'hup', 'usr1', 'usr2', 'chld', 'ra', 'route', 'child'}.
        """
        events = set()
        for key, _mask in self._selector.select(timeout):
            if key.data != 'signal':
                events.add(key.data)
                continue
            try:
                received = self._rsig.recv(64)
            except BlockingIOError:
                continue
            for signo in received:
                if signo in self._signals:
                    events.add(self._signals[signo])
        return events

    # router advertisements

    def ra_recv(self) -> list[discovery.RaPacket]:
        """ Drain the RA socket: one discovery.RaPacket per datagram that is complete and whose
            source parses. Whether a packet is accepted is decided by discovery.accept_ra().
        """
        packets = []
        space = socket.CMSG_SPACE(20) + socket.CMSG_SPACE(4)
        while True:
            try:
                data, ancdata, flags, sender = self._ra.recvmsg(4096, space)
            except BlockingIOError:
                return packets
            if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
                continue
            ifindex, hoplimit = 0, -1
            for level, kind, cdata in ancdata:
                if level != socket.IPPROTO_IPV6:
                    continue
                if kind == IPV6_PKTINFO and len(cdata) >= 20:
                    ifindex = struct.unpack_from('@16sI', cdata)[1]
                elif kind == IPV6_HOPLIMIT and len(cdata) >= 4:
                    hoplimit = struct.unpack_from('@i', cdata)[0]
            try:
                ifname = socket.if_indextoname(ifindex) if ifindex else ''
            except OSError:
                ifname = ''
            try:
                source = discovery.ll_norm(sender[0])
            except ValueError:
                continue
            packets.append(discovery.RaPacket(ifname, hoplimit, source, data))

    def rs_send(self, dev: str) -> bool:
        """ One Router Solicitation to ff02::2 on the device. The interface index is looked up
            for every packet: that of a PPP device changes at each reconnect.
        """
        try:
            ifindex = socket.if_nametoindex(dev)
            self._ra.setsockopt(socket.IPPROTO_IPV6, IPV6_MULTICAST_IF, ifindex)
            self._ra.sendto(struct.pack('!BBHI', ND_ROUTER_SOLICIT, 0, 0, 0), ('ff02::2', 0, 0, ifindex))
        except OSError:
            return False
        return True

    # routing socket

    def route_changed(self) -> bool:
        """ Drain the routing socket. True when a message that matters was read, or when the kernel
            dropped messages (ENOBUFS).
        """
        changed = False
        while True:
            try:
                buf = self._route.recv(4096)
            except BlockingIOError:
                return changed
            except OSError as exc:
                if exc.errno != errno.ENOBUFS:
                    raise
                changed = True
                continue
            if facts.rtm_relevant(buf):
                changed = True

    # DNS

    def dns_aaaa(self, server: str, name: str, timeout: float) -> tuple[str, list[str] | str, int | None]:
        """ One AAAA query to one server, with TCP when the reply is truncated.
            ('answer', [address, ...], ttl): the server answered; an empty list means "no AAAA".
            ('fail', reason, None): time-out, SERVFAIL, REFUSED or an error; not an answer.
        """
        import dns.exception
        import dns.message
        import dns.query
        import dns.rcode
        import dns.rdatatype

        query = dns.message.make_query(name, dns.rdatatype.AAAA)
        try:
            reply, _used_tcp = dns.query.udp_with_fallback(query, server, timeout=timeout)
        except dns.exception.Timeout:
            return ('fail', 'timeout', None)
        except (dns.exception.DNSException, OSError, EOFError, ValueError) as exc:
            return ('fail', type(exc).__name__, None)
        rcode = reply.rcode()
        if rcode not in (dns.rcode.NOERROR, dns.rcode.NXDOMAIN):
            return ('fail', dns.rcode.to_text(rcode), None)
        addrs, ttl = [], None
        for rrset in reply.answer:
            if rrset.rdtype == dns.rdatatype.AAAA:
                ttl = rrset.ttl if ttl is None else min(ttl, rrset.ttl)
                addrs.extend(item.address for item in rrset)
        if not addrs:
            for rrset in reply.authority:
                if rrset.rdtype == dns.rdatatype.SOA:
                    ttl = min(rrset.ttl, rrset[0].minimum)
        return ('answer', addrs, ttl)

    # the supervised child (tayga)

    def _die_with_parent(self) -> None:
        """ Runs in the child between fork and exec: ask for SIGTERM when the daemon exits. """
        signo = ctypes.c_int(signal.SIGTERM)
        self._procctl(P_PID, 0, PROC_PDEATHSIG_CTL, ctypes.byref(signo))

    def spawn(self, argv: list[str]) -> int | None:
        """ Start the one supervised child on a pseudo-terminal (its stdio would be block-buffered
            on a pipe), in its own session and with a clean environment. Returns the pid, None when
            the pty or the process cannot be created.
        """
        self.child_stop()
        try:
            master, slave = pty.openpty()
        except OSError as exc:
            self.log(3, 'unable to open a pseudo-terminal: %s' % exc)
            return None
        try:
            proc = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, close_fds=True,
                start_new_session=True, env={'PATH': PATH},
                preexec_fn=self._die_with_parent if self._procctl else None)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            os.close(master)
            self.log(3, 'unable to start %s: %s' % (argv[0], exc))
            return None
        finally:
            os.close(slave)
        os.set_blocking(master, False)
        self._selector.register(master, selectors.EVENT_READ, 'child')
        self._proc, self._pty, self._pty_live, self._pending = proc, master, True, b''
        return proc.pid

    def child_lines(self) -> list[str]:
        """ Lines the child has written since the last call; never blocks. At end of file the
            unfinished rest is the last line and the pty leaves the selector.
        """
        lines = []
        while self._pty_live:
            try:
                chunk = os.read(self._pty, 4096)
            except BlockingIOError:
                break
            except OSError:
                chunk = b''
            if not chunk:
                # zero-length read or EIO: the child has closed its side
                self._selector.unregister(self._pty)
                self._pty_live = False
                if not self._pending:
                    break
                chunk = b'\n'
            done, self._pending = facts.split_lines(self._pending, chunk)
            lines.extend(done)
        return lines

    def child_exit(self) -> int | None:
        """ None while the child runs or when there is none; else its exit status, reported until
            the next spawn() or child_stop().
        """
        return None if self._proc is None else self._proc.poll()

    def child_stop(self, timeout: float = 5.0) -> None:
        """ TERM, wait, KILL, then close the pty. For a child that has already exited only the pty
            is closed. Does nothing without a child.
        """
        if self._proc is None:
            return
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()
        if self._pty_live:
            self._selector.unregister(self._pty)
        os.close(self._pty)
        self._proc, self._pty, self._pty_live, self._pending = None, None, False, b''
