# MTU-2: tun + tayga 0.9.6 + pf with a WAN IPv6 MTU of 1520-1528 and above (up to 9000)

Research date: 2026-10-11. Source reading only. Nothing was executed on a box; every item that needs a
lab test says so. Confidence tags: **[V]** verified in the primary source, **[L]** likely (inferred from
verified code or from a standard), **[U]** unverified.

Path abbreviations (all under `refs/`):

- `SRC` = `opnsense-src` (stable/26.7, sparse). Files outside the sparse set (`sys/netinet/*`) were read
  through `https://raw.githubusercontent.com/opnsense/src/stable/26.7/<path>` (no local line numbers).
- `CORE` = `opnsense-core` (master). stable/26.7 `filter.inc` was read through
  `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/filter.inc`.
- `TAYGA` = `tayga` clone (apalrd/tayga master). Line numbers below are master. Every tayga statement that
  matters was re-read at tag 0.9.6 through `https://raw.githubusercontent.com/apalrd/tayga/0.9.6/<file>`
  (`tayga.h`, `tayga.c`, `nat64.c`, `conffile.c`; 0.9.6 has no `tun.c`, the tun code is in `tayga.c`).
  Differences between 0.9.6 and master are called out where they exist.
- Earlier report this one builds on: `research/gap-6-ipv4-mtu-mss-mechanism.md` ("gap-6").

Symbols used throughout:

| Symbol | Meaning |
|---|---|
| M | effective WAN IPv6 MTU (`IN6_LINKMTU` of the PPPoE device) |
| T | MTU of the tun = tayga `gcfg->mtu` |
| O | tayga `offlink-mtu` |
| E | min(O, T), the size limit tayga actually applies to non-DF traffic |
| C | (E - 48) & ~7, payload of the IPv6 fragments tayga emits |
| K | (T - 20) & ~7, payload of the IPv4 fragments the kernel emits toward the tun |
| V | IPv4 MTU the CLAT wants to present (1500 for normal LANs and for the IPv4 Internet behind the NAT64) |

---

## 0. Answer in one screen

