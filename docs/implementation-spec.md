# os-clat implementation specification

Version 2, 2026-10-11 (revised after two reviews). Implements DESIGN.md v0.8 sections 5 to 10, 12 and the packaging part of 14.

Precedence: DESIGN.md decides behaviour, except for the deviations listed in 14.B. Both were accepted (section 16, item 7). This SPEC fixes names, interfaces and the details DESIGN.md leaves open (listed in 14.A). The three sheets it cites as "sheet X n.n" were working notes and are not part of this repository. When this was written nothing had run on a box; the amendments of section 16 from item 8 on and the passages marked "lab" come from the lab runs of 2026-10-11 and 12.

All paths in sections 1 and 15 are relative to `net/clat/`. `src/<p>` installs to `/usr/local/<p>`.

## 1. File tree

| File | Comp. | Content |
|---|---|---|
| `Makefile` | A | plugin metadata (11.1) |
| `pkg-descr` | A | description and changelog (11.1) |
| `+PRE_DEINSTALL.pre` | A | stop the service (11.3) |
| `+POST_INSTALL.post` | A | register the interface, restart the service (11.3) |
| `+POST_DEINSTALL.post` | A | remove record and tun (11.3) |
| `src/etc/rc.d/clat` | A | rc.d script (11.2) |
| `src/opnsense/service/conf/actions.d/actions_clat.conf` | A | configd actions (5) |
| `src/opnsense/service/templates/OPNsense/Clat/+TARGETS` | A | template targets (3.3) |
| `src/opnsense/service/templates/OPNsense/Clat/rc.conf.d` | A | `clat_enable` (3.3) |
| `src/opnsense/service/templates/OPNsense/Clat/clatd.json` | A | daemon settings (3.3) |
| `src/opnsense/service/templates/OPNsense/Syslog/local/clat.conf` | A | local log filter (11.4) |
| `src/etc/inc/plugins.inc.d/clat.inc` | B | core hooks (4) |
| `src/opnsense/scripts/clat/facts.php` | B | config and gateway facts as JSON (9) |
| `src/opnsense/mvc/app/models/OPNsense/Clat/Clat.xml` | C | settings model (3.1) |
| `src/opnsense/mvc/app/models/OPNsense/Clat/Clat.php` | C | model class, cross-field validation (3.2) |
| `src/opnsense/mvc/app/models/OPNsense/Clat/ACL/ACL.xml` | C | privileges (10.4) |
| `src/opnsense/mvc/app/models/OPNsense/Clat/Menu/Menu.xml` | C | menu (10.4) |
| `src/opnsense/mvc/app/controllers/OPNsense/Clat/IndexController.php` | C | page controller (10.1) |
| `src/opnsense/mvc/app/controllers/OPNsense/Clat/Api/SettingsController.php` | C | settings API (10.1) |
| `src/opnsense/mvc/app/controllers/OPNsense/Clat/Api/ServiceController.php` | C | service API, status, test (10.1) |
| `src/opnsense/mvc/app/controllers/OPNsense/Clat/forms/general.xml` | C | settings form (10.2) |
| `src/opnsense/mvc/app/controllers/OPNsense/Clat/forms/status.xml` | C | status panel (10.2) |
| `src/opnsense/mvc/app/views/OPNsense/Clat/index.volt` | C | the page (10.3) |
| `src/opnsense/scripts/clat/lib/__init__.py` | D | empty (licence header only) |
| `src/opnsense/scripts/clat/lib/discovery.py` | D | PREF64, RFC 7050, prefix bookkeeping, link-local normalisation (6.3) |
| `src/opnsense/scripts/clat/lib/plan.py` | D | address selection, MTU, tayga.conf (6.4) |
| `src/opnsense/scripts/clat/lib/facts.py` | D | paths, parsers (commands, routing messages, pty lines), fact gathering, native-IPv4 tests, preflight (6.5) |
| `tests/test_discovery.py`, `tests/test_plan.py`, `tests/test_facts.py` | D | unit tests (12) |
| `src/opnsense/scripts/clat/lib/supervisor.py` | E | state machine, reconcile, sequences (6.6, 7) |
| `tests/fakes.py`, `tests/test_supervisor.py` | E | fake `System`, scenario tests (12) |
| `src/opnsense/scripts/clat/lib/sysif.py` | F | `System`: the only module that touches the OS (6.2) |
| `src/opnsense/scripts/clat/clatd.py` | F | daemon entry point (6.7) |
| `src/opnsense/scripts/clat/clatctl.py` | F | one-shot CLI: `status`, `event`, `test` (6.7) |
| `tests/test_clatctl.py` | F | CLI tests with the fake `System` (12) |

`tests/` is outside `src/` and is not packaged.

## 2. Names (fixed)

| Thing | Value |
|---|---|
| Plugin / package | `net/clat`, `PLUGIN_NAME=clat`, package `os-clat` |
| MVC namespace, model class, API model name | `OPNsense\Clat`, `\OPNsense\Clat\Clat`, `clat` |
| Model mount / config.xml path | `//OPNsense/clat` -> `/opnsense/OPNsense/clat/general/<field>` |
| Page | `/ui/clat` |
| API | `/api/clat/settings/{get,set}`, `/api/clat/service/{status,start,stop,restart,reconfigure,test}` |
| configd topic and actions | `clat`: `start stop restart reload status details event test` |
| Service (`clat_services()`) | name `clat`, description `CLAT` |
| rc.d script, `name`, rcvar, rc.conf.d | `/usr/local/etc/rc.d/clat`, `clat`, `clat_enable`, `/etc/rc.conf.d/clat` |
| Template module | `OPNsense/Clat` |
| Daemon, CLI, PHP helper | `/usr/local/opnsense/scripts/clat/{clatd.py,clatctl.py,facts.php}` |
| Daemon settings (rendered) | `/usr/local/etc/clat/clatd.json` |
| tayga config (written by the daemon) | `/usr/local/etc/clat/tayga.conf` |
| Secret for the interface-identifier hash | `/usr/local/etc/clat/secret`: 64 hex characters + newline, mode 0600, created by the daemon when missing, never deleted |
| Daemon pidfile | `/var/run/clat.pid`. tayga has no pidfile (it is a tracked child) |
| Runtime directory | `/var/run/clat/` (0755): `status.json` (0644), `gateway` (marker, 0644), `empty/` (tayga `data-dir` and chroot, 0755, always empty) |
| Router file | `/tmp/tun464_router` (written and removed with `ifctl` only) |
| Syslog | ident `clat`, facility `LOG_LOCAL4`; file `/var/log/clat/clat_YYYYMMDD.log`; viewer `/ui/diagnostics/log/core/clat` |
| Interface key / device / description | `clat` / `tun464` / `CLAT` (core derives gateway name `CLAT_GW`; nothing looks it up by name) |
| tayga binary | `/usr/local/sbin/tayga` |
| Files read, never written | `/conf/config.xml` (stat only), `/tmp/<dev>_prefixv6`, `/tmp/<dev>_router`, `/tmp/.interfaces.todo`, `/etc/resolv.conf` |

## 3. Settings model

### 3.1 Fields (`Clat.xml`: `<mount>//OPNsense/clat</mount>`, `<description>464XLAT CLAT settings</description>`, `<version>1.0.0</version>`, all fields under `<general>`)

Lint rules (sheet plugin-skeleton 4.2): `Default` only with `<Required>Y</Required>`; optional fields have neither; every `ValidationMessage` starts uppercase and ends with a dot.

| Field | Type and options | Req. / Default | Consumer |
|---|---|---|---|
| `enabled` | `OptionField`, options `<auto value="1">Automatic</auto><off value="0">Disabled</off>` | Y / `1` | clat.inc, rc.conf.d, clatd.json |
| `uplink` | `InterfaceField`, `<BlankDesc>Automatic</BlankDesc>`, `<Filters><enable>/^(?!0).*$/</enable></Filters>` | optional | clat.inc |
| `prefix` | `NetworkField`, `AddressFamily=ipv6`, `NetMaskRequired=Y`, `Strict=Y`, `WildcardEnabled=N` | optional | clatd.json |
| `discover_dns` | `BooleanField` | Y / `1` | clatd.json |
| `keep_with_native` | `BooleanField` | Y / `0` | clatd.json |
| `prefix_id` | `TextField`, `<Mask>/^[0-9a-fA-F]{1,4}$/</Mask>`, message "Enter one to four hexadecimal digits." | optional | clatd.json |
| `address` | `NetworkField`, `AddressFamily=ipv6`, `NetMaskAllowed=N`, `WildcardEnabled=N` | optional | clatd.json |
| `mss_clamp` | `BooleanField` | Y / `1` | clat.inc |
| `mss_offset` | `IntegerField`, `MinimumValue=0`, `MaximumValue=500` | optional (0) | clat.inc |
| `firewall_rule` | `BooleanField` | Y / `1` | clat.inc |
| `manual_nat` | `BooleanField` | Y / `0` | clatd.json |
| `ipv4_clat` | `NetworkField`, `AddressFamily=ipv4`, `NetMaskAllowed=N`, `WildcardEnabled=N` | Y / `192.0.0.1` | clatd.json |
| `ipv4_tayga` | same | Y / `192.0.0.2` | clatd.json |
| `ipv4_mtu` | `IntegerField`, 1280..1500 | Y / `1500` | clatd.json, clat.inc |
| `ipv6_mtu` | `IntegerField`, 1280..9000 | optional (no override) | clatd.json, clat.inc |
| `udp_cksum` | `OptionField`: `<calc>Calculate</calc><drop>Drop</drop><forward>Forward</forward>` | Y / `calc` | clatd.json |
| `test_target` | `NetworkField`, `AddressFamily=ipv4`, `NetMaskAllowed=N`, `WildcardEnabled=N` | optional | clatd.json |
| `log_state` | `BooleanField` | Y / `1` | clatd.json |

Mapping to DESIGN 12: Mode = `enabled`; "TCP MSS clamp: automatic, off, offset" = `mss_clamp` on with empty offset, `mss_clamp` off, `mss_clamp` on with `mss_offset`; "CLAT IPv6 address: automatic, prefix ID, full address" = both empty, `prefix_id`, `address`.

### 3.2 `Clat.php`

`namespace OPNsense\Clat; class Clat extends BaseModel` (directly, or the install migration skips it). `performValidation($validateFullModel = false)` calls the parent and then adds `new Message(gettext(...), 'general.<field>')` (pattern: sheet plugin-skeleton 4.4). Each check runs only when `$validateFullModel` or one of its fields `isFieldChanged()`. The all-defaults model must pass.

| Check | Field marked | Message |
|---|---|---|
| `prefix` set and its length is not 32, 40, 48, 56, 64 or 96 | `general.prefix` | "The NAT64 prefix length must be 32, 40, 48, 56, 64 or 96." |
| `address` and `prefix_id` both set | `general.prefix_id` | "Set either a prefix ID or a full address, not both." |
| `address` set and its last bit is 1 (`ord(inet_pton(..)[15]) & 1`) | `general.address` | "The CLAT address must be even; the next address is used by the translator." |
| `ipv4_clat` equals `ipv4_tayga` | `general.ipv4_tayga` | "The translator address must differ from the CLAT address." |

### 3.3 Rendering

`+TARGETS`:

```
rc.conf.d:/etc/rc.conf.d/clat
clatd.json:/usr/local/etc/clat/clatd.json
```

Both templates start with `{% set g = helpers.getNodeByTag('OPNsense.clat.general') %}` and read every value as `g.<field>|default(D)` (configd sees raw config.xml: no model defaults, empty nodes absent). D is that field's Default from 3.1 as a string: `"1"` for `enabled`, `discover_dns` and `log_state`, `"0"` for `keep_with_native` and `manual_nat`, `"192.0.0.1"`, `"192.0.0.2"`, `"1500"` for `ipv4_mtu`, `"calc"` for `udp_cksum`. Only the optional fields use `""` (`prefix`, `prefix_id`, `address`, `test_target`) or `"0"` (`ipv6_mtu`). A file rendered from a config.xml without the model node must equal the example below.

`rc.conf.d` renders `clat_enable="YES"` when `g.enabled|default("1") == "1"`, else `clat_enable="NO"`.

`clatd.json` renders exactly these keys (booleans as `{{ "true" if g.x|default(D) == "1" else "false" }}`, strings as `{{ g.x|default(D)|tojson }}`, integers as `{{ g.x|default(D)|int }}`):

```json
{
    "enabled": true,
    "prefix": "",
    "discover_dns": true,
    "keep_with_native": false,
    "prefix_id": "",
    "address": "",
    "manual_nat": false,
    "ipv4_clat": "192.0.0.1",
    "ipv4_tayga": "192.0.0.2",
    "ipv4_mtu": 1500,
    "ipv6_mtu": 0,
    "udp_cksum": "calc",
    "test_target": "",
    "log_state": true
}
```

The example is the all-defaults file. `ipv6_mtu` 0 means "no override". `uplink`, `mss_clamp`, `mss_offset` and `firewall_rule` are not rendered: only clat.inc uses them, and the daemon gets what derives from them through `facts.php` (section 9).

## 4. PHP glue: `clat.inc`

No namespace, no closing tag. Every function is cheap, has no side effects except where stated, and must not throw. Plugin settings are read from the global `$config` array (pending legacy edits are visible there, and no model object can throw); legacy sections with `config_read_array(..., false)`.

