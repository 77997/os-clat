# MTU-1: getting an IPv6 MTU of 1520 / 1528 on an OPNsense PPPoE WAN, and how a plugin learns the effective value

Research date: 2026-10-11. Research only. **Nothing was executed on a box**; every statement comes from reading
source or public pages. Confidence tags: **[V]** verified in a primary source, **[L]** likely (inferred from
verified code, not run), **[U]** unverified.

Path abbreviations (all under `refs/`):

- `CORE` = `opnsense-core` (opnsense/core master). stable/26.7 was re-read through
  `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/interfaces.inc` (fetched excerpts; no local
  line numbers).
- `SRC` = `opnsense-src` (stable/26.7, sparse). `sys/netgraph` and `usr.sbin/ndp` are not in the sparse clone and
  were read from `https://raw.githubusercontent.com/opnsense/src/stable/26.7/...`.
- `PORTS` = `opnsense-ports/net/mpd5` (`DISTVERSION= 5.9`, `PORTREVISION= 20`, `Makefile:2-3`).
- mpd5 C source: release tag `https://sourceforge.net/p/mpd/svn/HEAD/tree/tags/RELEASE_5_9/src/<file>?format=raw`
  ("5.9 tag") and trunk `.../tree/trunk/src/<file>?format=raw` ("trunk"). These were read as short verbatim
  excerpts, not whole files. The packaged binary is the 5.9 tag plus the patches in `PORTS/files/`.

---

## 0. Answer in one screen

| Question | Answer | Conf. |
|---|---|---|
| Does core emit `set pppoe max-payload`? | Yes, on master and stable/26.7, whenever the PPP MTU is above 1492. It never emits `set iface mtu`. | V |
| Which field? | The **MTU field of the assigned PPPoE interface (WAN)**. PPP MTU = that value minus 8. The same field also sets the MTU of the parent NIC / VLAN. Alternative: per-link MTU in Interfaces > Devices > Point-to-Point (advanced), which is used as-is. | V |
| PPP MTU 1500 (WAN MTU 1508) | Works by code and by many field reports. mpd5 keeps it across reconnects. | V (code), field reports |
| PPP MTU 1520 / 1528 (WAN MTU 1528 / 1536) | **Three obstacles in stock 26.7**, all on the OPNsense side: (A) core writes `set pppoe max-payload` *before* `set pppoe iface`; at that moment mpd5 cannot read the parent MTU and limits the value to 1510, so 1520 is rejected and the session comes up at 1492; (B) mpd5 caps the `pppoeN` MTU at 1500 unless `set iface mtu` is given, core papers over this with one `ifconfig pppoeN mtu N` after start, and mpd5 puts it back to at most 1500 at the next reconnect; (C) that one `ifconfig` is unconditional, so when negotiation fell back the ifnet MTU is larger than what the PPP link carries and oversize packets are dropped silently. | A: L (code V, runtime log shows the failing lookup). B, C: L |
| Effective IPv6 MTU | `IN6_LINKMTU(ifp)`: the RA-advertised MTU if it is non-zero and below `if_mtu`, else `if_mtu`. An RA can lower it, never raise it above `if_mtu`. The RA value is sticky for the life of the ifnet. | V |
| How to read it | `if_mtu` (SIOCGIFMTU / `ifconfig`) plus raw `linkmtu` (SIOCGIFINFO_IN6 / `ndp -i`), then apply the kernel formula. `ndp -i` prints the **raw** value (0 when no RA MTU option was accepted), not the effective one. | V |
| Change notification | `RTM_IFINFO` on every successful SIOCSIFMTU, `RTM_IFANNOUNCE` on ifnet arrival/departure. No message for an RA-driven change. An mpd5-internal redial keeps the ifnet; a core-driven restart of mpd5 destroys and re-creates it. | V / L |
| Other 1500 caps | None in pf or in core's rule generation. mpd5 `tcpmssfix` is IPv4-only. A WAN `mss` value left over from a 1492 setup would still clamp. LAN MTU 1500 bounds what hosts send. | V |
| Fallback | PPP level: 1492 (mpd5 needs the PADS to echo exactly the value it sent). Kernel level: not reliable, see (C). The plugin must not trust the ifnet MTU alone. | V / L |

Bottom line for the design: on stock OPNsense 26.7 the largest PPPoE MTU that is supported end to end is **1500**
(translated IPv4 MTU 1480, MSS 1440). 1520/1528 needs a small change in core's mpd5 config generator
(section 8). The ISP side can be prepared independently (section 6).

---

## 1. What core generates

### 1.1 Where the PPP MTU comes from **[V]**

`CORE/src/etc/inc/interfaces.inc`:

- `:1111` `$mtus = !empty($ppp['mtu']) ? explode(',', $ppp['mtu']) : [];` (per-link MTU of the PPP device)
- `:1271-1279`
  ```php
  if (empty($mtus[$pid])) {
      /* subtract default header when deriving from interface config (as shown there) */
      $mtus[$pid] = !empty($ifcfg['mtu']) ? intval($ifcfg['mtu']) - 8 : 1492;
  }
  if ($ppp['type'] == 'pppoe' && $mtus[$pid] > 1492) {
      $mpdconf_arr[] = "set pppoe max-payload " . $mtus[$pid];
  } else {
      $mpdconf_arr[] = "set link mtu " . $mtus[$pid];
  }
  ```
- `:1280-1287` `set link mru` / `set link mrru` only when the PPP device has those fields filled.
- `:1337-1338` `set pppoe service "..."` then `set pppoe iface {$port}`. These are appended to the same array
  **after** the max-payload line, so the generated file has max-payload first.
- `:1366-1392` after `mpd5 -b ...` is started: wait up to 20 s for the device to have the `up` flag, then
  `legacy_interface_mtu($ifcfg['if'], $mtus[0]);` (`ifconfig pppoeN mtu <value>`,
  `CORE/src/etc/inc/interfaces.lib.inc:150-158`).

`$ifcfg` is the assigned interface whose device is `pppoeN` (`:1047`), i.e. the WAN, not the parent NIC.

