#!/usr/bin/env python3
"""Send Router Advertisements with a PREF64 option (RFC 8781) from the LAN client. Negative test only."""
import argparse
import ipaddress

from scapy.all import Ether, IPv6, ICMPv6ND_RA, ICMPv6NDOptPREF64, get_if_hwaddr, sendp

PLC = {96: 0, 64: 1, 56: 2, 48: 3, 40: 4, 32: 5}

ap = argparse.ArgumentParser()
ap.add_argument("--iface", default="lan0")
ap.add_argument("--prefix", default="2001:db8:bad:64::/96")
ap.add_argument("--lifetime", type=int, default=1800)
ap.add_argument("--src", default="fe80::bad:64")
ap.add_argument("--count", type=int, default=3)
args = ap.parse_args()

net = ipaddress.IPv6Network(args.prefix)
ra = (Ether(src=get_if_hwaddr(args.iface), dst="33:33:00:00:00:01")
      / IPv6(src=args.src, dst="ff02::1", hlim=255)
      / ICMPv6ND_RA(chlim=64, routerlifetime=0)
      / ICMPv6NDOptPREF64(scaledlifetime=(args.lifetime + 7) // 8, plc=PLC[net.prefixlen],
                          prefix=str(net.network_address)))
sendp(ra, iface=args.iface, count=args.count, inter=1.0)