| Function | Behaviour |
|---|---|
| `clat_setting($name)` : string | `$v = $config['OPNsense']['clat']['general'][$name] ?? null;` Return the default only when `$v === null`, `$v === ''` or `is_array($v)`; otherwise return `(string)$v`. Do not use `empty()`: `'0'` is a stored value (Mode Disabled, a cleared checkbox). Defaults come from a static map that mirrors 3.1: `enabled => '1'`, `mss_clamp => '1'`, `firewall_rule => '1'`, `ipv4_mtu => '1500'`, everything else `''` |
| `clat_enabled()` : bool | `clat_setting('enabled') == '1'` |
| `clat_configured_uplink()` : ?string | Interface key from config only (DESIGN 12). If `clat_setting('uplink')` is set: that key when `interfaces/<key>/enable` is set, else `null`. Otherwise, over `config_read_array('interfaces', false)` in file order, candidates are records with `enable` set, `virtual` empty, key not `clat`, and `ipaddrv6` in `dhcp6`, `slaac`: return `wan` if it is a candidate, else the first candidate, else `null` |
| `clat_configured_uplink_mtu($key)` : int | As core derives it (sheet core-hooks section 3 sketch): find `ppps/ppp[]` whose `if` equals `interfaces/<key>/if`; if found: first element of its comma-separated `mtu`, else `interfaces/<key>/mtu - 8`, else 1492. Not PPP: `interfaces/<key>/mtu`, else 1500. `$key === null`: 1500 |
| `clat_mss()` : int or `''` | `''` if `clat_setting('mss_clamp') != '1'`. Else `$m = clat_configured_uplink_mtu(clat_configured_uplink())`; if `(int)clat_setting('ipv6_mtu') > 0` then `$m = min($m, that)`; return `min($m, (int)clat_setting('ipv4_mtu') + 20) - (int)clat_setting('mss_offset')` |
| `clat_services()` | `[]` when disabled. Else one entry: `'description' => gettext('CLAT')`, `'configd' => ['restart' => ['clat restart'], 'start' => ['clat start'], 'stop' => ['clat stop']]`, `'name' => 'clat'`, `'pidfile' => '/var/run/clat.pid'` |
| `clat_syslog()` | `['clat' => ['facility' => ['clat']]]` |
| `clat_devices()` | `[]` when disabled. Else one entry: `'function' => 'clat_configure_device'`, `'configurable' => false`, `'names' => ['tun464' => ['descr' => 'tun464 (CLAT)', 'ifdescr' => 'CLAT', 'name' => 'tun464']]`, `'pattern' => '^tun464$'`, `'spoofmac' => false`, `'volatile' => true`, `'type' => 'clat'` (mandatory on 26.7), `'typedescr' => gettext('CLAT')` |
| `clat_configure_device($device)` | Return at once unless `$device == 'tun464'`. If `!does_interface_exist($device)`: `legacy_interface_create($device)`. Then, if `/var/run/clat/gateway` is readable, its trimmed content passes `is_ipaddrv4()` and `isvalidpid('/var/run/clat.pid')`: `mwexecf('/usr/local/sbin/ifctl -i %s -4rd -a %s', [$device, $gw])`. Nothing else; returns nothing. The marker is how the daemon says "the CLAT gateway is up" (7.4) |
| `clat_interfaces()` | `[]` when disabled. Else `['clat' => ['enable' => true, 'if' => 'tun464', 'descr' => 'CLAT', 'type' => 'none', 'ipaddr' => '', 'ipaddrv6' => '', 'mss' => clat_mss()]]`. Pure function of config.xml |
| `clat_firewall($fw)` | Return unless `clat_enabled()` and `clat_setting('firewall_rule') == '1'`. Else `global $config;` and `$fw->registerFilterRule(1, ['type' => 'pass', 'direction' => 'in', 'quick' => true, 'interface' => 'clat', 'ipprotocol' => 'inet6', 'statetype' => 'keep', 'disablereplyto' => 1, 'log' => !isset($config['syslog']['nologdefaultpass']), 'descr' => 'CLAT: translated IPv6 from tayga', '#ref' => 'ui/clat']);` No `from`, `to` or `label` keys |
| `clat_configure()` | `[]` when disabled, else `['newwanip' => ['clat_event:3']]` |
| `clat_event($verbose = false, $interfaces = null, $family = null)` | `if (!plugins_argument_map($interfaces)) return;` If `$interfaces` is an array whose only value is `clat`: return (activation step 7 raises exactly that). `$family = $family === 'inet6' ? 'inet6' : 'inet'`. `$hit` is true when `$interfaces === null` or `clat_configured_uplink()` is in it. Then `configdp_run('clat event', [$family, $hit ? '1' : '0'], true);` (detached) |

No `clat_xmlrpc_sync()` (HA is not in v1).

## 5. configd actions: `actions_clat.conf`

One INI section per row, keys in the order `command:`, `parameters:`, `type:`, `message:` (no space after the colon; `parameters:` is written even when empty). `[restart]` also has `description:Restart CLAT`.

| Section | command | parameters | type | message | Caller receives |
|---|---|---|---|---|---|
| `[start]` | `/usr/local/etc/rc.d/clat start` | | `script` | `starting clat` | `OK` on exit status 0, else `Error (n)` |
| `[stop]` | `/usr/local/etc/rc.d/clat stop; exit 0` | | `script` | `stopping clat` | always `OK` |
| `[restart]` | `/usr/local/etc/rc.d/clat restart` | | `script` | `restarting clat` | `OK` / `Error (n)` |
| `[reload]` | `/usr/local/etc/rc.d/clat reload` | | `script` | `reloading clat` | `OK` / `Error (n)` |
| `[status]` | `/usr/local/etc/rc.d/clat status; exit 0` | | `script_output` | `request clat status` | rc.subr wording: `clat is running as pid N.` or `clat is not running.` |
| `[details]` | `/usr/local/opnsense/scripts/clat/clatctl.py status` | | `script_output` | `request clat details` | one JSON object, section 8.1 |
| `[event]` | `/usr/local/opnsense/scripts/clat/clatctl.py event` | `%s %s` | `script` | `clat event %s %s` | `OK`. Words: family `inet` or `inet6`, then `1` or `0` (configured uplink affected). The CLI sends SIGUSR2 for `inet6 1`, SIGUSR1 otherwise |
| `[test]` | `/usr/local/opnsense/scripts/clat/clatctl.py test` | | `script_output` | `running clat tests` | one JSON object, section 8.3 |

## 6. Python package

### 6.1 Rules

- Runs on Python 3.11 to 3.13 (26.7 ships 3.11 or 3.13 depending on the source consulted). Standard library only, plus `dns` (dnspython), imported inside `System.dns_aaaa()` and nowhere else.
- Scripts start with `#!/usr/local/bin/python3` exactly; they import `from lib import ...` (the script directory is `sys.path[0]`).
- Single-threaded. Monotonic time for every timer and lifetime; wall-clock only inside the status file.
- Only `lib/sysif.py` may import `socket`, `subprocess`, `selectors`, `signal`, `syslog`, `pty`, `ctypes`, `os`, `time`, or open files. `discovery.py`, `plan.py`, `facts.py` and `supervisor.py` get a `System` object passed in and are importable on Linux.
- `ipaddress` objects are used for all addresses and prefixes inside the package; text only at the edges.

### 6.2 `lib/sysif.py`: `class System` (the one injectable OS interface)

`tests/fakes.py:FakeSystem` implements the same methods and attributes. Implementation notes refer to sheet python-runtime.

| Method | Returns / behaviour |
|---|---|
| `monotonic() -> float`, `time() -> float`, `sleep(seconds: float) -> None` | `time.monotonic()`, `time.time()`, `time.sleep()` |
| `read(path: str) -> str \| None` | file content (utf-8, errors replaced); `None` when missing or unreadable |
| `write(path: str, text: str, mode: int = 0o644) -> bool` | atomic: temp file in the same directory, `os.fchmod(mode)`, `os.replace` (9.3). False on `OSError` (logged at 4); never raises |
| `remove(path: str) -> bool` | true when the file is gone afterwards, also when it was missing; false on any other `OSError`; never raises |
| `stat(path: str) -> tuple[int, int, int] \| None` | `(st_mtime_ns, st_size, st_ino)`; `None` when missing |
| `mkdir(path: str, mode: int = 0o755) -> bool` | `os.makedirs(exist_ok=True)` then `os.chmod` (Daemonize sets umask 027). False on `OSError` (logged at 4); never raises |
| `run(argv: list[str], timeout: float = 10.0) -> tuple[int, str, str]` | `(returncode, stdout, stderr)`; no shell; env `PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin` only; return code 124 on timeout, 127 when the program cannot be started; never raises |
| `log(priority: int, message: str) -> None` | `syslog.syslog`; priorities are the numeric levels 3 (err), 4 (warning), 5 (notice), 6 (info) |
| `if_index(dev: str) -> int \| None` | `socket.if_nametoindex`; `None` when the device does not exist |
| `random(n: int) -> bytes` | `os.urandom` |
| `pid_alive(pid: int) -> bool`, `kill(pid: int, signo: int) -> bool` | `os.kill(pid, 0)`; `os.kill`, false when the process is gone |
| `SIGTERM`, `SIGKILL`, `SIGUSR1`, `SIGUSR2` | integer attributes taken from `signal`. `FakeSystem` defines the same four names. No other module contains a signal number (10 and 12 are SIGBUS and SIGSYS on FreeBSD) |
| `__init__()` | `syslog.openlog('clat', facility=syslog.LOG_LOCAL4)` and nothing else; the daemon constructs it after daemonising |
| `open() -> None` | daemon only, called once: RA socket (1.3), routing socket (4.1), selector, `signal.set_wakeup_fd` on a socketpair with Python handlers for TERM, INT, HUP, USR1, USR2, CHLD (9.2); these replace the dispositions set by `ignore_signals()` (below). `clatctl.py` never calls it |
| `close() -> None` | close sockets and selector |
| `wait(timeout: float \| None) -> set[str]` | block until something is readable or the time-out passes; returns a subset of `{'term', 'hup', 'usr1', 'usr2', 'chld', 'ra', 'route', 'child'}` (`'term'` for TERM and INT; `'child'` = pty readable) |
| `ra_recv() -> list[RaPacket]` | drain the RA socket; one `discovery.RaPacket(ifname, hoplimit, source, data)` per datagram: `ifname` from the `IPV6_PKTINFO` index (`''` if the index no longer resolves), `hoplimit` from `IPV6_HOPLIMIT` (-1 if absent), `source` = `discovery.ll_norm(<address text of the sender>)` (an `IPv6Address`, 6.3), `data` the ICMPv6 message. Truncated datagrams and datagrams whose source does not parse are dropped (1.4) |
| `rs_send(dev: str) -> bool` | one Router Solicitation, setting `IPV6_MULTICAST_IF` and the scope id afresh (section 2); false on `OSError` |
| `route_changed() -> bool` | drain the routing socket; true if `facts.rtm_relevant(buf)` (6.5) holds for any buffer read or the socket reported `ENOBUFS` (4.2). The message filter itself is in `facts.py` so that it is tested |
| `dns_aaaa(server: str, name: str, timeout: float) -> tuple[str, list[str], int \| None]` | `('answer', [aaaa text...], ttl)` or `('fail', reason, None)`, exactly as `query_ipv4only()` in 6.2 of the sheet (SERVFAIL, REFUSED, time-out and errors are `'fail'`) |
| `spawn(argv: list[str]) -> int \| None` | start the one supervised child on a pty with a clean environment, new session and `PROC_PDEATHSIG_CTL` (7.2; a failing `procctl` lookup is ignored); registers the pty in the selector; returns the pid. `None` when the pty or the process cannot be created (logged at 3); never raises |
| `child_lines() -> list[str]` | lines read from the pty since the last call; never blocks (7.3). What was read goes through `facts.split_lines` (6.5), which strips `\r` and limits the length; at end of file a non-empty rest is returned as the last line and the pty leaves the selector |
| `child_exit() -> int \| None` | `None` while the child runs or when there is none to report; else its exit status, reported until the next `spawn()` or `child_stop()` |
| `child_stop(timeout: float = 5.0) -> None` | TERM, wait, KILL, close the pty; for a child that has already exited only the pty is closed; no-op without a child (7.4) |

`lib/sysif.py` also has one module-level function, `ignore_signals() -> None`: it sets SIGHUP, SIGUSR1 and SIGUSR2 to `SIG_IGN`. `clatd.py` calls it before daemonising (6.7).

### 6.3 `lib/discovery.py` (pure)

Constants: `PLC_TO_LEN = (96, 64, 56, 48, 40, 32)`, `DNS_NAME = 'ipv4only.arpa.'`, `DNS_TIMEOUT = 2.0`, `DNS_MIN_REFRESH = 60.0`, `DNS_NEGATIVE_MAX = 300.0`, `DNS_RETRY_STEPS = (10.0, 30.0, 60.0, 300.0)`.

`RaPacket = collections.namedtuple('RaPacket', 'ifname hoplimit source data')` with `ifname: str`, `hoplimit: int`, `source: ipaddress.IPv6Address` (always a result of `ll_norm`, never text), `data: bytes`.

| Function / class | Behaviour |
|---|---|
| `ll_norm(text: str) -> IPv6Address` | address text to an `IPv6Address` without zone: cut the text at `%`; inside fe80::/10 clear bytes 2 and 3 (a zone id embedded by the kernel). `ValueError` for text that is not an IPv6 address. Code: sheet 3.1. Used for the RA source (6.2) and the default router (6.5), so that the two compare equal |
| `parse_ra_pref64(data: bytes) -> list[tuple[IPv6Network, int]] \| None` | `None` for anything that is not a well-formed RA (type 134, code 0, length >= 16, every option length non-zero and inside the packet). Else one `(prefix, lifetime_s)` per option 38 with length 2 and PLC 0..5: `lifetime_s = field & 0xFFF8`, prefix masked to the PLC length. Other option-38 forms are skipped. Code: sheet 1.5 |
| `accept_ra(pkt: RaPacket, uplink: str \| None, router: IPv6Address \| None) -> list[tuple[IPv6Network, int]] \| None` | `None` (rejected) unless `uplink` is set, `pkt.ifname == uplink`, `pkt.hoplimit == 255`, `pkt.source.is_link_local`, `router` is not `None` and `router == pkt.source` (both are `IPv6Address` objects without zone); else `parse_ra_pref64(pkt.data)`. An empty list means "accepted, no PREF64 information" |
| `pref64_candidates(aaaa: str) -> set[IPv6Network]` | every RFC 6052 prefix the address can have been built with from 192.0.0.170 or 192.0.0.171 (sheet 6.3; octet 8 must be zero except for /96) |
| `pref64_from_answer(addrs: list[str], current: IPv6Network \| None = None, reject: Iterable[IPv6Network] = ()) -> IPv6Network \| None` | union of candidates of all records, minus those overlapping `reject`; `current` if it is among them, else the lowest by `(int(network_address), prefixlen)`, else `None` |
| `embed(prefix: IPv6Network, ipv4: str) -> IPv6Address` | RFC 6052 synthesis for all six lengths (used by the tests of section 8.3) |
| `overlaps(prefix: IPv6Network, others: Iterable[IPv6Network]) -> bool` | any `prefix.overlaps(o)` |
| `class RaPrefix` | The RA source holds one entry. `update(entries, now: float, reject=()) -> bool`: for the current prefix refresh `expiry = now + lifetime`, or remove it when lifetime is 0; with no current entry take the lowest entry with lifetime > 0 that does not overlap `reject`; a different prefix while one is current is ignored; an empty list changes nothing. Returns true when the selected prefix changed. `expire(now) -> bool` removes an entry with `expiry <= now`. `current() -> tuple[IPv6Network, float] \| None` (prefix, expiry). |
| `class DnsPrefix` | Attributes `prefix: IPv6Network \| None = None`, `next_query: float = 0.0`, `failures: int = 0`. `due(now) -> bool`. `result(outcome, now, reject=()) -> bool` applies one `System.dns_aaaa()` result: on `'answer'` set `prefix = pref64_from_answer(addrs, self.prefix, reject)`, `failures = 0`, and `next_query = now + max(ttl or 0, DNS_MIN_REFRESH)`, capped at `DNS_NEGATIVE_MAX` when no prefix resulted; on `'fail'` keep the prefix and set `next_query = now + DNS_RETRY_STEPS[min(failures, 3)]`, `failures += 1`. Returns true when `prefix` changed. `reset()` restores the initial values |

