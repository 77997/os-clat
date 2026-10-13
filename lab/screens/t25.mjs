#!/usr/bin/env node
/*
 * t25.mjs - lab test T25: the buttons of the GUI of clat-opn, pressed in a browser. Lab use only.
 *
 *   bash lab.sh t25 [options] [part ...]               (Git Bash; it runs: node screens/t25.mjs ...)
 *     parts, done in the order given (default: install settings assign drift remove install):
 *       install    System > Firmware > Plugins: the link to the community plugins, the + of os-clat, Install in
 *                  the notice "Third party software". The box must be without the plugin and have the repository
 *                  (bash lab.sh fw remove os-clat)
 *       settings   Services > CLAT > Settings: Mode Disabled and Apply, Mode Automatic and Apply, Run tests (with
 *                  no test target when the box has none, then with the test target answering large pings in
 *                  fragments and whole: ispctl echodf off and on), then Services > CLAT > Log File
 *       assign     Interfaces > Assignments: the pencil of WAN, Save in Edit Assignment with nothing changed, Apply
 *       drift      Interfaces > Assignments: the pencil of CLAT, Save, Apply; then up to five minutes for the plugin
 *                  to register its interface again (the hand test of docs/PLAN.md)
 *       remove     System > Firmware > Plugins: the bin of os-clat, OK in "Confirm removal"
 *     --out DIR            where the pictures and t25.txt go (default .work/results/t25-<UTC>)
 *     --target ADDRESS     the IPv4 test target of the lab (default 192.88.99.1)
 *     --base URL, --profile DIR     as for capture.mjs
 *
 * The browser, its tunnel and the login are those of capture.mjs (headless Edge of the host, a throwaway profile).
 * Unlike a capture this changes the box: it installs and removes the package, saves settings and applies them.
 * Every click is a mouse press at the place where the element is drawn; a click on something that is not visible,
 * or that something else covers, fails. Text is typed as key input. After each step the box is asked over ssh
 * (clat-opn, and the LAN client on clat-world), as "lab.sh o" and "lab.sh c" do.
 *
 * Output: one line per check, PASS or FAIL with what was seen after "::", a picture of the window at each decisive
 * moment (the PPPoE user name is shown as YOUR_USERNAME; a picture in which a lab secret is readable is not saved),
 * and a last line "RESULT  T25 pass|fail ...". Exit status: 0 every check passed, 1 a check failed or a part
 * stopped, 2 usage, or nothing could be started.
 */
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { BUILD, Failure, LAB, gui, secrets, sleep } from './capture.mjs';

const PARTS = ['install', 'settings', 'assign', 'drift', 'remove'];
const PLUGIN = 'os-clat';
const view = { width: 1280, height: 1000 };
const started = Date.now();
const lines = [];
const checks = [];
let out, page, hidden = [], pairs = [], pictures = 0, part = '';

function say(line) {
    console.log(line);
    lines.push(line);
    if (out) {
        fs.appendFileSync(path.join(out, 't25.txt'), line + '\n');
    }
}

function usage(message) {
    if (message) {
        console.error('t25: ' + message);
    }
    const text = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
    console.error(text.slice(text.indexOf(' * t25.mjs'), text.indexOf(' */')).replace(/^ \* ?/gm, ''));
    process.exit(2);
}

function check(id, ok, what, seen) {
    checks.push({ id, ok });
    say(`${ok ? 'PASS' : 'FAIL'}    T25.${id} ${what} :: ${seen}`);
    return ok;
}

/* ---- the box and the client, over ssh ---------------------------------------------------------------------------- */