stable/26.7 has the same statements (fetched): the same `$mtus` line, the same max-payload / link-mtu branch, and
the function ends with a 20 x `sleep(1)` wait followed by `legacy_interface_mtu($ifcfg['if'], $mtus[0]);`.
"set iface mtu" does not occur in either branch (grep on master: the only `set iface` lines are `name`,
`on-demand`, `idle`, `addrs`, `tcpmssfix`, `up-script`, `down-script`, `interfaces.inc:1174-1200`).

### 1.2 Parent NIC / VLAN MTU **[V]**

- `interfaces.inc:2277-2285`: `$device = $realhwif = $wancfg['if'];` then
  `$ppps_hardware = interface_ppps_hardware($device); if (count($ppps_hardware)) { $realhwif = $ppps_hardware[0]; }`
  For a PPPoE WAN `$realhwif` is the parent port (`:987-1005`).
- `:2418-2420` `if (!empty($wancfg['mtu'])) { interface_configure_mtu($realhwif, $wancfg['mtu'], $ifconfig_details); }`
  runs before `interface_ppps_configure()` (`:2423`). The WAN MTU value is applied **unchanged to the parent
  device**.
- `:2240-2263` `interface_configure_mtu()`: when the device is a VLAN, the VLAN's parent gets `$mtu + 4`, unless
  that parent is itself an assigned, enabled interface with an MTU, in which case its own value is forced
  (`$parent_mtu = $parent_cfg['mtu']; $force = true;`).
- Kernel: a VLAN can have the parent's full MTU when the NIC has `IFCAP_VLAN_MTU`
  (`SRC/sys/net/if_vlan.c:1747-1762` "No need to fudge the MTU since the parent can handle extended frames"),
  and `SIOCSIFMTU` on a VLAN fails with `EINVAL` above `PARENT(ifv)->if_mtu - ifv->ifv_mtufudge`
  (`:2290-2304`). Core's "+4" is therefore more than a VLAN_MTU-capable NIC needs, and it is harmless as long as
  the NIC accepts it.

### 1.3 GUI fields **[V]**

| Page | Field | Stored as | Effect |
|---|---|---|---|
| Interfaces > [WAN] (`CORE/src/www/interfaces.php:1206-1216`) | MTU | `interfaces.wan.mtu` | parent MTU = value; PPP MTU = value - 8 unless the PPP device has its own |
| same page (`:1219-1227`) | MSS | `interfaces.wan.mss` | pf `max-mss` (value-40 / value-60) on `pppoeN` |
| Interfaces > Devices > Point-to-Point, advanced, "Link Parameters" (`CORE/src/www/interfaces_ppps_edit.php:816-839`) | MTU, MRU, MRRU | `ppps.ppp.mtu/mru/mrru` (comma list per port) | MTU used as PPP MTU as-is; MRU -> `set link mru` |

- Validation: WAN MTU 576..65535 (`interfaces.php:583-588`); per-link MTU/MRU only `>= 576`
  (`interfaces_ppps_edit.php:203-208`). No upper check against the parent.
- Help texts: "MTU: MTU will default to 1492." / "MRU: MRU will be auto-negotiated by default."
  (`interfaces_ppps_edit.php:837-838`).
- The hint "Calculated PPP MTU: N-8" is shown only when the **IPv4** type is `pppoe`
  (`interfaces.php:901-915`: `switch ($(this).val()) { case "pppoe": $("#mtu_calc").show(); ... default: $("#mtu_calc").hide(); }`
  on `#type`). With IPv4 = None, which an IPv6CP-only ISP requires, the hint is hidden; the "-8" still applies.
- The MVC model on master has the same range (`.../Interfaces/NetworkInterface.xml:59-63`).

### 1.4 History and field reports

- RFC 4638 support: opnsense/core #572, closed 2016-03-01, "will ship this tomorrow in 16.1.5"; needed mpd 5.8
  (`https://github.com/opnsense/core/issues/572`). mpd changelog: 5.7 "Added `set pppoe max-payload ...` command
  from RFC 4638", 5.8 "Added new option `override` for the command `set iface mtu`"
  (`https://mpd.sourceforge.net/doc5/mpd4.html`). **[V]**
- #6738 "PPPoE 'Baby Jumbos' - RFC 4638 - not applied on boot" (23.7.1; closed 2023-08-30, milestone 24.1):
  maintainer "VLANs cannot set MTU because the parent is not updated", "This is fixed on the development
  version" (`https://github.com/opnsense/core/issues/6738`). **[V]**
- #8435 "PPPoE interfaces MTU problems" (25.1.3, March 2025): reporter notes that at that time `$ppp['mtu']`
  was "never used in interfaces.inc" and that with WAN MTU 1508 "the pppoe0 interface also showed 1508"; the
  maintainer quotes the same "-8" lines at commit f8b35d0 (`https://github.com/opnsense/core/issues/8435`).
  The current code (per-link MTU honoured, explicit `ifconfig pppoeN mtu`) is therefore newer than 25.1.3. The
  commit that introduced it was not identified. **[V for the quotes, L for the dating]**
- Forum HOWTO (meyergru, 2025-02-05, edited 2026-02-24): PPP device advanced MTU 1500, VLAN 1508, NIC 1512,
  each underlying interface assigned; "sometimes cannot be successfully changed via UI manipulations", reboot
  "if in doubt" (`https://forum.opnsense.org/index.php?topic=45658.0`). **[V]**
- #9398 (2025-11 to 2026-06): one user sets MTU 1508 on KPN, reports success, then retracts: "duckduckgo.com
  was unreachable at 1508 but worked at 1492" (`https://github.com/opnsense/core/issues/9398`). Consistent with
  obstacle (C) below, but the cause was not diagnosed there. **[U as to cause]**
- No issue or forum thread about a PPPoE MTU **above** 1500 on OPNsense was found. All reports are about 1500.

---

## 2. What mpd5 5.9_20 does with it

### 2.1 `set pppoe max-payload` and the PPPoE discovery **[V unless marked]**