### 6.4 `lib/plan.py` (pure)

```python
@dataclass(frozen=True)
class Plan:
    pref64: IPv6Network
    clat6: IPv6Address      # even address of the /127: "map <ipv4_clat> <clat6>"
    tayga6: IPv6Address     # odd address: "ipv6-addr"
    ipv4_clat: str
    ipv4_tayga: str
    tun_mtu: int
    offlink_mtu: int
    udp_cksum: str          # calc | drop | forward
    # properties: ipv4_mtu = offlink_mtu - 20; pair = "<clat6>/127" (str)

class PlanError(Exception):
    code: str               # 'uplink_mtu' | 'prefix_id' | 'address'
```

Two plans are equal exactly when tayga needs no restart.

| Function | Behaviour |
|---|---|
| `effective_mtu6(if_mtu: int, linkmtu: int, maxmtu: int) -> int` | kernel `IN6_LINKMTU` (sheet 5.3) |
| `clat_mtus(m: int, v: int = 1500) -> tuple[int, int, int]` | `tun = min(m, v + 28)`, `off = min(tun, v + 20)`, returns `(tun, off, off - 20)` |
| `parse_prefix_file(text: str \| None) -> IPv6Network \| None` | first line that parses as `prefix/len` with `len <= 64` (`strict=False`); `None` for missing, empty or unusable content |
| `choose_subnet(delegated: IPv6Network, claims: Iterable[int], prefix_id: str = '') -> IPv6Network` | `n = 2 ** (64 - delegated.prefixlen)`. With `prefix_id`: index `int(prefix_id, 16)`, `PlanError('prefix_id')` if `>= n`. Else the highest index in `0..n-1` not in `claims`; if all are claimed, `n - 1`. Returns that /64 |
| `iid_excluded(iid: int) -> bool` | true for `iid < 0x10000` (covers all-zero and small fixed values) and for `0xFDFFFFFFFFFFFF80 <= iid <= 0xFDFFFFFFFFFFFFFF` (RFC 5453) |
| `interface_id(subnet: IPv6Network, secret: bytes, in_use: Iterable[IPv6Address] = ()) -> int` | for `counter` in 0..255: `iid = int.from_bytes(sha256(secret + subnet.network_address.packed[:8] + bytes([counter])).digest()[:8], 'big') & ~1`; accept the first for which neither `iid` nor `iid \| 1` is excluded and neither resulting address is in `in_use`. `PlanError('address')` if none |
| `make_plan(settings: dict, pref64: IPv6Network, delegated: IPv6Network, claims: Iterable[int], secret: bytes, in_use: Iterable[IPv6Address], mtu6: int \| None) -> Plan` | `PlanError('uplink_mtu')` if `mtu6` is `None` or below 1280. Pair: if `settings['address']`: that address with bit 0 cleared and its successor; else `choose_subnet(delegated, claims, settings['prefix_id'])` and `interface_id(...)`. `PlanError('address')` if the pair overlaps `pref64`. MTUs from `clat_mtus(mtu6, settings['ipv4_mtu'])` |
| `tayga_conf(plan: Plan, data_dir: str) -> str` | exactly eight lines, in this order, newline-terminated: `tun-device tun464`, `ipv4-addr <ipv4_tayga>`, `ipv6-addr <tayga6>`, `prefix <pref64>`, `map <ipv4_clat> <clat6>`, `udp-cksum-mode <udp_cksum>`, `offlink-mtu <offlink_mtu>`, `data-dir <data_dir>` |
| `tayga_argv(conf: str) -> list[str]` | `['/usr/local/sbin/tayga', '-c', conf, '--nodetach', '--stdout', '-u', 'nobody', '-g', 'nobody', '-r']` |

### 6.5 `lib/facts.py`

Constants: `TUN = 'tun464'`; paths `SETTINGS`, `TAYGA_CONF`, `SECRET`, `RUN_DIR`, `STATUS`, `MARKER`, `DATA_DIR` (`/var/run/clat/empty`), `PIDFILE`, `ROUTER_FILE`, `CONFIG_XML`, `TODO_FILE`, `RESOLV_CONF`, `TAYGA_BIN`, `FACTS_PHP` with the values of section 2; `DEFAULT_SETTINGS` (the example of 3.3); `TESTED_TAYGA = ('0.9.6',)`; `PHP_TIMEOUT = 30.0`.

Pure functions:

| Function | Behaviour |
|---|---|
| `parse_settings(text: str \| None) -> dict \| None` | JSON object -> `DEFAULT_SETTINGS` updated with the known keys whose value has the right type; `None` when the text is missing or not a JSON object |
| `parse_route_get(text: str) -> tuple[str, IPv6Address \| None] \| None` | `(interface, gateway)` from `route -6 -n get default` output; `gateway = discovery.ll_norm(value)`, `None` when the line is absent or `ll_norm` raises `ValueError` (for example `link#9`); `None` when there is no `interface:` line (sheet 3.1) |
| `parse_ifconfig(text: str) -> dict[str, dict]` | `ifconfig -a` output -> per device `{'mtu': int \| None, 'flags': set[str], 'inet': [(addr, peer \| None, masklen \| None)], 'inet6': [(addr without zone, prefixlen \| None)], 'opened_by': int \| None}`; addresses are text; a new device starts at each non-indented line containing `flags=`; `masklen` from the hexadecimal `netmask` (sheet 5.1) |
| `parse_ndp(text: str) -> tuple[int, int] \| None` | `(linkmtu, maxmtu)` from `ndp -i <dev>` |
| `first_nameserver(text: str \| None) -> str \| None` | first `nameserver` of resolv.conf text |
| `rtm_relevant(buf: bytes) -> bool` | one `recv` buffer of the routing socket (the loop of sheet 4.2, `struct` only). Walk the messages: `=HBB` at the message start gives length, version, type; stop when fewer than 4 bytes remain or the length is below 4; skip a message whose version is not 5. True when any message has type NEWADDR (0xc), DELADDR (0xd), IFINFO (0xe) or IFANNOUNCE (0x11), or has type ADD (1), DELETE (2) or CHANGE (3), at least 12 bytes present, and `RTF_LLDATA` (0x400) clear in the `=i` at offset 8. `RTM_GET` (4) and all other types are ignored: without that the daemon wakes on its own `route get` and on every neighbour entry. Never raises |
| `split_lines(pending: bytes, chunk: bytes, limit: int = 1024) -> tuple[list[str], bytes]` | pty output to lines: split `pending + chunk` at `\n`; a complete line loses a trailing `\r`, is decoded (utf-8, errors replaced) and cut to `limit` characters. The unfinished rest is returned as the new `pending`; a rest longer than `limit` bytes is emitted as a line instead and the new `pending` is empty |
| `native_gateways(gw: dict) -> list[str]` | DESIGN 5.3 second test over `gw['list']`: names with `if != TUN`, not `disabled`, not `tunnel`, `if_has_ipv4`, and (`upstream` or `priority <= 254` or `selected`) |
| `stale_gateways(gw: dict) -> list[str]` | names with `if != TUN`, not `disabled`, not `defunct`, non-empty `gateway`, (`upstream` or `priority < 254`) and not `if_has_ipv4` |
| `gateway_report(gw: dict) -> tuple[str, str]` | from `gw['default']`: `None` -> `('none', 'no IPv4 default gateway is selected')`; `if == TUN` -> `('default', 'active')`; `if_has_ipv4` -> `('not_default', 'active, but not the IPv4 default: gateway <name> is preferred')`; else `('stale', 'a stale gateway <name> on an interface without IPv4 blocks any default route')` |
| `preflight(facts: Facts, sysif, tayga_version: str \| None = None) -> list[dict]` | rows of section 8.2 in table order; a row whose facts are missing (`cfg`, `gw`, `route6`, version) is skipped. The daemon's rule 3 ignores the `stale_gateway` row; rule 7a tests it (7.2) |

`class Facts` (snapshot of what is known; attributes are plain data so tests can set them):

| Member | Meaning |
|---|---|
| `settings: dict` | from `clatd.json`; starts as `DEFAULT_SETTINGS` |
| `cfg: dict \| None`, `cfg_stat` | `config` object of `facts.php` (9.1) and the config.xml stat it was read at |
| `route6: tuple[str, IPv6Address \| None] \| None` | runtime uplink: device and default router of the IPv6 default route |
| `ifaces: dict[str, dict]` | last `parse_ifconfig` result |
| `ndp: tuple[int, int] \| None`, `gw: dict \| None` | activation facts: `ndp -i <uplink>` and the `gateways` object of `facts.php` (9.2) |
| `load_settings(sysif) -> bool` | `parse_settings(sysif.read(SETTINGS))`; keeps the old settings and returns false on failure |
| `refresh_config(sysif, force: bool = False) -> bool` | if `force` or `sysif.stat(CONFIG_XML) != cfg_stat`: run `[FACTS_PHP, 'config']`, store `['config']`; on failure keep the old value. Returns true when it ran |
| `refresh_link(sysif) -> None` | `route6 = parse_route_get(...)` from `['/sbin/route', '-6', '-n', 'get', 'default']` (`None` on non-zero exit); `ifaces` from `['/sbin/ifconfig', '-a']` |
| `refresh_activation(sysif) -> bool` | `ndp = parse_ndp(...)` from `['/usr/sbin/ndp', '-i', <uplink>]`, `None` on a non-zero exit; when `uplink_dev()` is `None` the command is not run and `ndp = None`. `gw` from `[FACTS_PHP, 'gateways']` (`PHP_TIMEOUT`). False (and `gw = None`) when the helper fails; the return value depends on the helper only |
| `drop_activation() -> None` | `ndp = gw = None` |
| `uplink_dev() -> str \| None`, `uplink_router() -> IPv6Address \| None` | from `route6` |
| `uplink_native(sysif) -> bool` | DESIGN 5.3 first test on `uplink_dev()`, or on `cfg['uplink']['if']` when there is no runtime uplink: `/tmp/<dev>_router` is non-empty, or `ifaces[dev]['inet']` has an address outside 169.254.0.0/16 |
| `delegated(sysif) -> IPv6Network \| None` | `parse_prefix_file(sysif.read('/tmp/<uplink_dev>_prefixv6'))` |
| `claims() -> list[int]` | `cfg['interfaces'][uplink_dev]['claims']`, `[]` when unknown |
| `local_networks(sysif) -> list[IPv6Network]` | the delegated prefix, the networks of every non-link-local `inet6` on the uplink device, and `cfg['static_v6']` |
| `addresses6() -> set[IPv6Address]` | every `inet6` address in `ifaces` |
| `mtu6() -> int \| None` | `effective_mtu6(ifaces[uplink]['mtu'], *(ndp or (0, 0)))`, lowered to `settings['ipv6_mtu']` when that is non-zero; `None` when the device MTU is unknown |
| `tun_ok(plan, pid) -> bool` | `ifaces[TUN]` has `(plan.ipv4_clat, plan.ipv4_tayga, 32)` in `inet` and `opened_by == pid` |

### 6.6 `lib/supervisor.py`: `class Supervisor`

| Member | Behaviour |
|---|---|
| `__init__(self, sysif)` | creates `Facts`, `RaPrefix`, `DnsPrefix`; `state = 'listening'`, no plan |
| `start() -> None` | start-up of 7.7, then `reconcile('start')` |
| `run() -> None` | `while not self.stopping: self.handle(self.sys.wait(self.next_timeout()))` |
| `handle(events: set[str]) -> None` | event dispatch of 7.6; at most one `reconcile()` per call |
| `next_timeout() -> float \| None` | seconds until the earliest timer |
| `reconcile(reason: str) -> None` | 7.5 |
| `decide(now: float) -> tuple[str, str]` | 7.2; returns `(state, reason)` where state may also be `'up'` or `'need_facts'`; sets `self.wanted` (a `Plan`) for `'up'`, and `self.gated` on every call |
| `confirm_session() -> None` | 7.7 |
| `activate(plan) -> bool`, `deactivate() -> None`, `tayga_exit(now: float) -> None`, `withdraw() -> None`, `replay() -> bool`, `renumber(plan) -> bool` | sequences of 7.4 |
| `status() -> dict` | status file content, 8.1 |
| `stop() -> None` | `deactivate()` if `running` is set (also when it is left over from a tayga exit); remove `STATUS`; log `stopped` |

Public attributes used by tests: `state`, `reason`, `running` (`Plan` or `None`), `withdrawn`, `gated`, `facts`, `timers` (dict name -> monotonic deadline), `restarts`.

### 6.7 Entry points

`clatd.py [-f|--foreground]`: `sys.path.insert(0, '/usr/local/opnsense/site-python')`, `from daemonize import Daemonize`; `lib.sysif.ignore_signals()`, then `Daemonize(app='clat', pid='/var/run/clat.pid', action=action, foreground=args.foreground).start()`.

- Daemonize writes the pidfile before it calls `action`, and until `System.open()` runs the default action of HUP, USR1 and USR2 is to terminate the process. At boot core replays `newwanip` events just before the service starts, and each ends in `clat event`. The ignored dispositions survive the fork; `open()` replaces them with the wake-up handlers. An event lost before `open()` is harmless: `start()` reconciles anyway.
- `action()` creates `System()`. Everything after that is inside `try:`: `open()`, `Supervisor(system)`, its `start()` and `run()`. `except Exception:` logs `'fatal: ' + traceback.format_exc()` at priority 3 (after Daemonize, stderr is `/dev/null`, so nothing else would record it). `finally:` the supervisor's `stop()` when it was created, then `close()`.
- Everything that opens a descriptor happens inside `action` (Daemonize closes all descriptors and handles only SIGTERM before it). Leaving `action` removes the pidfile.

`clatctl.py <command>`; always exits 0. The command functions take a `System`, so `tests/test_clatctl.py` runs them with the fake. `lib.sysif` is imported, the `System` created and the command dispatched only under `if __name__ == '__main__':`, so that importing `clatctl` on Linux pulls in nothing FreeBSD-specific.