function ssh(host, command, input) {
    return new Promise((resolve) => {
        const child = spawn('ssh', ['-F', path.join(BUILD, 'ssh_config').replace(/\\/g, '/'), host, command],
            { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
        let text = '';
        child.stdout.on('data', (chunk) => { text += chunk; });
        child.stderr.on('data', (chunk) => { text += chunk; });
        child.on('error', (error) => resolve('ssh: ' + error.message));
        child.on('close', () => resolve(text.replace(/\r/g, '').trim()));
        child.stdin.end(input);
    });
}

/* a script for /bin/sh on clat-opn; root's shell there is csh, so it travels on stdin (lab.sh, opn_sh) */
const opn = (script) => ssh('clat-opn', '/bin/sh -s', 'PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin; export PATH\n' + script + '\n');
const world = (script) => ssh('clat-world', 'bash -s', script + '\n');

const STATE = `configctl clat details 2>/dev/null | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["state"])
except Exception:
    print("none")'`;

/* what the box is like now, as key=value lines */
async function box() {
    const text = await opn(`echo "pkg=$(pkg query "%n %v %R" ${PLUGIN} 2>/dev/null)"
echo "tayga=$(pkg query "%n %v" tayga 2>/dev/null)"
echo "repo=$(test -s /usr/local/etc/pkg/repos/${PLUGIN}.conf && echo yes || echo no)"
echo "state=$(${STATE})"
echo "route4=$(netstat -rn -f inet | awk '$1 == "default" { print $2, $NF }' | tr '\\n' ' ' | sed 's/ $//')"
echo "tun=$(ifconfig tun464 >/dev/null 2>&1 && echo yes || echo no)"
echo "tunline=$(ifconfig tun464 2>/dev/null | head -n 1)"
echo "record=$(pluginctl -g interfaces.clat 2>/dev/null | tr -d ' \\n')"
echo "clatd=$(pgrep -f clatd.py | wc -l | tr -d ' ')"
echo "taygas=$(pgrep -x tayga | wc -l | tr -d ' ')"
echo "enabled=$(pluginctl -g OPNsense.clat.general.enabled 2>/dev/null)"
echo "target=$(pluginctl -g OPNsense.clat.general.test_target 2>/dev/null)"
echo "wan=$(pluginctl -g interfaces.wan | tr -d '\\n')"
echo "session=$(ifconfig pppoe0 2>/dev/null | grep -c 'inet6 2')"
echo "mpd=$(pgrep -f 'mpd5.*mpd_wan' | tr '\\n' ' ' | sed 's/ $//')"`);
    return Object.fromEntries(text.split('\n').map((line) => /^([a-z0-9]+)=(.*)$/.exec(line)).filter(Boolean).map((match) => [match[1], match[2]]));
}

/* waits on the box until the CLAT has the state, asking every 2 s; returns the last state seen */
async function boxState(want, seconds) {
    const text = await opn(`i=0
while :; do
    s=$(${STATE})
    [ "$s" = ${want} ] && break
    i=$((i + 1)); [ "$i" -ge ${Math.ceil(seconds / 2)} ] && break
    sleep 2
done
echo "$s"`);
    return text.split('\n').pop();
}

/* the IPv4-only LAN client: three pings and a page of the test target */
async function client(target) {
    const text = await world(`ispctl client sh -c 'ping -n -c3 -W2 ${target} 2>&1 | grep -E "transmitted|unreachable" | tail -n 1; curl -sS -m 10 -o /dev/null -w "http %{http_code}" http://${target}/ 2>&1 | tail -n 1'`);
    return text.replace(/\n/g, '; ');
}

/* ---- the browser ------------------------------------------------------------------------------------------------- */

const count = (selector) => page.call('count', selector);
const wait = (selector, ms) => page.waitFor(selector, () => count(selector), ms);
const gone = (selector, ms) => page.waitFor('the end of ' + selector, async () => !(await count(selector)), ms);
const text = (selector) => page.call('read', selector);

/* a press of the left mouse button where the first visible match is drawn */
async function mouse(selector, { quiet = true, name = '' } = {}) {
    const spot = await page.call('spot', selector);
    if (!spot) {
        throw new Failure('nothing visible to click: ' + selector);
    }
    await sleep(100);                                           // the page may have scrolled to show it
    const now = await page.call('spot', selector);
    if (!now || now.covered) {
        throw new Failure('cannot click ' + selector + ': it is covered by ' + (now ? now.covered : 'nothing, it is gone'));
    }
    say(`click   ${name || now.text || selector}`);
    const at = { x: now.x, y: now.y };
    await page.tools.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...at });
    await page.tools.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...at, button: 'left', buttons: 1, clickCount: 1 });
    await page.tools.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...at, button: 'left', clickCount: 1 });
    await sleep(200);
    if (quiet) {
        await page.quiet(120000);
    }
}

/* text typed into the field that was clicked, in place of what it held */
async function type(selector, value) {
    await mouse(selector, { name: 'the field ' + selector });
    await page.tools.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a', code: 'KeyA', modifiers: 2, commands: ['selectAll'] });
    await page.tools.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'a', code: 'KeyA', modifiers: 2 });
    say('type    ' + value);
    await page.tools.send('Input.insertText', { text: value });
}

/* after a click that leads to another page, or to another #part of this one */
async function arrived(before) {
    await page.waitFor('another page after the click', async () => {
        const now = await page.run('[performance.timeOrigin, location.href]').catch(() => null);
        return now && (now[0] !== before[0] || now[1] !== before[1]);
    });
    await page.quiet(120000);
}

/* the menu on the left: a level is clicked only while the one below it is not showing; the last entry is the page */
async function menu(...hrefs) {
    const link = (href) => `#mainmenu a[href="${href}"]`;
    for (const [level, href] of hrefs.entries()) {
        if (level === hrefs.length - 1) {
            await wait(link(href));
            const before = await page.run('[performance.timeOrigin, location.href]');
            await mouse(link(href), { quiet: false });
            await arrived(before);
        } else if (!(await count(link(hrefs[level + 1])))) {
            await mouse(link(href));
            await wait(link(hrefs[level + 1]));
            await sleep(500);                                   // the list slides open
        }
    }
    say('page    ' + await text('.page-content-head h1'));
}

/* the same page loaded again, as with the browser's reload button */
async function reload() {
    say('reload  the page');
    const loaded = page.tools.event('Page.loadEventFired', 45000);
    loaded.catch(() => {});
    await page.tools.send('Page.reload');
    await loaded;
    await page.quiet(120000);
}

/* a choice of a list that opens under its button */
async function choose(field, choice) {
    await mouse(`button[data-id="${field}"]`, { name: 'the list ' + field });
    await wait(`a[role=option] >> ${choice}`);
    await sleep(300);
    await mouse(`a[role=option] >> ${choice}`);
}

/* a button of the kind "Apply": pressed, then waited for until its spinner has gone */
async function action(button, seconds) {
    const icon = `document.querySelector('${button} .reload_progress').classList`;
    let tick = false;
    await mouse(button, { quiet: false });
    await page.waitFor('the end of ' + button, async () => {
        const [spins, ticked] = await page.run(`[${icon}.contains('fa-spinner'), ${icon}.contains('fa-check')]`);
        tick = ticked;                                          // the tick is shown for four seconds
        return !spins;
    }, seconds * 1000);
    await page.quiet(120000);
    const complaint = await count('.modal.in') ? (await text('.modal.in .modal-content')).replace(/\s*\n\s*/g, ' / ') : '';
    return { ok: tick && !complaint, complaint: complaint || (tick ? '' : 'the button ended without its tick') };
}