| Question | Answer | Conf. |
|---|---|---|
| (1) Largest tun MTU, and does tayga 0.9.6 cope? | The kernel accepts 72..65535 on a tun and has no other size limit below 65535. tayga 0.9.6 reads into a fixed 65540-byte buffer, stores the MTU in a `uint16_t`, and accepts `offlink-mtu` 1280..65535. There is no 1500 or 9000 constant in `nat64.c`. 9000 is fine. | V |
| (2) Behaviour with T = O = M | DF: passes up to M-20, above that ICMPv4 3/4 with MTU M-20. Non-DF unfragmented: passes without Fragment header up to M-20; above that tayga fragments on the IPv6 side at C. Already-fragmented IPv4: never dropped, never an ICMP error; a fragment whose payload exceeds C is split (re-fragmented). Reverse: IPv4 = IPv6 - 20 (no Fragment header) or IPv6 - 28 (Fragment header). | V |
| (3) 1520 or 1528? | 1520 is enough for every unfragmented 1500-byte IPv4 packet in both directions, DF or not, and therefore for TCP without a clamp. 1528 is needed only for fragments: one 1500-byte IPv4 fragment becomes one 1528-byte IPv6 fragment. The direction where this matters on OPNsense is inbound (what the NAT64 sends). Ask the ISP for at least 1528. | V (arithmetic), L (inbound dependence on the NAT64) |
| (4) `mss` key | Use `mss = min(M, V+20)`: below 1520 that is M (MSS M-60, unchanged); from 1520 up it is 1520 (MSS 1460). A 1460 clamp never changes a SYN from a 1500-byte host and is still useful for the firewall's own TCP and for jumbo LANs. To remove the rule the plugin must return `'mss' => ''`; omitting the key leaves the old value in config. | V |
| (5) Cap the tun MTU? | Yes: T = min(M, V+28) = min(M, 1528). Not 1520 (the kernel would refuse the NAT64's 1528-byte fragments) and not M when M is larger (no benefit; the firewall and jumbo LANs would then believe in an IPv4 MTU of up to M). Also cap `offlink-mtu` at V+20 = 1520, see section 5.3 for the reason (a silent drop for datagrams of 1501..1508 bytes otherwise). | V (mechanisms), L (remote NAT64 behaviour) |
| (6) pf reassembly | No size problem. pf reassembles up to 65535 in both families. IPv4 is re-fragmented by the stack at the tun MTU, IPv6 by pf at the largest received fragment size. The only visible effect of a large T is that reassembled IPv4 datagrams up to T reach tayga whole. | V |

Net change to the current design: three clamps. For M below 1520 nothing changes.

```
T        = min(M, V + 28)        # was: M
O        = min(T, V + 20)        # was: M
mss key  = O                     # was: M
IPv4 MTU presented = O - 20      # = min(M - 20, V)
```

---

## 1. Maximum tun MTU on FreeBSD 15 and tayga 0.9.6 packet sizes

### 1.1 Kernel **[V]**

- Generic bound, `SRC/sys/net/if.c:2759-2760`:
  `if (ifr->ifr_mtu < IF_MINMTU || ifr->ifr_mtu > IF_MAXMTU) return (EINVAL);`
  with `IF_MINMTU 72`, `IF_MAXMTU 65535` (`SRC/sys/net/if_var.h:416-417`).
- The tun driver adds no bound of its own, `SRC/sys/net/if_tuntap.c:1466-1467`:
  `case SIOCSIFMTU: ifp->if_mtu = ifr->ifr_mtu;`
- Default on creation is 1500: `ifp->if_mtu = TUNMTU;` (`if_tuntap.c:1058`), `#define TUNMTU 1500`
  (`SRC/sys/net/if_tun.h:23`). The plugin has to set the MTU itself.
- Write side (tayga to kernel), `if_tuntap.c:2042-2053`: `mru = l2tun ? TAPMRU : TUNMRU;` ...
  `else if ((tp->tun_flags & TUN_IFHEAD) != 0) mru += sizeof(uint32_t);` ...
  `if (uio->uio_resid < 0 || uio->uio_resid > mru) { ... return (EIO); }` with `#define TUNMRU 65535`
  (`if_tun.h:26`). The write limit is 65535 + 4 and does not depend on the interface MTU.
- Read side (kernel to tayga), `if_tuntap.c:1884-1887`: `error = m_mbuftouio(uio, m, 0); m_freem(m);`.
  One packet per read; whatever does not fit the user buffer is discarded.
- `tunoutput()` (`if_tuntap.c:1516-1598`) has no length check. Size policing is done by the IP stack and
  pf against `if_mtu` (section 5).
- IPv6 follows automatically: `if_notifymtu()` calls `nd6_setmtu()` (`if.c:2777-2778`, `4476-4482`), which
  sets `ndi->maxmtu = ifp->if_mtu;` (`SRC/sys/netinet6/nd6.c:374`). `IN6_LINKMTU(tun)` is then T.

### 1.2 tayga 0.9.6 **[V, fetched excerpt of the tag]**

- Receive buffer: `gcfg->recv_buf_size = 65536 + sizeof(struct tun_pi);` (`conffile.c`, `config_init`),
  `gcfg->recv_buf = (uint8_t *)malloc(gcfg->recv_buf_size);` (`tayga.c`, `main`),
  `ret = read(gcfg->tun_fd, gcfg->recv_buf, gcfg->recv_buf_size);` and
  `if ((uint32_t)ret == gcfg->recv_buf_size) { slog(LOG_WARNING, "dropping oversized packet\n");`
  (`tayga.c`, `read_from_tun`). Master has the same size as a macro: `#define RECV_BUF_SIZE (65536+sizeof(struct tun_pi))`
  (`TAYGA/tayga.h:119`). The buffer does not depend on the MTU, so any packet up to 65535 bytes fits.
- MTU storage: `uint16_t mtu;` in `struct config` (0.9.6 `tayga.h`; master `TAYGA/tayga.h:334`). Range 0..65535.
- MTU source on FreeBSD: `if (ioctl(fd, SIOCGIFMTU, &ifr) < 0) {` ... `gcfg->mtu = ifr.ifr_mtu;`
  (0.9.6 `tayga.c`, FreeBSD branch of `tun_setup`; master `TAYGA/tun.c:546-553`). The FreeBSD branch has
  no minimum or maximum check; the `MTU_MIN` test exists only in the Linux branch
  (master `TAYGA/tun.c:359-364`). tayga never sets the MTU (no `SIOCSIFMTU` in 0.9.6 `tayga.c`) and never
  re-reads it (SIGHUP ends in `slog(LOG_NOTICE, "Exiting on signal %d\n", sig);`).
- `offlink-mtu` validation (0.9.6 `conffile.c`, identical at master `TAYGA/conffile.c:645-660`):
  `long int mtu = strtol(args[0], &endptr, 10);` / `} else if(mtu < MTU_MIN) {` / `} else if(mtu > UINT16_MAX) {` /
  `gcfg->ipv6_offlink_mtu = mtu;`. Default: `if (gcfg->ipv6_offlink_mtu <= MTU_MIN) gcfg->ipv6_offlink_mtu = MTU_MIN;`.
  Accepted range 1280..65535, decimal only. A value above T is harmless because the code takes the
  minimum (`if (frag_size > gcfg->mtu) frag_size = gcfg->mtu;`).
- Constants: `#define MTU_ADJ 20u`, `#define MTU_MIN 1280` (0.9.6 `tayga.h`; master `TAYGA/tayga.h:184,187`).
  There is no `MTU_MAX`. Neither 1500 nor 9000 occurs in 0.9.6 `nat64.c`; 1280 appears as `MTU_MIN` and 576
  only as the cap on the size of ICMPv4 errors tayga generates.
- Lengths inside `nat64.c` are `uint32_t` (`struct pkt.data_len`, `header_len`, `frag_size`), and the
  fragment sanity checks use 65535 (`TAYGA/nat64.c:536-540`, `1076-1080`).

Conclusion: a tun MTU of 1520, 1528 or 9000 is inside every limit of the kernel and of tayga 0.9.6.
OPNsense ships exactly this version (`refs/opnsense-ports/net/tayga/Makefile:2` `DISTVERSION= 0.9.6`).

Operational consequences that follow from the same lines **[V]**: the MTU must be on the tun before tayga
starts, and tayga must be restarted whenever T changes.

---

## 2. Exact behaviour with T = O = M

### 2.1 The code that decides (0.9.6 confirmed, master line numbers)

`xlate_4to6_data`, `TAYGA/nat64.c:374-377` and `411-422`:

```c
frag_size = gcfg.ipv6_offlink_mtu;
if (frag_size > gcfg.mtu)
    frag_size = gcfg.mtu;
frag_size -= sizeof(struct ip6);
...
if ((off & (IP4_F_MASK | IP4_F_MF)) == 0) {          /* not a fragment */
    if (off & IP4_F_DF) {
        if (gcfg.mtu - MTU_ADJ < p->header_len + p->data_len) {
            host_send_icmp4_error(3, 4, gcfg.mtu - MTU_ADJ, p);
            return;
        }
        no_frag_hdr = 1;
    } else if (p->data_len <= frag_size) {
        no_frag_hdr = 1;
    }
}
```

Fragmenting path, `TAYGA/nat64.c:452-459`: `frag_size = (frag_size - sizeof(header.ip6_frag)) & ~7;`,
`while (p->data_len > 0) {`, `if (p->data_len < frag_size) frag_size = p->data_len;`,
`header.ip6.payload_length = htons(sizeof(struct ip6_frag) + frag_size);`.

The author's comment at `nat64.c:402-410` states the fragment rule: "We do not respect the DF flag for IP4
packets that are already fragmented, because the IP6 fragmentation header takes an extra eight bytes".

`xlate_6to4_data`, `nat64.c:983-986`:
`if (sizeof(struct ip6) + p->header_len + p->data_len > gcfg.mtu) { ... host_send_icmp6_error(2, 0, gcfg.mtu, p);`

`xlate_header_6to4`, `nat64.c:857-881`: `if (p->ip6_frag) {` ... `/* Always clear DF bit */` ...
`} else if (p->header_len + payload_length <= MTU_MIN) {` (DF clear, generated ident) ...
`} else { ip4->ident = 0; ip4->flags_offset = htons(IP4_F_DF); }`.

ICMP translation: frag-needed to PTB `mtu += MTU_ADJ; if (mtu > gcfg.mtu) mtu = gcfg.mtu; if (mtu < MTU_MIN) mtu = MTU_MIN;`
(`nat64.c:645-652`); PTB to frag-needed `if (mtu > gcfg.mtu) mtu = gcfg.mtu; mtu -= MTU_ADJ;` (`nat64.c:1179-1181`).

Errors tayga generates itself: `host_send_icmp4_error` sends from `gcfg.local_addr4` to the packet's
source, quoting at most `576 - sizeof(struct ip4) - sizeof(struct icmp)` bytes (`nat64.c:260-267`).

### 2.2 IPv4 to IPv6, as tayga sees the packet (IPv4 header without options) **[V]**

L is the IPv4 total length, P the IPv4 payload length of a fragment.

| IPv4 packet entering tayga | Result with T = O = M |
|---|---|
| DF, not a fragment, L <= M-20 | one IPv6 packet of L+20 bytes, no Fragment header |
| DF, not a fragment, L > M-20 | dropped; ICMPv4 type 3 code 4, next-hop MTU M-20, from tayga's `ipv4-addr` to the packet's source |
| non-DF, not a fragment, L <= M-20 | one IPv6 packet of L+20 bytes, no Fragment header (no atomic fragment) |
| non-DF, not a fragment, M-20 < L <= M | IPv6 fragments with payload C = (M-48) & ~7: first is 48+C bytes, second carries the rest. No error |
| IPv4 fragment (MF set or offset non-zero), P <= C | one IPv6 fragment of 48+P bytes; DF is ignored |
| IPv4 fragment, P > C | **re-fragmented**: split into IPv6 fragments of C bytes payload plus a remainder. Not dropped, no ICMP error |

With IPv4 options the DF test uses the full length (`header_len + data_len`) while the non-DF test uses only
the payload (`data_len <= frag_size`); the resulting IPv6 packet is 40 + payload either way.

What reaches tayga is first filtered by the kernel (section 5.1): a forwarded packet larger than T never
arrives whole. With DF it is answered by pf with frag-needed MTU T; without DF the stack cuts it into
fragments with payload K = (T-20) & ~7 (`int len = (mtu - hlen) & ~7;` in `ip_fragment()`, stable/26.7
`sys/netinet/ip_output.c`). Because K - C is always 24 or 32, tayga splits every full-size kernel-made
fragment in two.

Numbers:

| M = T = O | DF limit (M-20) | no-header limit for non-DF (M-20) | C | 48+C | K | a 1500-byte IPv4 fragment (P = 1480) becomes |
|---|---|---|---|---|---|---|
| 1492 | 1472 | 1472 | 1440 | 1488 | 1472 | 1440 + 40 (two IPv6 fragments) |
| 1500 | 1480 | 1480 | 1448 | 1496 | 1480 | 1448 + 32 |
| 1520 | 1500 | 1500 | 1472 | 1520 | 1496 | 1472 + 8 |
| 1528 | 1508 | 1508 | 1480 | 1528 | 1504 | one 1528-byte IPv6 fragment |
| 9000 | 8980 | 8980 | 8952 | 9000 | 8976 | one 1528-byte IPv6 fragment |

### 2.3 IPv6 to IPv4 **[V]**

L6 is the IPv6 total length. The kernel does not hand tayga anything above T (section 5.1); tayga checks
again and would answer with ICMPv6 Packet Too Big, MTU T.

| IPv6 packet from the NAT64 | IPv4 packet tayga writes |
|---|---|
| no Fragment header, L6 <= M | L6 - 20 bytes. DF = 0 with a generated ident when the IPv6 payload is at most 1280 bytes, else DF = 1 and ident 0 |
| with Fragment header, L6 <= M | L6 - 28 bytes. DF = 0, MF and offset copied, ident = low 16 bits of the IPv6 ident |

Largest IPv4 result: M-20 without, M-28 with Fragment header. It exceeds a 1500-byte LAN only when the
NAT64 really sends more than 1520 (no header) or 1528 (header) bytes, which requires M above those values
and an IPv4 packet above 1500 bytes arriving at the NAT64. The IPv4 Internet does not deliver that, and a
LAN host's own SYN advertises MSS 1460. If it does happen **[V for the quoted checks, L end to end; the
source address the kernel picks for its ICMP error was not traced]**:

- DF = 1 result larger than the LAN MTU: pf answers on the LAN's outbound hook with frag-needed, MTU = LAN
  `if_mtu` (`SRC/sys/netpfil/pf/pf.c:11083-11087`). That error is routed into the tun and tayga turns it
  into Packet Too Big with MTU 1500 + 20 = 1520 for the NAT64.
- DF = 0 result (it came with a Fragment header): pf reassembles on the tun's inbound hook and the stack
  fragments for the LAN at 1500 (`ip_fragment(ip, &m, nifp->if_mtu,` in stable/26.7 `ip_fastfwd.c`). No loss.

---

## 3. Minimum M for a full 1500-byte IPv4 MTU

All numbers are for IPv4 headers without options.

| Traffic | Requirement at tayga | Minimum |
|---|---|---|
| DF packet of 1500 bytes (all TCP, QUIC, most modern UDP) | T - 20 >= 1500 | **M >= 1520**, T >= 1520 |
| non-DF, unfragmented, 1500 bytes | E - 40 >= 1480 | **M >= 1520**, T >= 1520, O >= 1520 |
| 1500-byte IPv4 fragment (P = 1480) translated one to one, outbound | C >= 1480, i.e. E >= 1528 | **M >= 1528**, T >= 1528, O >= 1528 |
| the NAT64's translation of a 1500-byte IPv4 fragment (1528-byte IPv6 fragment), inbound | the WAN link and the tun must both carry 1528 | **M >= 1528**, T >= 1528 |