| Command | Function | Behaviour |
|---|---|---|
| `status` | `cmd_status(sysif) -> dict` | section 8.1; printed as one JSON line |
| `event <family> <uplink>` | `cmd_event(sysif, family, uplink) -> None` | read the pid from `PIDFILE`; `sysif.kill(pid, sysif.SIGUSR2)` when `family == 'inet6'` and `uplink == '1'`, else `sysif.SIGUSR1`; silent when the daemon is not running |
| `test` | `cmd_test(sysif) -> dict` | section 8.3; printed as one JSON line |

## 7. State machine

### 7.1 Constants (`supervisor.py`)

| Name | Value | Meaning |
|---|---|---|
| `DEBOUNCE` | 2.0 | routing-socket messages to reconcile; armed once, not pushed back |
| `NATIVE_GONE_HOLD` | 60.0 | native IPv4 must be absent this long before activation, counted from the pass that first finds it gone (rule 8a) |
| `UPLINK_LOSS_GRACE` | 15.0 | uplink without usable IPv6 before `suspended` |
| `RESTART_MIN_INTERVAL` | 60.0 | minimum time between a tayga start and a restart caused by renumbering or an MTU change |
| `BACKOFF_STEPS` | (5.0, 10.0, 30.0, 60.0, 300.0) | delay after the n-th consecutive failure; the count resets once `active` has lasted `BACKOFF_RESET` |
| `BACKOFF_RESET` | 300.0 | |
| `DRIFT_REPAIR_MIN_INTERVAL` | 300.0 | minimum time between two registration runs |
| `TICK` | 60.0 | periodic in-process check |
| `RS_MAX`, `RS_INTERVAL` | 3, 4.0 | Router Solicitation burst |
| `TAYGA_START_TIMEOUT`, `TAYGA_STOP_TIMEOUT` | 5.0, 5.0 | |
| `CONFIGCTL_TIMEOUT` | 130.0 | above configctl's own 120 s |
| `OUTPUT_KEEP`, `RELAY_BURST`, `RELAY_WINDOW` | 10, 20, 10.0 | tayga lines kept for status; lines relayed per window, then one "n lines suppressed" |

States (strings, as in DESIGN 5.4): `disabled`, `listening`, `blocked`, `native-ipv4`, `waiting-for-prefix-delegation`, `active`, `suspended`, `backoff`. "Up" means `active` or `suspended`.

### 7.2 Decision rules (`decide`, first match wins)

| # | Condition | Result (state / reason) | Class |
|---|---|---|---|
| 1 | `settings['enabled']` is false | `disabled` | hard |
| 2 | `facts.uplink_native(sys)`; also sets `native_present = True` | `native-ipv4` / `uplink` | hard |
| 3 | `preflight(facts, sys)` has a row with effect `block` other than `stale_gateway` (first one) | `blocked` / row id | hard |
| 4 | no NAT64 prefix selected (below) | `listening` / `no_uplink_ipv6` when there is no runtime uplink, else `no_nat64_prefix` | hard |
| 5 | no runtime uplink (`facts.route6 is None`) | `listening` / `no_uplink_ipv6` | soft |
| 6 | not `pd_trusted` (7.7) or `facts.delegated(sys)` is `None` | `waiting-for-prefix-delegation` | soft |
| 7 | `facts.gw is None` | `need_facts` (not a state; 7.5 gathers and decides again) | |
| 7a | `stale_gateways(facts.gw)` non-empty | `blocked` / `stale_gateway` | hard |
| 8 | not `keep_with_native` and `native_gateways(facts.gw)` non-empty; also sets `native_present = True` | `native-ipv4` / `gateway` | hard |
| 8a | no result: if `native_present`, set `native_gone = now` and `native_present = False` | | |
| 9 | `make_plan(...)` raises `PlanError` | `blocked` / its code | hard |
| 10 | not up, `native_gone` set and `now - native_gone < NATIVE_GONE_HOLD`; arms `hold` at `native_gone + NATIVE_GONE_HOLD` | `native-ipv4` / `hold` | hard |
| 11 | otherwise | `up`, `self.wanted = plan` | |

**Order.** Not up: as numbered. Up: rules 5 and 6 are evaluated after rule 8a instead of before rule 7, that is 1, 2, 3, 4, 7, 7a, 8, 8a, 5, 6, 9, 10, 11. Native IPv4 on another WAN and a stale gateway therefore end the CLAT also while the uplink has no IPv6 (grace or `suspended`); the gateway facts exist since activation.

**The gate.** Everything from rule 7 on needs the gateway facts of `facts.php`, which DESIGN 10 allows only once the other conditions hold. `decide` sets `self.gated = True` when it evaluates rule 7 and `False` when an earlier rule stops it. 7.5 uses `gated` to keep, refresh or drop those facts. No rule before 7 reads `facts.gw`; that is why the `stale_gateway` row is not part of rule 3.

**Hold.** `native_present` (initially false) says that the last pass which tested for native IPv4 found it; `native_gone` (initially unset) is the time of the pass that first found it gone. A pass can come up to `TICK` after the previous one, so the hold is counted from the pass that finds native IPv4 gone and not from the last pass that still saw it. When the decision stopped before rule 8 in between, the hold starts later than the real disappearance; it is never shorter than 60 s.

`make_plan` gets `facts.settings`, the selected prefix, `facts.delegated(sys)`, `facts.claims()`, the secret (read `SECRET`; when it is not 64 hex characters write `sys.random(32).hex() + '\n'` with mode 0600), `facts.addresses6()`, `facts.mtu6()`.

NAT64 prefix selection (DESIGN 5.2), `reject = facts.local_networks(sys)`:

1. `settings['prefix']` set: that prefix, source `static` (an overlap with `reject` is the preflight row `pref64_overlap`).
2. `ra.current()` present: source `ra`; call `dns.reset()`.
3. `settings['discover_dns']` false: `dns.reset()`, no prefix.
4. If there is a runtime uplink, `dns.due(now)`, and not (`self.state == 'native-ipv4'` and `self.reason == 'gateway'` and `dns.prefix` is set): `server = first_nameserver(sys.read(RESOLV_CONF))`; `dns.result(sys.dns_aaaa(server, DNS_NAME, DNS_TIMEOUT) if server else ('fail', 'no nameserver', None), now, reject)`.
5. `dns.prefix` (source `dns`) or none. Without a runtime uplink no query is made and a known DNS prefix is kept.

The exception in step 4 follows DESIGN 5.2 (RFC 7050 only without native IPv4) as far as the gate allows: while a native gateway keeps the CLAT down and a DNS prefix is held, nothing is asked. `self.state` is the state the previous pass ended in. The pass that leaves `native-ipv4` / `gateway` cannot end in `up`: rule 8a has just set `native_gone`, so rule 10 holds. A later pass therefore asks again before any activation. What remains of the deviation is 14.B item 2.

### 7.3 Transitions (applied after `decide`; checked in this order)

| Current | Condition | Actions | Next |
|---|---|---|---|
| up | hard result X | Deactivate | X |
| not up | a hard or soft result (rules 1 to 10) | Deactivate when the result is hard and `running` is still set (left over from a tayga exit, 7.4); clear the back-off timer (the failure count is kept) | that result |
| `active` | soft result, `now - lost_since < UPLINK_LOSS_GRACE` (`lost_since` is set to `now` at the first soft result) | arm `grace` at `lost_since + UPLINK_LOSS_GRACE` | `active` |
| `active` | soft result, grace elapsed | `facts.refresh_activation(sys)`; if `facts.gw` and `facts.gw['fallback']`: Withdraw | `suspended` |
| `suspended` | soft result | none | `suspended` |
| not up | `failed` (7.5) | arm `backoff` | `backoff` / `facts` |
| not up | `up`, `now < backoff_until` | none | `backoff` (reason kept) |
| not up | `up` | Activate(`wanted`); but Renumber(`wanted`) when `running` is set (left over from a tayga exit) and differs from `wanted` | `active`; on failure: Deactivate, arm `backoff`, `backoff` / failure code |
| up | `up`, `wanted != running`, `now - tayga_started < RESTART_MIN_INTERVAL` | arm `restart` at `tayga_started + RESTART_MIN_INTERVAL` | unchanged |
| up | `up`, `wanted != running` | Renumber(`wanted`) | `active`; on failure as above |
| `suspended` | `up`, `wanted == running` | Replay if `withdrawn`; clear `lost_since` | `active` |
| `active` | `up`, `wanted == running`, runtime intact | clear `lost_since` | `active` |
| `active` | `up`, `wanted == running`, runtime not intact | Replay | `active`; on failure as above |

A tayga exit is not a row of this table: `reconcile` handles it before `decide` (7.5), so the table then sees `backoff` / `tayga_exit` with `running` still set.

"Runtime intact": `sys.read(ROUTER_FILE)` stripped equals `running.ipv4_tayga`, and, in a pass that refreshed link facts, `facts.tun_ok(running, tayga_pid)`. Because the reconcile compares before acting, the routing-socket echo of the daemon's own commands causes no second action.

Every state or reason change logs one line `state <old> -> <new> (<reason>)` at priority 5 when `settings['log_state']`, and rewrites the status file. Nothing is logged per timer tick, RA or DNS attempt.

### 7.4 Sequences

Every command goes through `sys.run`. "Must succeed" means return code 0, for `configctl` also `stdout.strip() == 'OK'`, and for `sys.mkdir` and `sys.write` a true result; a failure stops the sequence with the given code. `C4` = `plan.ipv4_clat`, `T4` = `plan.ipv4_tayga`.

**Activate(plan)** (DESIGN 9):

| Step | Action | Failure code |
|---|---|---|
| 1 | `sys.mkdir('/usr/local/etc/clat')`, `sys.mkdir(DATA_DIR)`, `sys.write(TAYGA_CONF, tayga_conf(plan, DATA_DIR))` (all must succeed: tayga must never start from an older file) | `step_conf` |
| 2 | if `sys.if_index(TUN) is None`: `/sbin/ifconfig tun464 create` (must succeed); `/sbin/ifconfig tun464 mtu <tun_mtu>` (must succeed) | `step_tun` |
| 3 | `sys.child_stop()`; `pid = sys.spawn(tayga_argv(TAYGA_CONF))`, fail when it is `None`; poll `sys.child_lines()` every 0.1 s (`sys.sleep`) up to `TAYGA_START_TIMEOUT` for a line matching `Using tun device tun464 with MTU (\d+)`; fail if the child exits, the time runs out, or the number differs from `tun_mtu`. Set `tayga_started`, `tayga_pid` | `tayga_start` |
| 4 | `/sbin/ifconfig tun464 inet <C4>/32 <T4> up`, then `/sbin/ifconfig tun464 inet6 -ifdisabled` (both must succeed) | `step_address` |
| 5 | `/sbin/route -6 -q delete <clat6>/127` (result ignored); `/sbin/route -6 add <clat6>/127 -interface tun464` (must succeed) | `step_route` |
| 6 | `sys.write(MARKER, T4 + '\n')`; `/usr/local/sbin/ifctl -i tun464 -4rd -a <T4>` (both must succeed) | `step_router` |
| 7 | `/usr/local/sbin/configctl interface newip tun464 force` (must succeed, `CONFIGCTL_TIMEOUT`) | `step_newip` |
| 8 | `facts.refresh_link(sys)`, `facts.refresh_activation(sys)`; log `gateway_report(facts.gw)[1]` (priority 5 for `default`, else 4); run `/sbin/pfctl -sn` and log a warning (4) when no output line starts with `nat on tun464 `. Never fails | |

On success `running = plan`, `withdrawn = False`.

**Deactivate** (idempotent; uses `running`, or the plan being activated when a step failed):

1. `sys.remove(MARKER)`; `/usr/local/sbin/ifctl -i tun464 -4rd`.
2. `sys.child_stop(TAYGA_STOP_TIMEOUT)`.
3. `/sbin/route -6 -q delete <clat6>/127`.
4. `/sbin/pfctl -k <C4>`; `/sbin/pfctl -k <clat6>` (single-argument form).
5. `/usr/local/sbin/configctl interface routes configure` (`CONFIGCTL_TIMEOUT`).

Results are ignored; failures are logged at 4. Afterwards `running = None`, `withdrawn = False`, `facts.drop_activation()`.

**Tayga exit** (`tayga_exit(now)`; DESIGN 9 asks for the router file only): Deactivate steps 1 and 2 and nothing else; step 2 finds no process and closes the pty. Then `restarts += 1`, the back-off is armed (7.5) and the state becomes `backoff` / `tayga_exit`. `running`, `withdrawn` and the gateway facts are kept. The kernel has already removed the tun address and the default route through it; the /127 route and the pf states stay, so flows continue when the retry succeeds within their time-outs. `running` names what is left to clean up: the retry is Activate with the same plan (its step 5 replaces the route), or Renumber when the plan has changed meanwhile; a hard result or `stop()` runs the full Deactivate (7.3).

**Withdraw** (suspend with fail-over): (1) `sys.remove(MARKER)`; `ifctl -i tun464 -4rd`. (2) `/sbin/ifconfig tun464 inet <C4> -alias`. (3) `/sbin/pfctl -k <C4>`. (4) `configctl interface routes configure`. Then `withdrawn = True`. tayga, the tun and the /127 route stay.

**Replay** (resume after Withdraw, repair after an Apply on the record, after drift repair): Activate steps 4 (skipped when `facts.tun_ok` already holds), 6, 7, 8 with `running`; failure handling as Activate. Step 5 is not repeated: the /127 route is never removed on a path that leads here.

**Renumber(plan)**: `sys.child_stop()`; `route -6 -q delete <old clat6>/127`; `pfctl -k <old C4>`; `pfctl -k <old clat6>`; then Activate(plan).

### 7.5 Reconcile

```
EVENT_REASONS = ('start', 'route', 'event', 'reload')

def reconcile(reason):
    now = sys.monotonic()
    if up and sys.child_exit() is not None:
        tayga_exit(now)                                               # 7.4; from here on this pass is "not up"
    event = reason in EVENT_REASONS
    if reason in ('start', 'reload'):
        facts.load_settings(sys)
    changed = facts.refresh_config(sys, force=reason in ('start', 'reload'))   # PHP runs only when config.xml changed
    dev = facts.uplink_dev()
    linked = event or (dev is not None and sys.if_index(dev) is None)
    if linked:
        facts.refresh_link(sys)                                       # route get + ifconfig -a
        track_uplink(now)                                             # 7.7
    confirm_session()                                                 # 7.7; one sys.stat
    ra.expire(now)
    state, why = decide(now)                                          # also sets self.gated
    refresh = self.gated and (event or changed)                       # behind the gate: events and config changes
    about_to_activate = state == 'up' and not up and now >= backoff_until
    if state == 'need_facts' or refresh or about_to_activate:
        if not linked:
            facts.refresh_link(sys)
            track_uplink(now)
        if facts.refresh_activation(sys):                             # ndp -i (only with an uplink) + facts.php gateways
            state, why = decide(now)
        elif up:
            state = None                                              # helper failed: change nothing in this pass
        else:
            state, why = 'failed', 'facts'                            # helper failed: back-off as after a failed Activate
    elif not self.gated:
        facts.drop_activation()                                       # stopped before the gate: nothing to keep
    repair_record(now)                                                # 7.7
    if state is not None:
        apply(state, why, now)                                        # table 7.3; 'failed' -> arm backoff, state backoff
    arm_timers(now)
    write_status()                                                    # only when the content changed
```

