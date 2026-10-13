# Releases of os-clat

How the os-clat package is built, signed and published as a pkg repository on GitHub Pages, and how a router uses it.

**Status: the two scripts and the router's side have run in the lab (2026-10-12); GitHub's side has not.** On the lab's OPNsense 26.7.6 box `build-package.sh` built `os-clat-1.0.pkg` and `make-repo.sh` signed a repository with a lab key, both without a change to the scripts. The site was served over HTTPS and IPv6 by a stand-in host, and the router went the subscriber's way: the install line, the Plugins page's API, an upgrade to `1.0_1`, removal, and the recovery line with the site down. The section "In the lab" has the commands and what they showed. Not run: the build on plain FreeBSD 15.1 (the workflow's machine), any workflow, and GitHub Pages itself. The last section lists what is confirmed and what the first workflow run still has to confirm.

## What is published

The site of the repository `77997/os-clat`, served by GitHub Pages under the custom domain `https://os-pkg.gettuckamore.ca/`:

```
index.html             what the site is, the install command, the fingerprint
os-clat.conf           the repository definition; a router stores it as /usr/local/etc/pkg/repos/os-clat.conf
os-clat.fingerprint    SHA-256 of the signing key; a router stores it as
                       /usr/local/etc/pkg/fingerprints/os-clat/trusted/os-clat.fingerprint
repo/                  the pkg repository
  meta.conf, meta, data.pkg, packagesite.pkg        the signed catalogue, as "pkg repo" writes it
  All/os-clat-1.0.pkg                               the package; only the current version
```

Everything a router fetches is on this one host, which has IPv6 addresses. Nothing is fetched from github.com. The pkg of OPNsense 26.7.6 (2.8.4) reads `repo/meta.conf`, `repo/data.pkg` and the package; it also asks for `repo/files.pkg` and `repo/files.tzst`, which do not exist, and goes on after the 404. `packagesite.pkg` is what older versions of pkg read.

`os-clat.conf` is `site/os-clat.conf` with the address filled in. `os-clat.fingerprint`:

```
function: "sha256"
fingerprint: "<64 hex digits>"
```

## Files in this folder

| File | What it does |
|---|---|
| `build-package.sh` | builds `work/pkg/os-clat-<version>.pkg` from `../net/clat` with the OPNsense plugin framework |
| `make-repo.sh` | makes `work/site/`: the signed repository, `os-clat.conf`, `os-clat.fingerprint`, `index.html`; then reads the repository back with pkg |
| `site/os-clat.conf`, `site/index.html` | templates; `%%SITE_URL%%`, `%%VERSION%%` and `%%FINGERPRINT%%` are filled in by `make-repo.sh` |
| `repo-key.sha256` | the fingerprint of the signing key that routers trust, one line of 64 hex digits; `make-repo.sh` refuses any other key. Written on 2026-10-12 by the commands of set-up step 4; the key itself is not in git |
| `work/` | made by the scripts, ignored by git |

The workflows are `../.github/workflows/ci.yml` (tests and syntax checks on every push to master and every pull request) and `../.github/workflows/publish.yml`.

## How a release is made

`publish.yml` runs on the push of a tag `v<version>` and on a manual run.

1. The checks of `ci.yml`: Python unit tests, `php -l`, XML well-formedness, `sh -n` on the two scripts.
2. A FreeBSD 15.1 virtual machine on the GitHub runner (`vmactions/freebsd-vm`) runs `build-package.sh`:
   - It fetches the archive of one fixed commit of opnsense/plugins (tag 26.7.6, set as `PLUGINS_REF` in the script) and copies `net/clat` into it as `net/clat`.
   - It sets the file modes (644; 755 for `src/etc/rc.d` and `src/opnsense/scripts`) and refuses CR line ends.
   - It reads the package name and version from the framework (`PLUGIN_VERSION`, and `PLUGIN_REVISION` if set, in `net/clat/Makefile`) and stops if the git tag is not `v<version>`.
   - It runs `make PLUGIN_NO_ABI=yes PLUGIN_WWW=https://github.com/77997/os-clat PLUGIN_HASH=<commit> package`. The framework installs the dependency `tayga` with pkg to read its version, stages `src/` under `/usr/local`, writes `+MANIFEST` and the install scripts, and calls `pkg create`.