/* a picture of the window as it is; the PPPoE user name is shown neutral while it is taken */
async function shot(name) {
    await page.run(`(() => { const pairs = ${JSON.stringify(pairs)}; window.__t25 = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            let to = node.nodeValue;
            for (const [from, show] of pairs) { to = to.split(from).join(show); }
            if (to !== node.nodeValue) { window.__t25.push([node, node.nodeValue]); node.nodeValue = to; }
        } })()`);
    const [left, top] = await page.run('[window.scrollX, window.scrollY]');
    const seen = await page.call('seen', { x: left, y: top, width: view.width, height: view.height }, true);
    const file = String(pictures += 1).padStart(2, '0') + '-' + part + '-' + name + '.png';
    const readable = hidden.filter(([, value]) => seen.includes(value)).map(([key]) => key);
    if (readable.length) {
        say(`picture NOT SAVED ${file}: the value of ${readable.join(', ')} is readable in the window`);
    } else {
        fs.writeFileSync(path.join(out, file), await page.png());
        say('picture ' + file);
    }
    await page.run('(() => { for (const [node, value] of window.__t25) { node.nodeValue = value; } window.__t25 = []; })()');
}

/* ---- System > Firmware -------------------------------------------------------------------------------------------- */

const row = `#pluginlist tr.plugin_entry >> ${PLUGIN}`;

async function plugins() {
    if (await page.run(`location.pathname === '/ui/core/firmware'`)) {
        await reload();                                         // the menu entry of the page that is open leads nowhere
    } else {
        await menu('#System', '#System_Firmware', '/ui/core/firmware#plugins');
    }
    if (!(await page.run(`document.querySelector('#plugintab').classList.contains('active')`))) {
        await mouse('#plugintab a');
    }
    await wait('#pluginlist tr.plugin_entry', 60000);
    await page.quiet();
}

/* after Install or OK: the Updates tab with the page's own progress, until its spinner stops */
async function progress(id, verb, expect) {
    const since = Date.now();
    await page.waitFor('the progress of the page', () => page.run(`document.querySelector('#updatetab').classList.contains('active')`));
    await sleep(1500);
    await shot(verb + '-progress');
    await page.waitFor('the end of the progress on the Updates tab', () => page.run(`!document.querySelector('#updatetab_progress').classList.contains('fa-spinner')`), 600000);
    await page.quiet(120000);
    const log = (await text('#update_status')) || '';
    await page.run(`(() => { const e = document.querySelector('#update_status'); e.scrollTop = e.scrollHeight; })()`);
    await shot(verb + '-done');
    const last = log.split('\n').filter((line) => line.trim()).slice(-1)[0] || '';
    const missing = expect.filter((want) => !log.includes(want));
    check(id, !missing.length, `the Updates tab shows the ${verb} and ends with ***DONE***`,
        `${Math.round((Date.now() - since) / 1000)} s; ` + (missing.length ? 'not in the log: ' + JSON.stringify(missing) + '; ' : expect.map((want) => `"${want}"`).join(', ') + '; ') + `last line "${last}"`);
    return since;
}

async function install(opt) {
    const before = await box();
    if (before.pkg || before.repo !== 'yes') {
        throw new Failure(`"install" needs a box without ${PLUGIN} and with its repository (pkg "${before.pkg}", repository definition: ${before.repo}): bash lab.sh fw remove ${PLUGIN}; bash lab.sh repo subscribe`);
    }
    say(`box     before: no ${PLUGIN} package, tayga "${before.tayga}", repository definition ${before.repo}, IPv4 default route "${before.route4}", client: ${await client(opt.target)}`);
    await plugins();
    await wait('#plugins-act');
    check('1a', !(await count(row)), `System > Firmware > Plugins lists no ${PLUGIN} before the link is used`, await text('#plugins-act'));
    await shot('plugins');
    await mouse('#plugins-act');
    await wait(row);
    const cells = await page.run(`Array.from(document.querySelectorAll('#pluginlist tr.plugin_entry')).filter((tr) => tr.cells[0].innerText.trim().split(' ')[0] === '${PLUGIN}').map((tr) => Array.from(tr.cells, (td) => td.innerText.trim()).slice(0, 6).join(' | '))[0]`);
    check('1b', Boolean(await count(`.act_install[data-package="${PLUGIN}"]`)) && !/installed/.test(cells), `after the link the row of ${PLUGIN} is there with its +`, cells);
    await shot('community');
    await mouse(`.act_install[data-package="${PLUGIN}"]`, { name: 'the + of ' + PLUGIN });
    await wait('.modal.in .modal-footer button >> Install');
    await sleep(500);
    const notice = await text('.modal.in .modal-content');
    check('1c', notice.includes('Third party software'), 'the + opens the notice', notice.replace(/\s*\n\s*/g, ' / '));
    await shot('notice');
    await mouse('.modal.in .modal-footer button >> Install', { quiet: false });
    const since = await progress('1d', 'install', [`Installing ${PLUGIN}-`, '***DONE***']);
    const state = await boxState('active', 180);
    const active = Math.round((Date.now() - since) / 1000);
    await mouse('#plugintab a');
    await wait(row);
    const listed = await text(row);
    check('1e', listed.includes(PLUGIN + ' (installed)') && Boolean(await count(`.act_remove[data-package="${PLUGIN}"]`)), `the Plugins tab lists ${PLUGIN} as installed, with the bin`, listed.replace(/\s+/g, ' '));
    await shot('installed');
    const after = await box();
    check('1f', after.pkg.startsWith(PLUGIN + ' ') && after.pkg.endsWith(' ' + PLUGIN) && Boolean(after.tayga), 'box: the package is installed from the repository os-clat, and tayga with it', `${after.pkg}; ${after.tayga}`);
    check('1g', state === 'active' && /^192\.0\.0\.2 tun464$/.test(after.route4), 'box: the CLAT is active and has the IPv4 default route', `state ${state} within ${active} s of the click on Install; default route "${after.route4}"; ${after.clatd} clatd, ${after.taygas} tayga`);
    const reached = await client(opt.target);
    check('1h', / 3 received/.test(reached) && /http 200/.test(reached), 'the LAN client has IPv4', reached);
}