- Doc: "Set PPP-Max-Payload PPPoE tag (RFC4638)." "This option works when mpd5 acts as PPPoE client only."
  "This option takes precedence over both `set link mtu` and `set link mru` options, if PPPoE server agrees
  with our setting." (`https://mpd.sourceforge.net/doc5/mpd49.html`)
- Port patch `PORTS/files/patch-max-payload` (FreeBSD ports c9058615, 2023-03-30, PORTREVISION 14: "The
  `set pppoe max-payload` limit is now the parent interface MTU minus 8 instead of 1510",
  `https://cgit.freebsd.org/ports/commit/?id=c9058615733d904933b84ca1fada45bc0e2bbaa0`):
  - `:48` `#define PPPOE_MTU_MAX (ETHER_MAX_LEN_JUMBO - 8)` = 9010 (`SRC/sys/net/ethernet.h:20`
    `ETHER_MAX_LEN_JUMBO 9018`); `:56-57` `.mtu = PPPOE_MTU_MAX`; `.mru` stays `PPPOE_MRU` (1492).
  - `:99-118` `SET_MAX_PAYLOAD`:
    ```c
    if (pi->iface[0] == '\0') {
        if (ap < PPPOE_MRU)   /* postpone check for MTU */
            Error("PPP-Max-Payload value \"%s\" less than %d", av[0], PPPOE_MRU);
    } else {
        mtu = GetSystemIfaceMTU(pi->iface);
        if (mtu == 0)
            mtu = ETHER_MAX_LEN;
        if (ap < PPPOE_MRU || ap > mtu - 8)
            Error("PPP-Max-Payload value \"%s\" not in a range of %d..%hu", av[0], PPPOE_MRU, mtu);
    }
    pi->max_payload = ap;
    ```
  - `:83-95` `SET_IFACE`: `if (pi->max_payload > mtu - 8) { pi->max_payload = mtu - 8; Perror("[%s] PPPoE: PPP-Max-Payload value reduced to %hu", ...` (parent MTU minus 8).
  - `:129-149` `GetSystemIfaceMTU()` returns 0 when `ioctl(SIOCGIFMTU)` fails, after
    `Perror("[%s] %s: SIOCGIFMTU failed", ifname, __FUNCTION__)`.
- 5.9 tag `pppoe.c` `PppoeInit()`: `snprintf(pe->iface, sizeof(pe->iface), "undefined");`. The only other
  write to `iface` is `strlcpy(pi->iface, av[0], ...)` in `SET_IFACE`; the only test of `iface[0]` is the one
  above (trunk read). The "postpone" branch is therefore never taken for a freshly created link.
- `Error()` returns from the command handler: `#define Error(fmt, args...) do { snprintf(ctx->errmsg, ...); return(CMD_ERR_OTHER); } while (0)`
  (5.9 tag `console.h`). `ReadFile()` ignores the result and continues with the next line:
  `(*func)(ctx, ac, (const char *const *)av, filename, lineNum);` (5.9 tag `util.c`). `DoCommand()` logs
  `"%sError in '%s': %s"` with file and line (5.9 tag `command.c`).
- Kernel `ng_pppoe.c` (stable/26.7): `NGM_PPPOE_SETMAXP` stores the tag with no range check; PADI:
  `if (privp->max_payload.data != 0) insert_tag(sp, &privp->max_payload.hdr);`; PADO -> PADR:
  `if ((tag = get_tag(ph, PTT_MAX_PAYL)) && (privp->max_payload.data != 0)) insert_tag(sp, tag); /* return it */`;
  PADS: same test, then `send_maxp(sp, tag);` to mpd. `ng_pppoe.h`: `PTT_MAX_PAYL (0x0120)`. No MTU check in
  the data path.
- mpd on that message (5.9 tag and trunk `pppoe.c`):
  `if (pi->max_payload == maxp->data) pi->mp_reply = 1; else Log(LG_PHYS, ("[%s] PPPoE: sent and returned values are not equal", ...`.
  **The PADS must echo exactly the value the client sent.** A BNG that answers with its own, different maximum
  gets no jumbo session from mpd5.
- `PppoeGetMtu()/PppoeGetMru()` (patched): `if (pppoe->max_payload > 0 && pppoe->mp_reply > 0) return (pppoe->max_payload);`
  otherwise MTU = `l->conf.mtu ? l->conf.mtu : PPPOE_MTU` (1492) and MRU bounded by `l->type->mru` (1492).
  Core does not write `set link mtu` in the max-payload case, so the fallback MTU is 1492.

### 2.2 LCP **[V, trunk `lcp.c`; port patches do not touch these lines]**

```c
lcp->peer_mru = PhysGetMtu(l, 1);
lcp->want_mru = PhysGetMru(l, 1);
if (l->type && (lcp->want_mru > PhysGetMru(l, 0)))
    lcp->want_mru = PhysGetMru(l, 0);
...
if (!LCP_PEER_REJECTED(lcp, TY_MRU))
    cp = FsmConfValue(cp, TY_MRU, -2, &lcp->want_mru);
...
case MODE_REQ: ... if (mru < lcp->peer_mru) lcp->peer_mru = mru; FsmAck(fp, opt);
```

| Discovery result | MRU option mpd5 sends | Largest frame mpd5 will send (`peer_mru`) |
|---|---|---|
| PADS echoes N | N | min(N, MRU requested by the BNG) |
| no echo, or a different value | 1492 | min(1492, MRU requested by the BNG) |

Runtime example of the plain case: `MRU 1492` in both directions
(`refs/gh/opnsense_core_10828.md:221-238`).

mpd5 does not implement the RFC 4638 section 5.2 test ("the sending side SHOULD have the option of sending one
or more MRU-sized Echo-Request packets once the session is opened",
`https://www.rfc-editor.org/rfc/rfc4638.txt`): `FsmEchoTimeout()` calls `FsmSendEchoReq(fp, NULL);`, the
payload is the 4-byte magic number only (trunk `fsm.c`). A layer-2 device that silently drops the larger
frames is not detected by mpd5. **[L, one file read]**

