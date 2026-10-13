# os-clat

A 464XLAT CLAT plugin for OPNsense 26.7. On an IPv6-only uplink it gives LAN devices IPv4 through the ISP's NAT64, using a virtual WAN interface (`tun464`) as OpenWrt's 464xlat package does.

**Status: runs on OPNsense 26.7.6 in the lab, not yet on the ISP's network.** The lab (`lab/`) is an OPNsense box behind a simulated ISP. Its tests T01 to T24 pass with the plugin installed by copying its files, and so does the production set: the ISP simulated as its public setup guide describes it (a /64 by SLAAC on the WAN, a /56 by DHCPv6-PD, DNS64 by Google's addresses; no PREF64 in the simulator) and the box configured by the steps of the ISP's router-setup page, with PPPoE on the tagged VLAN 40 as on the ISP's line. The package has been built there and installed, upgraded and removed through OPNsense's firmware pages from a signed repository that the lab serves, and a browser has pressed the buttons of that installation and removal and of the plugin's own page (lab test T25). The release workflow and the real site on GitHub Pages have not run, and nothing has run on a real line or on customer hardware.

## Layout

| Path | What it is |
|---|---|
| `DESIGN.md` | the design: behaviour, decisions and their reasons |
| `docs/implementation-spec.md` | the contract the code was written to, with the amendments made during implementation |
| `docs/lab-spike-runbook.md` | commands to prove the datapath by hand, without the plugin (untested) |
| `docs/research/` | the source-reading reports behind the design. Paths in them that start with `refs/` name local clones of the upstream repositories as they were read; the clones are not part of this repository |
| `net/clat/` | the plugin, in the layout of the opnsense/plugins repository |
| `net/clat/tests/` | unit tests for the Python logic (standard library only) |
| `lab/` | the Hyper-V test lab: a simulated ISP and an OPNsense box, the test runner, the tool that takes pictures of the GUI for the ISP's router-setup page (`lab/screens/`), and, only on the machine that runs the lab, under `lab/.work/results/` the results (`changes.md` lists every change the tests led to). `lab/.work/` holds the lab's disks, keys, logs and results; git ignores it and it is not part of this repository |
| `packaging/` | the package build and the pkg repository (run in the lab; the GitHub workflow has not run) |

Inside `net/clat/src/`:

- `etc/inc/plugins.inc.d/clat.inc`: hooks into core (device, interface record, the one pass rule, MSS value, service, events).
- `opnsense/scripts/clat/clatd.py`: the supervisor daemon. `lib/supervisor.py` is the state machine, `lib/discovery.py` the NAT64 prefix discovery, `lib/plan.py` the addressing and MTU rules, `lib/facts.py` what is read from the system, `lib/sysif.py` the only module that touches the operating system.
- `opnsense/scripts/clat/clatctl.py`: status, tests and event delivery, called through configd.
- `opnsense/scripts/clat/facts.php`: prints configuration and gateway facts from core as JSON.
- `opnsense/mvc/app/...`: settings model, API and the page under Services.

## What has been checked

| Check | Result |
|---|---|
| Python unit tests (338) | pass, on Python 3.11 in a Linux container |
| PHP syntax (`php -l`, 6 files) | clean, on PHP 8.3 |
| XML well-formedness (5 files) | clean |
| Review against the design, the spec and core's source | done by reading; 21 findings (none high), 20 fixed, 1 left as harmless duplication |
| Lab tests T01 to T24 on OPNsense 26.7.6 (`lab/README.md`) | pass, 2026-10-12, after three plugin changes; two more followed from the results (DESIGN.md sections 15 and 16, `lab/.work/results/changes.md`). Pass again the same day with PPPoE on VLAN 40, with no plugin change; two checks of the test runner were changed for it, one in T18 and one that T27 uses (`lab/README.md` section 6) |
| Production set in the lab (`run-tests.sh --profile prod`: T01, T26, T14, T13, T11, T15, T27, T28, T29, T12; `lab/README.md` section 13) | pass, 2026-10-12, with no plugin change: first with PPPoE untagged, then with PPPoE on the tagged VLAN 40 |
| PPPoE on the tagged VLAN 40 in the lab (`lab/README.md` section 13, DESIGN.md section 8.3) | 2026-10-12: the session runs on `vlan0.40`, and a box that dials untagged gets none. With MTU 1508 on the WAN and on the port under the VLAN the session is 1500 on both sides, after Apply and after a reboot: frames of 1526 bytes with the tag pass in both directions, IPv4 through the CLAT is 1480 and the MSS 1440. With both MTU fields empty: 1492, 1472 and 1432 |
| Package and repository in the lab (`lab/README.md` section 14, `packaging/README.md`) | 2026-10-12: `os-clat-1.0.pkg` built on OPNsense 26.7.6 and signed with a lab key; installed through the firmware pages' API on a box with only IPv6 (IPv4 for a LAN client 9 s after the call), upgraded to `1.0_1` (IPv4 interrupted for 6 s), removed; the recovery line with the site down. One plugin change: the deinstall script removes Python's cache directory. T26, T14 and T13 pass on the installed package |
| The size test of the status page after its correction (DESIGN.md section 10) | 2026-10-12, in the lab, package upgraded from the lab repository: ok with 1480 when large echo replies return; inconclusive with 1260 when they return as fragments; inconclusive with 1400 when the ISP side silently drops larger packets (the code before said ok); ok with 1380 when the ISP side refuses larger packets with an error. T26 and T14 pass on that package |
| The GUI in a browser (`lab/README.md` section 15) | 2026-10-12: headless Edge rendered the pages of the router-setup steps, the firmware tabs, the plugin's page (State `Active.`) and its log; 29 pictures saved, each checked for the values it must show, all taken again in the final state (PPPoE on VLAN 40, package `1.0`) |
| The buttons of the GUI, pressed in that browser (lab test T25, `bash lab.sh t25`, `lab/README.md` section 15) | pass, 2026-10-12, 49 checks, each step checked on the box and from a LAN client: os-clat installed from the Plugins tab (the link, `+`, Install in the notice; `active` 11 to 13 s after the click) and removed (the bin, OK); on Services > CLAT, Mode Disabled and Automatic with Apply, Run tests (no target; `inconclusive` with 1260 bytes; `ok` with 1480), the Log File; in Interfaces > Assignments the WAN entry saved and applied (the session is dialled again, the CLAT stays `active`) and the CLAT entry saved and applied (core strips the record, the plugin registers it again after 1.1 to 1.2 s). One plugin change: the page asks for the service buttons in its head with every refresh; before, they read "stopped" after an Apply that started the service. T26, T14 and T13 pass on the package with that change |