async function remove(opt) {
    const before = await box();
    if (!before.pkg) {
        throw new Failure(`"remove" needs ${PLUGIN} installed`);
    }
    say(`box     before: ${before.pkg}, state ${before.state}, IPv4 default route "${before.route4}"`);
    await plugins();
    await wait(row);
    const listed = await text(row);
    check('4a', listed.includes(PLUGIN + ' (installed)'), `System > Firmware > Plugins lists ${PLUGIN} as installed, without the link`, listed.replace(/\s+/g, ' '));
    await mouse(`.act_remove[data-package="${PLUGIN}"]`, { name: 'the bin of ' + PLUGIN });
    await wait('.modal.in .modal-footer button >> OK');
    await sleep(500);
    const question = await text('.modal.in .modal-content');
    check('4b', question.includes('Confirm removal') && question.includes(PLUGIN), 'the bin opens the question', question.replace(/\s*\n\s*/g, ' / '));
    await shot('question');
    await mouse('.modal.in .modal-footer button >> OK', { quiet: false });
    await progress('4c', 'removal', [`Deinstalling ${PLUGIN}-`, '***DONE***']);
    await mouse('#plugintab a');
    await wait('#plugins-act');
    const still = await count(row);
    await mouse('#plugins-act');
    await wait(row);
    check('4d', !still && Boolean(await count(`.act_install[data-package="${PLUGIN}"]`)), `the Plugins tab lists ${PLUGIN} only after the link again, with its +`, (await text(row)).replace(/\s+/g, ' '));
    await shot('removed');
    const after = await box();
    check('4e', !after.pkg && !after.tayga && after.tun === 'no' && !after.route4 && after.clatd === '0' && after.taygas === '0', 'box: no package, no tayga, no tun464, no IPv4 default route, no process',
        `pkg "${after.pkg}", tayga "${after.tayga}", tun464 ${after.tun}, default route "${after.route4}", ${after.clatd} clatd, ${after.taygas} tayga, repository definition ${after.repo}`);
    const reached = await client(opt.target);
    check('4f', / 0 received/.test(reached) || /unreachable/i.test(reached), 'the LAN client has no IPv4 any more', reached);
    await reload();
    check('4g', !(await page.run(`Boolean(document.querySelector('#mainmenu a[href="/ui/clat"]'))`)), 'after a reload the menu has no Services > CLAT', await text('.page-content-head h1'));
}

/* ---- Services > CLAT ------------------------------------------------------------------------------------------------ */

const status = () => page.run(`Object.fromEntries(Array.from(document.querySelectorAll('#frm_status span[id^="status."]'), (span) => [span.id.slice(7), span.innerText.trim()]))`);

/* the label beside the page's heading that core draws for a service: running (green), stopped (red) or none */
const buttons = () => page.run(`(() => { const label = document.querySelector('#service_status_container .label');
    return !label || label.classList.contains('hidden') ? 'none' : label.classList.contains('label-success') ? 'running' : label.classList.contains('label-danger') ? 'stopped' : 'unknown'; })()`);

/* the State row; the page asks the box again only on Refresh, so that button is pressed until the text is there */
async function stateRow(want, seconds) {
    const until = Date.now() + seconds * 1000;
    let presses = 0;
    for (;;) {
        const rows = await status();
        if (rows.state === want || Date.now() > until) {
            return { rows, presses };
        }
        await sleep(3000);
        await mouse('#refreshAct');
        presses += 1;
    }
}

async function runTests() {
    const since = Date.now();
    const done = await action('#testAct', 120);
    const shown = await count('#testResult') ? await text('#testResult') : '(no result shown)';
    return { text: done.complaint || shown, seconds: Math.round((Date.now() - since) / 1000) };
}