So:

- **1520 is enough** for "IPv4 MTU 1500" in the path-MTU sense: every unfragmented packet up to 1500 bytes
  passes in both directions with no fragmentation and no ICMP, TCP needs no MSS reduction (natural MSS 1460).
- **1528 is needed only for fragments.** Two qualifications decide how much that matters here:
  1. Outbound, in the default OPNsense configuration, tayga does not see the LAN host's fragments at all.
     pf reassembles them on the LAN (26.7: `scrub in all`; master: `set reassemble yes`), the stack
     re-fragments at T if the datagram is larger than T, tayga cuts those, pf reassembles the IPv6
     fragments on the tun and re-fragments them on the WAN at tayga's largest fragment (section 6). The
     wire carries IPv6 fragments of 48 + C bytes. With E = 1520 that is 1520 bytes (IPv4 1492 after the
     NAT64), with E = 1528 it is 1528 bytes (IPv4 1500). The datagram arrives either way; the difference is
     at most one extra fragment. The one-to-one case exists only when pf reassembly is switched off.
  2. Inbound there is no such cushion. A fragmented IPv4 datagram from the Internet reaches the NAT64 as
     1500-byte fragments and leaves it as 1528-byte IPv6 fragments unless the NAT64 is configured to cut
     them smaller. With M below 1528 they do not fit the PPPoE link; with T below 1528 the CPE itself
     rejects them (section 5.2). **[L]**: depends on the ISP's NAT64 settings.

Recommendation to the ISP side: negotiate a PPP payload of **at least 1528** and make sure the NAT64's
IPv6 side and the path from it to the BNG carry 1528. If only 1520 is available, the NAT64 must keep its
IPv6 fragments within 1520.

---

## 4. The interface `mss` key as a function of M

### 4.1 What core does with it **[V]**

- master, `CORE/src/etc/inc/filter.inc:491-502`:
  `if (is_numeric($scrubcfg['mss'] ?? '')) {` ...
  `$mssclampv4 = 'max-mss ' . (intval($scrubcfg['mss'] - 40));` `$mssclampv6 = 'max-mss ' . (intval($scrubcfg['mss'] - 60));` ...
  `"match on {$scrubcfg['if']} inet all scrub ( {$mssclampv4}{$random_id} )\n"` and the inet6 twin.
- stable/26.7 (fetched excerpt): same condition and arithmetic, rendered as
  `"scrub on {$scrubcfg['if']} inet all {$scrub_gen_opts} {$mssclampv4}\n"` and the inet6 twin, inside
  `if (empty($config['system']['scrub_interface_disable'])) {`, followed by `"scrub in all {$scrub_gen_opts}\n"`.
- A CLAT flow has one state on the tun per family; the effective clamp is the inet6 one, `mss - 60` (gap-6
  section 3.5).
- pf only lowers: `if (ntohs(mss) > pd->act.max_mss) {` (`SRC/sys/netpfil/pf/pf_norm.c:1987`).

### 4.2 How to get no rule **[V]**

`CORE/src/etc/inc/plugins.inc:218-226` only walks the properties the plugin returns:

```php
foreach ($intf_data as $prop_name => $prop_value) {
    if ((empty($intf_config[$prop_name]) && !empty($prop_value)) || ($intf_config[$prop_name] ?? '') != $prop_value) {
        ...
        $intf_config[$prop_name] = $prop_value;
```

- Omitting `mss` leaves a previously stored value in `config.xml`; the old rule stays.
- Returning `'mss' => ''` overwrites it (`'1492' != ''`), and `is_numeric('')` is false, so no rule is
  rendered. With nothing stored, `'' != ''` is false and the key is never created.
- Never return `0`: it is numeric and would render `max-mss -40`.

### 4.3 Is a clamp of exactly 1460 harmful? **[V]**

No. For a host on a 1500-byte LAN the SYN already carries 1460 and the comparison at `pf_norm.c:1987` is
false, so nothing is rewritten. Costs and side effects:

- The option walk runs on every TCP packet of the state, not only on SYNs:
  `if (pd.proto == IPPROTO_TCP && pd.act.max_mss) pf_normalize_mss(&pd);` (`SRC/sys/netpfil/pf/pf.c:11303-11304`).
  That is a small per-packet cost, the same one the design already pays for M below 1520.
- On 26.7 the two `scrub on tun464 ...` rules are legacy scrub rules matched first, in both directions;
  without them only `scrub in all` (inbound) applies on the tun. They carry the same generic options, so
  apart from `max-mss` the only difference is normalisation in the outbound direction as well. No
  functional difference for this datapath was found. **[L]**

### 4.4 Is there still a reason to clamp at M >= 1520? **[V mechanism, L judgement]**

Yes, three senders are not limited by a 1500-byte interface:

1. **The firewall itself.** Its TCP takes the MTU from the route/interface: `maxmtu = nh->nh_mtu;`
   (`tcp_maxmtu`, stable/26.7 `sys/netinet/tcp_subr.c`). Through the tun that is T, so it advertises
   MSS T-40, which is always at least 20 above what fits (O-60). The clamp corrects both the SYN and the
   SYN-ACK without any ICMP.
2. **Jumbo LANs.** A host with MTU 9000 advertises 8960. As long as the peer is an ordinary 1500-byte
   server, the peer's own 1460 limits both directions. If the peer also has a large MTU, only a clamp or
   PMTUD keeps segments at 1460.
3. **Peers that advertise more than 1460.** Same case seen from the other end.

Without the clamp these cases still work, but through path-MTU discovery: tayga's frag-needed (T-20), then
the NAT64's Packet Too Big translated by tayga to frag-needed 1500. That depends on the ISP's NAT64
emitting ICMPv6 errors.

Recommendation: `mss = min(M, V+20)` in automatic mode for every M. For M >= 1520 that is the constant
1520 (rules `max-mss 1480` inet and `max-mss 1460` inet6, effective 1460). Offer "off", which returns `''`.
A jumbo LAN does not call for a different value: the limit is the 1500-byte IPv4 side of the NAT64, not the LAN.

---

## 5. Should the tun MTU be capped?

### 5.1 Where the kernel uses T **[V]**

| Check | Code | Effect |
|---|---|---|
| forwarded IPv4, DF, out on the tun, before NAT | `SRC/sys/netpfil/pf/pf.c:11083-11087`: `pd.df && (*m0)->m_pkthdr.len > ifp->if_mtu` then `icmp_error(*m0, ICMP_UNREACH, ICMP_UNREACH_NEEDFRAG, 0, ifp->if_mtu);` | LAN host is told MTU T by the firewall |
| forwarded IPv4, any | stable/26.7 `ip_fastfwd.c`: `if (ip_len <= nifp->if_mtu) {` / `if (ip_off & IP_DF) {` / `if (ip_fragment(ip, &m, nifp->if_mtu,` ; "nh_mtu" does not occur in the file | non-DF packets above T are cut into fragments with payload K |
| forwarded IPv6, out on the tun, pf | `pf.c:11098-11101`: `IN6_LINKMTU(ifp) < pf_max_frag_size(*m0)` then `icmp6_error(*m0, ICMP6_PACKET_TOO_BIG, 0, IN6_LINKMTU(ifp));` | sender (the NAT64 side) is told MTU T |
| forwarded IPv6, stack | `SRC/sys/netinet6/ip6_forward.c:393-397`: `if (m->m_pkthdr.len > IN6_LINKMTU(ifp)) {` ... `icmp6_error(mcopy, ICMP6_PACKET_TOO_BIG, 0, IN6_LINKMTU(ifp));` | same, also applied to each fragment pf re-creates |
| firewall-originated TCP | `maxmtu = nh->nh_mtu;` (`tcp_subr.c`) | MSS T-40 unless clamped |

`ip_tryforward()` has no early exit for fragments and runs the input hook (`pfil_mbuf_in`) before the
forward hook (`pfil_mbuf_fwd`), so a pf-reassembled datagram is what gets compared with T.

### 5.2 Three candidates for M >= 1528

| | T = 1520 | T = 1528 (V+28) | T = M (for example 9000) |
|---|---|---|---|
| DF limit tayga enforces and reports (T-20) | 1500, exact | 1508 | 8980 |
| IPv6 from the NAT64, 1500-byte IPv4 unfragmented (1520) | accepted | accepted | accepted |
| IPv6 fragments from the NAT64, 1500-byte IPv4 fragment (1528) | **refused**: pf re-creates the 1528-byte fragment and `ip6_forward` answers Packet Too Big 1520 | accepted | accepted |
| IPv6 above 1528 from the NAT64 | refused, PTB 1520 | refused, PTB 1528 | accepted up to M |
| Largest IPv6 packet tayga can emit | 1520 | 1528 | M |
| Firewall-originated IPv4 believes in MTU | 1520 (20 too many) | 1528 (28 too many) | M |
| Largest whole IPv4 datagram handed to tayga | 1520 | 1528 | M |
| tayga restart needed when M changes | only if M drops below 1520 | only if M drops below 1528 | on every change |