A failure (failed Activate, Replay or Renumber, tayga exit, `'failed'`) sets `backoff_until = now + BACKOFF_STEPS[min(failures, 4)]` and then `failures += 1`.

`up` is read from `self.state` each time it appears, so it is false after `tayga_exit`.

**Gateway facts** (`facts.gw`, `facts.ndp`) follow the gate:

- dropped by a full Deactivate, and in a pass that stops before rule 7 (`gated` false);
- gathered in the pass that first reaches rule 7 without them (`need_facts`);
- refreshed in a gated pass that is an event or in which `refresh_config` ran, and immediately before an activation;
- otherwise kept. A timer pass uses the cached facts, so `native-ipv4` / `gateway`, `native-ipv4` / `hold`, `blocked` / `stale_gateway` and `blocked` / PlanError do not alternate between using and re-gathering them.

**Command cost while dormant.** Deviation from DESIGN 5.4 and 10 (14.B item 1; accepted later, section 16, item 7): DESIGN says a dormant supervisor runs no external command at all.

- No timer runs a command, with two one-time exceptions: the pass that finds the uplink device gone refreshes the link facts, and the pass that first reaches rule 7 gathers the gateway facts (the latter is what DESIGN 10 allows).
- Each debounced routing-socket burst, `newwanip` event and reload costs one `route -6 -n get default` and one `ifconfig -a`.
- Each config.xml change costs one `facts.php config`.
- Behind the gate, each of those events and config changes also refreshes the gateway facts: one `ndp -i` and one `facts.php gateways`, after a link refresh when the pass had none.

Timers otherwise read files and in-process state only, plus one DNS query when one is due.

### 7.6 Events and timers

`handle(events)`:

| Event | Action |
|---|---|
| `term` | `stopping = True`; nothing else in this call |
| `hup` | reconcile reason `reload` |
| `usr1` | reconcile reason `event` |
| `usr2` | `event6 = True` (session confirmation, 7.7); reconcile reason `event` |
| `child`, `chld` | relay `sys.child_lines()` to syslog as `tayga: <line>` (priority 3 for lines starting with `Error` or `Unable` or containing `aborting`, else 6; rate-limited; last `OUTPUT_KEEP` lines kept); if `sys.child_exit() is not None`: reconcile reason `child` |
| `ra` | for each packet of `sys.ra_recv()`: `entries = accept_ra(pkt, facts.uplink_dev(), facts.uplink_router())`; if not `None`: stop the RS burst, and if `ra.update(entries, now, facts.local_networks(sys))`: reconcile reason `ra` |
| `route` | if `sys.route_changed()`: `timers.setdefault('debounce', now + DEBOUNCE)` |
| due timers | per the table below |

When several reasons arise in one call, one reconcile runs with the first of `reload`, `event`, `route`, `start` that is present, else any other.

| Timer | Armed | On expiry |
|---|---|---|
| `tick` | always, `now + TICK` | reconcile `tick`; reset the back-off count when `active` for `BACKOFF_RESET` |
| `debounce` | by `route` events | reconcile `route` |
| `rs` | by an attach while `rs_count < RS_MAX`, `now + RS_INTERVAL` | `sys.rs_send(dev)`, `rs_count += 1`, re-arm while below `RS_MAX` |
| `pref64` | at `ra.current()` expiry | reconcile `timer` |
| `dns` | at `dns.next_query` while selection step 4 could ask: steps 1 to 3 do not apply, a runtime uplink exists, and the state is not `native-ipv4` / `gateway` with a DNS prefix held | reconcile `timer` |
| `grace`, `hold`, `backoff`, `restart` | as in 7.2 and 7.3 | reconcile `timer` |

### 7.7 Uplink tracking, session confirmation, drift repair, start

**`track_uplink(now)`** (after every link refresh): `cur = (dev, sys.if_index(dev))` or `None`. If `cur != uplink_id`: when `uplink_id` was not `None`, set `pd_trusted = False` (the session changed); when `cur` is not `None`, this is an attach: `sys.rs_send(dev)`, `rs_count = 1`, arm `rs`. Then `uplink_id = cur`. Initially `uplink_id = None` and `pd_trusted = True`, so an uplink that is already up at start is an attach and its prefix file is used as it is.

**`confirm_session()`** (called in `reconcile` on every pass, after the link-refresh block and before `decide`; it costs one `sys.stat`). Without a runtime uplink: clear `event6` and return; nothing can be confirmed. Otherwise `st = sys.stat('/tmp/<dev>_prefixv6')`. If not `pd_trusted` and (`event6`, or `st` is not `None` and `st != pd_stat`): `pd_trusted = True`. Clear `event6`. While `pd_trusted`, store `pd_stat = st`. `pd_stat` therefore always describes the file as last seen in a trusted session, so a rewrite that happened before the loss was noticed still counts. Because this runs on every pass, also while rules 1 to 5 stop the decision, `pd_stat` is kept current and a `usr2` is used up in the pass it arrives in; it cannot confirm the stale file of a later session. Rule 6 reads only `pd_trusted` and `facts.delegated(sys)`.

**`repair_record(now)`** (DESIGN 7.2): if `facts.cfg` is known and `facts.cfg['record_ok']` is false, `sys.stat(TODO_FILE) is None`, and `now - last_repair >= DRIFT_REPAIR_MIN_INTERVAL`: set `last_repair`, run `/usr/local/sbin/configctl interface invoke registration`, `facts.refresh_config(sys, force=True)`, and if the state is `active` run Replay. The daemon starts from `rc.syshook start`, after `rc.bootup` has released the boot lock, so "never during boot" holds without a check.

**`start()`**: `sys.mkdir(RUN_DIR)`; `sys.remove(STATUS)`, so a file left by a crashed instance is never shown; `facts.load_settings(sys)`. Then the leftovers of an instance that did not stop cleanly: `facts.refresh_link(sys)`; if `ifaces[TUN]['opened_by']` is a pid whose `/bin/ps -o comm= -p <pid>` is `tayga`: `sys.kill(pid, sys.SIGTERM)`, up to 5 s in 0.2 s sleeps, then `sys.SIGKILL`; if `MARKER` exists or `ROUTER_FILE` is non-empty: Deactivate steps 1, 2 and 5 (no pair is known, so steps 3 and 4 are skipped; an Activate that follows replaces the route of its own pair in step 5). Then `reconcile('start')`.

## 8. Status, preflight, tests

### 8.1 Status

Status file `/var/run/clat/status.json`, written by `Supervisor.status()`:

```json
{"updated": 1760170000, "state": "active", "reason": "", "since": 1760169000,
 "uplink": "pppoe0",
 "pref64": {"prefix": "64:ff9b::/96", "source": "ra", "expires": 1760171800},
 "plan": {"clat6": "2001:db8:0:ff:8c5a:1f3e:77a0:4c12", "tayga6": "2001:db8:0:ff:8c5a:1f3e:77a0:4c13",
          "ipv4_clat": "192.0.0.1", "ipv4_tayga": "192.0.0.2", "tun_mtu": 1492, "offlink_mtu": 1492, "ipv4_mtu": 1472},
 "withdrawn": false,
 "tayga": {"started": 1760169000, "restarts": 0, "output": ["Using tun device tun464 with MTU 1492"]}}
```

`updated`, `since`, `expires`, `started` are wall-clock epoch seconds (converted at write time; `expires` is `null` for `static` and `dns`). `uplink`, `pref64`, `plan` are `null` when unknown. `tayga.started` is `null` while no tayga runs; `restarts` and `output` are always present. `plan` is the running plan, else the wanted one. The file carries no pid (`PIDFILE` has the daemon's; nothing reads tayga's) and no uplink MTU (`clatctl` computes it afresh).

`clatctl.py status` (configd `clat details`; the `clat` member of `GET /api/clat/service/status`) reads the status file, gathers fresh facts (`Facts.load_settings`, `refresh_config(force=True)`, `refresh_link`, `refresh_activation`; `pkg query %v tayga` for the version) and prints:

```json
{"running": true, "state": "active", "reason": "", "message": "Active.", "since": 1760169000,
 "uplink": {"configured": "wan", "configured_device": "pppoe0", "runtime_device": "pppoe0"},
 "pref64": {"prefix": "64:ff9b::/96", "source": "ra", "lifetime": 1630},
 "address": {"clat6": "2001:db8:0:ff:8c5a:1f3e:77a0:4c12", "tayga6": "2001:db8:0:ff:8c5a:1f3e:77a0:4c13",
             "ipv4_clat": "192.0.0.1", "ipv4_tayga": "192.0.0.2"},
 "mtu": {"configured": 1492, "effective": 1492, "tun": 1492, "offlink": 1492, "ipv4": 1472, "mss": 1432},
 "gateway": {"default": true, "message": "active"},
 "nat_rule": true,
 "tayga": {"running": true, "uptime": 1000, "restarts": 0, "output": []},
 "preflight": [],
 "text": {"state": "Active.", "uplink": "pppoe0", "pref64": "64:ff9b::/96 (RA, 1630 s left)",
          "address": "2001:db8:0:ff:8c5a:1f3e:77a0:4c12 (CLAT), 192.0.0.1",
          "mtu": "configured 1492, effective 1492, IPv4 1472, TCP MSS 1432",
          "gateway": "active", "tayga": "running for 1000 s, 0 restarts", "preflight": "No findings."}}
```

| Key | Rule |
|---|---|
| `running` | the pid in `PIDFILE` is alive. When false: `state` is `disabled` if `settings['enabled']` is false, else `stopped`; the status file is ignored. When true but the status file is missing or unreadable (the daemon removes it at start and writes it after the first reconcile): `state` is `starting`. `stopped` and `starting` are display values, not supervisor states |
| `message` | table below; for `blocked` the message of the preflight row whose id is `reason` |
| `uplink.configured*` | `cfg['uplink']` key and device, `null` without one |
| `pref64.lifetime` | `expires - now`, `null` when `expires` is `null` |
| `mtu.configured` | `cfg['uplink']['mtu']`, lowered to `settings['ipv6_mtu']` when set; `mtu.effective` = `facts.mtu6()`; `tun`, `offlink`, `ipv4` from the plan; `mtu.mss` = `cfg['mss'] - 60` when `cfg['mss']` is a number and `cfg['scrub']`, else `null` |
| `gateway`, `nat_rule` | only in state `active` (else `null`): `gateway_report(facts.gw)` with `default = code == 'default'`; `nat_rule` from `/sbin/pfctl -sn` as in Activate step 8 |
| `tayga` | `running` = `tayga.started` of the status file is not `null`; `uptime` = now minus `started` (`null` when not running); `restarts` and `output` copied |
| `preflight` | `preflight(facts, sysif, tayga_version)`, all rows |
| `text` | plain text for the page, one string per status row; lists joined with `\n`; `preflight` as `<effect>: <message>` lines or `No findings.`; unknown values as `-`. `text.gateway` is the gateway message, with `; NAT rule missing` appended when `nat_rule` is false (DESIGN 7.3 asks for the NAT check to be reported) |

State messages (English, in `clatctl.py`):

| State / reason | Message |
|---|---|
| `disabled` | Disabled. |
| `stopped` | The CLAT service is not running. |
| `starting` | The CLAT service is starting. |
| `listening` / `no_uplink_ipv6` | Listening: the uplink has no IPv6 default route. |
| `listening` / `no_nat64_prefix` | Listening: no NAT64 prefix found. |
| `native-ipv4` / `uplink`, `gateway`, `hold` | Native IPv4 is present on the uplink. / A native IPv4 gateway is present. / Native IPv4 disappeared; activation is held back for 60 seconds. |
| `waiting-for-prefix-delegation` | A NAT64 prefix is known; waiting for the delegated prefix of this session. |
| `active` | Active. |
| `suspended` | Suspended: the uplink lost IPv6. (plus " The IPv4 default route was handed to another gateway." when `withdrawn`) |
| `backoff` / code | Retrying after a failure (`<code>`). |

### 8.2 Preflight rows

Row format: `{"id": str, "effect": "block" | "warn", "message": str}`. An empty list means nothing to report. `u = cfg['uplink']`.

| id | Effect | Condition | Message |
|---|---|---|---|
| `tayga_missing` | block | `sysif.stat(TAYGA_BIN) is None` | The tayga package is not installed. |
| `wan_ipv4_ppp` | block | `u` and `u['ppp']` and `u['ipv4_ppp']` and not `facts.uplink_native(sysif)` | IPv6 cannot start with this setting. Set WAN IPv4 Configuration Type to None. |
| `nat_mode` | block | `cfg['nat_mode']` in `advanced`, `disabled` and not `settings['manual_nat']` | Outbound NAT mode is `<mode>`. Select automatic or hybrid mode, or add an outbound NAT rule on the CLAT interface and confirm that you manage outbound NAT yourself. |
| `pref64_overlap` | block | `settings['prefix']` overlaps `facts.local_networks(sysif)` | The NAT64 prefix `<p>` overlaps a local IPv6 prefix. |
| `stale_gateway` | block | `gw` known and `stale_gateways(gw)` non-empty | Gateway `<name>` is on an interface without an IPv4 address and outranks the CLAT gateway; core would install no IPv4 default route. Disable it. |
| `uplink_mtu`, `prefix_id`, `address` | block | not produced by `preflight()`; these are `PlanError` codes (rule 9) and `clatctl` adds the row when the state is `blocked` with that reason | The uplink IPv6 MTU is unknown or below 1280. / Prefix ID `<id>` does not fit in the delegated prefix. / The CLAT IPv6 address cannot be used. |
| `wan_ipv4_ppp_native` | warn | `u['ppp']` and `u['ipv4_ppp']` and `facts.uplink_native(sysif)` | If the ISP stops offering IPv4 on this line, IPv6 will not start either and the CLAT cannot take over. Set IPv4 to None first. |
| `scrub_disabled` | warn | `cfg['scrub']` is false | Firewall normalisation is disabled; no TCP MSS clamp is active. |
| `wan_mss` | warn | `u['mss']` is a number | The uplink interface has its own MSS value (`<n>`); it also clamps the translated flows. |
| `mtu_mismatch` | warn | `mtu.configured` and `mtu.effective` (8.1) both known and different | The configured uplink MTU (`<c>`) differs from the effective IPv6 MTU (`<e>`). |
| `uplink_mismatch` | warn | `u` and `route6` known and `u['if'] != route6[0]` | The configured uplink (`<a>`) is not the interface that holds the IPv6 default route (`<b>`). Choose the uplink explicitly. |
| `leftover_gateway` | warn | `gw` known, one row per entry of `gw['leftover']` | Gateway `<name>` has no address any more but is still used (`<refs>`). |
| `tayga_version` | warn | version given and, with any `_N` or `,N` suffix removed, not in `TESTED_TAYGA` | tayga `<v>` is installed; the plugin was tested with 0.9.6. |