async function settings(opt) {
    const before = await box();
    if (!before.pkg) {
        throw new Failure(`"settings" needs ${PLUGIN} installed`);
    }
    const from = await opn('date +%Y-%m-%dT%H:%M:%S');           // the log's time stamps are the box's clock
    if (!(await page.run(`Boolean(document.querySelector('#mainmenu a[href="/ui/clat"]'))`))) {
        say('menu    no Services > CLAT in the menu of the page that is open (it was drawn before the installation)');
        await reload();
    }
    await menu('#Services', '#Services_Clat', '/ui/clat');
    await wait('#frm_status span[id="status.state"]');
    let seen = await stateRow('Active.', 120);
    check('2a', seen.rows.state === 'Active.', 'Services > CLAT > Settings shows State Active.', Object.values(seen.rows).join(' | ').replace(/\n/g, ' / '));
    const top = Number((/IPv4 (\d+)/.exec(seen.rows.mtu || '') || [])[1]);
    await shot('active');

    await choose('clat.general.enabled', 'Disabled');
    let done = await action('#reconfigureAct', 120);
    seen = await stateRow('Disabled.', 30);
    check('2b', done.ok && seen.rows.state === 'Disabled.', 'Mode Disabled, Apply: the page shows State Disabled.', (done.complaint || 'Apply ended with its tick') + '; ' + Object.values(seen.rows).join(' | ').replace(/\n/g, ' / '));
    await shot('disabled');
    let now = await box();
    /* the device tun464 stays, down and without an address (DESIGN D2); what goes is the interface CLAT of the GUI */
    check('2c', now.enabled === '0' && now.state === 'disabled' && !now.route4 && ['', 'null', '[]', '{}'].includes(now.record) && now.clatd === '0' && now.taygas === '0',
        'box: the CLAT is stopped, the IPv4 default route and the interface CLAT are gone',
        `enabled ${now.enabled}, state ${now.state}, default route "${now.route4}", interfaces.clat "${now.record}", ${now.clatd} clatd, ${now.taygas} tayga; device: ${now.tunline || 'no tun464'}`);
    let reached = await client(opt.target);
    check('2d', / 0 received/.test(reached) || /unreachable/i.test(reached), 'the LAN client has no IPv4 while it is disabled', reached);

    await choose('clat.general.enabled', 'Automatic');
    const since = Date.now();
    done = await action('#reconfigureAct', 120);
    const atOnce = `State "${(await status()).state}", service buttons in the page head: ${await buttons()}`;
    await sleep(7000);                                          // the page looks again by itself 5 s after Apply
    const later = `State "${(await status()).state}", service buttons: ${await buttons()}`;
    say(`page    as Apply ends: ${atOnce}; 7 s later, nothing pressed: ${later}`);
    await shot('enabled-7s');
    seen = await stateRow('Active.', 180);
    const head = await buttons();
    check('2e', done.ok && seen.rows.state === 'Active.' && head === 'running', 'Mode Automatic, Apply: the page shows State Active. again, and the service buttons in its head show it running',
        `${done.complaint || 'Apply ended with its tick'}; ${Math.round((Date.now() - since) / 1000)} s after the click, Refresh pressed ${seen.presses} time(s); service buttons: ${head}; ` + Object.values(seen.rows).join(' | ').replace(/\n/g, ' / '));
    await shot('active-again');
    now = await box();
    reached = await client(opt.target);
    check('2f', now.enabled === '1' && now.state === 'active' && /^192\.0\.0\.2 tun464$/.test(now.route4) && / 3 received/.test(reached), 'box: active again with the IPv4 default route, and the LAN client has IPv4',
        `enabled ${now.enabled}, state ${now.state}, default route "${now.route4}"; ${reached}`);

    /* the test target is under Advanced */
    const field = '[id="clat.general.test_target"]';
    await mouse('#frm_general thead >> Advanced', { name: 'the heading Advanced' });
    await wait(field);
    const held = await text(field);
    say(`field   Test target holds "${held}"`);
    if (!held) {
        const none = await runTests();
        check('2g', none.text === 'No test target is set.', 'Run tests without a test target says so', `${none.seconds} s; ${none.text}`);
        await shot('test-no-target');
    }
    if (held !== opt.target) {
        await type(field, opt.target);
        done = await action('#reconfigureAct', 120);
        seen = await stateRow('Active.', 180);
        now = await box();
        check('2h', done.ok && now.target === opt.target && seen.rows.state === 'Active.', 'Test target typed, Apply: the box has it and the CLAT stays active',
            `${done.complaint || 'Apply ended with its tick'}; box: test_target ${now.target}, state ${now.state}; page: ${seen.rows.state}`);
    }
    for (const [id, echodf, verdict] of [['2i', 'off', `IPv4 packet size: inconclusive (largest ping answered: 1260 bytes; the next larger ping got no reply and no "fragmentation needed" error;`],
        ['2j', 'on', `IPv4 packet size: ok (largest IPv4 packet that passes: ${top} bytes)`]]) {
        say(`isp     ispctl echodf ${echodf}: ` + (await world(`ispctl echodf ${echodf}; nft list chain inet isp echodf | grep -c frag-off`)).replace(/\n/g, '; ') + ' rule(s) in the chain echodf');
        const result = await runTests();
        const rows = result.text.split('\n');
        check(id, rows.length === 3 && rows[0].startsWith('NAT64 gateway over IPv6: ok') && rows[1].startsWith('IPv4 through the CLAT: ok') && rows[2].startsWith(verdict),
            `Run tests, the test target answering large pings ${echodf === 'on' ? 'whole' : 'in fragments'}: the page shows the three results`, `${result.seconds} s; ` + rows.join(' / '));
        await shot('test-echodf-' + echodf);
    }
    const chain = await world('ispctl echodf off; nft list chain inet isp echodf | grep -c frag-off');
    check('2k', chain.split('\n').pop() === '0', 'the test target is as it was (ispctl echodf off)', chain.replace(/\n/g, '; ') + ' rule(s) in the chain echodf');

    await menu('#Services', '#Services_Clat', '/ui/diagnostics/log/core/clat');
    await wait('#grid-log');
    await page.quiet();
    const first = await text('#grid-log .tabulator-tableholder');
    say(`log     as the page opens, Severity ${await text('button[data-id="severity_filter"]')}: ` + (first ? first.split('\n').length + ' line(s) of text in the list, the first: ' + first.split('\n').slice(0, 4).join(' ') : 'nothing'));
    await shot('log-opens');
    await choose('severity_filter', 'Informational');
    await wait('#grid-log .tabulator-row >> state');
    const rows = await page.run(`Array.from(document.querySelectorAll('#grid-log .tabulator-row'), (row) => row.innerText.replace(/\\s+/g, ' ').trim()).slice(0, 12)`);
    const fresh = rows.filter((line) => /state \S+ -> active/.test(line) && line.slice(0, 19) >= from);
    check('2l', fresh.length > 0, 'Services > CLAT > Log File with Severity Informational lists the activation just made',
        `${rows.length} rows read, the box's clock at the start of this part ${from}; ` + (fresh[0] || 'no "state ... -> active" since then; newest rows: ' + rows.slice(0, 4).join(' / ')));
    await shot('log-informational');
}

