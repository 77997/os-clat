# os-clat: 464XLAT CLAT for OPNsense — design

Status: v0.16, 2026-10-13. Reviewed twice (see section 17); v0.4 to v0.8 add facts about the ISP's network and the decisions of section 16. Of those, only the DNS behaviour behind section 5.2 has been checked against the source (`docs/research/dns-default-behaviour.md`). v0.9 records three details settled during implementation (sections 5.4, 6 and 9). v0.10 records what the first lab run changed and measured (sections 5.1, 6, 8.3, 9, 10, 11, 12, 14, 15 and 16). v0.11 adds what the lab measured with the ISP simulated as its public setup guide describes it (section 16); it changed nothing in the design. v0.12 adds the first run of the package and of a signed repository in the lab (sections 14 and 16) and one more step of the deinstall script. v0.13 corrects the size test (section 10: a limit that only silence marks is never reported as ok) and makes two passages say what was measured and built (sections 5.2 and 14). v0.14 adds the runs with PPPoE on the tagged VLAN 40 (sections 8.3 and 16); they changed nothing in the design. v0.15 adds what the GUI showed when its buttons were pressed in a browser (sections 7.2, 7.6 and 15) and one change of the plugin's page that came out of it. v0.16 moves the ISP repository to the custom domain `os-pkg.gettuckamore.ca` (section 14), before any router stored an address. The implementation is in `net/clat/`; `docs/implementation-spec.md` is the contract it was written to.
Basis: OPNsense 26.7.6 (FreeBSD 15.1 base), opnsense/core master, tayga 0.9.6, OpenWrt main.
Evidence level: the design comes from reading source code, RFCs and public reports; the research reports behind each statement are in `docs/research/`. Since 2026-10-12 the plugin has run on OPNsense 26.7.6 in a Hyper-V lab behind a simulated ISP (`lab/README.md`; every result and change is in `lab/.work/results/changes.md`). Where a statement below says "measured" or "in the lab", it was observed there. Nothing has run on the ISP's own network or on customer hardware yet.

## 1. Goal, inputs and constraints

Customers of an ISP whose PPPoE negotiates IPv6CP only (no IPCP) install one plugin on OPNsense and their LAN devices get transparent IPv4 through the ISP's NAT64 (PLAT).

Facts about the ISP network:

| Fact | Consequence |
|---|---|
| PPPoE with IPv6CP only | no native IPv4 on the uplink; WAN "IPv4 Configuration Type" must be None |
| DHCPv6-PD is always provided | the CLAT IPv6 address always comes from the delegated prefix |
| The WAN may or may not have a SLAAC address | the datapath never depends on a global address on the WAN |
| NAT64 prefix is `64:ff9b::/96`, announced by RA and/or DNS | the plugin discovers it; it never assumes it |
| PPPoE supports jumbo payloads (RFC 4638), and the BNG echoes the client's PPP-Max-Payload value | the MTU logic follows the link; a PPPoE MTU of 1500 (WAN MTU field 1508) holds on stock 26.7, and 1500-byte IPv4 is possible once core asks for a PPP MTU of 1520 (section 8.3) |
| The delegated prefix is a /56, but the customer can request another size | the length is read from the live delegation, never assumed; a single /64 must work too |
| Resolvers are announced by RA or set by hand in OPNsense (for example Google's public DNS64) | DNS discovery goes through the system's resolver and follows its answer; upstream servers are not queried directly (section 5.2) |
| A line may offer PREF64 in the RA, DNS64 on the announced resolvers, or neither | with PREF64 no customer step is needed; otherwise one documented step in OPNsense (section 11) |
| IPv4 traffic leaves through the ISP's NAT64 (PLAT) | its ICMP and fragment behaviour are lab items (section 15) |

Requirements:

- Follow OpenWrt's 464xlat model: a virtual WAN interface for the CLAT, with routing and NAT done by the normal router machinery.
- Activate automatically when a NAT64 prefix is discovered from RA (PREF64, RFC 8781) and/or DNS (RFC 7050). No manual "turn it on" step.
- Do not own pf firewall rules where it can be avoided, because core is moving toward firewall-native translation (`af-to`, opnsense/core#10638).
- Work on stock 26.7 with packages that already exist in the OPNsense repository.

## 2. Findings that shape the design

1. **The open PR is not a CLAT.** opnsense/core#10638 adds `af-to` as an option on inbound filter rules with two literal fields. It has no prefix discovery, address selection, interface or gateway, and gives the firewall itself no IPv4. It has no milestone; "27.1" is a maintainer comment. The IPv4-to-IPv6 direction is expected to break under OPNsense's default shared forwarding. The plugin must be complete without it.
2. **tayga on a tun device is the only datapath that yields an interface today.** tayga 0.9.6 is in the 26.7 package set. `ipfw nat64clat` has no interface and core flushes ipfw on every filter reload. Jool, nat46 and clatd are Linux-only.
3. **Core treats a plugin tun as an IPv4 WAN without plugin NAT rules.** An enabled, non-virtual interface record, an IPv4 address on the device and a router file written with `ifctl` are enough. Core then creates a dynamic gateway, installs the default route and generates automatic outbound NAT.
4. **One firewall rule is unavoidable with any tun translator.** tayga writes the translated IPv6 packet back into the tun, so pf sees it as new inbound traffic on the tun. Core has no rule that passes it and no skip mechanism a plugin can use.
5. **Core raises no event for several changes the CLAT depends on:** loss of the PPP session, loss of native IPv4, RA-only changes. With DHCPv6 on the WAN, a reconnect and a changed delegated prefix do raise `newwanip`.
6. **WAN IPv4 type must be None.** With IPv4 = PPPoE and no IPCP, core never starts the IPv6 clients, so IPv6 never comes up. The setup wizard produces IPv4 = PPPoE. Maintainers closed this as not planned (core#9153).
7. **Nothing on OPNsense reads the RA PREF64 option.** The plugin parses it itself.
8. **On stock 26.7 the one jumbo setting that holds is WAN MTU 1508, a PPPoE MTU of 1500.** With 1528 OPNsense sends no PPP-Max-Payload tag at all: the session is 1492 while `pppoe0` shows 1520 (measured, section 8.3).

## 3. Architecture

```
                 ┌──────────────────────── OPNsense ────────────────────────┐
 LAN host        │  lan            tun464 "CLAT" (virtual WAN)       pppoe0 │        ISP
 192.168.1.10 ──►│──┐   default via 192.0.0.2                               │
                 │  └─► pf out on tun464: automatic outbound NAT            │
                 │        192.168.1.10 → 192.0.0.1          (core rule)     │
                 │      tun464 ─► tayga: 192.0.0.1 → CLAT6                  │
                 │                       dst a.b.c.d → pref64::a.b.c.d      │
                 │      tayga ─► tun464, pf in on tun464 inet6: pass        │
                 │                                   (the one plugin rule)  │
                 │      default6 via pppoe0, pf out: core "pass out" ───────│──► PLAT (NAT64) ──► IPv4
                 │                                                          │
                 │  return: pppoe0 in (state) → route CLAT6/127 → tun464    │
                 │          → tayga 6→4 → tun464 in (NAT44 state) → lan     │
                 └──────────────────────────────────────────────────────────┘
```

| Part | What it is | Owns |
|---|---|---|
| Translator | `tayga` 0.9.6 from the OPNsense repository, an unprivileged foreground child of the supervisor | stateless IPv4/IPv6 translation of one address pair |
| Supervisor | `clatd`, a small Python daemon shipped by the plugin (rc.d service `clat`) | discovery, the activation decision, the tun's addresses and routes, the router file, tayga's config and process |
| Core glue | `clat.inc` hooks, MVC model, API, UI | interface registration, the one pass rule, the MSS key, service and log registration, settings |

The translation model is OpenWrt's: stateful NAT44 to one address (192.0.0.1), then stateless 1:1 translation of that address to one IPv6 /128. RFC 8585 (464XLAT-1) and draft-ietf-v6ops-claton section 6.2.1 option (b) sanction it.

## 4. Decisions

| # | Decision | Choice | Main alternative and why not |
|---|---|---|---|
| D1 | Datapath | tayga 0.9.6 on a tun | pf `af-to`: no interface, broken with shared forwarding. ipfw nat64clat: no interface, core flushes ipfw |
| D2 | Device | Persistent `tun464`, created by the plugin, shown as "CLAT" | A custom name (`clat0`): tayga then clones and renames at each start, reads MTU 1500 before it can be set, and a stale interface blocks the next start. os-openconnect uses the same fixed-high-unit pattern (`tun30000`) |
| D3 | Interface record | Registered by `clat_interfaces()` as a non-virtual interface with key `clat` (core's IPsec VTI is the precedent) | User-assigned `optN`: four manual steps, and on 26.7.6 the Assignments page breaks it (core#10996). Plugin-created `optN`: no precedent, no stable id. Virtual group (os-tayga): cannot carry a gateway |
| D4 | Gateway and default route | Router file via `ifctl -i tun464 -4rd -a 192.0.0.2`; core derives gateway `CLAT_GW` and the default route | Plugin-written gateway item or `route add default`: fights core |
| D5 | NAT44 | Core's automatic outbound NAT (automatic or hybrid mode). In manual or disabled mode the CLAT does not activate unless the user confirms they manage NAT themselves | Plugin NAT rule or anchor: violates the constraint and double-translates |
| D6 | IPv6 pass rule | One address-less rule from `clat_firewall()`, priority 1, quick, with a setting to turn it off | Rule seeded into the user's rule set: leaves residue, can be shadowed. Manual rule: a guaranteed support ticket. Source bound to a pf table: see section 16 |
| D7 | TCP MSS | Interface `mss` key, computed from configuration only; core generates the clamp | Plugin scrub rule: a firewall rule. Route MTU: ignored by OPNsense's forwarding path. Live MTU in the hook: rewrites config.xml at every boot |
| D8 | Lifecycle | Supervisor daemon: listens for RAs and routing-socket events, converges on a desired state | Hooks plus a per-minute cron: see section 16 |
| D9 | NAT64 prefix | Static override, else RA PREF64, else RFC 7050 through the system's resolver; all six RFC 6052 lengths; never assumed | OpenWrt's single unvalidated `ipv4only.arpa` lookup with a hard-coded /96 and endless 3 s retries |
| D10 | CLAT IPv6 address | Route-only /127 pair in the delegated prefix | Configuring it on an interface: FreeBSD would deliver the PLAT's replies locally instead of forwarding them to tayga. WAN /64: depends on how the BNG handles neighbour discovery |
| D11 | Native IPv4 | The CLAT stays down while the box has a native IPv4 WAN gateway (section 5.3) | Always on: `CLAT_GW` gets priority 254 and would take the default route from most other gateways. OpenWrt makes the CLAT the least preferred route (metric 2048); core cannot express that without a gateway entry in config.xml |

## 5. Activation

### 5.1 Rule

The plugin ships enabled, in mode **Automatic**, so installing it is the only step on a box that meets the preconditions in section 11. The CLAT is active exactly while all of these hold:

1. Mode is Automatic.
2. The uplink has usable IPv6: an IPv6 default route on a device that is up, and a delegated prefix confirmed for the current session (section 6). The route alone is not enough: when a PPP session is lost, OPNsense keeps the route on a device that is down.
3. A NAT64 prefix is selected (section 5.2).
4. The box has no native IPv4 (section 5.3).
5. Preflight passes (section 10).

This follows draft-ietf-v6ops-claton section 4 (enable as soon as a prefix is known and there is no native IPv4, without waiting for DHCP) and section 5 (disable immediately when native IPv4 appears; preferring the CLAT over native IPv4 must be explicit configuration).

Activation and deactivation are runtime changes only: tun addresses, the router file, tayga. They never write `config.xml`.

### 5.2 NAT64 prefix discovery

Order: static override, then RA, then DNS. One source at a time. A customer line may offer PREF64, DNS64 on the announced resolvers, or neither. With PREF64 nothing needs configuring. Without it, one documented step in OPNsense supplies a source (section 11).

**RA PREF64 (RFC 8781).** The supervisor keeps one raw ICMPv6 socket (Python standard library) filtered to type 134.

- FreeBSD cannot bind such a socket to a device; it receives RAs from every interface. An RA is accepted only if the receiving interface is the uplink, the hop limit is 255, the source is link-local and the sender is the uplink's default router. Without the interface check any LAN host could hand the box a NAT64 prefix. The interface is matched by name: the index that the kernel reports with a packet is turned into a name each time, and no index is remembered, because `pppoeN` is not one device for the life of the box. Measured on 26.7.6: a redial by mpd5 keeps the device and its index; when core sets the PPP device up again (Apply on the WAN) it is a new device of the same name, and in the lab it had the index of the old one afterwards.
- Option 38: lifetime = field & 0xFFF8, prefix length code = field & 7 (/96, /64, /56, /48, /40, /32). Ignored unless its length is 2 and the code is 0 to 5. Lifetime 0 withdraws the prefix; an RA without the option does not.
- The supervisor sends one burst of Router Solicitations (at most three, four seconds apart, stopping at the first accepted RA) at every uplink attach. An attach is any of: a new IPv6 default route appears; the PPP device arrives or its link comes up; or the supervisor itself starts and finds the uplink already up. The last case is the normal one at boot, install, upgrade and restart, because core dials PPP before it starts services. Without a burst there, a line that announces the prefix by RA only would have no IPv4 until the next unsolicited RA, which can be 30 minutes away.
- After the burst the supervisor listens passively; unsolicited RAs refresh the lifetime. When the lifetime runs out without a refresh, the RA entry is removed and selection falls to DNS; with no DNS prefix either, this is prefix loss and the CLAT deactivates.
- Core's automatic ICMPv6 rules already pass RA and RS. No rule is added.

**RFC 7050.** Used only when no PREF64 is known and the uplink itself has no native IPv4.

- An AAAA query for `ipv4only.arpa` through the system's resolver, as any program on the box would get it. The upstream servers are not queried directly: how names are resolved on the box is the customer's configuration, and the plugin follows it.
- On a factory-default box the system's resolver is the local Unbound in recursive mode, which truthfully answers that the name has no AAAA record. DNS discovery therefore finds a prefix only where the customer has made the resolver DNS64-aware: "Use System Nameservers" ticked in Unbound with DNS64 servers announced or entered, DNS64 enabled in Unbound, or the local DNS service not used. On an unchanged box, activation relies on PREF64.
- Only the first server in `/etc/resolv.conf` is asked. The resolver library would move on to the next server whenever the first one times out or fails, which would make the result depend on whether Unbound happened to be answering at that moment.
- Every answer is checked against 192.0.0.170 and 192.0.0.171 for each RFC 6052 length. If several prefixes result, the lowest is chosen and kept while it stays valid.
- The answer is refreshed when its TTL runs out, at most once a minute. If a refresh returns no prefix, the prefix is dropped. A time-out is not an answer; it is retried with back-off and drops nothing.
- An answer without a prefix is asked for again after five minutes at most, so a resolver that the customer makes DNS64-aware later is noticed without a restart. Apply on the plugin page (a reload) asks at once, and so does a start of the service; what a customer waits is in section 11.

A prefix that overlaps the delegated prefix, the WAN /64 or a LAN prefix is rejected. If RA and DNS disagree, RA wins. A different prefix from the same source is ignored while the current one is valid.

With nothing found the CLAT stays dormant and listens. There is no fallback to `64:ff9b::/96`.

### 5.3 "No native IPv4"

The box has native IPv4 if either holds:

- the uplink device has a non-link-local IPv4 address or a non-empty IPv4 router file; or
- core's gateway list contains another enabled IPv4 gateway on a non-tunnel device (not gre/gif/ovpn/wg/ipsec) whose device has an IPv4 address, and that gateway is (a) marked upstream, or (b) at priority 254 or lower, or (c) the one selected in its interface's own settings.

Dynamic gateways (DHCP, PPPoE) get priority 254 and match (b). The wizard-made WAN gateway is marked upstream and matches (a). Test (c) covers a second WAN with a static address, whose gateway is created at priority 255 without the upstream flag; without (c) the CLAT, at 254, would take the default route from it. A static gateway that no interface selects, such as a LAN-side router used for static routes, is not native. Neither is a VPN gateway.

A native gateway that its monitor reports as down still counts. In v1 the CLAT is not an automatic backup for a failed native WAN.

Native IPv4 appearing tears the CLAT down after the two-second debounce. Native IPv4 disappearing must persist for 60 seconds before the CLAT activates, so a DHCPv4 renewal on another WAN does not cause a flap. A setting "Keep the CLAT when native IPv4 exists" turns the second test off; ranking is then left to System > Gateways.

### 5.4 States

| State | Meaning | Runtime footprint |
|---|---|---|
| `disabled` | mode Disabled | none; interface record removed |
| `listening` | no uplink IPv6 or no NAT64 prefix | RA socket and routing socket only |
| `blocked(reason)` | preflight failed | as `listening` |
| `native-ipv4` | native IPv4 present | as `listening` |
| `waiting-for-prefix-delegation` | NAT64 prefix known, no session-confirmed delegated prefix | as `listening` |
| `active` | CLAT up | tayga, tun addressed, router file, `CLAT_GW` |
| `suspended` | uplink lost for more than 15 s | tayga kept; the gateway is withdrawn only if another IPv4 gateway can take over (section 9) |
| `backoff(reason)` | tayga failed or a step failed | retry with increasing delay |

The supervisor wakes on: RAs, routing-socket messages (debounced two seconds), tayga's exit, an event from the `newwanip` hook (section 7.7), lifetime and TTL timers, and a 60-second timer. While dormant it does nothing on a timer beyond in-process checks: it writes no config, reloads no filter and logs one line per state change. A routing change or a configuration change makes it re-read a few facts with read-only commands. On a line without NAT64 that is its permanent condition.

## 6. Addressing

**IPv4 (RFC 7335).** `tun464` carries `192.0.0.1/32 → 192.0.0.2`. 192.0.0.1 is the NAT44 target and the source of the firewall's own IPv4 traffic; 192.0.0.2 is tayga's own address and the gateway. Both are settings, for the case where something else on the box uses 192.0.0.0/29.

**IPv6.** Two addresses forming a /127: the even one is the CLAT address (`map 192.0.0.1`), the odd one is tayga's own (`ipv6-addr`, source of its ICMPv6 errors). Neither is configured on any interface. One `/127` route into `tun464` captures both; it is more specific than any LAN /64 and than the discard route core installs for the delegated prefix.

Selection in automatic mode:

1. Read the delegated prefix and its real length from `/tmp/<uplink>_prefixv6` (not from the configured length).
2. Take the highest-numbered /64 that no tracking interface claims in `config.xml`. If every /64 is claimed, or the delegation is a single /64, take the highest one anyway: the /127 route still wins over the on-link /64.
3. Interface identifier: 64 bits of a stable hash of the /64 and a per-installation secret, re-hashed if it is all-zero, in the RFC 5453 anycast range, a small fixed value, or already on the box.

A manual setting (full address, or a prefix ID) overrides this. Placing the address in the WAN's SLAAC /64 is not done automatically; it depends on the BNG forwarding the whole /64 without neighbour resolution.

**Session-confirmed.** Core does not clear the prefix file when the PPP session drops, so a file from the previous session can be stale. The supervisor tells sessions apart by the uplink's device and interface index.

- *Another device, or the same name under another index.* The file is trusted only once it has been rewritten (dhcp6c rewrites it on every new binding) or a `newwanip` event for the uplink has arrived. A PPP device that core sets up again was expected to look like this. Measured on 26.7.6 (Apply on the WAN after the PPPoE port was changed, in both directions; the kernel log shows the device made anew twice each time): afterwards `pppoe0` had the index of the old device, so the supervisor saw the same device. Core had removed the prefix file together with the old device, and dhcp6c wrote it again in the new session, so there was no stale file to trust.
- *The session is lost and mpd5 redials.* Measured on 26.7.6: `pppoe0` stays and keeps its index, and the IPv6 default route, the default-router entry and the prefix file stay too. Only the device goes down: it loses the UP flag and both IPv6 addresses until the new session is up. The supervisor takes a default route on a device that is not up as no uplink (section 5.1), which starts the grace period of section 9. When the device is up again it is the same device under the same index, so the file stays trusted. dhcp6c rewrites it within seconds of the reconnect anyway, and a prefix that changed is then a renumbering (section 9).
- *A gap in the IPv6 default route on the same device* is not treated as a new session either, because nothing would confirm the file again afterwards.

At supervisor start with the uplink already up, no session change has been observed and the file is used as it is; after a boot `/tmp` was emptied, so the file belongs to the current session.

**Reading core's runtime files.** The supervisor reads `/tmp/<dev>_prefixv6` and `/tmp/<dev>_router` directly and treats an empty file as absent. It does not use `ifctl -i <dev> -6p` style reads: on 26.7 they create an empty file, which can hide RA-learned values from core. `ifctl` is used for writes only.

**Deviation.** draft-ietf-v6ops-claton section 6.2.2 asks for duplicate address detection and neighbour-solicitation responses for the CLAT address. FreeBSD cannot do that for an address that must be forwarded rather than delivered locally. For an address in a delegated /64 this has no practical effect. OpenWrt, clatd and the tayga examples do not do it either.

## 7. OPNsense integration

Three terms used below:

- **Enabled.** One model field, `general.enabled` (default 1), shown in the GUI as Mode: 1 is Automatic, 0 is Disabled.
- **Router file.** `/tmp/tun464_router`, written and removed with `ifctl`. Core reads it as the interface's dynamic IPv4 gateway address; its presence is what makes `CLAT_GW` exist.
- **`internal_dynamic`.** A key core adds to every record registered through an `_interfaces()` hook. Core uses it to remove the record when the hook stops returning it, and it suppresses the automatic antispoof and force-gateway rules for the interface.

### 7.1 Device

`clat_devices()` returns one entry while the plugin is enabled, nothing otherwise: `names` listing `tun464`, `volatile => true`, `configurable => false`, and a device function. The function creates the device if absent and, if the CLAT is active, rewrites the router file, because core deletes that file whenever the record is applied. It must be fast and unable to fail: core calls it during boot and inside every Apply of the record. `^tun` is already one of core's volatile patterns, so a missing device never stops the boot at the console prompt.

### 7.2 Interface record

`clat_interfaces()` returns, while the plugin is enabled:

```php
['clat' => ['enable' => true, 'if' => 'tun464', 'descr' => 'CLAT', 'type' => 'none',
            'ipaddr' => '', 'ipaddrv6' => '', 'mss' => <computed from config, section 8.2>]]
```

- The hook is a pure function of `config.xml`. It reads no device and no supervisor state. Registration therefore writes the record once at install and again only when a setting changes.
- The record exists whenever the plugin is enabled, also while the CLAT is dormant. A dormant record has no address and no router file, so core lists no gateway and generates no NAT rule for it. The customer sees a "CLAT" interface without an address until a NAT64 prefix is found.
- Keys the hook returns are plugin-owned and restored at the next registration run; other keys stay with the user.

**Drift.** The record is editable in Interfaces > Assignments. An applied edit there strips `internal_dynamic` and `type`, and on 26.7.6 also writes `ipaddr=none` (core#10996, fixed on master only), after which core flushes the tun's addresses and names the gateway `CLAT_NONE`. Nothing in that page re-runs registration. So the supervisor checks the record on every reconcile and, on drift, runs `configctl interface invoke registration` and replays the runtime state. This is the one runtime action that can write `config.xml`; it is rate-limited, skipped while an Assignments edit is pending (`/tmp/.interfaces.todo` exists) and never run during boot. Nothing looks the gateway up by name. Seen in the lab on 2026-10-12, with the entry saved and applied in a browser (test T25): Apply wrote the record as `enable`, `if`, `descr`, `mss`, `ipaddr` `none` and `ipaddrv6` `none`; the supervisor logged `the CLAT interface record was changed; running the interface registration`, and the record was whole again 1.1 to 1.2 s later. With the same edit made 87 s after a repair the gateway list named `CLAT_NONE` and the repair came 243 s after the Apply. The state stayed `active`, and a LAN client was answered right after the Apply and after the repair; it was not asked in between.

### 7.3 Gateway, default route, NAT

After the tun is addressed and the router file written, the supervisor runs `configctl interface newip tun464 force`. Core then lists the dynamic gateway (priority 254, unmonitored), installs `default via 192.0.0.2` if no better IPv4 gateway exists, and reloads the filter with `nat on tun464 inet from (<lan>:network) to any -> (tun464:0)` for every LAN-type interface.

Afterwards the supervisor asks core which gateway holds the IPv4 default (a small PHP helper around `Gateways::getDefaultGW()`), compares by device, and reports the outcome: "active", "active, but not the IPv4 default: gateway X is preferred", or "a stale gateway X on an interface without IPv4 blocks any default route".

The gateway status is not a health signal: unmonitored means "always up", and a monitor on 192.0.0.2 is answered by tayga itself. A user who wants monitoring sets a remote IPv4 monitor address on `CLAT_GW` in System > Gateways. The plugin's own status page carries the real health checks.

### 7.4 The one firewall rule

```
pass in quick on tun464 inet6 from any to any keep state label "<id>"   # CLAT: translated IPv6 from tayga
```

Registered in `clat_firewall()` with `registerFilterRule(1, ...)`: interface key `clat` (the key, not the device name), direction in, `ipprotocol inet6`, quick, `disablereplyto`, a description and a link back to the plugin page. This is the documented mechanism Kea, Dnsmasq and IPsec use for their automatic rules.

- It carries no addresses, so renumbering never needs a rule change or a reload.
- It is not stored in `config.xml`, appears under automatic rules, and disappears with the plugin.
- Priority 1 with quick is the only position no user rule can shadow or capture. That includes a future floating `af-to` rule, which could otherwise translate tayga's output straight back to IPv4.
- Only the process holding the tun open can inject on that device, and the flow was already authorised on its IPv4 leg by the LAN rules.
- It must stay IPv6-only. An IPv4+IPv6 rule would add an IPv4 pass with reply-to on the tun.

What tayga can emit: with the well-known prefix, tayga's default strict mode refuses private IPv4 sources that arrive un-NATed. With a network-specific prefix it would translate them into the NAT64 prefix. D5 (no activation without NAT) is the guard for that case.

### 7.5 Everything the plugin causes in pf

| Item | Owner | When |
|---|---|---|
| The pass rule above | plugin, via hook | while the plugin is enabled |
| Two MSS clamp rules on `tun464` | core, from the `mss` key | while the plugin is enabled and normalisation is on |
| Automatic outbound NAT on `tun464` | core | while the CLAT is active |
| State kills for 192.0.0.1 and the CLAT address | plugin (`pfctl -k`) | deactivation and renumbering, as core does for an old WAN address |
| Filter reloads | core, triggered by `newip` or `routes configure` | activation, deactivation, suspension with failover |

The plugin never writes `rules.debug`, loads anchors or tables, or changes shared-forwarding or normalisation settings.

A side effect to document for customers: once the CLAT is active, IPv4 leaves through `tun464`, and what crosses the WAN is IPv6 to the NAT64 prefix. Existing IPv4 rules bound to the WAN (egress block lists, policy routing to a WAN gateway) no longer see that traffic; they belong on the CLAT interface.

### 7.6 Service, Apply path and logs

- `clat_services()` registers one service, "CLAT".
- The API service controller extends `ApiMutableServiceControllerBase` and overrides `invokeInterfaceRegistration()` and `invokeFirewallReload()` to return true and `reconfigureForceRestart()` to return false, as IPsec does. Without the first two, changing the mode would not add or remove the interface record until the next reboot. Without the third, every Apply would stop and start the service: a full deactivation, a new discovery and a new activation for any settings change. With it, Apply calls `clat reload`; the supervisor re-reads its settings and restarts tayga only if its configuration, the addresses or the MTU changed.
- configd actions `start`, `stop`, `restart`, `reload` are `type:script`; `status` is `script_output` and keeps the rc.d wording, which the controller parses. os-tayga broke on 26.7.6 by using `script_output` for the former.
- tayga runs as `tayga -c <conf> --nodetach --stdout -u nobody -g nobody -r` on a pseudo-terminal. Without `--stdout` it logs under the fixed name "tayga" and would mix with an os-tayga instance; on a pipe its output sits in a 4 KB buffer. The supervisor relays each line to syslog as `clat`.
- A local log view needs a syslog template plus menu and ACL entries; the `_syslog` hook alone only covers remote logging.
- The service buttons in the head of the plugin's page are asked for with every refresh of its status rows. Core's Apply button asks for them once, when `clat start` returns; the daemon writes its pid file about 150 ms after that (lab, 2026-10-12), so that answer said "stopped" for a service that was running, and the buttons stayed that way beside State `Active.` until the page was loaded again.

### 7.7 Event hook

`clat_configure()` registers one handler, `'newwanip' => ['clat_event:3']`. Core calls it with the verbose flag, the list of interface keys and the address family. The handler:

- ignores an event that names only `clat`. Activation step 7 raises exactly that event, and reacting to it would loop;
- otherwise passes the family, and whether the configured uplink (section 12) is among the interfaces, to the supervisor through the configd action `clat event`. Family `inet6` for the uplink is the "session confirmed" signal of section 6; family `inet` is the fast path for native IPv4 appearing.

The hook is an accelerator only. Everything it reports the supervisor would also find by reading state at its next wake-up.

## 8. MTU and MSS

### 8.1 Runtime values

One input: M, the uplink's effective IPv6 MTU, computed as the kernel does (the RA-advertised MTU if it is non-zero and below the interface MTU, otherwise the interface MTU). V is the IPv4 MTU to present, 1500.

| Value | Formula | Why |
|---|---|---|
| `tun464` MTU | min(M, V+28) | tayga treats the tun MTU as its IPv6 limit and reads it once at start. 28 = 20 bytes of header difference plus 8 for a fragment header |
| tayga `offlink-mtu` | min(tun MTU, V+20) | the default 1280 would fragment every DF-clear packet above 1260 bytes. Above V+20, reassembled datagrams larger than 1500 bytes would leave without a fragment header and be dropped at the NAT64 |
| IPv4 MTU presented | `offlink-mtu` - 20 | what LAN hosts can send unfragmented |

tayga is restarted when the tun MTU changes. For non-TCP traffic tayga answers oversized DF packets with ICMPv4 "fragmentation needed"; pf matches that to the NAT44 state and delivers it to the LAN host.

| Uplink IPv6 MTU | tun MTU | offlink-mtu | IPv4 MTU presented | TCP MSS |
|---|---|---|---|---|
| 1492 (default PPPoE) | 1492 | 1492 | 1472 | 1432 |
| 1500 | 1500 | 1500 | 1480 | 1440 |
| 1520 | 1520 | 1520 | 1500 (IPv4 fragments are split) | 1460 |
| 1528 or more | 1528 | 1520 | 1500 | 1460 |

### 8.2 MSS clamp

Core turns the interface `mss` key into a clamp of `mss`-60 for the IPv6 crossing of the tun, which is the binding one. Because the hook may only read configuration, the value is:

1. empty (no clamp) if the setting is "off";
2. otherwise min(configured uplink MTU, V+20) minus the offset setting (default 0). The configured uplink MTU belongs to the *configured uplink* of section 12, never the runtime one, and is derived exactly as core derives it: the PPP link's `mtu`, else the uplink interface's `mtu` minus 8, else 1492; for a non-PPP uplink the interface `mtu`, else 1500. A plugin IPv6 MTU override can only lower it.

The status page shows the configured and the effective MTU and warns when they differ. It also warns when the WAN interface has its own `mss` value left from an earlier setup, because that clamps the translated flows too, and when normalisation is globally disabled, because then no clamp exists.

### 8.3 Jumbo PPPoE on stock 26.7

The plugin needs no setting for jumbo frames; the table in 8.1 applies as soon as the link's IPv6 MTU rises. What OPNsense 26.7.6 does with the MTU field of the WAN interface was measured in the lab (tests T18 to T20, 2026-10-12, `lab/.work/results/changes.md`). The PPP MTU asked for is the field minus 8.

| WAN MTU field | PPP-Max-Payload tag OPNsense sends | BNG in the lab | Measured session | `pppoe0` shows | IPv4 MTU presented | MSS clamp |
|---|---|---|---|---|---|---|
| empty | none (mpd's configuration has no `max-payload` line) | | 1492 | 1492 | 1472 | 1432 |
| 1508 | 1500 | echoes 1500 | 1500 on both sides, again after a redial | 1500 | 1480 | 1440 |
| 1508 | 1500 | does not echo | 1492 on both sides | 1492 | 1472 | 1440 |
| 1518 | 1510 | returns 1500, its maximum | 1492 | 1510 | 1472 | 1450 |
| 1528 | no tag at all | nothing to answer | 1492 | 1520 | 1472 | 1460 |

- **1508 is the value to document.** With a BNG that echoes the tag it gives PPPoE 1500, a translated IPv4 MTU of 1480 and MSS 1440, and it held across a redial. Path MTU discovery worked at that size: a DF packet of 1480 bytes was answered, and one of 1481 bytes got "fragmentation needed, MTU 1480" from 192.0.0.2. Against a BNG that does not echo, both ends fell back to 1492 and the interface showed 1492 as well; a 1500-byte ping6 from the box was still answered, and tayga restarted once for the new MTU.
- **Above 1508 nothing is gained on stock 26.7.** With 1528 OPNsense sends no PPP-Max-Payload tag, so no BNG can grant more than 1492, and the interface then shows an MTU (1520) that the session does not carry. With 1518 it asked for 1510 and the interface showed 1510 on a 1492 session. In the lab the RA's MTU option (1492) kept the kernel's IPv6 MTU, and with it the tun and the IPv4 MTU, at 1492 and 1472 in both cases, and the DF probe reported 1472. With a BNG that sends no MTU option the effective MTU would be the interface's and packets above 1492 bytes would be at risk; that case was not run.
- **After a fall-back the MSS clamp is too high.** It follows the configuration (section 8.2), so in the last three rows it stayed at 1440, 1450 and 1460 where the session needs 1432. TCP then depends on path MTU discovery. The status page warns in each of the three cases, for example "The configured uplink MTU (1510) differs from the effective IPv6 MTU (1492)."
- **The devices below PPPoE follow the WAN field.** With PPPoE directly on the NIC and the field at 1508, core set the NIC to 1508, whether the NIC was assigned as an interface of its own with an empty MTU field or with 1508. With `vlan0.40` between them, as on the ISP's line (run in the lab on a tagged link, 2026-10-12), the VLAN device had 1508. Its parent NIC had 1508 with 1508 in the parent's own MTU field, after Apply and after a reboot, and 1512 after a reboot with that field empty: core gives the NIC under a VLAN device the VLAN's MTU plus 4 unless the NIC is an interface with an MTU of its own. In both cases the session was 1500 on both sides and carried full packets: frames of 1526 bytes on the wire, the tag included, in both directions, and DF pings of 1500 bytes each way. The lab's NIC has the capability `VLAN_MTU`; a NIC without it was not tried.
- **On VLAN 40 the table holds.** Tests T18 to T20 ran again with PPPoE on `vlan0.40`: the same tags, sessions, IPv4 MTU and MSS in the four rows that have a value in the field. The first row, the empty field, was measured there by hand: PPPoE 1492, IPv4 1472, MSS 1432. With 1518 `pppoe0` showed 1492 in one run and 1510 in the next, on a 1492 session both times.
- **Not exercised.** The lab's PPPoE server grants 1500 at most, so no session above 1500 has been seen. What OPNsense does when a BNG grants 1510 is unknown, including whether it keeps the MTU across a redial.

The ISP's BNG echoes the tag, so on this network WAN MTU 1508 is the setting: PPPoE 1500, IPv4 1480, MSS 1440. The field must not be set above 1508 on stock 26.7. The MTU shown on `pppoeN` is no proof of what the session carries (rows 4 and 5); the DF probe of section 10 measures it where echo replies of that size return.

A 1500-byte translated IPv4 MTU needs a PPP MTU of 1520 (WAN MTU 1528), and 1528 (WAN MTU 1536) to cover IPv4 fragments as well. With 1528 stock 26.7 asks the BNG for nothing (1536 was not tried), so this waits for a change in core.

ISP side: the BNG must echo the client's exact PPP-Max-Payload value in PADO and PADS (without the echo, and with another value returned, the session was 1492 in the lab); the RA MTU option must equal the negotiated value or be absent; and for a 1500-byte translated IPv4 MTU the IPv6 MTU must be at least 1528 all the way to the NAT64 and on it.

## 9. Lifecycle sequences

**Activate.**

1. Compute the MTU values. Write `/usr/local/etc/clat/tayga.conf` using only directives that exist in 0.9.6: `tun-device tun464`, `ipv4-addr 192.0.0.2`, `ipv6-addr <odd>`, `prefix <pref64>`, `map 192.0.0.1 <even>`, `udp-cksum-mode calc`, `offlink-mtu <n>`, `data-dir <empty directory>`.
2. Create `tun464` if absent; set its MTU.
3. Start tayga; wait until the tun's link is up.
4. `ifconfig tun464 inet 192.0.0.1/32 192.0.0.2 up`, then `ifconfig tun464 inet6 -ifdisabled`. The explicit /32 matters: without a mask FreeBSD 15 stores netmask 0.0.0.0, which makes pf's "CLAT net" mean "any". A new tun has IPv6 disabled and the kernel drops what tayga writes until the second command.
5. `route -6 delete <pair>/127` (ignoring "not in table"), then `route -6 add <pair>/127 -interface tun464`. The route survives a tayga exit, so the delete is needed.
6. `ifctl -i tun464 -4rd -a 192.0.0.2`.
7. `configctl filter reload`, then `configctl interface newip tun464 force`. The reload comes first because core's `newip` installs the default route before it reloads the filter; packets forwarded in that gap would create states without NAT, and those states would persist.
8. Check the default gateway and the NAT rule (section 7.3); report the result.

**Deactivate** (once, on leaving `active` or `suspended` for `disabled`, `native-ipv4`, `blocked` or prefix loss).

1. `ifctl -i tun464 -4rd`. Removing the router file first means no routing run from here on sees `CLAT_GW`.
2. Stop tayga. The kernel downs the tun and removes 192.0.0.1 and the default route through it.
3. `route -6 delete <pair>/127`.
4. Kill states for 192.0.0.1 and the CLAT address.
5. `configctl interface routes configure`. `newip` cannot be used here: it returns early when the device has no IPv4 address, and it would not hand the default route to another gateway.

**Suspend and resume.** "No usable IPv6" is condition 2 of section 5.1 failing: no IPv6 default route, a default route on a device that is down, or no confirmed delegated prefix. A lost PPP session is the second case: on 26.7.6 the device, its index and the route stay while mpd5 redials, and only the device goes down (section 6). The routing socket reports that, in both directions. When the uplink has had no usable IPv6 for 15 seconds, the supervisor asks core (the helper of section 7.3) whether another usable IPv4 gateway exists. A redial that is back sooner changes nothing: in the lab a session reset took the link down for 6 to 8 seconds and the state stayed `active`.

- *None, the standard single-uplink customer.* Nothing in core is changed. The router file, the tun address, the default route, the NAT rule and the states stay, and tayga keeps running; only the reported state becomes `suspended` (in the lab 17 to 18 seconds after `pppoe0` went down). IPv4 from the LAN goes unanswered until the uplink is back. Withdrawing only the router file here would be wrong: the kernel keeps the default route through the tun while the filter reload removes the NAT rule, so new flows would get un-NATed states that outlive the resume.
- *Another gateway exists.* (1) `ifctl -i tun464 -4rd`. (2) `ifconfig tun464 inet 192.0.0.1 -alias`, so the kernel drops the default route through the tun. (3) Kill states for 192.0.0.1. (4) `configctl interface routes configure`, which lets core install the other gateway's default route. tayga, the tun and the /127 route stay.

On resume the delegated prefix and the NAT64 prefix are re-validated. If both are unchanged, the first case needs nothing and the second runs activation steps 4, 6 and 7. If either changed, treat it as renumbering.

**Renumbering or MTU change.** tayga 0.9.6 cannot reload (SIGHUP terminates it), so a changed NAT64 prefix, CLAT address or tun MTU means: stop tayga, delete the old /127 route, kill the old states, and run activation again. A restart rate limit prevents a flapping PPPoE from causing a restart and a full core reload per session.

**tayga exit.** The supervisor removes the router file in the same step, then retries with back-off. The child is started so that it dies with the supervisor; at start the supervisor kills any tayga left on `tun464`.

**Boot.** The service starts from rc.d after core has replayed deferred WAN events. The interface record and pass rule are already loaded; pf accepts rules on a missing or address-less device. The supervisor starts in `listening` and treats an uplink that is already up as an attach (section 5.2).

## 10. Preflight and status

Preflight is re-evaluated continuously, not only at install: re-running the setup wizard sets the WAN back to IPv4 = PPPoE. Rows that only read `config.xml` or files in `/tmp` run on every reconcile. Rows that need core's gateway list run only once the other activation conditions hold, and on status requests.

| Check | Effect | Message gives |
|---|---|---|
| The configured uplink is a PPP device, its IPv4 type is a PPP type, and the device has no IPv4 address | blocks | "IPv6 cannot start with this setting. Set WAN IPv4 Configuration Type to None" |
| Same setting, but the device has an IPv4 address (state `native-ipv4`) | warns | "If the ISP stops offering IPv4 on this line, IPv6 will not start either and the CLAT cannot take over. Set IPv4 to None first" |
| Outbound NAT mode is manual or disabled | blocks unless confirmed | the mode to select, or the rule to add on the CLAT interface |
| The static NAT64 prefix of the settings overlaps a local IPv6 prefix (section 5.2) | blocks | the prefix |
| A static IPv4 gateway that is marked upstream or has priority below 254 sits on an interface without an IPv4 address | blocks | which gateway to disable; core ranks it above `CLAT_GW` and then installs no IPv4 default at all |
| Normalisation disabled | warns | no MSS clamp is active |
| WAN `mss` set; configured and effective MTU differ; configured and runtime uplink differ | warns | sections 8.2 and 12 |
| Leftover `WAN_PPPOE` gateway used as monitor, DNS binding or policy-rule target | warns | what refers to it |
| `tayga` package missing | blocks | |
| `tayga` is not a version the plugin was tested with (0.9.6 at release) | warns | the installed version; if tayga then fails to start, the state is `backoff` with tayga's own output |

Gateways at priority 254 or 255 are not judged before activation: `CLAT_GW` is not in core's list until the router file exists, so core cannot yet say who will win. The check in section 7.3 decides after activation and never blocks.

Status (page and `GET /api/clat/service/status`): state and reason; uplink; NAT64 prefix with source and remaining lifetime; CLAT address; configured, effective and presented MTU and the MSS; whether `CLAT_GW` holds the default route; tayga uptime and restart count. The supervisor rewrites its status file whenever an accepted Router Advertisement moves the expiry of the PREF64 entry, so the remaining lifetime shown is never older than the last advertisement. Such an advertisement starts no reconcile pass and logs nothing.

Three tests: IPv6 ping to `pref64::<target>` (PLAT reachable without the CLAT), IPv4 ping to the target through `tun464` (whole path), and a DF probe that reports the largest IPv4 size for which a ping is answered. It starts at the IPv4 MTU presented (section 8.1) and searches below it only when that size is not answered. The MTU shown on `pppoeN` is not proof of what the link carries (section 8.3), so the probe is the authoritative number where it gives one. The tests need a target address (section 16).

The probe is a ping, so it measures the way back as well. tayga 0.9.6 does not translate a fragmented ICMP message, and a NAT64 that keeps RFC 7915's default returns an IPv4 packet without DF as IPv6 fragments of at most 1280 bytes. A Linux host, like the lab's target, answers an echo without DF. On such a line echo replies above 1260 bytes never return, although the line is healthy: TCP is not fragmented, and fragments of UDP are translated (in the lab a 1300-byte UDP reply that came back as two IPv6 fragments reached the client). A path that silently loses packets above some size looks the same to a ping: no reply and no error. The test cannot tell the two apart, so it has three outcomes:

- *ok*, with the largest size answered: the IPv4 MTU presented is answered, or the next size above the largest one answered is refused with "fragmentation needed". A limit that is announced like this is one that path MTU discovery finds;
- *inconclusive*, with the largest size answered: small pings are answered, and the next size above the largest one answered gets neither a reply nor "fragmentation needed". This holds at any size, above 1280 bytes as well as below. The text names both causes without choosing one (the NAT64 returns large ping replies as fragments, which the translator does not pass for ping; or packets of that size are lost on the path) and says to check with a TCP download. This is reported neither as a failure nor as ok;
- *failed*: no ping is answered at all, or 1280 bytes, or the IPv4 MTU presented when that is lower, are refused with "fragmentation needed"; a refusal met below that size, after it got no answer, counts the same. 1280 bytes is the lowest value the setting "IPv4 MTU to present" accepts (section 12; 1280 to 1500), so a path that refuses them carries less than the CLAT can be set to present. That is reported as failed although path MTU discovery finds such a limit too: an announced limit of 1260 to 1279 bytes is an IPv6 path MTU of 1280 to 1299 beyond the uplink, which IPv6 allows.

Measured in the lab at PPP MTU 1500 (IPv4 MTU presented 1480, 2026-10-12):

| Lab condition | Result |
|---|---|
| the test target answers echo with DF set | ok, 1480 (one probe, 4 s for the three tests) |
| the target answers with DF clear, so replies above 1260 bytes return as fragments | inconclusive, 1260 (11 s) |
| DF set, and the ISP side drops IPv6 packets above 1420 bytes without an error | inconclusive, 1400. The code before this correction reported "ok, 1400" here |
| DF set, and the MTU of the ISP's NAT64 device lowered to 1400, so that the ISP's router refuses larger IPv6 packets | ok, 1380: a probe of 1381 bytes got "frag needed and DF set (MTU 1380)" from 192.0.0.2 |

## 11. Onboarding

"Install the plugin and nothing else" holds on a box that already has working IPv6 on the WAN and can reach the plugin's repository. Two things come before that:

1. **WAN settings.** The setup wizard can only produce IPv4 = PPPoE, with which IPv6 never starts and the box has no connectivity at all. The customer must set Interfaces > WAN to IPv4 Configuration Type None, IPv6 DHCPv6 with the delegation size the ISP provides, and apply. This belongs in the ISP's quick-start, before any plugin step. Re-running the wizard reverts it.
2. **Getting the plugin.** No GUI writes third-party repository files, so an ISP-hosted repository needs one shell command for the repository configuration and its fingerprint. If the plugin is accepted into opnsense/plugins it appears under System > Firmware > Plugins with no shell step, which is the only route to a GUI-only install.

One more step applies only to lines without PREF64 in the RA. The customer then does one of these, and the plugin activates:

- tick "Use System Nameservers" under Services > Unbound DNS > Query Forwarding, where the announced DNS servers do DNS64 or a DNS64 server (for example Google's `2001:4860:4860::6464`) is entered under System > Settings > General;
- enable DNS64 in Unbound; or
- enter the NAT64 prefix on the plugin page.

The ISP's own router-setup page takes the first of these: the customer enters Google's DNS64 servers under System > Settings > General and ticks "Use System Nameservers" (steps 8 and 9 of its OPNsense section). On a line set up that way DNS is the source the plugin finds.

What the customer should expect, as measured in the lab:

- *The DNS step is done before the plugin is installed.* The first lookup finds the prefix: the CLAT was active 2 seconds after the service started with forwarding to a DNS64 resolver already in place, and after a reboot 15 seconds after the first possible login. The ISP's quick-start should put the DNS steps first.
- *The plugin was installed first.* The supervisor finds the prefix at its next lookup, which is up to five minutes away (116 to 298 seconds in the lab). Apply on Services > CLAT > Settings asks at once: active 3 seconds later. A restart of the CLAT service does the same.
- *With PREF64 in the RA* nothing is waited for: active 3 to 4 seconds after an install, 10 to 11 seconds on a freshly booted box (section 16).

## 12. Settings

One page; advanced fields collapsed. For the ISP's standard customer nothing needs to be set.

| Field | Default | Notes |
|---|---|---|
| Mode | Automatic | Automatic or Disabled |
| Uplink | automatic | automatic, or a chosen interface; see below |
| NAT64 prefix | empty = discover | a static prefix replaces discovery; any RFC 6052 length |
| Discover through DNS | on | RFC 7050 asks for a way to turn it off |
| Keep the CLAT when native IPv4 exists | off | section 5.3 |
| CLAT IPv6 address | automatic | automatic, prefix ID, or full address |
| TCP MSS clamp | automatic | automatic, off, or offset |
| Automatic firewall rule | on | section 7.4 |
| I manage outbound NAT myself | off | lifts the D5 block |
| Advanced | | CLAT and translator IPv4; IPv4 MTU to present (1500); IPv6 MTU override (may only lower); UDP zero-checksum handling (`calc`); test target; log state changes |

**Uplink resolution.** Two values are used, because the interface hook and preflight cannot rely on the routing table.

- The *configured uplink* is computed from `config.xml` only: the chosen interface; in automatic mode `wan` if it is enabled with IPv6 type DHCPv6 or SLAAC, otherwise the first enabled interface with one of those types. The `mss` value (section 8.2), the first preflight rows (section 10) and the event hook (section 7.7) use it. All three must work while IPv6 is down.
- The *runtime uplink* is the device holding the kernel's IPv6 default route, as long as that device is up. A default route on a device without the UP flag is what a lost PPP session leaves behind (section 6); the box then has no runtime uplink. The supervisor uses the runtime uplink for RAs, the delegated prefix and the live MTU.

Normally both name the same interface. When they differ the status page says so; the fix is to choose the uplink explicitly.

## 13. Relation to core's `af-to`

- A user's `af-to` rule and this plugin can both exist, but an `af-to` rule overrides routing for the traffic it matches, and the two must not use the same IPv6 source address.
- "Handing over" to core's inbound `af-to`, as the PR stands, would mean: the plugin shrinks to discovery and status; the user owns the translation rule, whose two fields are literals that need editing at every renumbering; and `tun464`, the gateway, the default route, automatic NAT, path-MTU signalling and IPv4 for the firewall itself all disappear. That gives up the virtual-WAN model.
- Having the plugin feed such a rule would mean either rewriting a user rule in `config.xml` at every renumbering or emitting a plugin-owned `af-to` rule. Both are more firewall ownership than today's single pass rule.
- So no hand-over is planned. The discovered prefix and CLAT address are exposed through the status API, which is what any later arrangement would need. Revisit when 27.1 ships and it is clear whether the IPv4-to-IPv6 direction works with shared forwarding.

## 14. Packaging and distribution

- Plugin `net/clat`, package `os-clat`, BSD-2-Clause, `PLUGIN_DEPENDS= tayga`. No binaries shipped. dnspython is already a core dependency.
- Identifiers are distinct from os-tayga (config path, rc script, device, service, log name), so both can be installed.
- The model has a version, and `enabled` is required with default 1, so the generated install script persists it.
- Package scripts. pkg runs the old package's pre-deinstall script on every upgrade, and the generated `+POST_INSTALL` starts no service, so:
  - `+PRE_DEINSTALL.pre`: stop the service (normal deactivation).
  - `+POST_INSTALL.post`: `pluginctl -i`, then restart the service. This is what brings the CLAT back after an upgrade.
  - `+POST_DEINSTALL.post`: `pluginctl -i` (removes the record, since the hook is gone), destroy the tun, remove `/tmp/tun464_oldip` and `/tmp/tun464_oldgw`, remove Python's cache directory `scripts/clat/lib/__pycache__`, `configctl interface routes configure`. All steps idempotent. The two files are core's: `rc.newwanip` keeps the last address and gateway of every device it ran for and removes them only at the next boot, so without this step a removal would leave two files that name the device. The cache files are written when the daemon first runs and belong to no package, so pkg left them and with them `scripts/clat` and `scripts/clat/lib`; pkg 2.8.4 removes the package's empty directories after this script has run, so removing the cache is enough.
  - In the lab (pkg 2.8.4, package 1.0 to 1.0_1 through the firmware page's update): the old pre-deinstall and the new post-install ran, the old post-deinstall did not. A LAN client's IPv4 was interrupted for 6 s, and the CLAT came back by itself with the same address, because the secret in `/usr/local/etc/clat` is not a file of the package.
  - A removal leaves `/etc/rc.conf.d/clat`, `/usr/local/etc/clat` (configuration and the secret), `/var/run/clat`, `/var/log/clat` and the `<clat>` node in config.xml. A second install finds the settings and the address again.
- ISP repository (the choice of section 16, item 7; built in `packaging/`, and `packaging/README.md` is its description). A pkg repository is static files. It is published as the GitHub Pages site of the plugin's repository under the ISP's own name, `https://os-pkg.gettuckamore.ca` (a CNAME to `77997.github.io`, set as the site's custom domain), which GitHub Pages is to serve over IPv6 with a Let's Encrypt certificate for that name; on 2026-10-13 the name resolved to GitHub Pages' IPv6 addresses, nothing was deployed and the certificate was not issued yet (`packaging/README.md`, set-up step 2). Everything a router fetches is on that one host, and nothing comes from github.com.
  - The layout is fixed: `os-clat.conf` (the repository definition), `os-clat.fingerprint`, `index.html` with the install line, and one directory `repo/` with the signed catalogue and the current package only. The address has no `${ABI}`. The package is built without an ABI (`FreeBSD:*:*`), so the one catalogue serves every OPNsense series.
  - The address is stored on every subscribed router and never fetched again. The name is therefore fixed from the first release on; what serves it can change without a change on any router, as long as it serves the same files over HTTPS and IPv6.
  - The catalogue is signed with one key. Its fingerprint is in git (`packaging/repo-key.sha256`) and on every router, and the build refuses any other key. A changed key cuts every router off until its owner runs the install line again.
  - Each release replaces the whole site, so a bad release is corrected by a higher version, not by going back.
  - Core's firmware check runs over every configured repository, so an unreachable or badly signed repository blocks OPNsense updates on every customer box. The site must stay reachable over IPv6, and every repository is read back with pkg before it is uploaded.
  - A series upgrade does not upgrade or reinstall os-clat, so the build installed before the upgrade runs on first boot of the new series with whatever tayga that series ships. One build must therefore run on both, and a build validated on 27.1 must be published before 27.1 is released.
- What the lab saw of it (2026-10-12; `packaging/README.md`). The lab built that package on 26.7.6 and served a repository signed with a lab key from a stand-in host. The router's side works as designed: the install line on a box with only IPv6, the Plugins page (tier 4, behind "Click to view the community plugins."), installation, an upgrade that arrives with the normal update, and removal. The risk named above is real: with the site unreachable or the key not trusted, the firmware check ended in an error and offered no update of OPNsense either, after 7 s when the site refused connections and after 22 minutes when it did not answer at all. Removing the repository definition (`rm -f /usr/local/etc/pkg/repos/os-clat.conf`) ended that state at once and left the plugin running. The release workflow and GitHub Pages themselves have not run.
- ISP presets, optional. A companion package can ship a read-only preset file (for example the test target) without forking os-clat.

## 15. Lab verification before coding

On a 26.7.6 box behind a real or simulated IPv6CP-only PPPoE, in priority order. `docs/lab-spike-runbook.md` has the commands for items 1 to 4 (untested; it uses the name `clat0` because `tun464` is not assignable in the GUI without the plugin's hook).

Status 2026-10-12: the list was run with the finished plugin, not as a spike before coding, on 26.7.6 behind a simulated ISP (`lab/README.md`, tests T01 to T24), first on an untagged link and later that day again with PPPoE on the tagged VLAN 40. Every item was exercised except these: the hand-made datapath of item 1 (the runbook was not needed); in item 8 the plugin page beyond its Mode, its test target and its two buttons (the other settings were changed through the API; the package upgrade and removal followed later the same day, section 16; the Apply on the CLAT record with the `ipaddr=none` case, and enable and disable on the plugin page, were done in a browser later that day, lab test T25, sections 7.2 and 7.6); in item 9 the ISP's own BNG and any session above 1500; in item 10 a second WAN with DHCP; in item 11 customer hardware. Three plugin changes came out of it (the UP flag in section 5.1, the status file in section 10, the two files in section 14), and section 16 lists what was measured.

1. Manual datapath: tayga on a tun, started unprivileged and chrooted on a pseudo-terminal as in section 7.6, a hand-made pass rule, end-to-end TCP, UDP and ICMP from a LAN host.
2. A non-virtual interface record plus router file yields the gateway, the default route and the automatic NAT rule (`pfctl -vsn` shows `(tun464:0:1)`).
3. The hook-registered pass rule loads, has no reply-to, and works with interface-bound states.
4. MSS: the SYN leaves `pppoe0` with 1432; the SYN-ACK is clamped where it leaves `tun464`. DF pings of 1473 to 1492 bytes are answered "fragmentation needed, MTU 1472".
5. A dormant registered interface is inert: no gateway, no NAT rule, no log noise, sensible display.
6. PREF64: the supervisor's RS is answered on `pppoeN` with option 38, also when sent at supervisor start; behaviour across a reconnect. An RA with option 38 sent by a LAN host must not change the learned prefix. DNS discovery through the system resolver: on a default box (expected: nothing found), with "Use System Nameservers" ticked and DNS64 servers announced or entered, and with DNS64 enabled in Unbound.
7. Return traffic for a CLAT address in the delegated prefix, including a delegation of a single /64.
8. Lifecycle: PPPoE drop and reconnect, new delegated prefix, tayga crash, GUI Apply on the CLAT record, the 26.7.6 `ipaddr=none` case, reboot, plugin upgrade and removal; on the plugin page, enable, change a setting, disable.
9. Jumbo: WAN MTU 1508, 1518 and 1528 against the ISP's BNG, to confirm or refute section 8.3.
10. A second WAN with native IPv4 (DHCP, and static with a hand-made gateway): the CLAT stays down; after the native WAN is removed the CLAT takes over; suspend with failover hands the default route to the other gateway and back.
11. Throughput and CPU on the hardware customers use. tayga is single-threaded on FreeBSD; published Linux figures run from about 200 Mbit/s on low-power CPUs to about 3 Gbit/s on a desktop CPU.

## 16. Settled questions

All eight are settled: the recommendation in each of items 1 to 6, the ISP's own repository for item 7, and no built-in target for item 8. The items are kept for their reasoning.

1. **The one pass rule (D6).** It is the single exception to "no firewall rules". The alternative is a documented manual rule, as os-tayga does.
2. **Address-less rule or source bound to a pf table.** Review passes recommended binding the rule's source to a table holding the CLAT /127, which also stops un-NATed sources when the NAT64 prefix is network-specific. This design keeps the rule address-less: with the well-known prefix tayga already refuses private sources, D5 covers missing NAT, and a table is a second pf object that fails closed (no IPv4) if it is ever emptied.
3. **Supervisor daemon (D8).** Most of the independent analyses preferred hooks plus a per-minute cron as simpler and closer to plugin conventions. The daemon is kept because tracking a PREF64 lifetime without repeated Router Solicitations needs a listener, because loss of native IPv4 and a tayga exit raise no core event, and because a listener costs less on boxes that never see NAT64. The reconcile logic is a separate one-shot command, so switching to cron later is small.
4. **Active by default at install.** Right for an ISP package. For opnsense/plugins there are precedents (os-crowdsec, os-ddclient) but no rule; maintainers may ask for default off.
5. **A permanently listed, dormant "CLAT" interface** on boxes that never see NAT64. The alternative, registering at first discovery, costs a config write per transition.
6. **Multi-WAN.** With another native IPv4 WAN, as defined in section 5.3, the CLAT stays down unless "Keep the CLAT" is set. With that set, the CLAT outranks gateways at priority 255 and dynamic gateways of interfaces listed before it; upstream-flagged gateways, lower priorities and interfaces assigned later outrank it. Ranking the CLAT below native IPv4 automatically, as OpenWrt does, would need the plugin to write a gateway entry.
7. **Distribution route: decided.** The ISP's own repository on a static host (section 14). Each customer runs one shell command to add it. Submission to opnsense/plugins remains possible later.
8. **Test target.** The status tests need an IPv4 address that answers ICMP echo up to 1500 bytes through the NAT64. Either the ISP names one, shipped in a presets package, or the field stays empty for the customer to fill. No default is built in. Where the target's large replies come back through the NAT64 as fragments, the size test can only say "inconclusive" (section 10); a target that answers echo with DF set gives a number.

Facts about the ISP's network. Its public setup guide states that a /56 is delegated and that DNS servers are set by the customer (resolvers announced by RA are covered as well, section 1), and gives a WAN MTU of 1528 for a 1520-byte session, which stock 26.7 does not ask for (section 8.3). The ISP adds that the requested prefix size can change and that the BNG echoes PPP-Max-Payload.

Any of the three discovery cases can occur on a customer line (PREF64 in the RA, DNS64 on the announced resolvers, or neither); the design covers each (sections 5.2 and 11).

Left for the ISP's own network, none blocking (the lab's ISP is a simulation and answers none of them):

1. Where the RA carries PREF64: whether solicited RAs carry it too, and its lifetime. This only affects how quickly IPv4 comes up after a boot.
2. Whether the RA-announced resolver addresses are global or link-local.
3. On the ISP's NAT64: ICMP echo translation (the tests and a gateway monitor need it), handling of fragments, and its IPv6 MTU. If it returns large echo replies as fragments, the size test says "inconclusive" there (section 10).

Measured in the lab on 2026-10-11 and 12 (OPNsense 26.7.6, tayga 0.9.6, a simulated ISP in a second VM; `lab/.work/results/changes.md` has the runs):

| What | Measured |
|---|---|
| Install to `active`, PREF64 in the RA | 3 to 4 s on a warm box, 10 to 11 s on a freshly booted one. The first pass asks DNS before it reads the answer to its Router Solicitation, and on a cold box without IPv4 that lookup ends in a time-out after 2 to 3 s. The order is left as it is: the delay is a few seconds, once per start of the service, and only while the resolver cannot answer |
| Reboot to `active` | 18 s after the first possible login; first ping from the LAN client 76 s after the reboot command. With DNS as the only source: 15 s after the first login |
| "Use System Nameservers" ticked with the plugin already running | `active` at the supervisor's next lookup: 116, 116, 117 and 298 s. With Apply on the plugin page afterwards: 3 s. Service started with forwarding already in place: 2 s |
| DNS64 resolver stops synthesising | dormant after 57 to 58 s |
| PREF64 appears while DNS is the source | the RA takes over within 1 s, tayga not restarted |
| PPP session reset (link down 6 to 8 s) | stays `active`, tayga not restarted; a silent loss was noticed by OPNsense after 67 s |
| PPPoE server away for 45 s | `suspended` 17 to 18 s after `pppoe0` went down, `active` again as soon as the uplink was back, tayga not restarted |
| New delegated /56 | new CLAT address 44 s after the prefix file changed, one tayga restart |
| tayga killed | `active` again after 8, 12 and 33 s (three kills in a row, back-off) |
| Native IPv4 gone | hold, then `active` 61 to 68 s later |
| Dormant for 15 minutes | no log line, supervisor CPU time +0.02 to 0.04 s |
| Throughput through the CLAT in a VM on the lab host | 192 Mbit/s up, 656 Mbit/s down, tayga at 8 to 25 % of one core in the samples. Says nothing about customer hardware |
| Echo replies above 1260 bytes | lost when the NAT64 returns them as IPv6 fragments: tayga does not translate fragmented ICMP. UDP returned as fragments passes (section 10) |

The same lab with the ISP set up as its public setup guide describes it, on 2026-10-12: a /64 by SLAAC on the WAN and a /56 by DHCPv6-PD; no PREF64 and no resolver in the RA in the simulator; PPP-Max-Payload echoed. OPNsense was configured by the steps of the ISP's router-setup page (Google's DNS64 servers entered by hand, "Use System Nameservers", "Request prefix only", WAN MTU field 1508), and the plugin was installed with no setting changed. PPPoE ran untagged at first. Later the same day the lab link was tagged and PPPoE ran on VLAN 40 (`vlan0.40`), as on the ISP's line; the tests of both profiles passed there again (the values below are from the untagged runs). No plugin change came out of these runs.

| What, in the production profile | Measured |
|---|---|
| Install on the configured box to `active` | prefix by DNS; 15 s from the start of the install on a freshly booted box (the first lookup timed out, the second came 10 s later), 2 to 3 s on a warm one |
| Addresses and sizes | CLAT address in the highest /64 of the /56; the WAN keeps its SLAAC address with "Request prefix only" ticked; PPP MTU 1500, IPv4 MTU 1480, MSS 1440 in the SYN on the PPP link; a 1481-byte packet with DF gets "fragmentation needed, mtu 1480" from 192.0.0.2 |
| Reboot | `active` 17 s after the first possible login; first ping from the LAN client 80 s after the reboot command |
| PPP session reset, silent loss, PPPoE server away for 45 s | as in the table above: `active` through a reset (new session after 6 s), a silent loss noticed after 67 s, `suspended` 16 s after `pppoe0` went down |
| tayga killed three times | `active` again after 7, 12 and 32 s |
| Renumbering (new WAN /64 and new /56 together) | new CLAT address 48 s after the prefix file changed, one tayga restart, no address or state of the old prefixes left |
| The DNS64 resolver answers nothing for 10 minutes | the CLAT stays `active` on the prefix it holds and IPv4 by address goes on (no client ping lost, a 100 MB download during the outage completed). Names fail for the firewall (SERVFAIL) and for LAN clients (time-out), because Unbound has nothing to forward to, and in the one run that measured it they came back 42 s after the resolver did. Neither the status nor the log of the plugin says that its lookups fail |
| The service starts while the resolver is silent | `listening`, "no NAT64 prefix found", no IPv4 default route; `active` 60 to 61 s after the resolver answered again in two runs. The lookup is repeated after 10, 30 and 60 s and then every 300 s, so after a longer silence it can take five minutes. In one run, in which Unbound was not restarted with the service and still came from a 10-minute outage, the CLAT was not active 321 s after the resolver was back: by that schedule its lookup a minute after the return must have failed as well, and the next was 300 s away |
| Unbound restarts | nothing changes: `active` throughout, tayga not restarted, longest gap between client pings 0.5 s |
| 15 minutes without client traffic | no Router Solicitation; `ipv4only.arpa` asked once a minute (the lab answers with TTL 60) and no other DNS query on the PPP link |
| radvd announcing PREF64 on the LAN and Dnsmasq offering DHCPv4 option 108, the plugin running | the plugin is unchanged, its prefix still from DNS; an IPv4-only client through the CLAT and an IPv6 host sending to the NAT64 prefix work side by side |

The package, from a signed repository that the lab serves over HTTPS and IPv6, through the API of the firmware pages (2026-10-12, the same profile; `packaging/README.md`, `lab/README.md` section 14):

| What, with the package | Measured |
|---|---|
| Install on a box that has only IPv6, never had the plugin and has no tayga | pkg takes os-clat from the ISP repository and tayga from OPNsense's; the log of the page ends after 7 to 8 s; `active` 8 to 9 s after the API call; the first ping of an IPv4-only LAN client was answered 9 s after it in two runs |
| Second install, settings and secret still there | first client ping answered 7.5 s after the API call, the CLAT address as before |
| Upgrade 1.0 to 1.0_1 | IPv4 interrupted for 6.1 and 6.5 s (longest gap between two answered pings, one every 0.2 s); no reboot; the same CLAT address |
| Removal | tayga removed as well; left are the settings, the four paths of section 14 and nothing else |
| Firmware check while the repository site refuses connections | error after 7 s, no update listed, not of OPNsense either; the CLAT keeps running |
| The same while the site does not answer at all | the same error after 22 minutes 37 s |
| The repository definition removed with the site still down | the check works again (12 s); the plugin is listed as installed without a repository and keeps running |

Three things about core that the lab showed and the plugin now lives with: a lost PPP session leaves the device, its index and the IPv6 default route in place (section 6); `opnsense-log clat` finds the log only after core's hourly `syslog archive` job has made `latest.log`, the dated file under `/var/log/clat/` is there from the first line; and `configctl interface gateways list` is answered from a 20-second cache, so `CLAT_GW` can still be listed for that long after a deactivation.

## 17. Scope, deviations, review

Not in v1: a stateless mode without NAT44; more than one CLAT instance; HA/CARP; the CLAT as automatic backup for a failed native WAN; automatic LAN-side PREF64 advertisement (a core radvd field; the status page shows the prefix); DHCPv4 option 108 (out of scope); inbound port forwards, which 464XLAT cannot provide.

Known deviations from the standards:

- No duplicate address detection for the CLAT address (draft-ietf-v6ops-claton 6.2.2; section 6).
- The interface identifier is not checksum-neutral (claton 6.2.1; harmless with tayga, which recomputes checksums).
- The IPv4 MTU follows RFC 7915's minus 20, with the fragment case covered by the tun MTU, not claton's flat minus 28.
- One Router Solicitation burst at supervisor start, which RFC 4861 section 6.3.7 does not list as an occasion (section 5.2).
- A DNS answer may be used up to 60 seconds past its TTL (section 5.2).
- DNS discovery goes through the system's resolver, not directly to the resolvers learned on the uplink as RFC 8880 section 7.1 says (section 5.2). Decision: the plugin follows however the box is configured to resolve names.

Review: sixteen research reports; independent analyses that decided the contested points without seeing the draft; review passes that checked the draft against the source, each finding re-verified; separate verified research on activation and on jumbo MTU; and a final check of v0.2. The findings are incorporated, except the two declined in section 16 (items 2 and 3). None required a change of architecture. The largest corrections were to teardown and suspend, package upgrade scripts, RA acceptance, the config-only MSS value, and the jumbo-MTU expectations.

Implementation phases:

1. **Lab spike** (no plugin code): section 15 items 1 to 4 and 9.
2. **MVP**: hooks, supervisor with a static prefix, address selection, pass rule, MSS, settings.
3. **Discovery and activation**: PREF64, RFC 7050, the state machine, preflight, status and tests.
4. **Distribution**: package scripts, repository or upstream submission, customer quick-start.