Why T = 1520 is wrong when the link carries 1528: the fragment row. pf reassembles the NAT64's fragments
on the WAN, re-creates them on the tun's outbound hook with their original payload
(`SRC/sys/netpfil/pf/pf_norm.c:1078-1087`, `maxlen = maxlen & ~7;` `error = ip6_fragment(ifp, m, hdrlen, proto, maxlen, frag_id);`)
and feeds each to `ip6_forward(m, 0)` (`pf_norm.c:1126-1128`), where the 1528-byte fragment fails the
check against `IN6_LINKMTU(tun)`. The Packet Too Big goes to a sender that already fragments at 1500 on
its IPv4 side, so the datagram is lost every time. **[V for the local steps, L for the outcome]**

Why T = M brings nothing for M above 1528 **[L]**:

- IPv4 behind the NAT64 is the 1500-byte Internet. Presenting more than 1500 to IPv4 senders can only end
  in a Packet Too Big from the NAT64.
- The firewall's own IPv4 (TCP MSS, IPsec, OpenVPN, GRE outer packets) would size itself for M. With the
  cap the error is bounded to 28 bytes.
- The jumbo capability only has to exist where it was promised (1528 end to end). A PPPoE link MTU of 9000
  says nothing about the path from the BNG to the NAT64.
- T stops following M, so PPPoE renegotiations above 1528 do not restart tayga.

What the cap costs: IPv6 packets above 1528 from the NAT64 are answered with Packet Too Big 1528. A NAT64
translating from the 1500-byte IPv4 Internet does not produce them. If a deployment really has IPv4 above
1500 behind the NAT64, the user raises V.

Consequence for 1500-byte LAN hosts with T >= 1520: neither pf's pre-NAT check nor the stack check can
fire any more. In the 1492 design a 1500-byte DF packet needed two ICMP rounds (1492 from pf, then 1472
from tayga); with M >= 1520 it needs none.

Firewall-originated IPv4 and PMTUD against tayga **[L]**: the firewall's packets leave with source
192.0.0.1, so tayga's frag-needed (from 192.0.0.2 to 192.0.0.1) is delivered locally and matched by pf to
the state the outgoing packet created on the tun (gap-6 section 5.2 for the matching rules). With T = 1528
a DF packet of 1509..1528 bytes is answered by tayga with MTU 1508; 1501..1508 passes tayga and is
corrected by the NAT64's Packet Too Big (tayga converts 1520 to 1500). TCP does not get there because of
the clamp. The kernel cannot be told "1500" for the tun: one MTU per interface, and core adds the default
route without `-mtu` (gap-6 sections 2 and 4).

### 5.3 The second cap: `offlink-mtu` at V+20

With E above 1520, tayga sends non-DF IPv4 packets of 1501..(E-20) bytes as IPv6 packets **without** a
Fragment header (`} else if (p->data_len <= frag_size) { no_frag_hdr = 1;`). Such packets do reach tayga:

- pf reassembles a LAN host's fragments into one datagram and clears MF and offset
  (`pf_norm.c:873-875`, `ip->ip_off &= ~(IP_MF|IP_OFFMASK);`),
- the stack forwards it whole when it is not larger than T (`if (ip_len <= nifp->if_mtu) {`).

At the NAT64 an IPv6 packet without Fragment header becomes an IPv4 packet with DF set: RFC 7915 section
5.1, "If the size of the translated IPv4 packet is less than or equal to 1260 bytes, it is set to zero;
otherwise, it is set to one." A 1501..1508-byte result does not fit a 1500-byte IPv4 link, so the NAT64
drops it and returns Packet Too Big. tayga converts that to frag-needed 1500 for a host that sent DF = 0
fragments at MTU 1500 already. Nothing changes on the next datagram. **[V for tayga and pf, L for the
NAT64 and the host]**

Concrete case with T = O = 1528: a UDP datagram with 1473..1480 bytes of payload (IPv4 length 1501..1508)
from a 1500-byte host. It would be lost every time. With T = O = 9000 the window is every fragmented
datagram of 1501..8980 bytes.

With O = V+20 = 1520 the no-header limit is exactly 1500. Anything larger gets Fragment headers
(C = 1472, IPv6 fragments of 1520 bytes), the NAT64 emits DF = 0 fragments, and the datagram arrives.
RFC 7915 section 4.1 describes this knob as the "user-defined length" above which a non-DF packet is
fragmented; it is the size at which the CLAT stops treating a non-DF packet as if it had DF.

Price of O = 1520 when M >= 1528:

- Outbound fragments on the wire are 1520 instead of 1528 bytes (payload 1472 instead of 1480).
- With pf reassembly switched off, each 1500-byte IPv4 fragment from a LAN host becomes two IPv6 fragments
  (1520 and 56 bytes). Works, wasteful. A plugin could use O = T in that one case; the 1501..1508 window
  then only concerns jumbo LANs and the firewall itself. This is an optional refinement, not part of the
  recommended default.