/* ---- Interfaces > Assignments ---------------------------------------------------------------------------------------- */

async function assign(opt) {
    const before = await box();
    const pppd = () => world(`ispctl status | sed -n '/^== session/{n;p;}; /^== pppd/{n;p;}' | awk 'NR == 1 { print } NR == 2 { print "pppd", $1 }' | tr '\\n' ' '`);
    const isp = await pppd();
    say(`box     before: state ${before.state}, mpd5 pid ${before.mpd}, IPv4 default route "${before.route4}"; ISP: ${isp}`);
    await menu('#Interfaces', '/ui/interfaces/assignment');
    await wait('.tabulator-row >> WAN');
    await page.quiet();
    await shot('list');
    await mouse('.tabulator-row >> WAN >> .command-edit', { name: 'the pencil of the WAN row' });
    await wait('#dialog_dialogAssignment.in .modal-footer button >> Save');
    await sleep(500);
    const title = await text('#dialog_dialogAssignment .modal-title');
    const device = (await text('#dialog_dialogAssignment button[data-id="interface.if"]')) || '';
    check('3a', title === 'Edit Assignment' && device.startsWith('pppoe0 (vlan0.40)'), 'the pencil of WAN opens Edit Assignment with the PPPoE device', `${title}; Device ${pairs.reduce((shown, [from, show]) => shown.split(from).join(show), device)}`);
    await shot('edit');
    await mouse('#dialog_dialogAssignment .modal-footer button >> Save');
    await gone('#dialog_dialogAssignment.in', 30000).catch(() => {});
    const open = await count('#dialog_dialogAssignment.in');
    const pending = await count('#change_message_base_form') ? await text('#change_message_base_form') : '';
    /* core asks for Apply when the save changed the record: it does for a WAN that Interfaces > [WAN] wrote last, and not for one this window wrote */
    check('3b', !open, 'Save with nothing changed closes the window',
        open ? 'the window is still open: ' + (await text('#dialog_dialogAssignment .modal-body')).replace(/\s+/g, ' ').slice(0, 300) : pending ? 'the page then says: ' + pending : 'no notice on the page then: nothing to apply');
    await shot('pending');
    const since = Date.now();
    const done = await action('#reconfigureAct', 300).catch((error) => ({ ok: false, complaint: error.message }));
    check('3c', done.ok, 'Apply ends with its tick', `${Math.round((Date.now() - since) / 1000)} s; ` + (done.complaint || 'no window with an error; the notice is ' + (await count('#change_message_base_form') ? 'still there' : 'gone')));
    await shot('applied');
    const session = await opn(`i=0; until [ "$(ifconfig pppoe0 2>/dev/null | grep -c 'inet6 2')" -ge 1 ] || [ "$i" -ge 90 ]; do i=$((i + 1)); sleep 2; done; ifconfig pppoe0 2>/dev/null | grep -c 'inet6 2'`);
    const state = await boxState('active', 240);
    const waited = Math.round((Date.now() - since) / 1000);
    const after = await box();
    const ispAfter = await pppd();
    check('3d', session !== '0' && state === 'active' && /^192\.0\.0\.2 tun464$/.test(after.route4), 'box: the PPPoE session is there and the CLAT is active',
        `${waited} s after the click on Apply: pppoe0 has a global address, state ${state}; the session was ${isp === ispAfter ? 'not ' : ''}dialled again (ISP before: ${isp}; now: ${ispAfter}; mpd5 pid ${before.mpd} -> ${after.mpd}); default route "${after.route4}"`);
    say('log     the CLAT log since the click: ' + ((await opn(`awk -v from=${new Date(since).toISOString().slice(0, 19)} 'substr($2, 1, 19) >= from' /var/log/clat/clat_*.log | sed -n 's/.*\\] \\(state .*\\)/\\1/p' | tr '\\n' ';'`)) || 'no change of state'));
    /* the window writes the record in its own form: what counts is that no setting is lost or has another value */
    /* "lock" 0 is the window's way to write "not locked", and it puts that into records as it saves others */
    const [was, is] = [before.wan, after.wan].map((json) => Object.entries(JSON.parse(json)).filter(([key, value]) => value !== '' && !(key === 'lock' && value === '0')));
    const lost = was.filter(([key, value]) => !is.some(([k, v]) => k === key && v === value)).map(([key, value]) => key + '=' + value);
    const added = is.filter(([key]) => !was.some(([k]) => k === key)).map(([key, value]) => key + '=' + value);
    check('3e', !lost.length, 'box: every setting of the WAN is there with the value it had', `${was.length} settings before, ${is.length} now; lost or changed: ${lost.join(', ') || 'none'}; new: ${added.join(', ') || 'none'}`);
    const reached = await client(opt.target);
    check('3f', / 3 received/.test(reached) && /http 200/.test(reached), 'the LAN client has IPv4', reached);
}