3. The same machine runs `make-repo.sh`:
   - It derives the public key from the private key, takes its SHA-256 as the fingerprint, and stops unless that is the fingerprint in `repo-key.sha256`.
   - For a tag it reads the version the site serves now and stops if that is higher than the version built.
   - It runs `pkg repo work/site/repo signing_command: ...`. The signing command is the script itself; it signs the catalogue hash with `openssl dgst -sign`, as in pkg-repo(8).
   - It writes `os-clat.conf`, `os-clat.fingerprint` and `index.html`.
   - It lets pkg update from the new repository with that definition and that fingerprint, and stops unless pkg accepts the signature and offers `os-clat-<version>`.
4. `work/site` is uploaded as the Pages artifact.
5. Only when the run is for a tag: the artifact is deployed to GitHub Pages, and the deploy job then fetches from the live site. `index.html` must show the new version (it tries for five minutes); `os-clat.conf`, `os-clat.fingerprint`, `repo/meta.conf`, `repo/data.pkg`, `repo/packagesite.pkg` and `repo/All/os-clat-<version>.pkg` must be served; and the address in `os-clat.conf` must be the one the site is served on. GitHub's runners have no IPv6, so the path over IPv6 is checked from a router. A manual run on a branch stops after step 4 and publishes nothing.

### The address

`https://os-pkg.gettuckamore.ca` is stored on every subscribed router, in `/usr/local/etc/pkg/repos/os-clat.conf`, and a router never fetches that file again. The address is therefore fixed from the first release on. It is set in one place, the default of `SITE_URL` in `make-repo.sh`; the workflow does not ask GitHub for it. `../README.md` and the ISP's router setup page repeat it by hand in the install line.

The name is the ISP's own: a DNS record `os-pkg.gettuckamore.ca CNAME 77997.github.io`, and the same name as the custom domain of the Pages site (set-up step 2). Keep both for as long as any router uses the plugin; without them every router's update check fails until its owner runs the recovery line. Keep the TXT record `_github-pages-challenge-77997.os-pkg.gettuckamore.ca` as well: it keeps the name verified for the organization, so that no other GitHub account can publish a site under it. Because the name is not GitHub's, the files can later move to any static host that serves them over HTTPS and IPv6, the repository can be renamed without any change, and the organization with the CNAME pointed at the new `<name>.github.io` and the name verified again, all without a change on a router. GitHub redirects `77997.github.io/os-clat/` to the name (to `http://` until *Enforce HTTPS* is ticked); nothing relies on that redirect. The check in step 5 compares the address GitHub reports for the deployment with the one in `os-clat.conf` and fails when they differ; while *Enforce HTTPS* is not ticked GitHub gives the address with `http://` (its redirect did on 2026-10-13), so the check fails then too, after the deployment.

## One-time set-up