Not checked: in a browser, anything but the buttons of T25 (the steps of the router-setup page were done through the API and the pages' forms, not clicked), and no browser but headless Edge; the package build on plain FreeBSD, the release workflow and the site on GitHub Pages; `make lint` and `make style` from the plugins repository; the ISP's own BNG and NAT64; customer hardware. `lab/README.md` section 10 has the full list.

## Running the tests

They need only a Python 3 interpreter. From the top of the checkout:

```bash
cd net/clat && python3 -B -m unittest discover -s tests
```

The same in a container, for example with wslc from Git Bash (any container runtime works):

```bash
MSYS_NO_PATHCONV=1 wslc.exe run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$(cygpath -w "$PWD"):/work:ro" -w /work/net/clat python:3.11-alpine python -m unittest discover -s tests
```

## Building the package

`sh packaging/build-package.sh` builds the package, as root on FreeBSD 15 or on an OPNsense 26.7 system. It fetches the plugin framework (one fixed commit of opnsense/plugins, branch `stable/26.7`; on `master` the package would be named `os-clat-devel`), copies `net/clat` into it, sets the executable bits that a Windows checkout does not have, and runs the framework's `make package`. `packaging/README.md` has the details. It has run on the lab's OPNsense 26.7.6 box (`bash lab/lab.sh repo build`), not on plain FreeBSD. `make lint` and `make style` of the framework need opnsense/core checked out next to that plugins tree.

## Releases

Subscribers install the plugin from a signed pkg repository on the GitHub Pages site of this repository, served under the ISP's own name as `https://os-pkg.gettuckamore.ca/`. A tag `v<version>` makes a release: `.github/workflows/publish.yml` builds the package in a FreeBSD 15 virtual machine, signs the repository and deploys the site. The scripts it calls, the one-time set-up (Pages, the signing key) and the lab check before a release are in `packaging/README.md`. The scripts and the router's side have run in the lab, against a stand-in for the site; the workflow and the site itself have not run.

On the router, with OPNsense up to date, one line in the shell as root (console or SSH, then menu option 8) adds the repository:

```
mkdir -p /usr/local/etc/pkg/fingerprints/os-clat/trusted /usr/local/etc/pkg/fingerprints/os-clat/revoked && fetch -o /usr/local/etc/pkg/fingerprints/os-clat/trusted/os-clat.fingerprint https://os-pkg.gettuckamore.ca/os-clat.fingerprint && fetch -o /usr/local/etc/pkg/repos/os-clat.conf https://os-pkg.gettuckamore.ca/os-clat.conf
```

Then *System > Firmware > Plugins*, *Click to view the community plugins.* at the end of the list, **os-clat**, **+**, and *Install* in the *Third party software* notice. The plugin needs no setting on a router set up for an IPv6-only line with a DNS64 resolver; in the lab the CLAT was active 11 to 13 s after the click (a LAN device was answered 9 s after the same request sent through the page's API). Later versions arrive with the normal firmware updates (*System > Firmware > Status*, *Check for updates*, *Update*); an update interrupts IPv4 for a few seconds. The repository is signed; the fingerprint of its key is on the site and in `packaging/repo-key.sha256`.

OPNsense checks all its repositories together. If this one cannot be reached, or its key is no longer accepted, the firmware page reports an error and offers no updates, not of OPNsense either. This line brings OPNsense's updates back at once:

```
rm -f /usr/local/etc/pkg/repos/os-clat.conf
```

The plugin stays installed and keeps running; the Plugins page lists it as orphaned. Running the install line again brings its updates back.

## First run

Before installing on a test box, read DESIGN.md section 11 (the WAN must have IPv4 Configuration Type set to None) and section 15 (what the lab checked, and what it left out). The plugin activates on its own once a NAT64 prefix is discovered; the page under Services > CLAT shows the state and the reason when it does not.