The daemon acts on `block` rows only: in rule 3, except `stale_gateway`, which needs the gateway facts and is tested as rule 7a (7.2). `warn` rows matter to `clatctl status` only.

### 8.3 Tests (`clatctl.py test`)

Preconditions, checked in order: daemon running and status state `active`, else `error` "The CLAT is not active."; `settings['test_target']` set, else `error` "No test target is set.". With an error, `tests` is empty.

| id | Command | Pass |
|---|---|---|
| `plat` | `/sbin/ping -6 -n -c 3 -t 5 <embed(pref64, target)>` | return code 0 |
| `path` | `/sbin/ping -4 -n -c 3 -t 5 -S <ipv4_clat> <target>` | return code 0 |
| `mtu` | `/sbin/ping -4 -n -D -c 1 -t 2 -S <ipv4_clat> -s <size - 28> <target>`: try `size = settings['ipv4_mtu']`; if that fails try 1280, and if that passes binary-search the largest passing size between them | a size was found |

Each `sys.run` gets a time-out 5 s above the ping `-t` value. Output:

```json
{"status": "ok", "error": "", "target": "198.51.100.7",
 "tests": [{"id": "plat", "ok": true, "detail": "64:ff9b::c633:6407: 3 of 3 replies"},
           {"id": "path", "ok": true, "detail": "198.51.100.7 from 192.0.0.1: 3 of 3 replies"},
           {"id": "mtu", "ok": true, "size": 1472, "detail": "largest IPv4 packet that passes: 1472 bytes"}],
 "text": "NAT64 gateway over IPv6: ok (64:ff9b::c633:6407: 3 of 3 replies)\n..."}
```