1. Create the public repository `77997/os-clat` on GitHub and push `master`.
2. *Settings > Pages*: under *Build and deployment*, *Source* **GitHub Actions**; under *Custom domain*, `os-pkg.gettuckamore.ca`, and **Enforce HTTPS** ticked once GitHub has issued the certificate for the name. The name needs the record `os-pkg.gettuckamore.ca. CNAME 77997.github.io.` at the domain's DNS host, so that GitHub can obtain the certificate. GitHub asks Let's Encrypt for it when the custom domain is saved, which can take up to an hour (up to 24 hours before *Enforce HTTPS* can be ticked); if no certificate comes, or the record changed after the domain was saved, click *Remove* next to the custom domain and save it again, which restarts the request. Verifying the name in the organization's settings (*Pages*, *Add a domain*; it asks for the TXT record `_github-pages-challenge-77997.os-pkg.gettuckamore.ca`, which has to stay) keeps other GitHub accounts from publishing a site under it. All of it before the first tag: routers fetch over HTTPS and need the certificate, and the check of release step 5 needs *Enforce HTTPS* (see "The address"). On 2026-10-13 the source was GitHub Actions, the record answered with GitHub Pages' four IPv6 addresses (the domain's name servers returned the CNAME itself), the verification record existed, and `https://77997.github.io/os-clat/` redirected to `http://os-pkg.gettuckamore.ca/`; the certificate was not issued yet (GitHub still presented its `*.github.io` certificate for the name).
3. *Settings > Environments > github-pages > Deployment branches and tags > Add deployment branch or tag rule*: ref type **Tag**, name pattern `v*`. Without it the deploy job of a tag is refused ("not allowed to deploy to github-pages due to environment protection rules"). On 2026-10-13 the environment already existed, before any run, with one rule for the branch `master`; add the tag rule next to it. If it is not listed, it appears after the first run; add the rule then and re-run the failed job.
4. Make the signing key on a maintainer's own machine, not in the workflow, and write its fingerprint into `packaging/repo-key.sha256`. This was done on 2026-10-12: the committed `repo-key.sha256` holds the fingerprint of a key made this way. No router trusts that key before the first release, so until then it can still be replaced by running the commands again. From the top of the working tree (`.secrets/` is ignored by git):

   ```
   mkdir -p .secrets
   openssl genrsa -out .secrets/os-clat-repo.key 4096
   openssl rsa -in .secrets/os-clat-repo.key -pubout | tr -d '\r' | sha256sum | cut -c1-64 > packaging/repo-key.sha256
   ```

   Commit and push `packaging/repo-key.sha256`. It is public: it is the value every router stores, and the site shows it. `make-repo.sh` stops before it signs when the key it is given has another fingerprint, so the key cannot change by accident. `tr -d '\r'` matters only for an openssl on Windows that writes CR LF.

   Keep a copy of the key offline. Whoever has this key can publish packages that every subscribed router installs as root; whoever loses it has to rotate it (below).
5. Store the key as the repository secret `REPO_SIGNING_KEY` (*Settings > Secrets and variables > Actions > New repository secret*; paste the whole file), or:

   ```
   gh secret set REPO_SIGNING_KEY --repo 77997/os-clat < .secrets/os-clat-repo.key
   ```

## Making a release

1. Set `PLUGIN_VERSION` in `net/clat/Makefile` (for a rebuild of the same version add or raise `PLUGIN_REVISION`; version 1.0 with revision 1 is `1.0_1`). Add the changes to `net/clat/pkg-descr`. Commit and push.
2. Rehearsal: *Actions > publish > Run workflow* on `master`. It builds and signs and deploys nothing. Read the log of the FreeBSD step: name, version, ABI `FreeBSD:*:*`, `depends on: tayga-...`, the file list, and the last line `OK os-clat-<version>, address ..., fingerprint ...`. The site is attached to the run as the artifact `github-pages` for one day.
3. Release:

   ```
   git tag v1.0
   git push origin v1.0
   ```

4. The run ends with the step *Check the published site*. Open `https://os-pkg.gettuckamore.ca/` as well and compare the fingerprint with `repo-key.sha256`. GitHub Pages caches for ten minutes.

To publish the same release again (after step 3 of the set-up was missing): *Actions > publish > Run workflow*, and choose the tag instead of a branch. A tag whose version is lower than the one the site serves is refused.

Each release replaces the whole site: older package versions are not kept in the repository. Their source stays in git under their tags. A router does not go back to a lower version on a normal update, so a bad release is corrected by a new, higher version.

## On the router

The subscriber first brings OPNsense up to date (*System > Firmware > Status*): core's `install.sh` refuses a plugin while the mirror has a newer `opnsense` package ("Installation out of date."; read from the source, the lab box was up to date). Then the install line in the shell, as root (console or SSH, then menu option 8). The line is in `../README.md`, section Releases, on the ISP's router setup page (`https://gettuckamore.ca/router/setup`, written by hand), and on the site, where it is generated from `site/index.html`.

It uses only `mkdir` and `fetch` from the base system, works in root's csh, can be repeated, and puts the repository definition in place last, after the fingerprint: with the site down it stops at the first `fetch` and writes no definition. Then *System > Firmware > Plugins*, the link *Click to view the community plugins.* at the end of the list, **os-clat**, **+**, and *Install* in the *Third party software* notice.

What core's firmware pages do with this repository. Seen on 26.7.6 in the lab on 2026-10-12, through the API the pages call; the labels are read from `firmware.volt`. A headless browser has since rendered the Status tab (`Repositories`: `OPNsense (Priority: 11), os-clat (Priority: 5)`), the Plugins tab before and after the installation, and the notice *Third party software* (`../lab/README.md` section 15). Since then it has also pressed the buttons of the Plugins tab (lab test T25, the same section): the link, **+**, *Install* in the notice, and for the removal the bin and *OK* in *Confirm removal*. The Updates tab ended with `***DONE***` 10 to 11 s after *Install* and 8 to 10 s after *OK*; the menu entry *Services > CLAT* appears, and after a removal goes, when the page is loaded again:

- The Plugins tab lists `os-clat` with version `1.0`, tier `4` and repository `os-clat`, whatever repository a package named `os-...` comes from. Plugins of tier 3 and 4 are hidden until the link is clicked. Once os-clat is installed it is always listed.
- *Install* takes `os-clat` from this repository and `tayga` from OPNsense's, as a dependency. The package scripts run (model migration, plugin configuration, both templates, the service), and os-clat is entered in the list of plugins in config.xml. The log ended 7 to 8 s after the API call, and an IPv4-only LAN client had its first reply 9 s after it, on a box set up by the ISP's page and with nothing set in the plugin.
- The update check runs `pkg update -f` and `pkg upgrade -Un` over all repositories, so a new os-clat appears among the normal updates (`os-clat: 1.0 -> 1.0_1 [os-clat]`) and *Update* installs it. In two upgrades the client's IPv4 was interrupted for 6.1 and 6.5 s, and the CLAT came back by itself with the same address.
- *Remove* takes tayga away as well (`pkg autoremove`) and leaves the settings and four paths (DESIGN.md, section 14).
- **If one repository cannot be updated, the check reports an error and lists no updates at all**, not of OPNsense either, and the Plugins tab lists only what is installed. Seen three ways: the site refuses connections ("Could not find the repository on the selected mirror.", after 7 s); the site does not answer at all (the same message, but only after 22 minutes 37 s, because pkg waits three times for each of six files; the Plugins tab did not load meanwhile); the router's fingerprint is not that of the signing key ("Could not verify the repository fingerprint.", after 7 s). The plugin kept running in all three. `make-repo.sh` therefore reads every repository back before it is uploaded, and the site must stay up.

The subscriber's way out of that state is `rm -f /usr/local/etc/pkg/repos/os-clat.conf`. Seen with the site down: the next check works and lists OPNsense's updates, the Plugins tab has all its rows again, the plugin stays installed and running, and its row is *orphaned* (installed, offered by no repository). Running the install line again, once the site is back, brings its updates back. `../README.md` says this too, because it is read on github.com when the site is the thing that is down.

Removal: the plugin under *System > Firmware > Plugins*, then

```
rm -f /usr/local/etc/pkg/repos/os-clat.conf && rm -rf /usr/local/etc/pkg/fingerprints/os-clat
```

## By hand, without GitHub

On FreeBSD 15 or an OPNsense 26.7 box, as root, in a copy of this repository (`net/clat` and `packaging` are enough):

```
sh packaging/build-package.sh
env SIGNING_KEY=/root/test-repo.key SITE_URL=file:///root/os-clat/packaging/work/site sh packaging/make-repo.sh
```

- `build-package.sh` needs Internet access for the framework archive and, where `tayga` is not installed, for that package. For a box without access to github.com, download `https://github.com/opnsense/plugins/archive/<PLUGINS_REF>.tar.gz` elsewhere and put it at `packaging/work/plugins-<PLUGINS_REF>.tar.gz`.
- On a host that is not OPNsense the framework prints `warning: Cannot build without PLUGIN_PHP set` and the same for `PLUGIN_PYTHON`. Both variables only form the names of PHP and Python module packages, and os-clat depends on none.
- With `SITE_URL=file:///...` the site can be used where it lies: pkg and `fetch` both read `file://` addresses, so the install line of the generated `index.html` should work on the same box (the lab ran the script this way, with its read-back through pkg, but not that install line). Such a run takes any key. For every `https://` address, the real one included, the script accepts only the key of `repo-key.sha256`.
- On an OPNsense box `tayga` is installed by the build when it is missing and stays there. Remove it again (`pkg delete -y tayga`) before the box is used to try an installation as a subscriber has it.
- The path of the copy must not contain blanks.

## In the lab, before a release

Run on 2026-10-12; the outputs are in `../lab/.work/results/stage-package/` and the account of the run in `../lab/.work/results/changes.md`. The lab (`../lab/README.md`, section 14) is in its production profile: the ISP as its public setup guide describes it, and clat-opn set up by the steps of the ISP's router page. clat-opn builds the package, clat-world serves the site as `https://repo.clat.lab/os-clat`, and clat-opn is then the subscriber's router. From Git Bash in the checkout's `lab/` folder:

```
bash lab.sh repo build              # both scripts on clat-opn, as publish.yml calls them; lab key; the site goes to clat-world
bash lab.sh plugin remove           # takes off a plugin installed by copying files, or the package
bash lab.sh o 'pkg delete -y tayga' # the build installed it; a subscriber's box has none
bash lab.sh repo subscribe          # trusts the lab CA, then runs the install line of the generated index.html in root's csh
bash lab.sh fw info                 # the row of os-clat on the Plugins tab
bash lab.sh fw install os-clat      # the + button
bash lab.sh st                      # "state": "active"
bash lab.sh c ping -c3 192.88.99.1  # the IPv4-only LAN client

bash lab.sh repo build 1            # the same tree as 1.0_1 (PLUGIN_REVISION=1 in the copy on clat-opn)
bash lab.sh fw check                # Check for updates: os-clat: 1.0 -> 1.0_1 [os-clat]
bash lab.sh fw update               # Update
bash lab.sh fw remove os-clat       # the Remove button

bash lab.sh w systemctl stop isp-repo                          # the site is down ("start" brings it back)
bash lab.sh fw check                                           # error, no updates listed
bash lab.sh o 'rm -f /usr/local/etc/pkg/repos/os-clat.conf'    # the recovery line
bash lab.sh fw check                                           # works again
```

`RELEASE_TAG=v1.0_1 bash lab.sh repo build 1` runs both scripts as the push of a tag does: the tag has to match the Makefile, and the version the site serves is read and compared. `lab.sh fw` sends what a button of *System > Firmware* sends (`POST /api/core/firmware/<action>`) and then polls `upgradestatus` as the page does.

What stands in for what:

| A release | The lab |
|---|---|
| FreeBSD 15.1 in the workflow's virtual machine | clat-opn itself, OPNsense 26.7.6 with pkg 2.8.4; the copy is `/root/os-clat` |
| `https://os-pkg.gettuckamore.ca` on GitHub Pages | `https://repo.clat.lab/os-clat`, a small HTTPS server on clat-world, reached over IPv6 through the PPPoE line |
| a certificate every router trusts | a certificate of a lab CA, which `lab.sh repo subscribe` first adds under *System > Trust > Authorities*. That step and the address (`repo.clat.lab/os-clat` instead of `os-pkg.gettuckamore.ca`) are all that differs from the subscriber's line |
| the release signing key and `repo-key.sha256` in git | a lab key in `lab/.work/disks/build/`; its fingerprint file exists only in the copy on clat-opn. The fingerprint is computed by the command of set-up step 4 |
| the commit of the release as `PLUGIN_HASH` | the SHA-256 of the plugin tree's tar (the lab builds the working tree, whatever is committed) |
| OPNsense's mirror, reached over IPv6 | the lab has no IPv6 Internet, so its resolver ignores the AAAA record of `pkg.opnsense.org` and the box reaches the mirror through the NAT64 |

What it showed, apart from the router's side in "On the router":

- `build-package.sh` ran unchanged at the first attempt: `os-clat-1.0.pkg`, ABI `FreeBSD:*:*`, origin `opnsense/os-clat`, `depends on: tayga-0.9.6`, 27 files (the 26 of `src/` and `opnsense/version/clat`), mode 644 and 755 for `etc/rc.d/clat` and everything under `opnsense/scripts/clat`. The annotations are those of the version file: `product_abi 26.7`, `product_arch amd64`, `product_tier 3`, `product_hash`, `product_website`.
- `make-repo.sh` ran unchanged: pkg called it as the signing command with the key in the environment, the fingerprint it derived equals the one computed by the command of set-up step 4, and the read-back through pkg accepted the signature.
- The refusals, each before anything is signed or published: a tag that does not match the Makefile (`tag v1.1 does not match net/clat/Makefile, which says 1.0`); an `https://` address with another key (`the key given has the fingerprint ..., but routers trust ...; nothing was signed`); no `repo-key.sha256` (`... is missing; the key given has the fingerprint ...`), which was the state of this repository at the time of the lab run; a release of 1.0 while the site serves 1.0_1 (`the site serves os-clat 1.0_1, which is higher than os-clat 1.0`).
- One defect in the plugin, found by the removal and corrected: Python's cache directory under `scripts/clat/lib` stayed behind (`net/clat/+POST_DEINSTALL.post`, DESIGN.md section 14).
- One addition to the workflow: the published-site check now also fetches `repo/data.pkg`, the file the router's pkg reads.

To try the repository a rehearsal has built, with the real key (not tried yet): download the artifact `github-pages` of that run, unpack `artifact.tar` on the lab router, copy `os-clat.fingerprint` to `/usr/local/etc/pkg/fingerprints/os-clat/trusted/`, and install `os-clat.conf` with its `url` changed to `file:///<directory>/repo`. `pkg update -f -r os-clat` must then succeed. This is the check that a catalogue written by FreeBSD's pkg is accepted by OPNsense's.

## The signing key

- The fingerprint that routers trust is in git, `repo-key.sha256`. `make-repo.sh` derives the fingerprint of the key it is given and stops before it signs when the two differ (a `file://` site, a lab run, takes any key). A regenerated or mistyped secret is a failed build, and a key change is a commit.
- In the workflow the key exists as the file `packaging/work/signing.key` for the duration of the FreeBSD step, because that step copies the workspace into the virtual machine; the next step deletes it. That step is the only action in the workflow that is not GitHub's own (`vmactions/freebsd-vm`), and it is the one that sees the key.
- The commit that action is pinned to fixes the action's own code. It does not fix what that code fetches at run time, by version and without a checksum: `anyvm.py` 0.7.2 and the FreeBSD image of builder 2.2.8 (both named in the action's `conf/15.1.conf`), and the runner's apt packages (qemu, rsync). The machine that holds the key has Internet access; the build in it fetches the framework archive (pinned by commit) and installs `tayga` from FreeBSD's package repository, of which only the version enters the manifest. This is accepted, because a signed catalogue is made by FreeBSD's pkg; signing outside the machine would mean re-packing pkg's archives by hand. The fingerprint in git makes a swapped key visible. It does not help against a copied one.
- **Write access to the repository is access to the key.** `REPO_SIGNING_KEY` is a repository secret, and the build job reads it on every run, also on a manual run of any branch, with the scripts of that branch. Whoever can push a branch can have anything signed or read the key out. A rehearsal also leaves its signed site as the artifact `github-pages` for one day. While only the maintainers can push, this is the intended trust level. Before anyone else gets write access: move the key into a secret of an environment that allows only tags `v*` and has a maintainer as required reviewer; select it on the build job with `environment: ${{ github.ref_type == 'tag' && 'release' || 'rehearsal' }}`; let rehearsals sign with a key made in the job and compare the fingerprint for tags only; and add a tag ruleset so that only maintainers create `v*` tags. Until then a `v*` tag on any commit, on `master` or not, is published.
- **Changing the key cuts every router off** until its owner runs the install line again: the router trusts only the fingerprint it fetched once. Until then its update check fails as described above.
- Planned change, without that break: generate the new key; add its fingerprint file to the plugin as `net/clat/src/etc/pkg/fingerprints/os-clat/trusted/<name>` (the vendor plugin `vendor/sunnyvalley` of opnsense/plugins ships its fingerprint this way); release that version signed with the old key. When the routers have it: replace the secret, put the new fingerprint into `repo-key.sha256`, raise `PLUGIN_REVISION` and release.
- Lost or stolen key: make a new key at once, replace the secret, put the new fingerprint into `repo-key.sha256`, raise `PLUGIN_REVISION` and release; tell subscribers to repeat the install line. A stolen key stays trusted on a router until its fingerprint file is replaced that way.

