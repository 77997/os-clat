# os-tayga as a template, plugin packaging, and third-party distribution

Research date: 2026-10-10. Scope: facts only, no design.

Path shorthand used below:

- `PLUGINS` = `refs/opnsense-plugins`
- `CORE`    = `refs/opnsense-core`
- `PORTS`   = `refs/opnsense-ports`
- `TAYGA`   = `refs/tayga` (apalrd/tayga master, `version.h` says `0.9.6-15-g1fcb318`)

Confidence tags: **[verified]** = primary source read; **[likely]** = inferred from strong evidence; **[unverified]**.

---

## 1. os-tayga: complete file inventory and behaviour

Plugin lives in `PLUGINS/net/tayga`. Version 1.5, maintainer m.muenz@gmail.com, tier 3 (default), depends on the `tayga` binary package.

### 1.1 Inventory (22 files) [verified]

| File (relative to `PLUGINS/net/tayga`) | Role |
|---|---|
| `Makefile` | 5 variables + `.include "../../Mk/plugins.mk"` |
| `pkg-descr` | Description + "Plugin Changelog" (1.0 .. 1.5) |
| `src/etc/inc/plugins.inc.d/tayga.inc` | Legacy hook file: `tayga_enabled()`, `tayga_services()`, `tayga_xmlrpc_sync()`, `tayga_interfaces()` |
| `src/etc/rc.d/opnsense-tayga` | Own rc.d script (the FreeBSD port ships none): starts daemon, addresses the tun, adds routes; stop destroys the tun |
| `src/opnsense/mvc/app/controllers/OPNsense/Tayga/GeneralController.php` | UI page controller (`/ui/tayga/general`) |
| `.../Tayga/Api/GeneralController.php` | `ApiMutableModelControllerBase` for model `General` (`/api/tayga/general/get|set`) |
| `.../Tayga/Api/MappingController.php` | `ApiMutableModelControllerBase` for model `StaticMapping` (grid CRUD) |
| `.../Tayga/Api/ServiceController.php` | `ApiMutableServiceControllerBase` (start/stop/restart/status/reconfigure), overrides `invokeInterfaceRegistration()` |
| `.../Tayga/forms/general.xml` | Form definition for the General tab |
| `.../Tayga/forms/dialogEditStaticMapping.xml` | Form/grid definition for static mappings |
| `src/opnsense/mvc/app/models/OPNsense/Tayga/General.php` / `General.xml` | Model mounted at `//OPNsense/tayga/general`, version 1.3.0 |
| `.../Tayga/StaticMapping.php` / `StaticMapping.xml` | Model mounted at `//OPNsense/tayga/staticmapping`, ArrayField |
| `.../Tayga/ACL/ACL.xml` | One privilege `page-tayga-config` (`ui/tayga/*`, `api/tayga/*`) |
| `.../Tayga/Menu/Menu.xml` | `Services > Tayga` |
| `src/opnsense/mvc/app/views/OPNsense/Tayga/general.volt` | Two-tab view (General, Static Mappings) + apply button |
| `src/opnsense/scripts/OPNsense/Tayga/setup.sh` | `mkdir -p /var/db/tayga` (dead code, see 1.6) |
| `src/opnsense/service/conf/actions.d/actions_tayga.conf` | configd actions `tayga start|stop|restart|status` |
| `src/opnsense/service/templates/OPNsense/Tayga/+TARGETS` | Template -> target file map |
| `.../templates/OPNsense/Tayga/tayga` | Renders `/etc/rc.conf.d/opnsense-tayga` |
| `.../templates/OPNsense/Tayga/tayga.conf` | Renders `/usr/local/etc/tayga.conf` |

Absent in os-tayga (relevant omissions): no `tayga_devices()` hook, no `tayga_configure()` hook (no `bootup`/`newwanip` reaction), no `tayga_firewall()` hook, no `tayga_syslog()` / `Syslog/local/*.conf` (no log viewer page), no `+PRE_DEINSTALL*`/`+POST_INSTALL*` overrides, no `Migrations/`, no tests. [verified by glob of the directory]

### 1.2 How the `nat64` tun is created, named, addressed

Name is hard-coded in the template (`PLUGINS/net/tayga/src/opnsense/service/templates/OPNsense/Tayga/tayga.conf:3-6`):

```
tun-device nat64
data-dir /var/db/tayga
udp-cksum-mode fwd
wkpf-strict no
```

Creation is done by the tayga daemon itself. On FreeBSD a name not starting with `tun` makes tayga open the cloning device `/dev/tun` and rename the resulting `tunN` via `SIOCSIFNAME` (`TAYGA/tun.c:461-462, 472, 532-541`):

```c
if (strncmp(gcfg.tundev, "tun", 3))
        do_rename = 1;
...
snprintf(devname, sizeof(devname), "/dev/%s", do_rename ? "tun" : gcfg.tundev);
...
if (do_rename) {
        ...
        strcpy(ifr.ifr_name, fdevname(gcfg.tun_fd));
        ifr.ifr_data = gcfg.tundev;
        if (ioctl(fd, SIOCSIFNAME, &ifr) < 0) {
```

The same logic exists in the released 0.9.6 (there in `tayga.c`; `tun.c` does not exist at tag 0.9.6) -- checked at https://raw.githubusercontent.com/apalrd/tayga/0.9.6/tayga.c. The port in OPNsense is 0.9.6 (`PORTS/net/tayga/Makefile:1-2`, `distinfo:2`). [verified]

The FreeBSD branch of `tun_setup()` does NOT bring the interface up, assign addresses or add routes (`TAYGA/tun.c:454-558`); the `tun-ip` / `tun-route` / `tun-up` directives of master are implemented only in the `__linux__` branch via netlink (`TAYGA/tun.c:376-422`) and do not exist at all in 0.9.6 (directive table at tag 0.9.6 lists only `ipv4-addr, ipv6-addr, prefix, wkpf-strict, udp-cksum-mode, tun-device, map, dynamic-pool, data-dir, strict-frag-hdr, log, offlink-mtu`). [verified]

Hence the rc script does addressing and routing (`PLUGINS/net/tayga/src/etc/rc.d/opnsense-tayga:22-34`):

