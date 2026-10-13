#!/usr/bin/env node
/*
 * capture.mjs - screenshots of the OPNsense GUI of clat-opn, one per step of the customer page. Lab use only.
 *
 *   bash lab.sh screens [options] [step id ...]        (Git Bash; it runs: node screens/capture.mjs ...)
 *     --list               the steps with their set, file and title; nothing is started
 *     --set NAME           the steps taken when no id is given: now (default), vlan (those that show PPPoE on
 *                          VLAN 40), fresh (those that need a box without the plugin), or all
 *     --out DIR            where the PNG files and screens.json go (default .work/results/screens)
 *     --steps FILE         another list of steps (default steps.mjs beside this file, which also explains a step)
 *     --base URL           a GUI that is reachable already, for example https://127.0.0.1:8443 of "lab.sh gui";
 *                          no tunnel is started then
 *     --profile DIR        the throwaway Edge profile; it must not exist and is removed at the end
 *                          (default: a new folder under the system's temporary folder)
 *     --debug DIR          also write <id>.page.png there: the page as it was when the step was taken or failed
 *
 * What a run does: the lab's tunnel to the GUI on a free local port (the ssh command of "lab.sh gui"), Microsoft
 * Edge headless with a profile of its own, driven through the Chrome DevTools Protocol; the login; then per step:
 * open the page, wait until it is quiet (page loaded, no request under way, jQuery idle), do the step's actions,
 * check that what must be visible is visible, and save the part of the page the step names. At the end, also after
 * an error or Ctrl-C: Edge closed, tunnel closed, profile removed. Nothing is installed: Node (fetch and WebSocket
 * are built in) and the Edge that Windows has. A capture saves no form and applies nothing: actions change only what
 * the open page shows.
 *
 * The login is the lab's GUI account (lab README section 1): GUI_USER (default root) and GUI_PASS from the
 * environment or from .work/disks/build/secrets.env. Neither is printed. Edge is found at EDGE or at its usual
 * place, ssh on the PATH (Git's, which reads the MSYS paths of the lab's ssh_config).
 *
 * Exit status: 0 every requested step saved, 1 a step failed, 2 usage, or nothing could be started.
 *
 * t25.mjs beside this file (the buttons of the GUI, pressed) imports the browser, the page and the login from here.
 */
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const LAB = path.dirname(HERE);
export const BUILD = path.join(LAB, '.work', 'disks', 'build');
const OPN = '10.99.0.2';                // clat-opn on the management switch (lab.sh: OPN)
const EDGE_PLACES = [
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
];
const QUIET_MS = 500;                   // no request for this long, and none under way: the page is quiet
const PAGE_TIMEOUT = 45000;
const WAIT_TIMEOUT = 20000;

export const say = (line) => console.log(line);
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export class Failure extends Error {}

function usage(message) {
    if (message) {
        console.error('capture: ' + message);
    }
    const text = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
    console.error(text.slice(text.indexOf(' * capture.mjs'), text.indexOf(' */')).replace(/^ \* ?/gm, ''));
    process.exit(2);
}

function options(argv) {
    const opt = { set: 'now', out: path.join(LAB, '.work', 'results', 'screens'), steps: path.join(HERE, 'steps.mjs'), ids: [] };
    const args = argv.slice();
    while (args.length) {
        const arg = args.shift();
        if (arg === '--list') {
            opt.list = true;
        } else if (['--set', '--out', '--steps', '--base', '--profile', '--debug'].includes(arg)) {
            if (!args.length) {
                usage(arg + ' needs a value');
            }
            opt[arg.slice(2)] = args.shift();
        } else if (arg.startsWith('-')) {
            usage(arg === '-h' || arg === '--help' ? '' : 'unknown option ' + arg);
        } else {
            opt.ids.push(arg);
        }
    }
    return opt;
}