For M below 1520 neither cap is active and the window does not exist (the no-header limit M-20 is below 1500).

---

## 6. pf scrub and reassembly with packets above 1500 crossing the tun twice

Facts **[V]**:

- When reassembly happens. With legacy scrub rules present (26.7) a packet is normalised only if a scrub
  rule matches; IPv4 fragments are then reassembled unless the rule says otherwise, IPv6 always
  (`pf_norm.c:1157-1167`, `1193-1197`, `1255-1256`, `1344-1348`, `1363-1366`). `scrub in all` covers every
  inbound hook. Without scrub rules (master) reassembly follows `set reassemble`:
  `"set reassemble %s%s\n", $enabled ? 'yes' : 'no'` (`CORE/src/etc/inc/filter.inc:476`); kernel default is
  off (`V_pf_status.reass = 0;`, `SRC/sys/netpfil/pf/pf_ioctl.c:407`).
- Size limits are the protocol maximum, not the MTU: `if (hdrlen + total > IP_MAXPACKET) {` (`pf_norm.c:877`),
  `if (hdrlen - sizeof(struct ip6_hdr) + total > IPV6_MAXPACKET) {` (`pf_norm.c:998`). Per datagram at most
  `PF_FRAG_ENTRY_LIMIT 64` fragments per 4096-byte offset bucket (`SRC/sys/net/pfvar.h:1852-1859`,
  `pf_norm.c:413,430`); tayga's doubling of fragments stays far below that (about six per bucket).
- IPv4 is never re-fragmented by pf. The reassembled packet goes back to the stack, which fragments at the
  outgoing `if_mtu` (section 5.1). pf only refuses DF packets above the MTU.
- IPv6 is re-fragmented by pf on the outbound hook to the largest fragment payload it received:
  `frag->fr_maxlen = frent->fe_len;` / `if (frent->fe_len > frag->fr_maxlen)` (`pf_norm.c:632,655-656`),
  `ftag->ft_maxlen = maxlen;` (`:982`), `action = pf_refragment6(ifp, m0, mtag, NULL, pflags & PFIL_FWD);`
  (`pf.c:11503-11506`). `fe_len` is the payload behind the Fragment header
  (`frent->fe_len = sizeof(struct ip6_hdr) + ntohs(ip6->ip6_plen) - hdrlen;`, `pf_norm.c:918`), and
  `ip6_fragment()` takes a payload length (`SRC/sys/netinet6/ip6_output.c:232-291`,
  `m->m_pkthdr.len = fraglen + hlen + sizeof(*ip6f);`). Re-created fragments are never larger than the
  largest original one.
- pf's forward check for reassembled IPv6 compares the link MTU with that payload length
  (`pf_max_frag_size()` returns `ftag->ft_maxlen`, `pf_norm.c:1019-1031`), which is 48 bytes lenient; the
  full-length check is the one in `ip6_forward()` on each re-created fragment (they carry
  `M_SKIP_FIREWALL`, `pf_norm.c:1103`, and pf passes them, `pf.c:11031-11033`).

The four crossings with the recommended values (T = 1528, O = 1520, M >= 1528, LAN 1500, reassembly on):

| Step | Outbound, LAN host sends a 4000-byte UDP datagram as 1500-byte fragments |
|---|---|
| in on LAN (inet) | reassembled to one 4000-byte packet |
| out on tun (inet) | not DF, passes pf; stack fragments at T: payload K = 1504 |
| tayga | each 1504-byte fragment becomes IPv6 fragments of 1472 + 32 bytes payload (same ident, contiguous offsets) |
| in on tun (inet6) | reassembled; remembered fragment payload 1472 |
| out on WAN (inet6) | re-fragmented at 1472: 1520-byte IPv6 fragments, each <= M |

| Step | Inbound, NAT64 sends 1528-byte IPv6 fragments |
|---|---|
| in on WAN (inet6) | reassembled; remembered fragment payload 1480 |
| out on tun (inet6) | re-fragmented at 1480: 1528-byte fragments, each must be <= T (this is why T >= 1528) |
| tayga | 1500-byte IPv4 fragments, DF clear |
| in on tun (inet) | reassembled |
| out on LAN (inet) | stack fragments at the LAN MTU |

Effect of a large T that is specific to reassembly: a reassembled IPv4 datagram of up to T bytes is handed
to tayga in one piece. Combined with a large E that is the silent-drop window of section 5.3. With
E <= V+20 it is harmless: tayga adds Fragment headers above 1500.

With reassembly switched off (26.7 `scrub_interface_disable`, master `scrub_enabled` = 0) the fragments
pass tayga individually; see the last bullet of section 5.3. No MSS rule is generated in that state either.

---

## 7. Recommended algorithm