/*
 * The hand test of the plan (docs/PLAN.md, T25; DESIGN section 7.2, "Drift"): the CLAT entry itself saved and applied
 * in Interfaces > Assignments. Core then rewrites the record the plugin registered; the supervisor has to register
 * it again. The three conditions of a drifted record are those of T25 in run-tests.sh.
 */
async function drift(opt) {
    const record = async () => {
        const json = await opn(`pluginctl -g interfaces.clat | tr -d '\\n'`);
        try {
            return JSON.parse(json);
        } catch {
            return null;
        }
    };
    const drifted = (rec) => Boolean(rec) && (!('internal_dynamic' in rec) || rec.type !== 'none' || rec.ipaddr === 'none');
    const gateways = () => opn(`configctl interface gateways status | python3 -c 'import json, sys
print(" ".join("%s=%s" % (name, gw["address"]) for name, gw in sorted(json.load(sys.stdin).items())))'`);
    const before = await box();
    const was = await record();
    if (before.state !== 'active' || !was || drifted(was)) {
        throw new Failure(`"drift" needs the CLAT active and its interface record as the plugin registers it (state ${before.state}, record ${JSON.stringify(was)})`);
    }
    say(`box     before: state ${before.state}, interfaces.clat ${JSON.stringify(was)}, gateways ${await gateways()}`);
    if (await page.run(`location.pathname === '/ui/interfaces/assignment'`)) {
        await reload();
    } else {
        await menu('#Interfaces', '/ui/interfaces/assignment');
    }
    await wait('.tabulator-row >> tun464');
    await page.quiet();
    await mouse('.tabulator-row >> tun464 >> .command-edit', { name: 'the pencil of the CLAT row' });
    await wait('#dialog_dialogAssignment.in .modal-footer button >> Save');
    await sleep(500);
    const device = (await text('#dialog_dialogAssignment button[data-id="interface.if"]')) || '';
    check('5a', (await text('#dialog_dialogAssignment .modal-title')) === 'Edit Assignment' && device.includes('tun464'), 'the pencil of CLAT opens Edit Assignment with the device tun464', 'Device ' + device);
    await shot('edit');
    await mouse('#dialog_dialogAssignment .modal-footer button >> Save');
    await gone('#dialog_dialogAssignment.in', 30000).catch(() => {});
    const open = await count('#dialog_dialogAssignment.in');
    const pending = await count('#change_message_base_form') ? await text('#change_message_base_form') : '';
    check('5b', !open, 'Save with nothing changed closes the window',
        open ? 'the window is still open: ' + (await text('#dialog_dialogAssignment .modal-body')).replace(/\s+/g, ' ').slice(0, 300) : pending ? 'the page then says: ' + pending : 'no notice on the page then: nothing to apply');
    await shot('pending');
    const saved = await record();
    const since = Date.now();
    const done = await action('#reconfigureAct', 300).catch((error) => ({ ok: false, complaint: error.message }));
    check('5c', done.ok, 'Apply ends with its tick', `${Math.round((Date.now() - since) / 1000)} s; ` + (done.complaint || 'no window with an error'));
    await shot('applied');
    let now = await record();
    say(`box     interfaces.clat after Save: ${JSON.stringify(saved)}; gateways after Apply ${await gateways()}; state ${(await box()).state}; client: ${await client(opt.target)}`);
    let healed = Boolean(now) && !drifted(now);
    while (!healed && Date.now() - since < 320000) {
        await sleep(5000);
        now = await record();
        healed = Boolean(now) && !drifted(now);
    }
    /* the repair can be faster than a look at the box: what Apply wrote is in the revisions core keeps of config.xml */
    const kept = (await opn(`cd /conf/backup && for f in $(ls -t config-*.xml | head -n 12); do
    d=$(sed -n '/<revision>/,/<\\/revision>/p' "$f" | sed -n 's/.*<description>\\(.*\\)<\\/description>.*/\\1/p')
    t=$(sed -n '/<revision>/,/<\\/revision>/p' "$f" | sed -n 's/.*<time>\\(.*\\)<\\/time>.*/\\1/p')
    r=$(sed -n '/<interfaces>/,/<\\/interfaces>/p' "$f" | sed -n '/<clat>/,/<\\/clat>/p' | tr -d '\\n' | sed 's/  */ /g')
    echo "$t|$d|$r"
done`)).split('\n').map((line) => line.split('|')).filter((cells) => cells.length === 3).map(([time, what, rec]) => ({ time: Number(time), what, rec: rec.trim() }));
    const stripped = (rec) => !rec.includes('<internal_dynamic>') || !rec.includes('<type>none</type>') || rec.includes('<ipaddr>none</ipaddr>');
    const at = kept.findIndex((entry) => entry.what.includes('/api/interfaces/assignment/reconfigure'));
    const applied = at >= 0 && kept[at + 1] && kept[at + 1].what.includes('set_item/clat') ? kept[at] : null;
    const again = applied ? kept.slice(0, at).reverse().find((entry) => !stripped(entry.rec)) : null;
    if (applied && stripped(applied.rec)) {
        check('5d', true, 'box: Apply wrote the record without what the plugin registered (no internal_dynamic, no type none, or ipaddr none)', applied.rec);
        check('5e', healed && Boolean(again) && again.time - applied.time <= 300, 'box: within 5 minutes the supervisor has registered the record again',
            (again ? `${(again.time - applied.time).toFixed(1)} s after the revision of the Apply, revision "${again.what}": ${again.rec}` : 'no later revision has it') + `; now ${JSON.stringify(now)}`);
    } else {
        say(`note    T25.5d and 5e do not apply: ${applied ? 'Apply left the record as the plugin registers it: ' + applied.rec : 'no revision of this Apply was found in /conf/backup'}`);
    }
    const state = await boxState('active', 60);
    const names = await gateways();
    const after = await box();
    check('5f', state === 'active' && /(^| )CLAT_GW=192\.0\.0\.2/.test(names) && /^192\.0\.0\.2 tun464$/.test(after.route4), 'box: the gateway is named CLAT_GW and the CLAT is active',
        `state ${state}; gateways ${names}; default route "${after.route4}"`);
    say('log     the CLAT log since the click: ' + ((await opn(`awk -v from=${new Date(since).toISOString().slice(0, 19)} 'substr($2, 1, 19) >= from' /var/log/clat/clat_*.log | sed 's/.*\\] //' | grep -v '^tayga: ' | tr '\\n' ';'`)) || 'nothing'));
    const reached = await client(opt.target);
    check('5g', / 3 received/.test(reached) && /http 200/.test(reached), 'the LAN client has IPv4', reached);
    await menu('#Services', '#Services_Clat', '/ui/clat');
    await wait('#frm_status span[id="status.state"]');
    const seen = await stateRow('Active.', 60);
    check('5h', seen.rows.state === 'Active.' && seen.rows.preflight === 'No findings.', 'Services > CLAT > Settings shows State Active. and no finding', Object.values(seen.rows).join(' | ').replace(/\n/g, ' / '));
    await shot('clat-page');
}