### 2.3 What MTU mpd5 puts on the ng_iface (`pppoeN`) **[V for the code, L for the consequences]**

- `BundUpdateParams()` (trunk `bund.c`; the 5.9 context is visible in `PORTS/files/patch-overhead:5-17`):
  `if (b->n_up == 0) { mtu = NG_IFACE_MTU_DEFAULT; } else if (!b->peer_mrru) { mtu = MIN(b->links[the_link]->lcp.peer_mru, PhysGetMtu(b->links[the_link], 0)); } ... IfaceSetMTU(b, mtu);`
- 5.9 tag `iface.c`: `IfaceInit()`: `iface->mtu = NG_IFACE_MTU_DEFAULT; iface->max_mtu = NG_IFACE_MTU_DEFAULT;`
  `IfaceSetMTU()`: `if (iface->mtu_override) { mtu = iface->mtu_override; ... } else if (mtu > iface->max_mtu) mtu = iface->max_mtu;`
  then always `ioctl(s, SIOCSIFMTU, ...)`. (Trunk adds `if (mtu == iface->mtu) return;`; the 5.9 tag does not,
  and no file in `PORTS/files/` touches `IfaceSetMTU`, `max_mtu` or `SIOCSIFMTU` - grep.)
- `NG_IFACE_MTU_DEFAULT 1500`, `NG_IFACE_MTU_MAX 65535` (stable/26.7 `sys/netgraph/ng_iface.h`).
- Doc for `set iface mtu value [override]`: "Without optional keyword `override`, this command sets an upper
  bound on the MTU that will be configured"; "Even if a higher bundle MTU is negotiated, this limit will still
  apply."; default 1500 (`https://mpd.sourceforge.net/doc5/mpd28.html`). Allowed range `IFACE_MIN_MTU 296` ..
  `IFACE_MAX_MTU 65536` (trunk `iface.h`).
- Kernel `ng_ppp.c` (stable/26.7), per-link limit that mpd sets from `lcp->peer_mru` (trunk `bund.c`
  `BundJoin`: `b->pppConfig.links[l->bundleIndex].mru = b->iface.mtu_override ? b->iface.mtu_override : lcp->peer_mru;`):
  ```c
  /* Check peer's MRU for this link. */
  mru = link->conf.mru;
  if (mru != 0 && m->m_pkthdr.len > mru) {
      NG_FREE_M(m);
      ERROUT(EMSGSIZE);
  }
  ```
  A packet that fits the ifnet MTU but exceeds the negotiated MRU is freed here; no ICMP is generated for
  forwarded traffic. **[L]**

So mpd5 itself never sets `pppoeN` above 1500 with core's config. Everything above 1500 on the ifnet comes
from core's single `ifconfig pppoeN mtu N` in `interface_ppps_configure()`. No other core code sets it: `mtu`
does not occur in `CORE/src/etc/rc.newwanip`, `rc.newwanipv6`, `rc.linkup`, `rc.syshook.d/*` or
`CORE/src/opnsense/scripts/interfaces/*` (grep). **[V]**

### 2.4 The three obstacles for PPP MTU above 1500

**(A) `set pppoe max-payload` above 1510 is rejected. [L - code verified, failing lookup seen at runtime]**

Core's order is max-payload first, `set pppoe iface` later (1.1). At that point `pi->iface` is `"undefined"`,
`GetSystemIfaceMTU("undefined")` fails, `mtu` becomes `ETHER_MAX_LEN` (1518, `SRC/sys/net/ethernet.h:19`), and
the accepted range is 1492..1510. For 1520 the handler returns through `Error()`, `pi->max_payload` stays 0,
the rest of the file is still applied, no tag is sent, LCP negotiates 1492.

Runtime evidence that the lookup is done on "undefined" on OPNsense (23.7, mpd 5.9, WAN MTU 1508):
```
[wan] Bundle: Interface ng1 created
[undefined] GetSystemIfaceMTU: SIOCGIFMTU failed: Device not configured
[wan_link0] Link: OPEN event
[wan_link0] PPPoE: Set PPP-Max-Payload to '1500'
```
(`https://forum.opnsense.org/index.php?topic=37006.0`, post of 2023-11-14). 1500 is inside 1492..1510, so it
passes. No report with a value above 1510 was found, so the rejection itself was not observed. Expected log
line on a 1520 attempt: `mpd_<if>.conf:<line>: Error in 'set pppoe max-payload 1520': PPP-Max-Payload value "1520" not in a range of 1492..1518`.

**(B) mpd5 resets the ifnet MTU to at most 1500. [L]**

With the 5.9 `IfaceSetMTU()` every `BundUpdateParams()` issues `SIOCSIFMTU` with min(negotiated, 1500).
That happens when the link joins the bundle and when it leaves (`BundLeave()` -> `BundReasses(b)`, trunk
`bund.c`). Sequence:

1. mpd5 starts, session opens, mpd5 sets min(negotiated, 1500).
2. Core sees `pppoeN` up and runs `ifconfig pppoeN mtu N`.
3. Later the session drops and mpd5 redials by itself (`set link max-redial 0`, `interfaces.inc:1253`;
   example of in-process redial: "Link: reconnection attempt 1" in the forum log above). On leave mpd5 sets
   1500, on re-join min(negotiated, 1500). Core is not involved (up/down scripts do not touch the MTU).

Result: after the first mpd5-internal reconnect `pppoeN` is at 1500, not N, until core reconfigures the
interface (GUI apply, reboot, `configctl interface reconfigure`). The same result occurs when the first
session needs more than 20 s: core's `ifconfig` then runs before the link joins, and mpd5 overwrites it.
For N <= 1500 none of this matters because mpd5 computes the right value itself.

**(C) Core forces the configured MTU even when negotiation fell back. [L]**

`legacy_interface_mtu($ifcfg['if'], $mtus[0])` uses the configured number, not the negotiated one. If the PADS
did not echo the tag (ISP does not support it, value mismatch, parent NIC MTU too small so that mpd5 reduced
the value, or obstacle A), the PPP link carries 1492 while `pppoeN` says N. Packets of 1493..N bytes are
dropped in `ng_ppp_link_xmit()` without any Packet Too Big. With LAN MTU 1500 this already hits native IPv6
traffic. This also applies to N = 1500 today.