```
inputs
  M            effective WAN IPv6 MTU: IN6_LINKMTU(wan) = min(if_mtu, RA link MTU)
  ovr          optional user override of the IPv6 MTU the CLAT may use ('' = automatic)
  V            IPv4 MTU to present, default 1500 (advanced setting; 1500 = IPv4 Internet behind the NAT64)
  mss_mode     auto | off | <number>           default auto
  scrub_on     global pf normalisation switch (26.7: system.scrub_interface_disable empty;
               master: Filter.settings.scrub_enabled not '0')

derive
  if ovr != '' and ovr > M:  warn "override above the WAN IPv6 MTU, using M"
  Mc = (ovr != '') ? min(ovr, M) : M
  if Mc < 1280:              error "IPv6 MTU below 1280, CLAT cannot run"; stop

  T  = min(Mc, V + 28)       # tun MTU; set on the device before tayga starts
  O  = min(T,  V + 20)       # tayga.conf: offlink-mtu O
  ipv4_mtu = O - 20          # status "IPv4 MTU presented" = min(Mc - 20, V)

  if   mss_mode == off:      mss_key = ''          # key present, empty: removes core's rule
  elif mss_mode is number:   mss_key = mss_mode
  else:                      mss_key = O           # core renders max-mss O-40 (inet), O-60 (inet6)
  tcp_mss = (mss_key == '') ? none : mss_key - 60  # status "TCP MSS clamp"

outputs
  tun MTU T, offlink-mtu O, interface property 'mss' => mss_key,
  status: ipv4_mtu, tcp_mss, df_limit = T - 20, fragment_payload = (O - 48) & ~7

warnings / notices
  Mc < V + 20:            "IPv4 MTU is {ipv4_mtu}; TCP MSS clamped to {tcp_mss}"         (normal for 1492)
  V + 20 <= Mc < V + 28:  "full {V}-byte IPv4 MTU for unfragmented packets; {V}-byte IPv4 fragments
                           from the NAT64 need an IPv6 MTU of {V + 28}"
  Mc > V + 28:            notice "tun MTU limited to {V + 28}"
  not scrub_on and mss_key != '':  "firewall normalisation is disabled, no MSS clamp is active"
  not scrub_on and Mc >= V + 28:   notice "IPv4 fragments are split by the translator"   (section 5.3)

apply
  if T or O differ from the running values:
      stop tayga; set tun MTU T; write offlink-mtu O; start tayga      # tayga reads the MTU once
  if mss_key differs from the registered value:
      re-register the interface (plugins_interfaces) and reload the filter
```

Worked values (V = 1500):

| M | T | O | `mss` | TCP MSS | IPv4 MTU presented | tayga DF limit | IPv6 fragment size on the wire |
|---|---|---|---|---|---|---|---|
| 1280 | 1280 | 1280 | 1280 | 1220 | 1260 | 1260 | 1280 |
| 1492 | 1492 | 1492 | 1492 | 1432 | 1472 | 1472 | 1488 |
| 1500 | 1500 | 1500 | 1500 | 1440 | 1480 | 1480 | 1496 |
| 1520 | 1520 | 1520 | 1520 | 1460 | 1500 | 1500 | 1520 |
| 1524 | 1524 | 1520 | 1520 | 1460 | 1500 | 1504 | 1520 |
| 1528 | 1528 | 1520 | 1520 | 1460 | 1500 | 1508 | 1520 |
| 9000 | 1528 | 1520 | 1520 | 1460 | 1500 | 1508 | 1520 |

Rows up to 1500 are identical to the current design.

---

## 8. Lab tests this report cannot replace

Nothing here was run. On a 26.7 box behind a PPPoE link with M >= 1528:

1. `ifconfig tun464 mtu 1528` accepted; tayga logs "Using tun device tun464 with MTU 1528".
2. From a LAN host: DF ping with 1472 bytes of data (1500 total) answered with no ICMP error; packet
   capture on the PPPoE device shows a 1520-byte IPv6 packet.
3. Non-DF UDP datagrams with 1472, 1473, 1480, 1481 and 4000 bytes of payload to an echo service on the
   IPv4 Internet: all answered; captures show no Fragment header for 1472 and Fragment headers above.
   Repeat the 1473..1480 cases with `offlink-mtu 1528` to confirm the loss described in section 5.3.
4. A fragmented IPv4 response from the Internet (for example a DNS answer above 1472 bytes without EDNS
   size limit): 1528-byte IPv6 fragments arrive on the PPPoE device and the LAN host gets the answer.
   Repeat with the tun at 1520 to confirm the refusal described in section 5.2.
5. `pfctl -sr` shows `max-mss 1480` / `max-mss 1460` on the tun with `mss` = 1520, and no rule after the
   plugin returns `'mss' => ''`.
6. TCP from the firewall itself to an IPv4 destination: SYN leaves the PPPoE device with MSS 1460.

## 9. Open questions

1. The ISP's NAT64: its IPv6 MTU, its setting for the RFC 7915 section 4.1 threshold, whether it
   reassembles IPv4 fragments before translating, and whether it sends ICMPv6 Packet Too Big. Sections 3,
   5.2 and 5.3 depend on it.
2. Whether the promised MTU holds end to end between the BNG and the NAT64, not only on the PPPoE link.
3. How LAN host stacks react to a frag-needed error for a flow they send with DF clear (section 5.3
   assumes it does not help; not tested).
4. `ip_fastfwd.c` on the branch 27.1 will ship: still `nifp->if_mtu`? Only stable/26.7 was read.
5. No functional difference was found between `scrub on tun464 ... max-mss` being present or absent on
   26.7 apart from the clamp; this was reasoned from `pf_normalize_ip()`/`pf_normalize_ip6()`, not observed.
6. IPv4 packets with options were only considered arithmetically (section 2.2).
7. Whether the firewall's own non-TCP IPv4 senders (IPsec, OpenVPN, WireGuard endpoints reached through
   the CLAT) need guidance because they see an IPv4 MTU of T; not analysed per service.