/* ---- main ------------------------------------------------------------------------------------------------------------- */

async function main() {
    const opt = { target: '192.88.99.1', parts: [] };
    const args = process.argv.slice(2);
    while (args.length) {
        const arg = args.shift();
        if (['--out', '--target', '--base', '--profile'].includes(arg)) {
            if (!args.length) {
                usage(arg + ' needs a value');
            }
            opt[arg.slice(2)] = args.shift();
        } else if (PARTS.includes(arg)) {
            opt.parts.push(arg);
        } else {
            usage(arg === '-h' || arg === '--help' ? '' : 'unknown part or option ' + arg);
        }
    }
    if (!/^\d+(\.\d+){3}$/.test(opt.target)) {
        usage('--target must be an IPv4 address');
    }
    if (!opt.parts.length) {
        opt.parts = ['install', 'settings', 'assign', 'drift', 'remove', 'install'];
    }
    const stamp = new Date().toISOString().replace(/[-:]|\.\d+/g, '');
    out = path.resolve(opt.out || path.join(LAB, '.work', 'results', 't25-' + stamp));
    fs.mkdirSync(out, { recursive: true });
    const secret = secrets();
    pairs = secret.PPPOE_USER ? [[secret.PPPOE_USER, 'YOUR_USERNAME']] : [];
    hidden = ['PPPOE_USER', 'PPPOE_PASS', 'API_KEY', 'API_SECRET', 'CONSOLE_PASS'].filter((name) => secret[name]).map((name) => [name, secret[name]]);

    const browser = gui(opt, view);
    process.on('SIGINT', () => browser.close().then(() => process.exit(130)));
    process.on('SIGTERM', () => browser.close().then(() => process.exit(143)));
    say(`== T25 ${stamp}: ${opt.parts.join(', ')}; results in ${out}`);
    let stopped = '';
    try {
        ({ page } = await browser.open(secret));
        for (part of opt.parts) {
            say(`== ${part}, ${new Date().toISOString().slice(11, 19)} UTC`);
            await { install, settings, assign, drift, remove }[part](opt);
        }
    } catch (error) {
        if (!(error instanceof Failure)) {
            throw error;
        }
        stopped = error.message;
        say(`STOP    ${part || 'start'}: ${stopped}`);
        if (page) {
            await shot('stopped').catch(() => {});
        }
    } finally {
        await browser.close();
        if (opt.parts.includes('settings')) {
            await world('ispctl echodf off');                   // also when the part stopped half way
        }
    }
    const failed = checks.filter((entry) => !entry.ok).map((entry) => 'T25.' + entry.id);
    const seconds = Math.round((Date.now() - started) / 1000);
    if (failed.length || stopped) {
        say(`RESULT  T25 fail (${seconds} s) ${failed.length} of ${checks.length} checks failed${failed.length ? ': ' + failed.join(' ') : ''}${stopped ? '; stopped in "' + part + '"' : ''}`);
        return 1;
    }
    say(`RESULT  T25 pass (${seconds} s) ${checks.length} checks passed`);
    return 0;
}

main().then((code) => {
    process.exitCode = code;
}, (error) => {
    console.error('t25: ' + (error instanceof Failure ? error.message : error.stack || error));
    process.exitCode = error instanceof Failure ? 2 : 1;
});