`status` is always `ok` (anything else makes the page's action button show a warning dialog). Reply counts come from the `N packets transmitted, M packets received` line; `size` is `null` when nothing passes. `text` has one line per test, or the error.

## 9. `facts.php`

`#!/usr/local/bin/php`; `require_once 'config.inc'; require_once 'util.inc'; require_once 'interfaces.inc'; require_once 'plugins.inc.d/clat.inc';`. Argument `config`, `gateways`, or none (both). Prints one line `json_encode([...]) . PHP_EOL` with the members asked for, exit status 0. Never writes configuration.

### 9.1 `config` (config.xml only; uses the functions of section 4)

```json
{"config": {
  "uplink": {"key": "wan", "if": "pppoe0", "ppp": true, "ipv4_ppp": false, "mtu": 1492, "mss": null},
  "mss": 1492,
  "nat_mode": "automatic",
  "scrub": true,
  "record_ok": true,
  "interfaces": {"pppoe0": {"key": "wan", "claims": [0]}, "igc1": {"key": "lan", "claims": []}},
  "static_v6": ["2001:db8:5::1/64"]
}}
```

| Key | Rule |
|---|---|
| `uplink` | `null` when `clat_configured_uplink()` is `null`. `if` = `get_real_interface($key, 'inet6')`; `ppp` = a `ppps/ppp[]` entry has the same `if` as the record; `ipv4_ppp` = record `ipaddr` in `ppp`, `pppoe`, `pptp`, `l2tp`; `mtu` = `clat_configured_uplink_mtu($key)`; `mss` = the record's own `mss` as int when numeric, else `null` |
| `mss` | `clat_mss()` as int, `null` when it returns `''` |
| `nat_mode` | `(string)($config['nat']['outbound']['mode'] ?? '')` |
| `scrub` | false when `OPNsense/Firewall/Filter/settings/filter/scrub_enabled` exists and is empty or `0`, or when it does not exist and `system/scrub_interface_disable` is non-empty; else true (works on 26.7 and master) |
| `record_ok` | true when `clat_interfaces()` returns nothing. Else: `interfaces/clat/internal_dynamic` is set and no returned key differs under the test of `plugins_interfaces()`: `(empty($have[$k]) && !empty($v)) \|\| ($have[$k] ?? '') != $v` |
| `interfaces` | for every `interfaces/<key>` with `enable` set, non-empty `if` and empty `virtual`, keyed by device: `claims` = sorted unique /64 indexes claimed on a delegation of that interface: its own `dhcp6-prefix-id` when numeric, and for every enabled non-virtual interface with `ipaddrv6` in `track6`, `idassoc6`, `track6-interface == <key>` and numeric `track6-prefix-id`: that id up to id + `max(1, (int)track6_prefix_range) - 1` |
| `static_v6` | `"<ipaddrv6>/<subnetv6>"` of every enabled interface whose `ipaddrv6` is a literal IPv6 address |

### 9.2 `gateways` (runs `ifconfig` through `legacy_interfaces_details()`; based on the sketch in sheet core-hooks section 5)

```json
{"gateways": {
  "default": {"name": "CLAT_GW", "if": "tun464", "if_has_ipv4": true},
  "fallback": null,
  "list": [{"name": "CLAT_GW", "interface": "clat", "if": "tun464", "gateway": "192.0.0.2", "priority": 254,
            "upstream": false, "disabled": false, "defunct": false, "dynamic": true, "selected": false,
            "tunnel": false, "if_has_ipv4": true}],
  "leftover": [{"name": "WAN_PPPOE", "refs": ["dns", "rule"]}]
}}
```

| Key | Rule |
|---|---|
| `list` | every record of `(new \OPNsense\Routing\Gateways())->getGateways()` with `ipprotocol == 'inet'` and no `is_loopback`. `priority` as int; `upstream` = `!empty($gw['defaultgw'])`; `disabled`, `defunct`, `dynamic` as bool; `gateway` `''` when unset; `selected` = `interfaces/<interface>/gateway == name`; `tunnel` = device matches `/^(gre\|gif\|ovpn\|wg\|ipsec)/`; `if_has_ipv4` = `!empty($ifdetails[$if]['ipv4'][0])` |
| `default` | `getDefaultGW($down, 'inet')` reduced to the three keys, or `null`. `$down` = names whose status contains `down` in `return_gateways_status()`, only when `system/gw_switch_default` is set (as `system_routing_configure()` does) |
| `fallback` | name of `getDefaultGW($down + <names of gateways on tun464>, 'inet')` when it has a non-empty `gateway` and `if_has_ipv4`, else `null`. This is "another usable IPv4 gateway" of DESIGN 9 |
| `leftover` | for each `defunct` IPv4 gateway whose `interface` is the configured uplink: `refs` lists `monitor` (non-empty `monitor`), `dns` (some `system/dns<N>gw` equals the name), `rule` (some `filter/rule[]/gateway` or `OPNsense/Firewall/Filter/rules/rule[]/gateway` equals the name); entries without refs are omitted |

## 10. MVC

### 10.1 Controllers

- `IndexController extends \OPNsense\Base\IndexController`: `indexAction()` sets `generalForm = getForm('general')`, `statusForm = getForm('status')`, picks `OPNsense/Clat/index`.
- `Api\SettingsController extends ApiMutableModelControllerBase`: `$internalModelName = 'clat'`, `$internalModelClass = '\OPNsense\Clat\Clat'`. Nothing else.
- `Api\ServiceController extends ApiMutableServiceControllerBase`: `$internalServiceClass = '\OPNsense\Clat\Clat'`, `$internalServiceEnabled = 'general.enabled'`, `$internalServiceTemplate = 'OPNsense/Clat'`, `$internalServiceName = 'clat'`; `invokeInterfaceRegistration()` and `invokeFirewallReload()` return true, `reconfigureForceRestart()` returns false (as core's IPsec controller).
  - `statusAction()`: `$result = parent::statusAction(); $details = json_decode(trim((new Backend())->configdRun('clat details')), true); $result['clat'] = is_array($details) ? $details : []; return $result;` (keeps `status` and `widget`).
  - `testAction()`: POST only; returns the decoded output of `configdRun('clat test')`, or `['status' => 'ok', 'error' => gettext('Unable to run the tests.'), 'tests' => [], 'text' => gettext('Unable to run the tests.')]`.

Apply (`POST /api/clat/service/reconfigure`) then runs: stop (only when disabled), interface registration, filter reload, `template reload OPNsense/Clat`, and `clat reload` when running or `clat start` otherwise.

### 10.2 Forms

`forms/general.xml` (ids `clat.general.<field>`; rows after the "Advanced" header are under `<type>header</type>` with `<collapse>true</collapse>`):

| Field | Label | Type | Help (short form; write full sentences) |
|---|---|---|---|
| `enabled` | Mode | dropdown | Automatic: the CLAT activates when a NAT64 prefix is found and the box has no native IPv4 |
| `uplink` | Uplink | dropdown | interface that carries IPv6 to the provider; automatic picks WAN |
| `prefix` | NAT64 prefix | text | empty = discover from router advertisements and DNS; hint `64:ff9b::/96` |
| `discover_dns` | Discover through DNS | checkbox | RFC 7050 lookup of ipv4only.arpa through the system resolver |
| `keep_with_native` | Keep the CLAT when native IPv4 exists | checkbox | ranking is then left to System: Gateways |
| `firewall_rule` | Automatic firewall rule | checkbox | passes the translated IPv6 packets that enter on the CLAT interface |
| `manual_nat` | I manage outbound NAT myself | checkbox | allows activation in manual or disabled outbound NAT mode |
| `mss_clamp` | TCP MSS clamp | checkbox | |
| `mss_offset` | TCP MSS offset | text | hint `0`; subtracted from the automatic value |
| header | Advanced | | |
| `prefix_id` | CLAT prefix ID | text | hexadecimal /64 index in the delegated prefix; empty = highest unused |
| `address` | CLAT IPv6 address | text | full address; replaces automatic selection |
| `ipv4_clat`, `ipv4_tayga` | CLAT IPv4 address, Translator IPv4 address | text | |
| `ipv4_mtu` | IPv4 MTU to present | text | |
| `ipv6_mtu` | IPv6 MTU override | text | can only lower the detected value |
| `udp_cksum` | UDP zero checksum | dropdown | |
| `test_target` | Test target | text | IPv4 address that answers pings up to 1500 bytes through the NAT64 |
| `log_state` | Log state changes | checkbox | |

`forms/status.xml`: `info` fields with ids `status.state` (State), `status.uplink` (Uplink), `status.pref64` (NAT64 prefix), `status.address` (CLAT address), `status.mtu` (MTU and MSS), `status.gateway` (IPv4 default route), `status.tayga` (Translator), `status.preflight` (Checks).

### 10.3 `index.volt`

Layout top to bottom: status box (`base_form` with `statusForm`, id `frm_status`; a `Refresh` button `#refreshAct`; a `Run tests` button `#testAct` with `data-endpoint="/api/clat/service/test"`; a hidden `div#testResult.alert.alert-info`), settings box (`base_form` with `generalForm`, id `frm_general`), then `base_apply_button` with `data_endpoint: '/api/clat/service/reconfigure'`, `data_service_widget: 'clat'`. A `<style>` rule gives the status spans (`#frm_status span[id^="status."]`) and `#testResult` `white-space: pre-line`.

| When | Call | Then |
|---|---|---|
| page load | `mapDataToFormUI({'frm_general': '/api/clat/settings/get'})` | `formatTokenizersUI()`, selectpicker refresh |
| page load, `#refreshAct` click, after Apply (at once and once more 5 s later), after the tests | `ajaxGet('/api/clat/service/status', {}, cb)`, and `updateServiceControlUI('clat')` | `setFormData('frm_status', {'status': data.clat.text})` when `data.clat.text` exists; the service buttons in the page head are drawn again. `data_service_widget` alone is not enough: the Apply button asks for them once, when `clat start` returns, and the daemon writes its pid file about 150 ms after that (lab, 2026-10-12), so the answer says `stopped` for a service that runs |
| Apply (`#reconfigureAct`, `SimpleActionButton`) | `onPreAction`: `saveFormToEndpoint('/api/clat/settings/set', 'frm_general', dfObj.resolve, true, dfObj.reject)` | `POST /api/clat/service/reconfigure` |
| `#testAct` (`SimpleActionButton`) | `POST /api/clat/service/test` | `onAction`: `$('#testResult').removeClass('hidden').html(data.text)` (as helloworld does) |

No periodic polling. No markup is built from values: API replies to browser sessions are already entity-escaped, and `setFormData` and `.html()` insert them as HTML; line breaks come from the `pre-line` rule. All visible strings go through `{{ lang._('...') }}`. Pattern: sheet plugin-skeleton 6.3.

### 10.4 Menu and ACL

`Menu.xml`: under `<Services>`: `<Clat VisibleName="CLAT" cssClass="fa fa-exchange fa-fw">` with `<Settings order="10" url="/ui/clat"/>` and `<Log VisibleName="Log File" order="20" url="/ui/diagnostics/log/core/clat"/>`.

`ACL.xml`: `page-services-clat` (name `Services: CLAT`, patterns `ui/clat/*`, `api/clat/*`) and `page-services-clat-log` (name `Services: CLAT: Log File`, patterns `ui/diagnostics/log/core/clat/*`, `api/diagnostics/log/core/clat/*`).

## 11. Packaging and service

### 11.1 `Makefile`, `pkg-descr`

```make
PLUGIN_NAME=		clat
PLUGIN_VERSION=		1.0
PLUGIN_COMMENT=		464XLAT CLAT for IPv6-only uplinks
PLUGIN_DEPENDS=		tayga
PLUGIN_MAINTAINER=	N/A

.include "../../Mk/plugins.mk"
```

`pkg-descr`: two or three sentences (464XLAT CLAT with tayga on a virtual WAN interface; automatic NAT64 prefix discovery by RA PREF64 and RFC 7050; activates only without native IPv4), a blank line, `Plugin Changelog`, a line of 16 `=`, blank, `1.0`, blank, `* Initial release`.

### 11.2 `src/etc/rc.d/clat` (verbatim; `name=` and `rcvar=` at column 0)

```sh
#!/bin/sh
#
# PROVIDE: clat
# REQUIRE: SERVERS
# KEYWORD: shutdown
#

. /etc/rc.subr

name=clat
rcvar=clat_enable
command=/usr/local/opnsense/scripts/clat/clatd.py
command_interpreter=/usr/local/bin/python3
pidfile="/var/run/${name}.pid"
required_files="/usr/local/etc/clat/clatd.json"
extra_commands="reload"

load_rc_config $name

: ${clat_enable:=NO}

run_rc_command $1
```

| Command | Behaviour |
|---|---|
| `start` | rc.subr starts `clatd.py`, which daemonises and writes the pidfile; fails when `clatd.json` is missing or the daemon already runs |
| `stop` | default rc.subr stop: SIGTERM, then waits for the pid. The supervisor runs Deactivate (if up) and exits. No custom `stop_cmd` and no hard kill |
| `reload` | SIGHUP: the supervisor re-reads `clatd.json` and the config facts and reconciles; tayga restarts only when the plan changed |
| `restart` | stop, then start |
| `status` | `clat is running as pid N.` / `clat is not running.` |

### 11.3 Package script fragments (no `exit`, every command tolerant of failure)

`+PRE_DEINSTALL.pre`:

```sh
#!/bin/sh

/usr/local/etc/rc.d/clat onestop >/dev/null 2>&1 || :
```

`+POST_INSTALL.post` (runs after the automatic lines: configd restart, model migration, plugin configuration, template reloads):

```sh
/usr/local/sbin/pluginctl -i || :
/usr/local/sbin/configctl clat restart || :
```

`+POST_DEINSTALL.post`:

```sh
/usr/local/sbin/pluginctl -i || :
clat_pid=$(/sbin/ifconfig tun464 2>/dev/null | /usr/bin/sed -n 's/.*Opened by PID \([0-9][0-9]*\).*/\1/p')
if [ -n "${clat_pid}" ]; then
	/bin/kill ${clat_pid} >/dev/null 2>&1 || :
	/bin/sleep 1
fi
timeout 10 /sbin/ifconfig tun464 destroy >/dev/null 2>&1 || :
/usr/local/sbin/configctl interface routes configure || :
```

- `ifconfig tun464 destroy` blocks for as long as a process holds the device open. `+PRE_DEINSTALL` stops the daemon and with it tayga, but a tayga orphaned by an uncleanly killed daemon would make pkg hang while it holds its database lock. So the holder of `tun464` is killed first (only that process; an os-tayga instance is on another device), and the destroy has a time limit. `timeout` is called without a path, as core's `opnsense-importer` does; its location on FreeBSD 15 was not checked.
- Rendered files (`/etc/rc.conf.d/clat`, `clatd.json`, `tayga.conf`) are left in place: DESIGN 14 names three steps, the files do nothing without the rc.d script, and the next install renders them again.
- The secret file is kept, so the CLAT address survives an upgrade (pkg runs the deinstall scripts on upgrade).

### 11.4 Log view

`Syslog/local/clat.conf`:

```
###################################################################
# Local syslog-ng configuration filter definition [clat].
###################################################################
filter f_local_clat {
    program("clat");
};
```

Together with the menu and ACL entries of 10.4 and `clat_syslog()`.

## 12. Unit tests

Standard library `unittest` only; run on Linux with `python3 -m unittest discover -s net/clat/tests -v` from the project root. Each test file starts with `sys.path.insert(0, <.../src/opnsense/scripts/clat>)` computed from `__file__`, then `from lib import ...` (`test_clatctl.py`: `import clatctl`). No test imports `lib.sysif`, directly or through `clatctl` (6.7); the logic that would otherwise be untested there (`rtm_relevant`, `split_lines`, `ll_norm`) is in the pure modules.

| Module | Cases |
|---|---|
| `test_discovery.py` | `ll_norm`: with and without `%zone`, embedded zone bytes in fe80::/10 cleared, global address unchanged, `ValueError` for `link#9`; the result of a zoned and an unzoned text compare equal. `parse_ra_pref64`: valid option for each PLC 0..5 with host bits masked; lifetime decoding (`0xFFF8` mask) and lifetime 0; RA without option 38 -> `[]`; option-38 length other than 2 and PLC 6, 7 skipped; two options in one RA; wrong type, wrong code, shorter than 16 bytes, option length 0, option running past the end -> `None`. `accept_ra`: wrong interface, hop limit 254, global source, source other than the router, router `None` -> `None`; accepted packet (the packet source is `ll_norm('fe80::1')`, the router `ll_norm('fe80::1%pppoe0')`). `pref64_candidates` / `pref64_from_answer`: the seven vectors of sheet python-runtime 6.3 (all six lengths and the negative one), both well-known addresses, lowest of several, `current` kept, `reject`. `embed`: the six RFC 6052 section 2.4 examples. `RaPrefix`: first prefix selected, refresh, different prefix ignored while current, lifetime 0 withdraws, expiry, overlap rejected, empty list no change. `DnsPrefix`: answer with prefix, answer without prefix drops it and caps the interval at 300 s, failure keeps the prefix and steps through `DNS_RETRY_STEPS`, minimum refresh 60 s |
| `test_plan.py` | `clat_mtus`: the four rows of DESIGN 8.1 (1492, 1500, 1520, 1528 and above) and `v` other than 1500. `effective_mtu6`: RA MTU below, equal, above the device MTU and zero. `parse_prefix_file`: /56, /64, empty, `None`, garbage, longer than /64, two lines. `choose_subnet`: /56 with no claims -> index 255; claims at the top -> next lower; single /64; all claimed -> highest; `prefix_id` in and out of range. `iid_excluded`: 0, 1, 0xFFFF, 0x10000, both ends of the RFC 5453 range. `interface_id`: deterministic for the same input, differs per subnet and per secret, even, re-hashes when the first candidate is excluded or in use (construct by putting the first candidate in `in_use`). `make_plan`: automatic pair, manual address (odd input normalised), pair inside the NAT64 prefix -> `PlanError('address')`, MTU below 1280 or `None` -> `PlanError('uplink_mtu')`, plan equality. `tayga_conf`: exact eight lines. MSS rule of DESIGN 8.2 as a table test of `min(mtu, v + 20) - offset` against the MSS column of 8.1 (a three-line helper in the test mirrors `clat_mss()`; the PHP itself cannot run here) |
| `test_facts.py` | `parse_route_get`: sample of sheet 3.1 with and without `%zone`, without gateway line, empty text. `parse_ifconfig`: two-device sample with point-to-point `inet` and `netmask 0xffffffff`, `Opened by PID`, link-local `inet6` with zone. `parse_ndp`, `first_nameserver`, `parse_settings` (defaults, wrong types, invalid JSON). `native_gateways`: upstream, priority 254, selected static at 255, unselected static at 255 (not native), tunnel device, device without IPv4, disabled, the CLAT's own gateway. `stale_gateways`, `gateway_report` (four outcomes). `preflight`: each row of 8.2 fires on its condition and is absent otherwise; rows needing missing facts are skipped; `manual_nat` lifts `nat_mode`. `rtm_relevant`, with buffers built by `struct.pack`: GET -> false; ADD with `RTF_LLDATA` -> false; ADD without -> true; IFINFO -> true; an ignored message followed by a relevant one in the same buffer -> true; wrong version -> false; truncated buffer and length below 4 -> false without an exception. `split_lines`: `\r\n` stripped, several lines in one chunk, a partial line carried in `pending` and completed by the next chunk, a line cut to `limit`, an over-long rest emitted. `refresh_activation` without a runtime uplink: no `ndp` command, `ndp is None`, result follows the helper. Uses a small stub object with `read`, `stat` and `run` (which raises `TypeError` for a non-`str` argument) |
| `test_supervisor.py` (with `fakes.FakeSystem`) | **activation**: uplink up at start, RA with PREF64, /56 delegation -> exact command order of Activate, state `active`, marker and status file written, RS burst stops at the accepted RA. **dormant**: no NAT64 prefix -> `listening`, and a `tick` runs no command. **dormant behind the gate**: started with a native gateway in the helper's reply -> `native-ipv4` / `gateway` with the gateway facts gathered once; two ticks run no command; a `route` event refreshes them; with the gateway gone on that event -> `native-ipv4` / `hold`, and a `tick` in `hold` runs no command; same for `blocked` / `stale_gateway`. **native IPv4 appears**: gateway facts gain a native gateway -> Deactivate order, state `native-ipv4`; after it disappears no activation before 60 s, activation after. **hold timing**: the last pass that saw the gateway is 59 s before the pass that finds it gone; still no activation for 60 s from the latter. **native gateway while suspended**: `suspended` without fall-back, a native gateway appears on a `route` event -> Deactivate order, state `native-ipv4` / `gateway`. **DNS and native gateway**: with a DNS prefix held in `native-ipv4` / `gateway` no query is made however long it lasts; after the gateway goes, a query is made before activation. **uplink native**: router file on the uplink -> `native-ipv4` / `uplink`. **prefix expires**: RA lifetime runs out, DNS gives nothing -> Deactivate, `listening`; variant where DNS returns the same prefix -> stays `active` without a restart. **uplink loss, no other gateway**: no command during 15 s, then `suspended` with nothing withdrawn; uplink back with rewritten prefix file -> `active`, no tayga restart. **uplink loss, other gateway**: Withdraw order; resume runs Replay (Activate steps 4, 6, 7, 8; no `route` command). **session confirmation**: after a loss the old prefix file is not trusted until its stat changes or `usr2` arrives; a `usr2` received while `listening` in a trusted session does not confirm the stale file after the next loss. **renumbering**: new delegated prefix -> Renumber order with old and new pair; a second change inside `RESTART_MIN_INTERVAL` is deferred to the `restart` timer. **MTU change** -> restart. **tayga exit**: marker and router file removed and no `route`, `pfctl` or `configctl` command; `backoff` / `tayga_exit` with `running` kept; Activate after 5 s, `restarts == 1`, delays grow; variant: disabled during the back-off -> full Deactivate order; variant: a changed delegated prefix during the back-off -> Renumber. **activation failure**: `route add` fails -> Deactivate, `backoff` / `step_route`; `spawn` returns `None` -> `backoff` / `tayga_start`. **start with leftovers**: marker present at start -> Deactivate steps 1, 2 and 5 only, and the old status file is removed. **drift repair guard**: `record_ok` false -> registration once; not while `TODO_FILE` exists; not again within 300 s; Replay after it when `active`. **blocked**: manual NAT mode blocks, `manual_nat` lifts it. **reload**: unchanged settings cause no command; a changed `ipv4_mtu` restarts tayga. **echo**: a `route` event after activation with unchanged facts runs no state-changing command |
| `test_clatctl.py` (component F, with `fakes.FakeSystem`) | `cmd_status`: no live pid and enabled -> `stopped`; disabled -> `disabled`; live pid without status file -> `starting`; with a status file: state, reason and the message of 8.1 for each state, the `blocked` message taken from the preflight row, every `text` row, `; NAT rule missing` in `text.gateway`. `cmd_event`: `SIGUSR2` for `inet6` / `1`, `SIGUSR1` for the other three combinations, nothing without a pidfile. `cmd_test`: not active and no target -> the two errors with empty `tests`; reply counting from the ping summary line; DF probe: passes at `ipv4_mtu` -> that size; fails there and passes at 1280 -> the largest passing size found by the search; fails at both -> `size` `null` |

`fakes.FakeSystem` implements every method and attribute of 6.2 (the four signal names as distinct integers; `write`, `mkdir`, `remove` return true) and adds: `clock`/`advance(seconds)` (moves both clocks; `sleep` advances), `files` (path -> text; `write` and `put(path, text)` give a new stat tuple), `commands` (list of every `argv` run), `reply(prefix: list[str], rc=0, out='', err='')` (answer for commands whose `argv` starts with `prefix`; default `(0, '', '')`, and `configctl` commands default to `'OK\n'`), `ifindex` (dev -> index), `ra_queue` (a list of `RaPacket` tuples whose `source` is an `IPv6Address`), `route_flag`, `dns_outcome`, `pids` (the set of live pids for `pid_alive`; `kill` records `(pid, signo)` in `signals`), and child control: `spawn` records `argv` and queues the line `Using tun device tun464 with MTU <n>` with `n` taken from the last `ifconfig tun464 mtu <n>` command unless `tayga_fails` is set, and returns `None` when `spawn_fails` is set; `exit_child(code)`. `run` raises `TypeError` when an element of `argv` is not a `str`, as `subprocess` would.

## 13. Coding conventions

| Area | Rule |
|---|---|
| Licence | BSD-2-Clause header with the line `Copyright (C) 2026 os-clat contributors` in: `clat.inc`, all PHP classes, `facts.php`, `index.volt`, every Python file (docstring form; `lib/__init__.py` too). Header text and comment style per file type: sheet plugin-skeleton section 11. No header in XML, `actions_clat.conf`, templates, `+TARGETS`, `rc.d/clat`, `Makefile`, `pkg-descr`, package fragments |
| All files | LF line endings, no trailing whitespace, exactly one final newline, ASCII only |
| File modes | 755 on `src/etc/rc.d/clat` and on every file under `src/opnsense/scripts/clat/` including `lib/*.py` and `facts.php` (lint-exec). The tree is on Windows: set modes where `make package` runs (`chmod 755 src/etc/rc.d/clat src/opnsense/scripts/clat/* src/opnsense/scripts/clat/lib/*`) |
| PHP | PSR-12: 4 spaces, `<?php` then a blank line, brace on its own line for classes and functions, short arrays, lowercase `true/false/null`, visibility on every method, soft limit 120 columns, one `use` per line and none unused, no closing tag. UI strings through `gettext()`; log messages not. Class file name equals class name. Hook functions are named `clat_*` |
| XML | 4-space indent, no XML declaration, model exactly as `xmllint --format` prints it; lint rules of sheet plugin-skeleton 4.2 |
| Python | 4 spaces, snake_case functions, CapWords classes, UPPER_CASE constants; clean under `pycodestyle --ignore=E501` (which re-enables W503/W504 and E226: never break a line at a binary operator, put spaces around all arithmetic operators); soft limit 120 columns; type hints on public functions, no syntax newer than Python 3.11; no f-string nesting; no global mutable state outside classes |
| Shell and configd | POSIX `sh`; configd `start/stop/restart/reload/event` are `type:script`, only `status/details/test` are `script_output` |
| Messages | daemon and CLI messages are English and not translated (14.A) |
| Checks to pass | `make lint`, `make style`, `make sweep` leave the tree unchanged (core checked out as `../core`); unit tests pass |

## 14. Choices and deviations

### 14.A Choices where DESIGN is silent

None of these changes behaviour DESIGN states.

1. Daemonisation uses core's `Daemonize` (dominant in-tree pattern), not daemon(8).
2. Settings reach the daemon as rendered JSON; everything derived from other parts of config.xml comes from `facts.php`, so the configured-uplink and MTU logic exists once, in PHP.
3. The event hook is delivered as a signal: SIGUSR2 for "inet6 on the uplink", SIGUSR1 for everything else. No payload file.
4. The device function learns "the CLAT gateway is up" from the marker `/var/run/clat/gateway` plus a live pidfile, not from the status file.
5. One RA entry at a time: a different PREF64 from the same router is ignored (not stored) while the current one is valid.
6. A negative DNS answer is re-asked after at most 300 s, whatever its negative TTL, so enabling DNS64 on the box is noticed without a restart. SERVFAIL and REFUSED count as failures, like a time-out.
7. A failed activation step runs the full Deactivate sequence, so core's view is correct before the retry. A tayga exit does not: as DESIGN 9 says, it removes the router file only, and the plan is kept for the retry or a later Deactivate (7.4).
8. Only `block` rows are evaluated by the daemon; `warn` rows, the tayga version, the NAT-rule and default-gateway reports are computed by `clatctl status` on request. The daemon logs the gateway and NAT results once per activation.
9. The fall-back gateway question is asked once, when suspension begins.
10. While `active`, the /127 route is not re-checked on every reconcile; router file, tun address and tun owner are.
11. A delegated prefix is required also with a manual full address (DESIGN 5.1 condition 2 is kept uniform).
12. An overlapping static NAT64 prefix, an unusable prefix ID, address or MTU give `blocked` with their own reason codes (DESIGN's preflight table has a row for the first since v0.13 and none for the other three; all four block activation).
13. Only the first prefix in the prefix file is used (advanced dhcp6c configurations with several IA_PDs are not handled).
14. `leftover_gateway` does not follow gateway groups.
15. MSS setting is a checkbox plus an optional offset; the CLAT address setting is two optional fields.
16. No check for "during boot" before drift repair: the service starts after `rc.bootup`.
17. Runtime messages are English only; the page shows text prepared by `clatctl` and does not poll.
18. One "Run tests" button runs the three tests in sequence.
19. No HA sync hook, no cron job, no dashboard widget, no migration class.
20. tayga's chroot directory is the plugin's own `/var/run/clat/empty`, created at each activation.
21. At start the daemon cleans up a left-over tayga, the router file and core's routing. It does not look for the /127 route of an earlier address pair (no tayga.conf parser); an Activate replaces the route of its own pair.
22. The 60 s hold starts at the pass that first finds native IPv4 gone (rule 8a), which can be later than the real disappearance, never earlier.
23. Package removal leaves the rendered files in place (11.3).

### 14.B Deviations from DESIGN

These change behaviour DESIGN states. They were not yet confirmed when this was written (accepted since: section 16, item 7); until confirmation they are implemented as written here, and an item that is declined is replaced by what "If declined" says.

1. **Commands while dormant.** DESIGN 5.4: "While dormant it runs no external commands"; DESIGN 10: "a dormant supervisor still runs no external commands". The supervisor needs the runtime uplink, its default router and its addresses to accept RAs and to see native IPv4 on the uplink, and it needs the configured uplink from config.xml. It gets them from `route -6 -n get default`, `ifconfig -a` and `facts.php config`. No timer runs them; the cost per event and per config.xml change is listed in 7.5. *If declined:* the link facts must be read in-process from the routing socket inside `sysif.py` (an `RTM_GET` exchange and the interface address messages), `Facts.refresh_link` (6.5) changes accordingly, and the config facts must be derived without starting PHP. That is a larger `sysif.py` and a second copy of the configured-uplink logic.
2. **RFC 7050 with native IPv4 on another WAN.** DESIGN 5.2: RFC 7050 is "Used only when no PREF64 is known and there is no native IPv4". Only the uplink half of the native test (rule 2) comes before the lookup. The gateway half needs the PHP helper, which DESIGN 10 allows only once a prefix is known, so the two sentences cannot both hold. On a box whose native IPv4 is on another WAN the lookup therefore runs until a DNS prefix is held: one query every 60 to 300 s while the answer is negative (6.3 `DnsPrefix`). Once a prefix is held and the state is `native-ipv4` / `gateway`, nothing more is asked (7.2 step 4). *If declined:* the gateway facts are gathered before a prefix is known, which gives up DESIGN 10's rule for that helper.

## 15. Components

| Key | Files | SPEC sections needed |
|---|---|---|
| A packaging | `Makefile`, `pkg-descr`, `+PRE_DEINSTALL.pre`, `+POST_INSTALL.post`, `+POST_DEINSTALL.post`, `src/etc/rc.d/clat`, `actions_clat.conf`, `templates/OPNsense/Clat/{+TARGETS,rc.conf.d,clatd.json}`, `templates/OPNsense/Syslog/local/clat.conf` | 1, 2, 3.1, 3.3, 5, 11, 13 |
| B php-glue | `clat.inc`, `facts.php` | 1, 2, 3.1, 4, 9, 13 |
| C mvc | model, ACL, menu, three controllers, two forms, view | 1, 2, 3.1, 3.2, 8.1 (`text`), 8.3, 10, 13 |
| D logic | `lib/__init__.py`, `lib/discovery.py`, `lib/plan.py`, `lib/facts.py`, `tests/test_discovery.py`, `tests/test_plan.py`, `tests/test_facts.py` | 1, 2, 3.3, 6.1 to 6.5, 8.2, 9, 12, 13 |
| E supervisor | `lib/supervisor.py`, `tests/fakes.py`, `tests/test_supervisor.py` | 1, 2, 6.2 to 6.6, 7, 8.1, 12, 13, 14 |
| F runtime | `lib/sysif.py`, `clatd.py`, `clatctl.py`, `tests/test_clatctl.py` | 1, 2, 5, 6.1 to 6.3, 6.5 to 6.7, 8, 12, 13 |

Interfaces between components are exactly: the names of section 2, the JSON of 3.3, 8 and 9, the configd actions of 5, the `System` methods and attributes of 6.2, the signatures of 6.3 to 6.6, and `FakeSystem` as described in 12 (written by E, used by F's test).

## 16. Amendments made during implementation (2026-10-12)

The code in `net/clat/` differs from the text above in these points. The code and its unit tests are authoritative; DESIGN.md was updated where behaviour changed.

1. **Activate step 7 and Replay (7.4).** `configctl filter reload skip_alias` runs before `configctl interface newip tun464 force`. Core's `newip` installs the default route before it reloads the filter, so without the first command packets forwarded in that gap would create states without NAT.
2. **Session tracking (7.7).** `track_uplink()` treats the session as changed only when an uplink appears whose (device, index) differs from the last one. A gap in the IPv6 default route on the same device keeps the delegated-prefix file trusted.
3. **Failed helpers (7.3, 7.5, 7.6).** A failed `facts.php config` is handled like a failed gateway helper and repeated when the back-off ends; the CLAT does not activate while the config facts are missing. A `need_facts` pass inside the back-off gathers nothing. The failure count resets once `active` has lasted `BACKOFF_RESET`.
4. **`refresh_link()` (6.5).** Exit codes 124 and 127 from `route -6 -n get default` (time-out, command not started) leave the known route unchanged; only a real answer updates it.
5. **Daemon liveness (6.7, 8.1).** The daemon counts as running when the pid in the pidfile is alive and its command line shows `clatd.py`.
6. **Status API (10.1).** `ServiceController::statusAction()` adds the `clat` member for GET requests only.
7. **Section 14.B.** Both deviations listed there were accepted; DESIGN.md sections 5.2, 5.4 and 10 now say the same.

Amendments from the first lab run (2026-10-12; symptom, cause and re-test of each are in `lab/.work/results/changes.md`):

8. **An uplink device that is down (6.5, 7.2 rule 5, 7.7, 8.1).** `Facts.refresh_link()` sets `route6 = None` when the device of the IPv6 default route does not have the flag `UP` in the `ifconfig -a` output of the same call (a device that output does not list counts as not up). No command is added. On OPNsense 26.7.6 a PPP session that is lost while mpd5 redials leaves the device, its interface index and the default route in place and only takes the device down, so "no IPv6 default route" alone never became true and `suspended` could not be reached. Rule 5 (`listening` / `no_uplink_ipv6`, soft), the grace period and `suspended` now follow from the flag as well. `track_uplink()` is unchanged: the device coming up again under the same index is the same session, so `pd_trusted` stays true, and it is an attach (one RS burst). The sentence in 7.7 that "a new PPP session has a new index" was seen in no case in the lab: mpd5 keeps the device, and a device that core set up again (Apply on the WAN) came back under the index of the old one, after core had removed the prefix file with the old device (the docstring of `track_uplink()` says so now). The message of `listening` / `no_uplink_ipv6` (8.1) is now `Listening: the uplink is down or has no IPv6 default route.` Unit tests: `test_refresh_link_route_on_a_device_that_is_down`, `test_refresh_link_route_on_an_unknown_device`, `test_session_ends_and_the_device_and_the_route_stay`, `test_session_back_within_the_grace_period_and_the_device_stayed` (the last one fails without this amendment: it asserts that the loss was noticed and the `grace` timer armed).
9. **Status file and Router Advertisements (7.3, 7.5, 7.6).** `handle()` calls `write_status()` after an `ra` event that started no reconcile pass. An advertisement that refreshes or shortens the lifetime of the current prefix changes the expiry without changing the selected prefix, so it starts no pass, and the file then named the expiry of the last pass for up to `TICK` plus one RA interval; `clatctl status` showed "0 s left" for a valid prefix. `write_status()` still writes only when the content differs: an advertisement that is rejected or changes nothing writes nothing, and a dormant supervisor writes nothing. No pass, command or log line is added. Unit test: `test_status_file_is_written_only_when_it_changes`.
10. **`+POST_DEINSTALL.post` (11.3).** One line after the destroy of the tun: `/bin/rm -f /tmp/tun464_oldip /tmp/tun464_oldgw`. Core's `rc.newwanip` writes these two files for every device it ran for (activation step 7 makes it run for `tun464`) and removes them only at boot. The fragment has four steps now; DESIGN 14 lists them.
11. **Size test (8.3).** Changed twice on 2026-10-12; this item says what the code does now. The `mtu` test has three outcomes, and its `ok` is `true`, `false` or `null`. One probe is `/sbin/ping -4 -n -D -c 1 -t 2 -S <ipv4_clat> -s <size - 28> <target>` as before and ends in one of three ways: a reply (return code 0); "too big", when the output or the error output matches `frag needed and DF set` (an ICMP error, from tayga) or `Message too long` (the kernel, for a size above the MTU of the tun); or lost. No size is asked twice. `top` is the IPv4 MTU presented, `plan['ipv4_mtu']` of the status file, and no longer `settings['ipv4_mtu']`: the setting is the largest value to present, and tayga refuses every packet above the presented one. `floor` is `min(1280, top)`. Order: (a) `top` is answered: `ok` true, `size` `top`, and nothing else is asked. (b) Else a probe of `floor`; if it is refused: `ok` false, `size` null, detail `an IPv4 packet of <floor> bytes is refused ("fragmentation needed")`. (c) Else the largest answered size is found by bisection: between `floor` and `top` when `floor` was answered; when it was lost, between 84 bytes (`PROBE_SMALL`, an ordinary ping) and `floor`, after the 84 bytes were answered. If they are not: `ok` false, `size` null, detail `no ping was answered`. (d) What the size above the largest one answered got decides. Refused, with the largest one answered at `floor` or above: `ok` true, detail `largest IPv4 packet that passes: <n> bytes`, as in (a). Refused below `floor`: `ok` false with the detail of (b) for the refused size. Lost: `ok` null, `size` the largest one answered, detail `largest ping answered: <n> bytes; the next larger ping got no reply and no "fragmentation needed" error; this happens when the NAT64 returns large ping replies as fragments, which the translator does not pass for ping, and also when packets of that size are lost on the path; check with a TCP download`. The `text` line of a test uses `ok`, `failed` or `inconclusive`. Reasons: tayga 0.9.6 does not translate a fragmented ICMP message, so where the NAT64 returns DF-clear echo replies above 1260 bytes as IPv6 fragments the probe failed on a healthy line (first change, which added `null`). That change reported `ok` whenever 1280 bytes were answered, also when every larger probe was lost without an error, and below 1280 bytes its text said that TCP and UDP are not affected; a path that silently loses large packets was therefore read as healthy (second change: a limit that only silence marks is `null` at any size, and the text names both causes). Unit tests in `test_clatctl.py`: `test_probe_answered_at_the_ipv4_mtu`, `test_probe_limit_marked_by_a_refusal`, `test_probe_refused_by_the_tun`, `test_probe_limit_marked_by_silence` (sizes below and above 1280), `test_probe_silence_below_a_refusal`, `test_probe_inconclusive_text`, `test_probe_refused_at_the_floor`, `test_probe_refused_below_the_floor`, `test_probe_without_any_answer`, `test_probe_at_the_lowest_ipv4_mtu`.
12. **Reload and DNS (7.5, 6.3).** `reconcile()` sets `dns.next_query = 0.0` when the reason is `start` or `reload`, so the pass that follows an Apply on the plugin page asks `ipv4only.arpa` again when DNS is the source to ask (selection step 4). The held prefix is kept: a time-out on that query is a failure, which drops nothing. Without this a customer who made the resolver DNS64-aware after installing the plugin waited for the next lookup, up to `DNS_NEGATIVE_MAX` (measured 116 to 298 s; with an Apply 3 s). Unit tests: `test_reload_asks_dns_again_at_once`, `test_reload_with_a_dns_time_out_keeps_the_prefix`, `test_reload_asks_no_dns_while_the_ra_has_the_prefix`.
13. **`+POST_DEINSTALL.post`, second addition (11.3).** One line after the removal of the two files: `/bin/rm -rf /usr/local/opnsense/scripts/clat/lib/__pycache__`. Python writes its cache files there when the daemon first imports the modules; they belong to no package, so `pkg delete` left them and the directories `scripts/clat/lib` and `scripts/clat` (seen on the first removal of the package through the firmware page, 2026-10-12). pkg 2.8.4 removes the empty directories of a package after its post-deinstall script has run, so the script only has to empty them; a second line that removed the two directories as well made pkg print `unlinkat(...): No such file or directory` twice and was taken out again. The line is harmless should a pkg version run it during an upgrade (pkg 2.8.4 did not run the old post-deinstall script on an upgrade): the cache is written again. The fragment has five steps now; DESIGN 14 lists them.