## A new OPNsense series

One repository serves every router, whatever its OPNsense series and FreeBSD version: the package is built with `PLUGIN_NO_ABI` (ABI `FreeBSD:*:*`, as OPNsense's theme plugins), because it holds only scripts. The address in `os-clat.conf` therefore never has to change. What has to be done for a new series (27.1, ...):

1. Test the plugin in the lab on the new series before that series is released (DESIGN.md, section 14: a series upgrade keeps the installed os-clat).
2. Point `PLUGINS_REF` in `build-package.sh` at a release tag of the new stable branch:

   ```
   git ls-remote https://github.com/opnsense/plugins 'refs/tags/27.1*'
   ```

   Take the commit of the line that ends in `^{}`. The series written into the package (`product_abi`) follows from the framework.
3. The release must still work on the series subscribers have not left yet, because they receive it too.
4. Raise the version and tag.

The actions in the workflows are pinned to commits; the version is in the comment behind each. To update one, replace commit and comment together (`git ls-remote https://github.com/<owner>/<action> 'refs/tags/v*'`). `release: "15.1"` in `publish.yml` is the FreeBSD of the build machine; it only has to be a release the action offers.

## Decisions

- **The site is `os-pkg.gettuckamore.ca`, a custom domain on the repository's Pages site.** The first proposal (DESIGN.md section 14, up to v0.12) was a custom domain, so that the address survives a change of host; the plain Pages address `77997.github.io/os-clat` was chosen first, and on 2026-10-13, before any router stored an address, the custom domain. The address belongs to the ISP, not to the GitHub account; "The address" above says what follows from that.
- **The address is a constant in `make-repo.sh`**, not read from the Pages settings at each release: a release must never publish another address than the one routers have stored.
- **The key's fingerprint is in git**, and a key that does not match it is refused, for the same reason: what routers have stored must not change without a commit that says so.
- **No `${ABI}` in the address.** The usual form `.../${ABI}` needs a directory named `FreeBSD:15:amd64`. Whether GitHub Pages serves a path with colons could not be confirmed, and a wrong guess would break every router at once. A fixed directory certainly works. Its cost, one catalogue for all FreeBSD versions, is met by the ABI-independent package.
- **Fingerprints, not a public key file.** The router needs one small file, and pkg-repo(8) and OPNsense's own repository work the same way.
- **Priority 5**, below OPNsense's 11: a package that exists in both repositories is taken from OPNsense's.
- **Only the current version is published**, because the site is replaced as a whole and pkg installs the newest version anyway.
- **The framework comes from a pinned commit of opnsense/plugins**, fetched at build time, not from a copy in this repository.
- **The package is built on FreeBSD, not OPNsense**, because that is what a GitHub runner can start. The framework falls back to series 26.7 there and takes `tayga` from FreeBSD's packages (the port is at 0.9.6, the version OPNsense 26.7 installs) only to write the dependency into the manifest.

## What is confirmed, and what the first workflow run has to confirm

Confirmed in the lab on 2026-10-12, on OPNsense 26.7.6 (pkg 2.8.4):

- `/usr/bin/make` exists on an OPNsense box, and `make package` of the framework completes there. Name `os-clat` (not `os-clat-devel`), version `1.0`, and `1.0_1` with `PLUGIN_REVISION=1`.
- `pkg query -F <file> %q` prints `FreeBSD:*:*`, and `PLUGIN_WWW` on the make command line reaches the manifest.
- The router installs the dependency `tayga` from OPNsense's repository. The manifest named the same version, 0.9.6, because the build ran on OPNsense.
- The fingerprint that set-up step 4 writes is the one `make-repo.sh` derives from the same key.
- `pkg repo <dir> signing_command: sh <script> sign` passes `SIGNING_KEY` and `SIGNING_PUB` to the script through the environment, and the read-back with `pkg -R <dir> -o PKG_DBDIR=... update -f` on a `file://` address works as root.
- `fetch` reads `index.html` of a live site, and `pkg version -t` prints `>` when the first version is the higher one: a release of a lower version was refused.
- The install line works on an IPv6-only OPNsense (name resolution through Unbound and a DNS64 resolver, `fetch`, the certificate check: without the lab CA `fetch` refused the site).
- The plugin is listed and installs as described, a later version arrives through *Check for updates* and *Update*, and after `rm -f /usr/local/etc/pkg/repos/os-clat.conf` the update check works again and the plugin's row is orphaned.

Still open, each read from source or documentation only:

Build:
- `make package` on plain FreeBSD 15.1 with only pkg installed. There the framework has no `opnsense-version`, PHP or Python, and takes `tayga` from FreeBSD's packages.
- Whether the router accepts a manifest that names another tayga version than OPNsense's repository has (pkg matches dependencies by name).
- The maintainer is still `N/A`, while the install notice of the GUI tells users to contact the author and the plugin's Info window ends with "Maintainer: N/A": add `PLUGIN_MAINTAINER=<address>` next to `PLUGIN_WWW` in `build-package.sh` once there is an address to name.
- `product_arch` in the version file is the architecture of the build machine (`amd64`), in a package whose ABI is `FreeBSD:*:*`. Nothing in the lab depended on it.

Repository:
- A catalogue written by the pkg of FreeBSD 15.1 is accepted by the pkg of OPNsense 26.7. In the lab both were OPNsense's pkg. "In the lab" says how to try a rehearsal's repository on the lab router.
- GitHub Pages serves the name over IPv6 with a certificate the router accepts, and serves what the lab's server served: `repo/meta.conf`, `repo/data.pkg`, the package, answers to conditional requests, and a 404 for `repo/files.pkg`.

Workflow:
- The FreeBSD machine has pkg, runs as root, receives `packaging/work/signing.key` with the workspace and copies `packaging/work/site` back.
- The `github-pages` environment accepts the tag after the rule of set-up step 3.
- `actions/deploy-pages` reports `https://os-pkg.gettuckamore.ca/` as `page_url` once *Enforce HTTPS* is ticked (neither its README nor GitHub's documentation says which scheme it reports), and the site answers there with the new version within five minutes of the deployment.
- The runner image has `php`.

Router:
- The install line against the real site over IPv6, with the certificate store as OPNsense ships it.
- *Check for updates* and an upgrade pressed in a browser. The lab drove those through the pages' API; a headless browser pressed the buttons of an installation and of a removal (`../lab/README.md` section 15).
