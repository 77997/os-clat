#!/usr/local/bin/python3

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

import argparse
import sys
import traceback

from lib import facts
from lib import sysif
from lib.supervisor import Supervisor


def action() -> None:
    """ The daemon. Daemonize has closed every descriptor before it calls this, so everything
        that opens one happens in here. Returning removes the pidfile.
    """
    system = sysif.System()
    supervisor = None
    try:
        system.open()
        supervisor = Supervisor(system)
        supervisor.start()
        supervisor.run()
    except Exception:
        # stderr is /dev/null by now: nothing else would record this
        system.log(3, 'fatal: ' + traceback.format_exc())
    finally:
        try:
            if supervisor is not None:
                supervisor.stop()
        except Exception:
            system.log(3, 'fatal: ' + traceback.format_exc())
        finally:
            system.close()


def main() -> None:
    parser = argparse.ArgumentParser(description='464XLAT CLAT supervisor')
    parser.add_argument('-f', '--foreground', help='do not detach', default=False, action='store_true')
    args = parser.parse_args()

    sys.path.insert(0, '/usr/local/opnsense/site-python')
    from daemonize import Daemonize

    # Daemonize writes the pidfile before action() runs, and "clat event" and "clat reload" signal
    # that pid: HUP, USR1 and USR2 must not terminate the process before System.open() handles them
    sysif.ignore_signals()
    Daemonize(app='clat', pid=facts.PIDFILE, action=action, foreground=args.foreground).start()


if __name__ == '__main__':
    main()