---

## 3. The settings a customer changes (question 1)

All values are for the assigned PPPoE interface (the WAN). Leave the PPP device's MRU empty. Leave the PPP
device's per-link MTU empty unless the parent interfaces are configured by hand.

| Target PPP = IPv6 MTU | WAN "MTU" field | Parent NIC (no VLAN) | VLAN parent | Generated mpd line | Stock 26.7 |
|---|---|---|---|---|---|
| 1492 (default) | empty | untouched (1500) | untouched | `set link mtu 1492` | works |
| 1500 | 1508 | 1508 | VLAN 1508, NIC 1512 | `set pppoe max-payload 1500` | works; survives reconnects |
| 1510 | 1518 | 1518 | VLAN 1518, NIC 1522 | `set pppoe max-payload 1510` | accepted by mpd5; ifnet at 1510 only until the first mpd5 redial (B) |
| 1520 | 1528 | 1528 | VLAN 1528, NIC 1532 | `set pppoe max-payload 1520` | rejected by mpd5 (A); PPP at 1492, ifnet forced to 1520 (C) |
| 1528 | 1536 | 1536 | VLAN 1536, NIC 1540 | `set pppoe max-payload 1528` | same as 1520 |

"WAN MTU 1536 gives PPP MTU 1528" is correct as far as core's arithmetic and the parent MTU go. The mpd5 step
fails. **[L]**

Further conditions **[V]**:

- If the VLAN's physical NIC is itself an assigned, enabled interface with an MTU, that MTU is forced
  (`interfaces.inc:2249-2252`) and must be large enough, otherwise the VLAN cannot be raised and mpd5 reduces
  the tag to "parent MTU - 8".
- If the non-VLAN parent NIC is assigned separately with its own MTU, two `interface_configure()` runs write
  different MTUs to the same device; the last one wins. Leave that MTU empty or equal.
- Alternative route (forum HOWTO): per-link MTU in the PPP device = PPP MTU, and the parent NIC / VLAN assigned
  with explicit MTUs. Then core does not touch the parent from the WAN record.
- What mpd5 sends when it works: PADI and PADR with PPP-Max-Payload = N (N = WAN MTU - 8, reduced to parent
  MTU - 8 if needed); LCP Configure-Request with MRU N; it accepts a peer MRU up to N. Log lines (default log
  mask includes `LG_PHYS` and `LG_LCP`, 5.9 tag `log.h`): `PPPoE: Set PPP-Max-Payload to 'N'`,
  `PPPoE: rec'd PPP-Max-Payload 'N'`, `MRU N`.