```sh
tayga_start()
{
        echo "starting tayga"
        ${command} ${command_args}
        sleep 1
        ifconfig nat64 inet ${tayga_v4destination}/32 ${tayga_v4address}
        ifconfig nat64 inet6 ${tayga_v6destination}/128
        ifconfig nat64 group tayga
        route -4 add ${tayga_v4pool} -interface nat64
        if [ "$tayga_v6routedisabled" != "YES" ]; then
            route -6 add ${tayga_v6prefix} -interface nat64
        fi
}
```

Stop (`opnsense-tayga:36-45`): `kill -2 ${rc_pid}` then `ifconfig nat64 destroy`.

Observations [verified from the script]:
- fixed `sleep 1` instead of waiting for the interface; no error handling (issue #2094 "interface nat64 does not exist" was exactly tayga failing to start and the following `ifconfig`/`route` lines erroring, https://github.com/opnsense/plugins/issues/2094).
- No MTU is set on `nat64`; no `offlink-mtu` in the template.
- `command_args="-p ${pidfile}"` only: default config path (`/usr/local/etc/tayga.conf`, compiled in by the port: `PORTS/net/tayga/Makefile:21` `CFLAGS+= -DTAYGA_CONF_PATH='\"${PREFIX}/etc/tayga.conf\"'`), pidfile `/var/run/tayga.pid` (`opnsense-tayga:9,16-18`).

### 1.3 Registration with OPNsense: only an interface *group*, via `_interfaces`

`PLUGINS/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80`:

```php
function tayga_interfaces()
{
    $interfaces = array();
    if (!tayga_enabled()) {
        return $interfaces;
    }
    $oic = array('enable' => true);
    $oic['if'] = 'tayga';
    $oic['descr'] = 'Tayga';
    $oic['type'] = 'group';
    $oic['virtual'] = true;
    $oic['networks'] = array();
    $interfaces['tayga'] = $oic;
    return $interfaces;
}
```

- This registers a virtual *group* interface `tayga` (not the device `nat64`). The rc script puts `nat64` into the ifconfig group `tayga` (`opnsense-tayga:29`). The result is the "Firewall > Rules > Tayga" tab. Identical pattern to core WireGuard (`CORE/src/etc/inc/plugins.inc.d/wireguard.inc:69-87`) and os-openconnect (`PLUGINS/security/openconnect/src/etc/inc/plugins.inc.d/openconnect.inc:56-73`).
- `plugins_interfaces()` writes these into `config.xml` `<interfaces>` with `internal_dynamic` and removes stale ones (`CORE/src/etc/inc/plugins.inc:178-242`). It is run by `pluginctl -i` (`CORE/src/sbin/pluginctl:242-245`) and on every legacy `write_config()` (`CORE/src/etc/inc/config.inc:214-219`).
- The service controller forces the registration on Apply (`PLUGINS/.../Tayga/Api/ServiceController.php:44-47` returns `true` from `invokeInterfaceRegistration()`); the base class then calls `runInterfaceRegistration()` = configd `interface invoke registration` = `/usr/local/sbin/pluginctl -i` (`CORE/.../Base/ApiMutableServiceControllerBase.php:201-203`, `CORE/.../Base/ApiControllerBase.php:411-417`, `CORE/src/opnsense/service/conf/actions.d/actions_interface.conf:68-72`).

The device `nat64` itself is NOT registered with `plugins_devices()` (no `tayga_devices()`). It is nevertheless assignable in Interfaces > Assignments, because `get_interface_list()` lists every ifconfig device whose name, split on digits, does not hit `interfaces_virtual_patterns()` -- `nat64` splits into `nat` which is not in the list (`tun`, `tap`, `wg`, `ovpns`, ... are) -- so it shows up in the "Hardware" option group (`CORE/src/etc/inc/interfaces.lib.inc:563-595, 636-640`; `CORE/src/opnsense/scripts/interfaces/list_assign_options.php:43-54`). Consequence: it is treated as a persistent ("non-volatile") hardware NIC. `is_interface_mismatch()` only skips devices matching a `volatile` plugin-device pattern or locked interfaces (`CORE/src/etc/inc/console.inc:48-76`), which is why the plugin's own help text demands locking it (`PLUGINS/.../Tayga/forms/general.xml:48`):

> "This is an advanced setting for selective routing scenarios. It will prevent installing the route which routes the IPv6 Prefix to Tayga. This requires assigning and locking the nat64 interface, enabling dynamic gateway policy, configuring a dynamic IPv6 gateway and adding custom routes."

For comparison, plugins that own tun-like devices declare them volatile: `zerotier_devices()` returns `[['pattern' => '^zt', 'spoofmac' => false, 'volatile' => true]]` (`PLUGINS/net/zerotier/src/etc/inc/plugins.inc.d/zerotier.inc:63-66`); `tailscale_devices()` adds `'configurable' => false` (`PLUGINS/security/tailscale/src/etc/inc/plugins.inc.d/tailscale.inc:56-64`); core WireGuard additionally supplies `names`, `function`, `type`, `typedescr` (`CORE/src/etc/inc/plugins.inc.d/wireguard.inc:101-122`). Defaults for device entries are in `CORE/src/etc/inc/plugins.inc:97-103` (`configurable=true`, `reload=true`, `spoofmac=true`, `volatile=false`).

### 1.4 Service registration and HA sync

- `tayga_services()` (`tayga.inc:36-54`): one service `name => 'tayga'`, `pidfile => '/var/run/tayga.pid'`, configd `tayga start|stop|restart`. Only returned when enabled.
- `tayga_xmlrpc_sync()` (`tayga.inc:56-64`): `id => 'taygavpn'`, `section => 'OPNsense.tayga'`, `services => ['tayga']`. Open issue #5503 "os-tayga: no configuration synchronization": reporter says sync does not arrive on the backup; maintainer Monviech could not reproduce (https://github.com/opnsense/plugins/issues/5503).

### 1.5 configd actions and the 26.7.6 breakage

`PLUGINS/net/tayga/src/opnsense/service/conf/actions.d/actions_tayga.conf:1-26`:

```
[start]
command:/usr/local/etc/rc.d/opnsense-tayga start; /usr/local/etc/rc.routing_configure
parameters:
type:script_output
...
[restart]
command:
    /usr/local/etc/rc.d/opnsense-tayga stop;
    /usr/local/etc/rc.d/opnsense-tayga start;
    /usr/local/etc/rc.routing_configure
type:script_output
...
[status]
command:/usr/local/etc/rc.d/opnsense-tayga status; exit 0
type:script_output
```

- `start`/`restart` chain `/usr/local/etc/rc.routing_configure`, which re-applies system routing and reloads the filter (`CORE/src/etc/rc.routing_configure:73-79`: `system_routing_configure(...)`, `filter_configure_sync(true, false)`); it exits immediately during boot (`rc.routing_configure:38` `exit_on_bootup();`).
- Issue #5778 (opened 2026-10-10, open): after 26.7.5 -> 26.7.6 the Tayga "Apply" reports `Service "tayga" failed to start`. Cause: `ApiMutableServiceControllerBase::reconfigureAction()` now compares the configd result with the literal `'OK'` (`CORE/.../Base/ApiMutableServiceControllerBase.php:219-229`; core commit bed9f78 "mvc: dispatch failed message during reconfiguredAction()", 2026-09-30). A `script` action returns `'OK'` on exit status 0 (`CORE/src/opnsense/service/modules/actions/script.py:40-46`), a `script_output` action returns the script's stdout. Maintainers (Monviech, fichtner): only `status` should be `script_output`. https://github.com/opnsense/plugins/issues/5778

### 1.6 Boot behaviour and dead setup script

- Enabled services are started at boot by `rc.syshook start` -> `start/20-freebsd` -> `/usr/local/etc/rc.freebsd start` (`CORE/src/etc/rc:243`, `CORE/src/etc/rc.syshook.d/start/20-freebsd:4`). `rc.freebsd` sources every file in `/etc/rc.conf.d` and runs each rc.d script whose `name=` + `${name}_enable` is YES (`CORE/src/etc/rc.freebsd:38-40, 87, 123-150`). This is AFTER `rc.bootup` has already run `interfaces_configure`, `system_routing_configure` and `filter_configure_sync` (`CORE/src/etc/rc.bootup:88-102`, `CORE/src/etc/rc:240-243`). At boot the rc script is called directly, so the `rc.routing_configure` of the configd action is not executed. [verified ordering; effect on assigned `nat64` gateways at boot: likely problematic, not tested]
- `setup.sh` is never executed: the rc.conf.d template sets `tayga_script=".../setup.sh"` (`templates/OPNsense/Tayga/tayga:2`), but rc.subr only honours `${name}_setup` (opnsense/src stable/26.7 `libexec/rc/rc.subr`: "`${name}_setup` n Command executed during start, restart and reload before `${rc_arg}_precmd` is run", function `_run_rc_setup`). Every other plugin uses `<name>_setup=` (e.g. `PLUGINS/databases/redis/src/opnsense/service/templates/OPNsense/Redis/redis:2`). Commit 596b876 ("net/tayga: use NAME_setup", 2022-10-21) renamed `tayga_var_script` to `tayga_script` and removed the explicit call from the configd action. Harmless because tayga itself creates a missing `data-dir` (`TAYGA/tayga.c:435-446`). [verified]

### 1.7 What the user must still do manually [verified from docs + code]

From https://docs.opnsense.org/manual/how-tos/tayga.html and the absence of any `_firewall` hook:
1. Firewall > Rules > **Tayga** tab: add a pass rule (IPv4+IPv6).
2. Firewall > NAT > Outbound: add a rule on WAN with source = the Tayga IPv4 pool.
3. DNS64 in Unbound; optionally PREF64 in Router Advertisements.
4. For "Custom IPv6 Routing": assign + lock `nat64`, enable dynamic gateway policy, create gateway and static routes (help text quoted in 1.3).

The plugin generates no pf rules and no NAT rules at all.

### 1.8 How routes are installed [verified]

Only by the rc script with `route(8)`, outside OPNsense's routing model (`opnsense-tayga:30-33`): `route -4 add <v4pool> -interface nat64` always; `route -6 add <v6prefix> -interface nat64` unless `v6routedisabled`. No default route, no gateway object, no `/tmp/<if>_router*` files, no static-route model entries. Routes disappear when the tun is destroyed on stop.

---

## 2. tayga.conf templating and model options

### 2.1 Templates [verified]

`+TARGETS` (`PLUGINS/.../templates/OPNsense/Tayga/+TARGETS:1-2`):

```
tayga:/etc/rc.conf.d/opnsense-tayga
tayga.conf:/usr/local/etc/tayga.conf
```

`tayga.conf` (Jinja2, `.../Tayga/tayga.conf:1-23`): hard-coded `tun-device nat64`, `data-dir /var/db/tayga`, `udp-cksum-mode fwd`, `wkpf-strict no`; then

```
ipv4-addr {{ OPNsense.tayga.general.v4address }}
{% if ... v6address != '' %}
ipv6-addr {{ OPNsense.tayga.general.v6address }}
{% endif %}
prefix {{ OPNsense.tayga.general.v6prefix }}
dynamic-pool {{ OPNsense.tayga.general.v4pool }}
...
{%   for mapping in helpers.toList('OPNsense.tayga.staticmapping.staticmappings.staticmapping') %}
{%     if mapping.enabled == '1' %}
map {{ mapping.v4 }} {{ mapping.v6 }}
```

`tayga` (rc.conf.d, `.../Tayga/tayga:1-17`): `tayga_enable`, `tayga_v4address`, `tayga_v4destination`, `tayga_v4pool`, `tayga_v6prefix`, `tayga_v6address` (unused by the rc script), `tayga_v6destination`, `tayga_v6routedisabled`.

Note: `/usr/local/etc/tayga.conf` is also the `@sample` target of the binary package (`PORTS/net/tayga/pkg-plist:1` `@sample etc/tayga.conf.example etc/tayga.conf`); os-tayga overwrites it.

### 2.2 Model fields [verified]

`General.xml` (`PLUGINS/.../models/OPNsense/Tayga/General.xml:1-43`, mount `//OPNsense/tayga/general`, version 1.3.0):

| Field | Type | Default | Meaning (form label) |
|---|---|---|---|
| `enabled` | BooleanField | 0 | Enable |
| `v4address` | NetworkField ipv4, required | 192.168.255.1 | `ipv4-addr` (Tayga's own IPv4) |
| `v4destination` | NetworkField ipv4, required | 192.168.254.1 | IPv4 address put on the tun (ifconfig local) |
| `v6address` | NetworkField ipv6, optional | empty | `ipv6-addr` |
| `v6destination` | NetworkField ipv6, required | 2001:db8:1:ffff::1 | IPv6 address put on the tun |
| `v6prefix` | NetworkField ipv6, required | 64:ff9b::/96 | `prefix` |
| `v4pool` | NetworkField ipv4, required | 192.168.255.0/24 | `dynamic-pool` (mandatory) |
| `v6routedisabled` | BooleanField | 0 | "Custom IPv6 Routing" |

`StaticMapping.xml` (`.../StaticMapping.xml:1-24`, mount `//OPNsense/tayga/staticmapping`): ArrayField `staticmappings.staticmapping` with `enabled`, `v4` (NetworkField ipv4), `v6` (NetworkField ipv6), `description`.

All address fields are literal NetworkFields; there is no InterfaceField, no "track interface / delegated prefix" option, no MTU, no logging option, no tun name. Open issue #5594 / PR #5705: the address fields accept a `/len` suffix that then breaks `ifconfig` / tayga (https://github.com/opnsense/plugins/issues/5594, https://github.com/opnsense/plugins/pull/5705).

---

## 3. Why os-tayga is not a CLAT, and coexistence of two tayga instances

### 3.1 What a tayga CLAT config looks like (upstream) [verified]

`TAYGA/docs/clat/clat-route.conf:2-10`:

```
tun-device clat
ipv4-addr 192.0.0.2
ipv6-addr 2001:db8:abcd::65
map 192.0.0.1 2001:db8:abcd::64
prefix 64:ff9b::/96
```

plus an IPv4 default route into the tun with reduced MTU and an IPv6 route for the translator addresses (`TAYGA/docs/clat/clat-masq.sh:15-21`: `ip addr add 192.0.0.1/29 dev clat`, `ip route add default dev clat mtu 1260`). README: "we require two addresses - one is used along with tayga's map directive to map IPv4 user traffic to IPv6, the other is used by tayga as its own address" (`TAYGA/docs/clat/README.md:7`).

### 3.2 Blockers in os-tayga 1.5 [verified unless tagged]

1. **Single instance**: one model node, one fixed conf path, one pidfile, one rc script, one configd namespace (see 3.3).
2. **Fixed tun name** `nat64` (`tayga.conf:3`, `opnsense-tayga:27-32,41`).
3. **Wrong IPv6 route for CLAT**: it routes the *translation prefix* into the tun (`route -6 add ${tayga_v6prefix} -interface nat64`). In a CLAT the pref64 must leave via WAN and only the CLAT's own /128s point at the tun. Disabling it with `v6routedisabled` leaves no route for the mapped CLAT address either.
4. **No IPv4 default route / gateway**: only `route -4 add ${tayga_v4pool}`. Nothing is offered to OPNsense's gateway/routing code; the only path is the manual "assign + lock + dynamic gateway policy" procedure. (Core does support an address-less interface gateway when the assigned interface has `gateway_interface` set: `CORE/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php:442-454`.)
5. **Static addresses only**: all fields literal; no way to derive the CLAT IPv6 source address from the WAN /64 or a delegated prefix.
6. **No dynamic prefix tracking**: no `tayga_configure()` hook, so nothing happens on `newwanip`/`updateip` (examples of plugins that do react: `PLUGINS/dns/rfc2136/src/etc/inc/plugins.inc.d/rfc2136.inc:32-40` -- `'newwanip' => ['rfc2136_configure_do:2']`; `PLUGINS/net/upnp/src/etc/inc/plugins.inc.d/miniupnpd.inc:115-116`). tayga 0.9.6 also has no config reload: SIGHUP terminates the process in 0.9.6; in master SIGHUP only reloads `map-file` and flushes the dynamic map (`TAYGA/tayga.c:113-122`). A prefix change therefore needs a daemon restart (tun destroyed and re-created by os-tayga's stop/start).
7. **Mandatory `dynamic-pool`** (`v4pool` required) and NAT64-oriented defaults/validation; `wkpf-strict no` and `udp-cksum-mode fwd` hard-coded.
8. **No MTU handling** (tun MTU, `offlink-mtu`), relevant behind PPPoE.
9. **No PREF64 discovery** (RA option / DNS64 `ipv4only.arpa`), prefix is typed in.
10. **Device not declared to core** (no `_devices`), boot ordering after interface/route/filter setup (1.6).
11. Currently broken Apply on 26.7.6 (#5778), dead setup hook, no log page.

Related closed request: #5338 "[Tayga] Adding support for NAT46" -- no maintainer response, timed out, closed "not planned" 2026-09-16, label "help wanted"; a user documented a workaround with static mappings + DNAT (https://github.com/opnsense/plugins/issues/5338). Static mappings themselves arrived via community PR #4986 after the feature request #4606 had also timed out (https://github.com/opnsense/plugins/issues/4606). A search of opnsense/plugins issues/PRs for "464xlat OR clat" returned 0 results on 2026-10-10 (https://github.com/opnsense/plugins/issues?q=464xlat+OR+clat).

### 3.3 Can a second tayga (CLAT) coexist with os-tayga?

tayga supports it [verified]: `-c|--config CONFIGFILE` and `-p|--pidfile PIDFILE` (`TAYGA/tayga.c:31-56`, same usage text at tag 0.9.6); upstream ships a multi-instance systemd template (`TAYGA/scripts/tayga@.service:6-14`); each instance opens its own cloned `/dev/tun` and renames it (3 lines quoted in 1.2).

Names already taken by os-tayga that a second plugin must NOT reuse [verified]:

| Resource | os-tayga value | Evidence |
|---|---|---|
| rc.d script | `/usr/local/etc/rc.d/opnsense-tayga`, `name=tayga`, `rcvar=tayga_enable` | `opnsense-tayga:3,9,13` |
| rc.conf.d file | `/etc/rc.conf.d/opnsense-tayga`, variables `tayga_*` | `+TARGETS:1`, template `tayga` |
| daemon config | `/usr/local/etc/tayga.conf` (also package `@sample` target) | `+TARGETS:2`, `PORTS/net/tayga/pkg-plist:1` |
| pidfile | `/var/run/tayga.pid` | `opnsense-tayga:16`, `tayga.inc:49` |
| tun device | `nat64` | `tayga.conf:3` |
| ifconfig group / interface key | `tayga` | `opnsense-tayga:29`, `tayga.inc:73,78` |
| data-dir | `/var/db/tayga` (contains fixed file name `dynamic.map`) | `tayga.conf:4`, `TAYGA/dynamic.c:23-24` |
| configd namespace | `tayga` (`actions_tayga.conf`) | file name / `tayga.inc:44-46` |
| legacy hook file / function prefix | `tayga.inc`, `tayga_*` | path |
| config.xml node | `//OPNsense/tayga/...` | `General.xml:2` |
| MVC namespace / URLs | `OPNsense\Tayga`, `/ui/tayga`, `/api/tayga` | controllers, `ACL.xml:5-6` |
| menu | `Services > Tayga` | `Menu.xml:1-5` |
| service name | `tayga` | `tayga.inc:48` |
| xmlrpc sync id | `taygavpn` | `tayga.inc:59` |

Residual shared things that cannot be separated by naming:
- **syslog ident** is hard-coded: `openlog("tayga", LOG_PID | LOG_NDELAY, LOG_DAEMON);` (`TAYGA/tayga.c:369`, identical in 0.9.6). Two instances are distinguishable only by PID unless the second runs with `--nodetach --stdout` under a wrapper that tags its output. [verified code; wrapper approach unverified]
- **process name** `/usr/local/sbin/tayga` is the same; rc.subr status works per pidfile, so separate pidfiles are sufficient. [likely]
- `rc.freebsd` keys enablement on the rc script's `name=` (`CORE/src/etc/rc.freebsd:93-129`), so a second rc script needs a different `name`.
- A CLAT instance needs no `data-dir` (no dynamic pool); tayga then just `chdir("/")` (`TAYGA/tayga.c:424-434`).

Conclusion: coexistence is technically possible if every item in the table is distinct. [likely -- not run-tested]

---

## 4. The modern OPNsense plugin skeleton

### 4.1 Directory layout [verified]

```
<category>/<plugin>/
  Makefile                       PLUGIN_* variables + .include "../../Mk/plugins.mk"
  pkg-descr                      description (+ WWW:/DOC: lines, "Plugin Changelog")
  +PRE_INSTALL[.pre|.post] +POST_INSTALL[...] +PRE_DEINSTALL[...] +POST_DEINSTALL[...]   (optional)
  src/                           copied 1:1 under /usr/local
    etc/inc/plugins.inc.d/<name>.inc        legacy hooks
    etc/rc.d/<script>                       optional own rc script (must be +x)
    etc/rc.syshook.d/<level>/NN-name        optional syshooks (early,start,stop,carp,monitor,...)
    etc/rc.loader.d/...                     optional loader.conf fragments
    etc/pkg/repos/*.conf.shadow[.in], etc/pkg/fingerprints/...   (vendor repo plugins)
    opnsense/mvc/app/controllers/OPNsense/<Ns>/{IndexController,Api/*Controller}.php, forms/*.xml
    opnsense/mvc/app/models/OPNsense/<Ns>/{<Model>.php,<Model>.xml,ACL/ACL.xml,Menu/Menu.xml,Migrations/M*.php}
    opnsense/mvc/app/views/OPNsense/<Ns>/*.volt
    opnsense/scripts/<...>                  backend scripts (must be +x)
    opnsense/service/conf/actions.d/actions_<name>.conf
    opnsense/service/templates/OPNsense/<Ns>/{+TARGETS,<templates>}
    opnsense/service/templates/OPNsense/Syslog/local/<name>.conf   (log viewer registration)
    opnsense/scripts/firmware/repos/<Repo>.php                     (vendor repo plugins)
    opnsense/mvc/tests/                     optional phpunit tests (TESTDIR)
```

Reference small modern plugin: `PLUGINS/net/ndp-proxy-go` (19 files, v1.5, 2025-2026).

### 4.2 Makefile variables (`PLUGINS/Mk/plugins.mk`, `defaults.mk`) [verified]

- Required: `PLUGIN_NAME`, `PLUGIN_VERSION`, `PLUGIN_COMMENT` (`plugins.mk:51`).
- Optional with defaults (`plugins.mk:45-49`): `PLUGIN_WWW?=https://opnsense.org/`, `PLUGIN_MAINTAINER?=N/A`, `PLUGIN_LICENSE?=BSD2CLAUSE`, `PLUGIN_TIER?=3`, `PLUGIN_REVISION?=0`.
- Others: `PLUGIN_DEPENDS` (package names; must be installed on the build host, `plugins.mk:140-150, 316-318`), `PLUGIN_CONFLICTS`, `PLUGIN_VARIANTS`, `PLUGIN_NO_ABI` (emit wildcard `abi: "FreeBSD:*:*"`, `plugins.mk:136-139`; used by themes), `PLUGIN_DEVEL`, `PLUGIN_OBSOLETE`, `PLUGIN_PREFIX?=os-`, `PLUGIN_SUFFIX?=-devel` (`plugins.mk:74-75`).
- Package name `os-<name>[-devel]` (`plugins.mk:116`); manifest `origin: opnsense/<pkgname>`, `categories: [ "<parent dir>" ]` (`plugins.mk:125-135`); annotations = contents of `/usr/local/opnsense/version/<name>` (`plugins.mk:151-153`) generated from `Templates/version` (`product_abi`, `product_arch`, `product_conflicts`, `product_email`, `product_hash`, `product_id`, `product_name`, `product_tier`, `product_version`, `product_website`).
- `PLUGIN_ABI` = `opnsense-version -a` if available, else default `26.7` (`defaults.mk:45-54`).
- Development mode: `Mk/devel.mk` ("This file merely exists on the development branch to force plugins to development mode: `PLUGIN_DEVEL?= yes`", `devel.mk:26-28`) is included unless `_PLUGIN_DEVEL` is defined (`plugins.mk:68-72`); in devel mode the package is `os-<name>-devel` and `PLUGIN_TIER=4` (`plugins.mk:105-112`).
- Substitution `%%PLUGIN_ABI%%` etc. in `*.in` files and in package scripts (`defaults.mk:81-97`, `plugins.mk:247-251`). `*.shadow` files are installed as `*.sample` with keyword `@shadow` (copy to target if missing, delete on deinstall; `plugins.mk:252-255, 271-276`, `PLUGINS/Keywords/shadow.ucl`).

### 4.3 Package scripts (`plugins.mk:155-239`) [verified]

Auto-generated `+POST_INSTALL` content, depending on which `src/` directories exist:
- `actions.d` present -> `if [ -f /usr/local/etc/rc.d/configd ]; then /usr/local/etc/rc.d/configd restart; fi` (`PLUGINS/Templates/actions.d`)
- per model dir (depth 2 under `models/`) -> `/usr/local/opnsense/mvc/script/run_migrations.php OPNsense/<Ns>` (`Templates/models`), then `/usr/local/etc/rc.configure_plugins POST_INSTALL` (also `POST_DEINSTALL` in `+POST_DEINSTALL`; `Templates/configure`). `rc.configure_plugins` flushes the menu/ACL caches and, on POST_INSTALL, restarts syslog (`CORE/src/etc/rc.configure_plugins:41-49`).
- per template dir (depth 2) -> `/usr/local/sbin/configctl template reload OPNsense/<Ns>` (`Templates/templates`)
- `rc.loader.d` present -> `/usr/local/etc/rc.configure_firmware`
- `rc.syshook.d/*.early|*.start` files are executed once at install
- `opnsense/scripts/firmware/repos/*` files are executed at install (`plugins.mk:218-223`)
- `<script>.pre` / `<script>.post` files extend the auto content; a bare `+POST_INSTALL` file replaces it entirely ("manual", `plugins.mk:155-165`). Examples: `PLUGINS/security/crowdsec/+POST_INSTALL.post` (`configctl crowdsec reconfigure`), `PLUGINS/security/crowdsec/+PRE_DEINSTALL.pre` (stops a service before removal).

os-tayga has none of the optional files, so nothing stops the daemon or destroys `nat64` on package removal. [verified absence; consequence likely]

### 4.4 Model / forms / controllers / view [verified]

- Model XML: `<model><mount>//OPNsense/x</mount><description>one line</description><version>1.1</version><items>...` (`PLUGINS/net/ndp-proxy-go/.../NdpProxy.xml:1-5`). Field types used there: `BooleanField`, `InterfaceField` (with `<Multiple>Y`), `IntegerField`, `NetworkField` (`NetMaskRequired`, `NetMaskAllowed`, `AddressFamily`, `AsList`, `Strict`), `ArrayField`, `ModelRelationField`, `DescriptionField`.
- Model PHP: `class X extends BaseModel`, optional cross-field validation by overriding `performValidation()` (`.../NdpProxy/NdpProxy.php:36-59`).
- Migrations: `models/OPNsense/<Ns>/Migrations/M1_0_5.php`, `class M1_0_5 extends BaseModelMigration { public function run($model) {...} }` (`PLUGINS/net/relayd/.../Migrations/M1_0_5.php:29-43`); executed by `run_migrations.php` from `+POST_INSTALL`.
- API model controller: `ApiMutableModelControllerBase` with `$internalModelName`, `$internalModelClass`; grid helpers `searchBase/getBase/addBase/setBase/delBase/toggleBase` (`PLUGINS/net/tayga/.../Api/MappingController.php:33-66`).
- API service controller: `ApiMutableServiceControllerBase` with `$internalServiceClass`, `$internalServiceTemplate`, `$internalServiceEnabled`, `$internalServiceName` (`PLUGINS/net/ndp-proxy-go/.../Api/ServiceController.php:35-41`). Provides `start/stop/restart/reconfigure/status`. `reconfigureAction()` = stop -> optional `invokeInterfaceRegistration()` -> optional `invokeFirewallReload()` (`filter reload skip_alias`) -> `template reload` -> start/reload; hooks `reconfigureForceRestart()`, `invokeInterfaceRegistration()`, `invokeFirewallReload()` are overridable (`CORE/.../Base/ApiMutableServiceControllerBase.php:147-166, 186-233`). `statusAction()` parses "is running"/"not running" from `<service> status` output (`:240-257`).
- UI controller: `extends IndexController`, `$this->view->x = $this->getForm('general')`, `getFormGrid(...)`, `$this->view->pick('OPNsense/<Ns>/general')` (`.../NdpProxy/GeneralController.php:35-44`).
- Forms XML: `<field><id>model.path</id><label/><type>checkbox|text|dropdown|select_multiple|header|subheader</type><help/><advanced>true</advanced><hint/><style>tokenize</style><allownew>true</allownew>` (`.../NdpProxy/forms/general.xml`).
- Volt: `partial('layout_partials/base_form', ...)`, `base_bootgrid_table`, `base_dialog`, `base_apply_button` with `data_endpoint` + `data_service_widget`; JS `mapDataToFormUI`, `saveFormToEndpoint` inside `SimpleActionButton.onPreAction`, `UIBootgrid`, `updateServiceControlUI('<service>')` (`.../NdpProxy/general.volt:28-80`).
- Menu: `<menu><Services><ndpproxy VisibleName="NDP Proxy" cssClass="fa fa-bullseye fa-fw"><Settings order="10" url="/ui/ndpproxy/general"/><Log VisibleName="Log File" order="20" url="/ui/diagnostics/log/core/ndpproxy"/>` (`.../NdpProxy/Menu/Menu.xml:1-8`).
- ACL: `<acl><page-...><name/><patterns><pattern>ui/x/*</pattern><pattern>api/x/*</pattern>` plus a separate privilege for the log page (`.../NdpProxy/ACL/ACL.xml:1-17`).

### 4.5 configd actions, templates, rc.d [verified]

- Actions (`.../actions_ndpproxy.conf:1-25`): `[start]`/`[stop]`/`[restart]` are `type:script`, only `[status]` is `type:script_output` with `errors:no`. This is the form that works with the 26.7.6 `'OK'` check (1.5).
- Templates: `+TARGETS` lines `template:absolute/target` (`.../NdpProxy/+TARGETS:1`); Jinja2 with `helpers.getNodeByTag`, `helpers.exists`, `helpers.toList`, `helpers.physical_interface(<interface key>)`, `helpers.getUUID` (`.../NdpProxy/ndp_proxy_go:2-64`).
- rc.d: either the port's script driven by a generated `/etc/rc.conf.d/<name>` (ndp-proxy-go) or a plugin-owned script under `src/etc/rc.d/` (os-tayga). Pre-start hook = `<name>_setup="..."` in the rc.conf.d file (rc.subr feature, 1.6).

### 4.6 Log viewer registration [verified]

A file `src/opnsense/service/templates/OPNsense/Syslog/local/<name>.conf` containing only a filter named `f_local_<name>` (`PLUGINS/net/ndp-proxy-go/.../Syslog/local/ndpproxy.conf:4-6`: `filter f_local_ndpproxy { program("ndpproxy"); };`). Core globs these and writes `/var/log/<name>/<name>_YYYYMMDD.log` (`CORE/src/opnsense/service/templates/OPNsense/Syslog/syslog-ng-local.conf:7-29`, rules in `.../Syslog/local/README`). Menu entry `url="/ui/diagnostics/log/core/<name>"` + ACL patterns `ui/diagnostics/log/core/<name>/*`, `api/diagnostics/log/core/<name>/*`. The `_syslog()` legacy hook is only for remote-logging application lists (`CORE/src/etc/inc/plugins.inc:148-171`).

### 4.7 Legacy hook file (`plugins.inc.d/<name>.inc`) [verified]

Dispatcher: `CORE/src/etc/inc/plugins.inc`. Hooks: `_services` (:69), `_devices` (:94), `_cron` (:127), `_syslog` (:152), `_interfaces` (:178), `_firewall` (:244), `_configure` (:261), `_run` (:337), `_xmlrpc_sync` (:372). The file name must not equal any `/usr/local/etc/inc/<name>.inc|.class` or the plugin is silently skipped (`plugins.inc:51-62`). `_configure` returns `event => ['function[:argc]']` (`plugins.inc:293-327`). HA sync hook returns `id`, `section`, `description`, `services` (`plugins.inc:372-400`; example `PLUGINS/net/ndp-proxy-go/.../ndpproxy.inc:54-66`).

CARP syshook example: `PLUGINS/net/ndp-proxy-go/src/etc/rc.syshook.d/carp/20-ndpproxy` (PHP script reacting to MASTER/BACKUP).

### 4.8 Tests [verified]

`make test` runs `phpunit` in `src/opnsense/mvc/tests` if it exists (`plugins.mk:361-365`, `defaults.mk:103`). No plugin in the current tree ships a `tests/` directory (glob `**/tests/**` over `PLUGINS` returned nothing).

---

## 5. Building and distributing outside the official repository

### 5.1 Building [verified from Makefiles; workflow likely]

- `make package` in the plugin dir: installs missing `PLUGIN_DEPENDS` with `pkg install -yA`, stages `src/` into `work/src/usr/local`, generates `+MANIFEST`, `+DESC`, scripts and `plist`, then `pkg create -v -m work/src -r work/src -p work/src/plist -o work/pkg` (`plugins.mk:313-329`). Result: `work/pkg/os-<name>-<version>.pkg`. `make upgrade` additionally removes the installed package and `pkg add`s the new one (`plugins.mk:334-340`).
- Unless `PLUGIN_NO_ABI` is set the manifest carries no `abi`/`arch`, so `pkg create` stamps the build host's ABI (`plugins.mk:136-139`). The official repo URL is `https://pkg.opnsense.org/${ABI}/26.7/latest` (`CORE/src/etc/pkg/repos/OPNsense.conf.shadow.in:3`, `CORE/Mk/version.mk:26,39`); `${ABI}` is expanded by pkg (26.7 is FreeBSD 15 based; tools README: "Install FreeBSD 15.1 RELEASE for amd64", https://raw.githubusercontent.com/opnsense/tools/master/README.md).
- `make lint|style|sweep` need the core repository checked out as a sibling directory: `.-include "${PLUGINSDIR}/../core/Mk/lint.mk"` (`PLUGINS/Mk/lint.mk:26`, `style.mk:28`, `sweep.mk:26`, `common.mk:26`).
- `PLUGINSDIR?= ${.CURDIR}/../..` (`plugins.mk:26`); `Templates/`, `Scripts/`, `Keywords/` of the plugins repo are required (`defaults.mk:37-40`, `plugins.mk:328` `PORTSDIR=${PLUGINSDIR}` for the `@shadow` keyword).
- Building from plugins `master` yields `os-<name>-devel` (4.2). The firmware GUI hides remote `-devel` plugins on non-devel systems (`CORE/.../Core/Api/FirmwareController.php:870-880`: `$type == 'remote' && ($devel || end($plugin) != 'devel')`).
- Full builder alternative: opnsense/tools `make plugins PLUGINSLIST="devel/debug"`, signing with `PRIVKEY`/`PUBKEY`, `make sign-...`, `make fingerprint` (tools README).
- The `tayga` binary package is part of the official 26.7 package set (`net/tayga` in https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/ports.conf), so a third-party plugin can simply depend on it. `net/tayga` and `net/ndp-proxy-go` are in `config/26.7/plugins.conf`.

### 5.2 pkg repository and trust [verified]

In-tree vendor example `PLUGINS/vendor/sunnyvalley` (tier 2 "repo plugin"):

`src/etc/pkg/repos/SunnyValley.conf.shadow.in:1-7`
```
SunnyValley: {
  fingerprints: "/usr/local/etc/pkg/fingerprints/SunnyValley",
  url: "https://updates.zenarmor.net/opnsense/${ABI}/%%PLUGIN_ABI%%/latest",
  signature_type: "fingerprints",
  priority: 7,
  enabled: yes
}
```
`src/etc/pkg/fingerprints/SunnyValley/trusted/updates.sunnyvalley.org.20190702:1-2`
```
function: "sha256"
fingerprint: "eb6b99a1..."
```
plus `revoked/.placeholder` and `src/opnsense/scripts/firmware/repos/SunnyValley.php` which regenerates the live `.conf` from the `.sample` (`SunnyValley.php:32-47`). Core runs every executable in `/usr/local/opnsense/scripts/firmware/repos/` when writing firmware settings (`CORE/src/etc/inc/system.inc:857-880`; `CORE/src/opnsense/scripts/firmware/repos/README`: "Repository-based scripts live here to be provided by plugins").

Official repo for comparison: priority 11, `signature_type: "fingerprints"` (`CORE/src/etc/pkg/repos/OPNsense.conf.shadow.in:1-7`).

Community example (mimugmail), unsigned (https://www.routerperformance.net/mimugmail.conf, install instructions https://www.routerperformance.net/opnsense-repo/):
```
mimugmail: {
  url: "https://opn-repo.routerperformance.net/repo/${ABI}",
  priority: 5,
  enabled: yes
}
```
installed with `fetch -o /usr/local/etc/pkg/repos/mimugmail.conf https://www.routerperformance.net/mimugmail.conf`, then "System : Firmware : Plugins and check for updates". Package names there carry a suffix (`os-adguardhome-maxit`, `os-speedtest-community`).

Signing mechanics (pkg-repo(8), https://man.freebsd.org/cgi/man.cgi?query=pkg-repo&sektion=8): `pkg repo <repo-path> [rsa:<keyfile> | signing_command: <cmd>]`; the signing command gets the catalogue SHA256 on stdin and prints `SIGNATURE ... CERT ... END`; client uses `signature_type: "fingerprints"`; fingerprint = `sha256 -q repo.pub`, stored as `function: sha256` / `fingerprint: "..."` in `<fingerprints>/trusted/`. OPNsense's own builder calls `pkg repo <dir> signing_command: ${PRODUCT_SIGNCMD}` with `scripts/pkg_sign.sh <pub> <priv>` (https://raw.githubusercontent.com/opnsense/tools/master/build/common.sh).

### 5.3 How the plugin appears in System > Firmware > Plugins [verified]

- Package lists come from all enabled repos: `pkg rquery -U "%n|||%v|||%c|||%sh|||0|||0|||%L|||%R|||%o"` and local `pkg query ...` (`CORE/src/opnsense/scripts/firmware/query.sh:55-58`).
- A package is a "plugin" iff its name starts with `os-` (`FirmwareController.php:870-880`).
- Tier column: forced to `4` unless the repository is `OPNsense` or `SunnyValley` (`FirmwareController.php:915-922`: "for any community repository, orphaned package or otherwise unknown force the lowest tier" / `in_array($plugin['repository'], ['OPNsense', 'SunnyValley'])`).
- The list initially shows only tier 1/2 or installed/configured plugins; others are behind "Click to view the community plugins." (`CORE/src/opnsense/mvc/app/views/OPNsense/Core/firmware.volt:446-448, 478-488`). The repository name is shown in its own column (`firmware.volt:455`).
- Install from GUI = `pkg install -y <name>` + `register.php install <name>` (`CORE/src/opnsense/scripts/firmware/install.sh:34-48`); for `os-*` packages the install is refused when the core package is out of date ("Installation out of date. The update to ... is required.", `install.sh:34-44`).
- `register.php` records the plugin in `config.xml` `system.firmware.plugins` if `/usr/local/opnsense/version/<name>` exists with a `product_id` (`CORE/src/opnsense/scripts/firmware/register.php:79-133, 139-145`). Recorded-but-absent plugins show as "missing", installed-but-not-in-any-repo as "orphaned" (`firmware.volt:426-441`).
- Update check runs `pkg update -f` over all repos and greps the combined output for `Unable to update repository`, `No signature found`, `No trusted public keys found` etc. (`CORE/src/opnsense/scripts/firmware/check.sh:109, 124-176`). [verified code; that an unreachable third-party repo degrades the whole update check: likely]
- `hostnames.sh` matches repo names against `<Repo>.conf` file names (`CORE/src/opnsense/scripts/firmware/hostnames.sh:32-53`), so the conf file should be named after the repo.
- On a series change the check forces reinstall of all packages (`check.sh:88-90` `force_all="-f"` when `opnsense-version -x` differs from `-a`).

---

## 6. Upstreaming to opnsense/plugins

`PLUGINS/CONTRIBUTING.md` [verified]:

Pull requests (`:44-49`):
- "Base your code on the latest master branch to avoid manual merges"
- "Pull request must adhere to 2-Clause BSD licensing"

New plugins (`:54-62`):
- "Open an issue first to explain what you want to work on and give it time for discussion"
- "If you are integrating a service binary it should at least be available in FreeBSD ports"
- "Precompiled binaries in the plugins are not allowed"
- "Plugins should almost always focus on integrating an existing service and providing MVC/API GUI pages for it"
- "It is not possible to review and integrate plugins with a large initial codebase"
- "If you use AI tools in your submission please disclose their use (name and model)"
- "Even though you are the maintainer you effectively force burden of maintainership to the community and OPNsense developers as soon as you open your first PR"

PR template (`PLUGINS/.github/pull_request_template.md:5-12`) repeats: guidelines read, issue opened first for non-trivial changes, AI disclosure (model + extent).

README (`PLUGINS/README.md:143-145`): "Commits for individual plugins should therefore be split into individual chunks for each src/ directory". Commit subject convention seen in history: `net/tayga: <summary>` (also produced by `make commit`, `plugins.mk:367-370`).

Tiers (https://docs.opnsense.org/support.html): Tier 1 critical/core; Tier 2 supplemental, core team supported; Tier 3 "community supported ... Submitter must commit to maintaining it", "The feature will be removed if the submitter stops maintaining it and no-one steps up to take over"; promotion to tier 2 requires usability, maintainability, documentation. `PLUGIN_TIER?= 3` is the default; `net/tayga` is listed tier 3, `net/frr` tier 2. Stale issues time out after 180 days (seen on #5338, #4606).

License headers: every PHP/volt/inc file carries the 2-clause BSD text with a `Copyright (C) <year> <holder>` line (e.g. `tayga.inc:3-27`); `Scripts/license` collects them into `LICENSE` (`PLUGINS/Scripts/license:63-124`).

Lint/style (`CORE/Mk/lint.mk`, `style.mk`, `sweep.mk`), all run per plugin dir:
- `make lint` = `lint-plist lint-desc lint-shell lint-xml lint-model lint-acl lint-class lint-import lint-exec lint-php` (`lint.mk:163`): `pkg-descr` must exist; `*.sh` need a shebang and pass `sh -n`; all `*.xml*` pass `xmllint`; model rules (single-line `<description>`, no `Default` on non-required fields, no `Required=N`/`Multiple=N`, `ValidationMessage` starts uppercase and ends with a dot, ...; `lint.mk:52-109`); files in `src/etc/rc.d`, `src/etc/rc.syshook.d` and `src/opnsense/scripts/*` must be executable (`lint.mk:122-130`); `exec(`/`shell_exec(`/`passthru(`/`system(` are grepped (`lint.mk:133-138`); PHP parallel-lint.
- `make style` = pycodestyle (`--ignore=E501`) + `phpcs --standard=<core>/ruleset.xml` on `src/etc/inc` and `src/opnsense` (`style.mk:26-52`).
- `make sweep` = whitespace cleanup, model XML re-format (`xmllint --format`, 4 spaces), `phpcbf` (`sweep.mk:26-66`).
- `make revision` bumps `PLUGIN_REVISION` (`plugins.mk:358-359`); changelog goes into `pkg-descr`.

Core absorbs plugins by listing them as conflicts: `CORE_CONFLICTS?=firewall wireguard wireguard-go` with comment "plugins that were migrated to core are here" (`CORE/Mk/version.mk:33-34`).