/* KEY=value lines of the lab's secrets file; quotes are tolerated. Values are never printed. */
export function secrets() {
    const found = {};
    let text = '';
    try {
        text = fs.readFileSync(path.join(BUILD, 'secrets.env'), 'utf8');
    } catch {
        return found;
    }
    for (const line of text.split(/\r?\n/)) {
        const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
        if (match) {
            found[match[1]] = match[2].replace(/^(["'])(.*)\1$/, '$2');
        }
    }
    return found;
}

function freePort() {
    return new Promise((resolve, reject) => {
        const server = net.createServer();
        server.on('error', reject);
        server.listen(0, '127.0.0.1', () => {
            const { port } = server.address();
            server.close(() => resolve(port));
        });
    });
}

function portOpen(port) {
    return new Promise((resolve) => {
        const socket = net.connect({ host: '127.0.0.1', port });
        socket.setTimeout(1000);
        socket.on('connect', () => { socket.destroy(); resolve(true); });
        socket.on('timeout', () => { socket.destroy(); resolve(false); });
        socket.on('error', () => resolve(false));
    });
}

function exited(child) {
    return child.exitCode !== null || child.signalCode !== null;
}

function waitExit(child, ms) {
    if (exited(child)) {
        return Promise.resolve(true);
    }
    return new Promise((resolve) => {
        const timer = setTimeout(() => resolve(false), ms);
        child.once('exit', () => { clearTimeout(timer); resolve(true); });
    });
}

/* ---- the tunnel: what "lab.sh gui" runs, on a free port ---------------------------------------------------- */

async function startTunnel() {
    const config = path.join(BUILD, 'ssh_config');
    if (!fs.existsSync(config)) {
        throw new Failure('no ' + config + ': start clat-world, then run: bash lab.sh addr --wait');
    }
    const port = await freePort();
    let complaint = '';
    const child = spawn('ssh', ['-F', config.replace(/\\/g, '/'), '-N', '-o', 'ExitOnForwardFailure=yes',
        '-L', `127.0.0.1:${port}:${OPN}:443`, 'clat-world'], { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
    child.on('error', (error) => { complaint = String(error.message); });
    child.stderr.on('data', (chunk) => { complaint = (complaint + chunk).slice(-400); });
    const until = Date.now() + 30000;
    while (!(await portOpen(port))) {
        if (exited(child) || complaint.includes('ENOENT')) {
            throw new Failure('the ssh tunnel to clat-world did not start: ' + (complaint.trim() || 'ssh ended'));
        }
        if (Date.now() > until) {
            child.kill();
            throw new Failure('the ssh tunnel to clat-world did not open port ' + port + ' within 30 s');
        }
        await sleep(300);
    }
    return { child, base: 'https://127.0.0.1:' + port };
}

/* ---- Edge and the DevTools connection ------------------------------------------------------------------------ */

async function startEdge(profile, view) {
    const binary = process.env.EDGE || EDGE_PLACES.find((place) => fs.existsSync(place));
    if (!binary || !fs.existsSync(binary)) {
        throw new Failure('Microsoft Edge was not found; set EDGE to the path of msedge.exe');
    }
    const port = await freePort();
    const child = spawn(binary, ['--headless=new', '--remote-debugging-port=' + port, '--user-data-dir=' + profile,
        '--ignore-certificate-errors', `--window-size=${view.width},${view.height}`, '--force-device-scale-factor=1',
        '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
        '--disable-background-networking', '--disable-component-update', '--hide-scrollbars', '--lang=en-US',
        'about:blank'], { stdio: 'ignore', windowsHide: true });
    let complaint = '';
    child.on('error', (error) => { complaint = String(error.message); });
    const until = Date.now() + 30000;
    for (;;) {
        try {
            const reply = await fetch(`http://127.0.0.1:${port}/json/version`);
            const version = await reply.json();
            return { child, socket: version.webSocketDebuggerUrl, product: version.Browser };
        } catch {
            if (exited(child) || complaint) {
                throw new Failure('Edge did not start: ' + (complaint || 'it ended with status ' + child.exitCode));
            }
            if (Date.now() > until) {
                throw new Failure('Edge did not open its DevTools port within 30 s');
            }
            await sleep(250);
        }
    }
}

/* One DevTools connection; after attach() every call goes to the one page. */
class DevTools {
    constructor(socket) {
        this.socket = socket;
        this.serial = 0;
        this.calls = new Map();
        this.listeners = new Set();
        this.session = undefined;
        socket.addEventListener('message', (event) => {
            const message = JSON.parse(event.data);
            if (message.id !== undefined) {
                const call = this.calls.get(message.id);
                this.calls.delete(message.id);
                if (!call) {
                    return;
                }
                if (message.error) {
                    call.reject(new Failure(call.method + ': ' + message.error.message));
                } else {
                    call.resolve(message.result);
                }
            } else {
                for (const listener of this.listeners) {
                    listener(message);
                }
            }
        });
        socket.addEventListener('close', () => {
            for (const call of this.calls.values()) {
                call.reject(new Failure(call.method + ': the browser closed the connection'));
            }
            this.calls.clear();
        });
    }

    static open(address) {
        return new Promise((resolve, reject) => {
            const socket = new WebSocket(address);
            socket.addEventListener('open', () => resolve(new DevTools(socket)));
            socket.addEventListener('error', () => reject(new Failure('no DevTools connection to Edge')));
        });
    }

    send(method, params = {}, session = this.session) {
        return new Promise((resolve, reject) => {
            const id = ++this.serial;
            this.calls.set(id, { method, resolve, reject });
            this.socket.send(JSON.stringify(session ? { id, method, params, sessionId: session } : { id, method, params }));
        });
    }

    /* resolves with the first event of that name, from now on */
    event(name, ms) {
        return new Promise((resolve, reject) => {
            const listener = (message) => {
                if (message.method === name) {
                    clearTimeout(timer);
                    this.listeners.delete(listener);
                    resolve(message.params);
                }
            };
            const timer = setTimeout(() => {
                this.listeners.delete(listener);
                reject(new Failure('no ' + name + ' within ' + ms / 1000 + ' s'));
            }, ms);
            this.listeners.add(listener);
        });
    }
}

/* ---- what runs inside the page -------------------------------------------------------------------------------- */

/*
 * Installed in every document before its own scripts. A selector is CSS, or "CSS >> text" for the elements whose
 * text contains the text, or "CSS >> text >> CSS" for what the last part matches inside those. "Visible" means
 * the element has a box.
 */
function pageHelpers() {
    const shown = (element) => element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden';
    const tidy = (text) => text.replace(/\s+/g, ' ').trim();
    const every = (selector) => {
        const [css, text, inner] = selector.split(' >> ');
        let found = Array.from(document.querySelectorAll(css));
        if (text !== undefined) {
            found = found.filter((element) => tidy(element.innerText || element.textContent || '').includes(text));
        }
        return inner === undefined ? found : found.flatMap((element) => Array.from(element.querySelectorAll(inner)));
    };
    const all = (selector) => every(selector).filter(shown);
    const picker = (element) => (element.tagName === 'SELECT' && element.parentElement &&
        element.parentElement.classList.contains('bootstrap-select') ? element.parentElement : element);
    const overlap = (a, b) => a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top && a.width > 0 && a.height > 0;
    /* false when something else lies over the middle of the rectangle, as an open dialog does over the page */
    const onTop = (element, rect) => {
        const top = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
        return !top || element.contains(top) || top.contains(element);
    };

    window.__screens = {
        ready() {
            return document.readyState === 'complete' && (!window.jQuery || window.jQuery.active === 0);
        },
        count(selector) {
            return all(selector).length;
        },
        click(selector) {
            const element = all(selector)[0];
            if (!element) {
                return false;
            }
            element.scrollIntoView({ block: 'center' });
            element.click();
            return true;
        },
        /* where the mouse has to go for the first visible match (t25.mjs): its middle, its text, and what covers it */
        spot(selector) {
            const element = all(selector)[0];
            if (!element) {
                return null;
            }
            element.scrollIntoView({ block: 'center' });
            const rect = element.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            const top = document.elementFromPoint(x, y);
            const covered = top && element.contains(top) ? '' : (top ? '<' + top.tagName.toLowerCase() + ' class="' + top.className + '">' : 'nothing: it is outside the window');
            return { x, y, covered, text: tidy(element.innerText || element.getAttribute('aria-label') || element.getAttribute('data-original-title') || element.title || '').slice(0, 80) };
        },
        /* the text of the first visible match, or what a field holds (t25.mjs) */
        read(selector) {
            const element = all(selector)[0];
            if (!element) {
                return null;
            }
            return (['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName) ? element.value : element.innerText).replace(/[ \t]+/g, ' ').trim();
        },
        hide(selector) {
            const elements = every(selector);
            elements.forEach((element) => element.style.setProperty('display', 'none', 'important'));
            return elements.length;
        },
        /* what a person would enter in the open page; nothing is sent */
        set(selector, value) {
            const element = every(selector)[0];
            if (!element) {
                return 'no element';
            }
            if (element.type === 'checkbox' || element.type === 'radio') {
                element.checked = Boolean(value);
            } else if (element.tagName === 'SELECT') {
                const wanted = Array.isArray(value) ? value.map(String) : [String(value)];
                const taken = new Set();
                for (const option of element.options) {
                    const hit = wanted.find((want) => want === option.value || want === tidy(option.textContent));
                    option.selected = hit !== undefined;
                    if (hit !== undefined) {
                        taken.add(hit);
                    }
                }
                const missing = wanted.filter((want) => !taken.has(want));
                if (missing.length) {
                    return 'no choice ' + JSON.stringify(missing) + ' among ' +
                        JSON.stringify(Array.from(element.options, (option) => tidy(option.textContent)));
                }
            } else {
                element.value = String(value);
            }
            if (window.jQuery) {
                const wrapped = window.jQuery(element);
                if (wrapped.data('selectpicker')) {
                    wrapped.selectpicker('refresh');
                }
                wrapped.trigger('input').trigger('change').trigger('keyup');
            } else {
                for (const name of ['input', 'change', 'keyup']) {
                    element.dispatchEvent(new Event(name, { bubbles: true }));
                }
            }
            return '';
        },
        /* text shown in place of other text: [[from, to], ...], in text and in fields */
        neutral(pairs) {
            let count = 0;
            const swap = (text) => {
                let out = text;
                for (const [from, to] of pairs) {
                    out = out.split(from).join(to);
                }
                return out;
            };
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                const out = swap(node.nodeValue);
                if (out !== node.nodeValue) {
                    node.nodeValue = out;
                    count += 1;
                }
            }
            for (const field of document.querySelectorAll('input:not([type=password]):not([type=hidden]), textarea')) {
                const out = swap(field.value);
                if (out !== field.value) {
                    field.value = out;
                    count += 1;
                }
            }
            return count;
        },
        /* the rectangle around every visible element the selectors match, in page coordinates */
        box(selectors, pad) {
            let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
            for (const selector of selectors) {
                const elements = all(selector);
                if (!elements.length) {
                    return { missing: selector };
                }
                for (const element of elements) {
                    const rect = element.getBoundingClientRect();
                    left = Math.min(left, rect.left + window.scrollX);
                    top = Math.min(top, rect.top + window.scrollY);
                    right = Math.max(right, rect.right + window.scrollX);
                    bottom = Math.max(bottom, rect.bottom + window.scrollY);
                }
            }
            const page = document.documentElement;
            left = Math.max(0, Math.floor(left - pad));
            top = Math.max(0, Math.floor(top - pad));
            right = Math.min(Math.max(page.scrollWidth, window.innerWidth), Math.ceil(right + pad));
            bottom = Math.ceil(bottom + pad);
            /* a dialog is as tall as the window allows and scrolls inside: how much of it does not fit */
            const more = Math.max(0, ...all('.modal.in .modal-body').map((body) => body.scrollHeight - body.clientHeight));
            return { x: left, y: top, width: right - left, height: bottom - top, view: window.innerHeight, more };
        },
        /*
         * What a reader of the picture can read inside the rectangle: text, field values, ticks. With "under", also
         * what something else lies over or a narrow column cuts short, for the search for values that must not show.
         */
        seen(clip, under) {
            const area = { left: clip.x - window.scrollX, top: clip.y - window.scrollY };
            area.right = area.left + clip.width;
            area.bottom = area.top + clip.height;
            area.width = clip.width;
            area.height = clip.height;
            const parts = [];
            const range = document.createRange();
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                const owner = node.parentElement;
                if (!node.nodeValue.trim() || !owner || ['SCRIPT', 'STYLE', 'OPTION', 'TEXTAREA'].includes(owner.tagName) || !shown(owner)) {
                    continue;
                }
                range.selectNodeContents(node);
                if (overlap(range.getBoundingClientRect(), area) && (under || onTop(owner, range.getClientRects()[0]))) {
                    parts.push(tidy(node.nodeValue));
                }
            }
            for (const field of document.querySelectorAll('input, textarea, select')) {
                const face = picker(field);
                const rect = face.getBoundingClientRect();
                if (field.type === 'hidden' || !shown(face) || !overlap(rect, area) || !(under || onTop(face, rect))) {
                    continue;
                }
                if (field.type === 'password') {
                    parts.push(field.value ? '(password: masked)' : '(password: empty)');
                } else if (field.type === 'checkbox' || field.type === 'radio') {
                    parts.push(field.checked ? '(ticked)' : '(cleared)');
                } else if (field.tagName === 'SELECT') {
                    if (face === field) {       // a bootstrap-select shows its choice as text already
                        parts.push(Array.from(field.selectedOptions, (option) => tidy(option.textContent)).join(', '));
                    }
                } else {
                    parts.push(field.value);
                }
            }
            return parts.join(' | ');
        },
        /* one field for a check: its value, the texts of its choices, or its tick; and whether it is in the rectangle */
        field(selector, clip) {
            const element = every(selector)[0];
            if (!element) {
                return { missing: true };
            }
            const face = picker(element);
            const rect = face.getBoundingClientRect();
            const inside = shown(face) && onTop(face, rect) && rect.left + window.scrollX >= clip.x - 1 && rect.top + window.scrollY >= clip.y - 1 &&
                rect.right + window.scrollX <= clip.x + clip.width + 1 && rect.bottom + window.scrollY <= clip.y + clip.height + 1;
            if (element.type === 'checkbox' || element.type === 'radio') {
                return { inside, value: element.checked };
            }
            if (element.tagName === 'SELECT') {
                return { inside, value: Array.from(element.selectedOptions, (option) => tidy(option.textContent)).join(', ') };
            }
            return { inside, value: 'value' in element ? element.value : tidy(element.textContent) };
        },
    };
}

/* ---- one page, driven ------------------------------------------------------------------------------------------- */

class Page {
    constructor(tools, view) {
        this.tools = tools;
        this.view = view;
        this.pending = new Map();        // request id -> address, while under way
        this.last = Date.now();
        tools.listeners.add((message) => {
            if (message.method === 'Network.requestWillBeSent') {
                if (message.params.type === 'EventSource') {
                    return;             // the streams of the dashboard never end
                }
                this.pending.set(message.params.requestId, message.params.request.url.split('?')[0]);
                this.last = Date.now();
            } else if (message.method === 'Network.loadingFinished' || message.method === 'Network.loadingFailed') {
                this.pending.delete(message.params.requestId);
                this.last = Date.now();
            } else if (message.method === 'Page.javascriptDialogOpening') {
                tools.send('Page.handleJavaScriptDialog', { accept: false }).catch(() => {});     // never confirm anything
            }
        });
    }

    async setup() {
        const tools = this.tools;
        await tools.send('Page.enable');
        await tools.send('Network.enable');
        await tools.send('Runtime.enable');
        await tools.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
        await tools.send('Page.addScriptToEvaluateOnNewDocument', { source: '(' + pageHelpers.toString() + ')();' });
        await this.resize(this.view.height, this.view.width);
    }

    async resize(height, width = this.width) {
        this.width = width;
        this.height = height;
        await this.tools.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    }

    /* an expression in the page; a promise is awaited; the value comes back as JSON */
    async run(expression) {
        const reply = await this.tools.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
        if (reply.exceptionDetails) {
            const detail = reply.exceptionDetails.exception && reply.exceptionDetails.exception.description;
            throw new Failure('in the page: ' + String(detail || reply.exceptionDetails.text).split('\n')[0]);
        }
        return reply.result.value;
    }

    call(name, ...args) {
        return this.run(`window.__screens.${name}(${args.map((arg) => JSON.stringify(arg)).join(', ')})`);
    }

    /* loaded, no request under way and none for QUIET_MS, jQuery idle, and two frames drawn after that */
    async quiet(ms = PAGE_TIMEOUT) {
        const until = Date.now() + ms;
        for (;;) {
            const calm = this.pending.size === 0 && Date.now() - this.last >= QUIET_MS;
            if (calm && await this.run('Boolean(window.__screens) && window.__screens.ready()').catch(() => false)) {
                await this.run('new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(true))))');
                return;
            }
            if (Date.now() > until) {
                throw new Failure('the page did not become quiet within ' + ms / 1000 + ' s; under way: ' + (Array.from(this.pending.values()).join(' ') || 'nothing, but the page is not ready'));
            }
            await sleep(100);
        }
    }

    async load(address) {
        this.pending.clear();
        const loaded = this.tools.event('Page.loadEventFired', PAGE_TIMEOUT);
        loaded.catch(() => {});
        const reply = await this.tools.send('Page.navigate', { url: address });
        if (reply.errorText) {
            throw new Failure('the page did not load: ' + reply.errorText);
        }
        await loaded;
    }

    /*
     * Always from an empty page, because an address that differs from the last one only after its # would load
     * nothing; and with nothing the GUI remembers in the browser (open groups, grid layouts, filters), so that a
     * step finds the page as a first visit does, whatever ran before it.
     */
    async open(address) {
        await this.load('about:blank');
        await this.tools.send('Storage.clearDataForOrigin', { origin: new URL(address).origin, storageTypes: 'local_storage,session_storage' });
        await this.load(address);
        await this.quiet();
    }

    async waitFor(what, test, ms = WAIT_TIMEOUT) {
        const until = Date.now() + ms;
        while (!(await test())) {
            if (Date.now() > until) {
                throw new Failure('waited ' + ms / 1000 + ' s for ' + what);
            }
            await sleep(150);
        }
    }

    async png(clip) {
        const reply = await this.tools.send('Page.captureScreenshot', clip ?
            { format: 'png', clip: { ...clip, scale: 1 }, captureBeyondViewport: false } : { format: 'png' });
        return Buffer.from(reply.data, 'base64');
    }
}

async function login(page, base, user, password) {
    await page.open(base + '/');
    if (!(await page.call('count', 'input[name=usernamefld]'))) {
        throw new Failure('no login form at ' + base);
    }
    for (const [field, text] of [['usernamefld', user], ['passwordfld', password]]) {
        await page.run(`document.querySelector('input[name=${field}]').focus()`);
        await page.tools.send('Input.insertText', { text });      // typed, so that it is in no expression and no message
    }
    const loaded = page.tools.event('Page.loadEventFired', PAGE_TIMEOUT);
    loaded.catch(() => {});
    await page.run(`document.querySelector('input[name=usernamefld]').form.querySelector('[type=submit]').click()`);
    await loaded;
    await page.quiet();
    if (await page.call('count', 'input[name=usernamefld]')) {
        throw new Failure('the GUI refused the login as ' + user);
    }
}

/*
 * The tunnel, Edge with its throwaway profile and one page signed in to the GUI. open(secret) starts them and
 * returns { page, base }; close() ends whatever was started and removes the profile, and may be called at any time.
 * opt: base and profile as on the command line.
 */
export function gui(opt, view) {
    const profile = path.resolve(opt.profile || path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'os-clat-screens-')), 'edge-profile'));
    if (fs.existsSync(profile)) {
        throw new Failure('the profile folder exists already: ' + profile);
    }
    let tunnel, edge, tools;
    let closing;
    const close = () => {
        closing = closing || (async () => {
            if (edge) {
                if (tools) {
                    await tools.send('Browser.close', {}, null).catch(() => {});
                }
                if (!(await waitExit(edge.child, 8000))) {
                    spawnSync('taskkill', ['/PID', String(edge.child.pid), '/T', '/F'], { stdio: 'ignore' });
                    await waitExit(edge.child, 5000);
                }
            }
            if (tunnel) {
                tunnel.child.kill();
                await waitExit(tunnel.child, 5000);
            }
            for (let attempt = 0; attempt < 20 && fs.existsSync(profile); attempt += 1) {
                try {
                    fs.rmSync(profile, { recursive: true, force: true });
                } catch {
                    await sleep(500);       // Edge's helpers let go of their files a moment after the browser has gone
                }
            }
            if (!opt.profile) {
                fs.rmSync(path.dirname(profile), { recursive: true, force: true });
            }
            if (fs.existsSync(profile)) {
                console.error('capture: could not remove ' + profile);
            }
        })();
        return closing;
    };
    const open = async (secret) => {
        const user = process.env.GUI_USER || secret.GUI_USER || 'root';
        const password = process.env.GUI_PASS || secret.GUI_PASS;
        if (!password) {
            throw new Failure('no GUI_PASS in the environment or in ' + path.join(BUILD, 'secrets.env') + ' (the GUI login of the lab: README section 1)');
        }
        let base = opt.base && opt.base.replace(/\/+$/, '');
        if (!base) {
            tunnel = await startTunnel();
            base = tunnel.base;
        }
        edge = await startEdge(profile, view);
        tools = await DevTools.open(edge.socket);
        say(`== ${edge.product}, window ${view.width}x${view.height}, GUI at ${base}${tunnel ? ' (tunnel to ' + OPN + ')' : ''}`);
        const { targetId } = await tools.send('Target.createTarget', { url: 'about:blank' });
        tools.session = (await tools.send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
        const page = new Page(tools, view);
        await page.setup();
        await login(page, base, user, password);
        say('== signed in as ' + user);
        return { page, base };
    };
    return { open, close };
}

async function act(page, action) {
    const [[verb, value]] = Object.entries(action);
    switch (verb) {
    case 'click':
        if (!(await page.call('click', value))) {
            throw new Failure('nothing visible to click: ' + value);
        }
        await sleep(150);
        await page.quiet();
        break;
    case 'wait':
        await page.waitFor(value, () => page.call('count', value));
        break;
    case 'gone':
        await page.waitFor('the end of ' + value, async () => !(await page.call('count', value)));
        break;
    case 'until':
        await page.waitFor(value, () => page.run(`Boolean(${value})`));
        break;
    case 'set': {
        const complaint = await page.call('set', value, action.to);
        if (complaint) {
            throw new Failure('cannot set ' + value + ': ' + complaint);
        }
        await sleep(150);
        await page.quiet();
        break;
    }
    case 'hide':
        await page.call('hide', value);
        break;
    case 'js': {
        const result = await page.run(value);
        if (result !== undefined && result !== null) {
            say('     js: ' + (typeof result === 'string' ? result : JSON.stringify(result)));
        }
        await page.quiet();
        break;
    }
    case 'pause':
        await sleep(value);
        break;
    default:
        throw new Failure('unknown action ' + JSON.stringify(action));
    }
}

/* One step; returns what goes into screens.json. */
async function take(page, step, context) {
    const { base, out, debug, pairs, hidden } = context;
    const view = { ...context.view, ...(step.view || {}) };
    let passed = false;
    try {
        await page.resize(view.height, view.width);
        await page.open(base + step.url);
        if (await page.call('count', 'input[name=usernamefld]')) {
            throw new Failure('the GUI asks for the login again');
        }
        for (const action of step.actions || []) {
            await act(page, action);
        }
        await page.quiet();
        await page.call('neutral', pairs);
        await page.run('window.scrollTo(0, 0)');
        /* a window tall enough for the part wanted, so that nothing has to be scrolled */
        let clip;
        for (let round = 0; round < 4; round += 1) {
            clip = await page.call('box', step.clip, step.pad || 0);
            if (clip.missing) {
                throw new Failure('nothing visible matches the clip selector ' + clip.missing);
            }
            const need = clip.y + clip.height + 80;     // the footer of the GUI stays at the bottom of the window
            if (need > 12000) {
                throw new Failure('the part to capture would be ' + clip.height + ' pixels tall');
            }
            if (need <= clip.view && !clip.more) {
                break;
            }
            await page.resize(Math.max(need, clip.view + clip.more + 20));
            await sleep(250);
            await page.quiet();
            await page.run('window.scrollTo(0, 0)');
        }
        const seen = await page.call('seen', clip);
        const problems = [];
        for (const expected of step.expect || []) {
            if (typeof expected === 'string') {
                if (!seen.includes(expected)) {
                    problems.push('not visible: "' + expected + '"');
                }
            } else if ('absent' in expected) {
                if (seen.includes(expected.absent)) {
                    problems.push('visible but must not be: "' + expected.absent + '"');
                }
            } else {
                const field = await page.call('field', expected.field, clip);
                if (field.missing) {
                    problems.push('no field ' + expected.field);
                } else if (!field.inside) {
                    problems.push('the field ' + expected.field + ' is not in the picture');
                } else if (field.value !== expected.is) {
                    problems.push('the field ' + expected.field + ' shows ' + JSON.stringify(field.value) + ', expected ' + JSON.stringify(expected.is));
                }
            }
        }
        const under = hidden.length ? await page.call('seen', clip, true) : '';
        for (const [name, value] of hidden) {
            if (under.includes(value)) {
                problems.push('the value of ' + name + ' is readable in the picture');
            }
        }
        if (problems.length) {
            throw new Failure(problems.join('; '));
        }
        const image = await page.png({ x: clip.x, y: clip.y, width: clip.width, height: clip.height });
        fs.writeFileSync(path.join(out, step.file), image);
        passed = true;
        return { id: step.id, file: step.file, title: step.title, page: step.url, ok: true, width: clip.width, height: clip.height, shows: seen };
    } finally {
        if (debug) {
            await page.png().then((image) => fs.writeFileSync(path.join(debug, step.id + '.page.png'), image)).catch(() => {});
        }
        if (passed) {
            for (const action of step.after || []) {    // close what the step opened; the next page load would drop it anyway
                await act(page, action).catch(() => {});
            }
        }
    }
}

/* ---- main ----------------------------------------------------------------------------------------------------------- */

async function main() {
    const opt = options(process.argv.slice(2));
    const list = await import(pathToFileURL(path.resolve(opt.steps)).href);
    const wanted = opt.ids.length ? opt.ids.map((id) => list.steps.find((step) => step.id === id) || usage('no step ' + id)) :
        list.steps.filter((step) => opt.set === 'all' || (step.set || 'now') === opt.set);
    if (opt.list) {
        for (const step of list.steps) {
            say(`${(step.set || 'now').padEnd(5)} ${step.id.padEnd(24)} ${step.file.padEnd(40)} ${step.title}`);
        }
        return 0;
    }
    if (!wanted.length) {
        usage('no step in the set ' + opt.set);
    }
    const secret = secrets();
    /* shown in place of lab values, and what must never be readable in a picture */
    const pairs = (list.neutral || []).map((entry) => [entry.secret ? secret[entry.secret] : entry.text, entry.show]).filter((pair) => pair[0]);
    const hidden = ['PPPOE_PASS', 'API_KEY', 'API_SECRET', 'CONSOLE_PASS'].filter((name) => secret[name]).map((name) => [name, secret[name]]);
    const view = list.view || { width: 1280, height: 900 };
    const browser = gui(opt, view);
    const close = browser.close;
    fs.mkdirSync(opt.out, { recursive: true });
    if (opt.debug) {
        fs.mkdirSync(opt.debug, { recursive: true });
    }
    process.on('SIGINT', () => close().then(() => process.exit(130)));
    process.on('SIGTERM', () => close().then(() => process.exit(143)));

    const results = [];
    try {
        const { page, base } = await browser.open(secret);
        for (const step of wanted) {
            try {
                const result = await take(page, step, { base, out: opt.out, debug: opt.debug, pairs, hidden, view });
                results.push(result);
                say(`OK   ${step.id}  ${step.file}  ${result.width}x${result.height}`);
            } catch (error) {
                if (!(error instanceof Failure)) {
                    throw error;
                }
                results.push({ id: step.id, file: step.file, title: step.title, page: step.url, ok: false, problem: error.message });
                say(`FAIL ${step.id}  ${error.message}`);
            }
        }
    } finally {
        await close();
    }
    /* what was taken, for whoever places the pictures: merged with the entries of earlier runs into the same folder */
    const index = path.join(opt.out, 'screens.json');
    let known = [];
    try {
        known = JSON.parse(fs.readFileSync(index, 'utf8'));
    } catch {
        known = [];
    }
    const taken = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    for (const result of results.filter((entry) => entry.ok)) {
        known = known.filter((entry) => entry.id !== result.id);
        known.push({ ...result, ok: undefined, taken });
    }
    known.sort((a, b) => a.file.localeCompare(b.file));
    fs.writeFileSync(index, JSON.stringify(known, null, 2) + '\n');
    const failed = results.filter((entry) => !entry.ok).length;
    say(`== ${results.length - failed} of ${wanted.length} step(s) saved to ${opt.out}${failed ? ', ' + failed + ' failed' : ''}`);
    return failed || results.length < wanted.length ? 1 : 0;
}

/* only when this file is the script that was started, not when t25.mjs imports it */
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href.toLowerCase() === import.meta.url.toLowerCase()) {
    main().then((status) => {
        process.exitCode = status;
    }, (error) => {
        console.error('capture: ' + (error instanceof Failure ? error.message : error.stack || error));
        process.exitCode = error instanceof Failure ? 2 : 1;
    });
}