- Versions: the max-payload generator exists since 16.1.5; the parent/VLAN MTU handling was fixed in the
  23.7.x / 24.1 cycle (#6738); mpd5 accepts values above 1510 only since port revision 5.9_14 and only when
  the parent is known at that moment; OPNsense ports ship 5.9_20.

---

## 4. The ifnet MTU and the effective IPv6 link MTU (question 2)

### 4.1 `pppoeN` ifnet MTU by scenario (N = configured PPP MTU) **[L]**

| Scenario | `ifconfig pppoeN` shows | PPP link really carries |
|---|---|---|
| N <= 1500, negotiated | N | N |
| N = 1500, ISP does not echo the tag | 1500 (forced by core) | 1492 |
| N > 1500, negotiated, session up within 20 s | N | N |
| same, after an mpd5-internal reconnect | 1500 | N |
| N > 1500, negotiation fell back (incl. obstacle A) | N (forced by core) | 1492 |
| same, after an mpd5-internal reconnect | 1492 | 1492 |

Kernel limits: `SIOCSIFMTU` accepts 72..65535 (`SRC/sys/net/if_var.h:416-417`, `SRC/sys/net/if.c:2759`) and
ng_iface accepts `NG_IFACE_MTU_MIN..NG_IFACE_MTU_MAX`. Nothing in the kernel caps a PPP ifnet at 1500. **[V]**

### 4.2 Effective IPv6 MTU **[V]**

- `SRC/sys/netinet6/nd6.h:103-107`:
  ```c
  #define IN6_LINKMTU(ifp) \
      ((ND_IFINFO(ifp)->linkmtu && ND_IFINFO(ifp)->linkmtu < (ifp)->if_mtu) \
          ? ND_IFINFO(ifp)->linkmtu \
          : ((ND_IFINFO(ifp)->maxmtu && ND_IFINFO(ifp)->maxmtu < (ifp)->if_mtu) \
              ? ND_IFINFO(ifp)->maxmtu : (ifp)->if_mtu))
  ```
- `maxmtu` is a copy of `if_mtu` (`nd6.c:369-374` `ndi->maxmtu = ifp->if_mtu;`, called from `if_notifymtu()`,
  `if.c:4476-4482`, after every MTU change, `if.c:2777-2778`).
- Users: forwarding `ip6_fastfwd.c:206` `mtu = IN6_LINKMTU(nifp);`, `ip6_forward.c:393-397`; pf
  `pf.c:11098-11104` `IN6_LINKMTU(ifp) < pf_max_frag_size(*m0)` -> `icmp6_error(..., ICMP6_PACKET_TOO_BIG, 0, IN6_LINKMTU(ifp))`;
  route MTU `in6_rmx.c:117-120`; `rt_updatemtu()` uses `if_getmtu_family()` (`route.c:512-532`), which for
  inet6 is `IN6_LINKMTU` (`in6.c:2637-2643`).

### 4.3 RA MTU option **[V]**

`SRC/sys/netinet6/nd6_rtr.c:543-570`:
```c
mtu = (u_long)ntohl(ndopts.nd_opts_mtu->nd_opt_mtu_mtu);
if (mtu < IPV6_MMTU) { ... "bogus mtu option" ... goto skip; }
maxmtu = (ndi->maxmtu && ndi->maxmtu < ifp->if_mtu) ? ndi->maxmtu : ifp->if_mtu;
if (mtu <= maxmtu) {
    if (ndi->linkmtu != mtu) { ndi->linkmtu = mtu; rt_updatemtu(ifp); }
} else {
    nd6log((LOG_INFO, "%s: bogus mtu=%lu sent from %s; exceeds maxmtu %lu, ignoring\n", ...
```
- Processed only with `accept_rtadv` on the interface (`nd6_rtr.c:380-381`). Core sets it for IPv6 type SLAAC
  and DHCPv6 (`interfaces.inc:2449-2452`), not for `pppoev6`.
- It can **lower** the IPv6 MTU to anything from 1280 up to `if_mtu`.
- It can **not raise** it above `if_mtu`; a larger value is ignored (logged only with ND debugging).
- A value above the current `linkmtu` but not above `if_mtu` replaces it, so a later RA can raise a previous RA
  value up to `if_mtu`.
- `linkmtu` has no lifetime. It is cleared only when the ifnet is created (`nd6_ifattach()`, `nd6.c:285`
  `M_ZERO`). An mpd5-internal reconnect keeps the ifnet, so a value from an earlier session stays until an RA
  with another value arrives.
- Ordering trap: the first RA after IPv6CP-up can arrive while `if_mtu` is still 1500 (before core's
  `ifconfig`). An RA MTU of 1520 is then ignored (harmless, effective MTU follows `if_mtu`). An RA MTU of 1500
  is accepted and pins the IPv6 MTU to 1500 even after `if_mtu` goes to 1520. The BNG must send the session's
  real MTU or no MTU option.
- rtsold does not look at the option (no "mtu" in `SRC/usr.sbin/rtsold`, grep).

### 4.4 Reading it **[V for the interfaces, U for exact command output]**

| Source | Returns |
|---|---|
| `ifconfig pppoe0` / `SIOCGIFMTU` / core `legacy_interfaces_details()` (`interfaces.lib.inc:280-282`) | `if_mtu` |
| `ndp -i pppoe0` (stable/26.7 `usr.sbin/ndp/ndp.c`: `ioctl(sock, SIOCGIFINFO_IN6, ...)`, `xo_emit("linkmtu={:linkmtu/%d}", ND.linkmtu); xo_emit(", maxmtu={:maxmtu/%d}", ND.maxmtu);`) | **raw** `linkmtu` (0 = none) and `maxmtu`. libxo is used, so `ndp --libxo json -i pppoe0` should work. |
| `SIOCGIFINFO_IN6` (`nd6.c:1670-1672` `ND = *ND_IFINFO(ifp);`) | raw struct, same as above |
| `OSIOCGIFINFO_IN6` (`nd6.c:1657-1662` `ND.linkmtu = IN6_LINKMTU(ifp);`) | effective value, but its struct `in6_ondireq` is `#ifdef _KERNEL` only (`nd6.h:143-158`); not a clean userland API |
| `route -n get -inet6 <address in the NAT64 prefix>` | route MTU, which follows `IN6_LINKMTU` (4.2) |

Most reliable for a daemon: read `if_mtu` and the raw `linkmtu`, then compute
`effective = (linkmtu != 0 && linkmtu < if_mtu) ? linkmtu : if_mtu`. Core has no helper for the nd6 value
(no `linkmtu` / `ndp -i` in `CORE/src`, grep; radvd uses the plain `if_mtu`, `plugins.inc.d/radvd.inc:172-183`).

What the kernel numbers cannot tell: whether the PPP link really carries that size (2.4 C). Two additional
sources:

- `ngctl msg mpd<pid>-<bundle>: getconfig`: the ng_ppp node is named
  `snprintf(nm.name, sizeof(nm.name), "mpd%d-%s", gPid, b->name);` (trunk `bund.c`), the bundle name is the
  OPNsense interface key (`create bundle static {$interface}`, `interfaces.inc:1171`), the pid is in
  `/var/run/pppoe_<if>.pid`. The reply contains `links[].mru` = "peer MRU" (`ng_ppp.h` `NG_PPP_LINK_TYPE_INFO`).
  That is the real transmit limit. **[L; node name and output format need a lab check]**
- An end-to-end probe (section 7).

### 4.5 Notification **[V]**

- `SIOCSIFMTU` success -> `rt_ifmsg(ifp, 0)` (`if.c:2767-2769`) -> `RTM_IFINFO` with `ifi_mtu`
  (`if.c:1705`). Both core's `ifconfig` and mpd5's own `SIOCSIFMTU` produce it.
- Interface arrival and departure -> `RTM_IFANNOUNCE` (`rtsock.c:322`, `:329`, `:2210-2215`). A rename is
  seen as a departure of the old name: rtsold logs `interface ng0 removed` right after mpd5 created `ng0` and
  applied `set iface name pppoe0` (`refs/gh/opnsense_core_10828.md:207-208`). **[L for rename]**
- RA-driven `linkmtu` change: only `rt_updatemtu(ifp)`, no `rt_ifmsg`. Needs polling.
- Does a renegotiation re-create the ifnet?
  - mpd5-internal redial: no. `create bundle static` sets `stay = 1`; `BundLeave()` ends with
    `if (!b->stay) BundShutdown(b);` and the only teardown of the iface is in `BundShutdown()` ->
    `BundNgShutdown(b, 1, 1)` (trunk `bund.c`). The ifnet, its index and its `linkmtu` survive. **[L]**
  - Core restarts mpd5 (apply, reconfigure, `interface_ppps_reset()` -> `killbypid`, `interfaces.inc:1018`):
    yes. Runtime log: `[opt7] Bundle: Shutdown`, rtsold `interface pppoe0 removed`, new process,
    `[opt7] Bundle: Interface ng0 created` (`refs/gh/opnsense_core_10828.md:199-207`). New ifindex, `if_mtu`
    1500, `linkmtu` 0. **[V]**
  - `ppp-linkdown.sh:10` `ngctl shutdown ${IF}:` addresses the ng_pppoe node that `ppp-rename.sh:44` named
    after the device, not the ng_iface (ng_iface names its node once, `ng_name_node(node, ifp->if_xname)`, and
    has no rename handler; stable/26.7 `ng_iface.c`). **[L]**

---

## 5. Does anything else cap packets at 1500 (question 3)

| Item | Finding | Conf. |
|---|---|---|
| WAN `mtu` key | Not a cap. It is the knob (section 1). | V |
| WAN `mss` key | `filter.inc:492-501` emits `max-mss (mss-40)` inet and `(mss-60)` inet6 on `pppoeN`. A value kept from a 1492 setup (1492 is a widely repeated workaround, #9398) clamps translated TCP as well, because the CLAT flow also has a state on `pppoeN`. Clear it or set it to the new PPP MTU. | V |
| pf pre-checks | IPv4: `pf.c:11083-11090` uses `ifp->if_mtu`. IPv6: `pf.c:11098-11104` uses `IN6_LINKMTU(ifp)`. No constant. | V |
| pf reassembly / scrub | `set reassemble yes` (master `filter.inc:475-476`) or `scrub in all` (26.7). No size limit below 65535; the IPv6 check uses `pf_max_frag_size()`. | V / L |
| Firewall > Settings > Normalization | Only user-defined rules (`scrub_max_mss`, `Filter.xml:432-435`). Nothing by default. | V |
| mpd5 `tcpmssfix` | Enabled by core (`interfaces.inc:1193-1197`). IPv4 only: the option is tested only in `IfaceNgIpInit`; `IfaceNgIpv6Init` has no MSS code; `IfaceCorrectMSS` parses `struct ip` (trunk `iface.c`, first 100 kB). No effect on an IPv6CP-only session. | L |
| LAN | LAN MTU 1500 bounds what hosts send. radvd advertises min(LAN MTU, tracked WAN `if_mtu`) (`radvd.inc:172-183`), so 1500 once the WAN is at 1500 or more. | V |
| Parent NIC / VLAN | Must accept MTU = PPP MTU + 8 (1508 / 1528 / 1536); core adds 4 on the physical NIC under a VLAN. If the NIC refuses, mpd5 lowers the tag to parent MTU - 8 (`patch-max-payload:83-95`). | V |
| Everything on layer 2 between firewall and BNG | ONT / modem in bridge mode, media converter, any switch, and on a virtualised firewall the host bridge and host NIC ("you must set the larger MTU ... on the underlying host interface(s) as well", forum HOWTO). Frame on the wire for PPP MTU 1528: 1528 + 8 + 14 + 4 = 1554 bytes untagged, 1558 with one VLAN tag, 1562 with two. Which consumer ONTs and NIC drivers accept that was not researched. | U |
| mpd5 link test | None (2.2). A silent layer-2 drop is not detected. | L |

IPv4 side for completeness: nothing on the PPPoE path carries IPv4 in this design. The IPv4 limit is set by the
plugin's tun MTU and by tayga's fixed 20-byte adjustment (gap-6 report).

---

## 6. What the ISP must provide for a 1500-byte translated IPv4 MTU (question 4)

Arithmetic: IPv4 1500 becomes IPv6 1520; an IPv4 fragment of 1500 becomes 1528 (8-byte Fragment header).
"1520" covers all unfragmented traffic including every TCP segment. "1528" additionally lets full-size IPv4
fragments pass as single IPv6 fragments.

Checklist:

1. **BNG, PPPoE discovery.** Accept PPP-Max-Payload up to at least 1528 and echo the client's value unchanged
   in PADO and PADS. RFC 4638 section 4: the server "MUST respond with an echo of the clients tag in the PADO
   and PADS packets". mpd5 treats a different value as "not agreed" (2.1).
2. **BNG, LCP.** Request and acknowledge an MRU equal to the echoed value (section 5.1: MRU above 1492 only
   when "both the PPPoE client and server have indicated the ability to support a larger MRU in the PPPoE
   Discovery Stage").
3. **Publish one number per service.** Because the value must match, tell customers the exact PPP MTU
   (for OPNsense: "WAN MTU = that number + 8"). Accepting any value from 1493 up to the maximum is better,
   since stock OPNsense can currently ask for at most 1510.
4. **BNG subscriber interface IPv6 MTU** equal to the negotiated MRU, not a template default of 1492 or 1500.
   RFC 5072 section 2: "The maximum length of an IPv6 packet transmitted over a PPP link is the same as the
   maximum length of the Information field".
5. **RA MTU option** on the session: the negotiated value, or omitted. A lower value pins the customer's IPv6
   MTU (4.3). RFC 4861 section 4.6.4: the option exists "to ensure that all nodes on a link use the same MTU
   value".
6. **Access and aggregation layer 2** (OLT, ONT profile, DSLAM/MSAN, aggregation switches, wholesale handover):
   forward PPPoE frames with 1536 bytes of Ethernet payload plus the service and customer tags.
7. **IPv6 path BNG <-> NAT64**: MTU of at least 1528 on every hop, in both directions.
8. **NAT64 IPv6-side interface MTU** at least 1528; IPv4-side MTU 1500.
9. **NAT64 fragmentation threshold for DF=0 IPv4 packets.** RFC 7915 section 4: such packets are fragmented
   "so that it fits in 1280-byte IPv6 packets" and "the translator MUST provide a configuration function for
   the network administrator to adjust the threshold". Jool calls it `lowest-ipv6-mtu`, "Default: 1280", and
   warns "You want to set this value as the minimum MTU accross all your IPv6 networks"
   (`https://nicmx.github.io/Jool/en/usr-flags-global.html`). Raising it to 1520/1528 is only safe if every
   subscriber behind that NAT64 instance has that IPv6 MTU. With mixed subscribers keep it at the smallest
   subscriber MTU (or use a separate instance or prefix for jumbo subscribers) and accept that DF=0 inbound
   packets arrive fragmented. DF=1 packets, which is all TCP, are not affected by this knob ("This flag does
   not affect DF-enabled IPv4 packets").
10. **ICMP.** The NAT64 must translate in both directions with the RFC 7915 formulas (section 4.2:
    `maximum(1280, minimum(MTU + 20, MTU_of_IPv6_nexthop, MTU_of_IPv4_nexthop + 20))`; section 5.2:
    `minimum(PTB MTU - 20, MTU_of_IPv4_nexthop, MTU_of_IPv6_nexthop - 20)`). The BNG must send ICMPv6 Packet
    Too Big with the session's MTU for larger packets towards a subscriber, without a rate limit that starves
    it. ICMPv6 type 2 must not be filtered between NAT64, BNG and subscriber. This is what keeps customers who
    stay at 1492 working once the NAT64 emits 1520-byte packets.
11. **Verification from the ISP side**: a 1500-byte DF ping from an IPv4 host on the Internet side to a
    subscriber's mapped address, and the reverse, on a jumbo session and on a 1492 session.

Which NAT64 product the ISP runs, and its knob names, are not known. **[U]**

---

## 7. Fallback and what the plugin reports (question 5)

Protocol-level fallback **[V for the mpd5 code]**:

| Cause | mpd5 result |
|---|---|
| BNG ignores the tag | no `mp_reply`; MRU 1492 both ways |
| BNG echoes a different value | log "sent and returned values are not equal"; 1492 |
| Parent NIC / VLAN MTU too small | tag reduced to parent MTU - 8 ("value reduced to"), possibly down to 1492 |
| Requested value above 1510 with stock core (obstacle A) | command rejected, no tag, 1492 |
| Layer 2 drops the big frames silently | not detected; session "up" at N, large packets vanish in one or both directions |

On OPNsense the ifnet MTU does not follow these outcomes reliably (4.1). Therefore:

1. **Computed value.** `W` = effective IPv6 MTU of the WAN device (4.4). Report
   - `W >= 1528`: IPv4 MTU 1500, fragments included;
   - `1520 <= W < 1528`: IPv4 MTU 1500 for unfragmented packets;
   - `W < 1520`: IPv4 MTU `W - 20` (1492 -> 1472, 1500 -> 1480, 1510 -> 1490).
   Show `if_mtu`, the raw RA `linkmtu` and the configured WAN MTU next to it, and flag
   "configured PPP MTU N, interface shows M".
2. **Negotiated value** (optional cross-check): `links[0].mru` from the ng_ppp node, or the last
   `rec'd PPP-Max-Payload` / `MRU` lines of the PPP log. If it is lower than `if_mtu`, report a core/mpd5
   mismatch and use the lower number.
3. **Measured value.** A DF probe at the computed size through the translator, for example an ICMP echo of
   IPv4 total length X sourced from the CLAT IPv4 address to a configurable IPv4 target, or an ICMPv6 echo of
   total length `W` with fragmentation disabled to `<pref64>::<target>`. Success at X confirms
   "IPv4 MTU presented = X". On failure step down (1500, 1490, 1480, 1472, 1260) and report the largest size
   that passes. This is the only check that covers obstacle C, silent layer-2 drops, the ISP path and the
   NAT64. The forum HOWTO uses the same idea: `ping -4 -c4 -D -s 1472 1.1.1.1` "should succeed".
   The probe target has to answer large echoes; that is an operational choice.
4. Re-evaluate on `RTM_IFINFO` / `RTM_IFANNOUNCE` for the WAN device, or in the plugin's existing reconcile
   poll, and after every PPP link-up. tayga reads the tun MTU once at start, so a change of `W` means a tayga
   restart.

---

## 8. What a core fix would look like (fact base only)

From sections 2.3 and 2.4, two generator changes in `interface_ppps_configure()` would remove A and B, and one
would remove C:

- write `set pppoe iface <port>` before `set pppoe max-payload <N>` (mpd5 then validates against the real
  parent MTU, `patch-max-payload:99-118`);
- write `set iface mtu <N>` (bundle level) when N > 1500; mpd5 then sets min(negotiated, N) itself on every
  join, including after its own redials (5.9 tag `IfaceSetMTU`);
- drop or condition the unconditional `ifconfig pppoeN mtu N`.

Whether the maintainers accept this, and in which release, is open. None of it was tested.

---

## 9. Open questions

1. Lab confirmation of obstacle A on 26.7.x: WAN MTU 1528, then look for
   `Error in 'set pppoe max-payload 1520'` in the PPP log and for `MRU 1492` in LCP.
2. Lab confirmation of obstacle B: `ifconfig pppoe0` before and after an ISP-side session reset with a PPP MTU
   above 1500 (requires a hand-edited mpd config or a patched core to get that far).
3. Lab confirmation of obstacle C with N = 1500 against a BNG that does not echo the tag: does `pppoe0` show
   1500 while 1493..1500-byte packets are dropped?
4. Exact ordering of core's `ifconfig pppoeN mtu` against the first RA and against mpd5's own `SIOCSIFMTU`
   when the session needs close to 20 s.
5. `ngctl msg mpd<pid>-<bundle>: getconfig`: node name, permissions and output format on 26.7.
6. Which commit and release introduced the per-link MTU handling and the explicit `ifconfig pppoeN mtu`
   (after 25.1.3).
7. Does a link flap of the parent NIC restart mpd5 through `rc.linkup` when the parent is not assigned?
8. The ISP's BNG behaviour: does it echo the client's value or its own maximum; what MRU does it request; does
   its RA carry an MTU option, and which value.
9. The ISP's NAT64: product, IPv6-side MTU, fragmentation threshold, ICMP translation, and whether jumbo and
   non-jumbo subscribers share one instance.
10. Hardware: which ONTs, switches and NIC drivers in the customer base accept 1536-byte Ethernet payloads.
11. FreeBSD PR 270687 (mpd5 5.9_14 regression, fixed by ports commit 174076e9: "mpd5 should default to 1492
    then but revision 14 defaults to 1500") could not be read (bot protection); only the commit message was.
12. mpd5 behaviour when the BNG sends no MRU option at all after echoing the tag (code says `peer_mru` stays
    at the tag value); not confirmed against a real BNG.
