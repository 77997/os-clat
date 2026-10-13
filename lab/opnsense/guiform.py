#!/usr/bin/env python3
""" guiform.py - read and send the forms of OPNsense's web GUI the way a browser does. Lab use only.

    Runs on clat-world (Python 3, standard library):   bash lab.sh gui-form <verb> ...
      fields PAGE                      every field of the page's form: name, kind, value, label
      post PAGE [--submit NAME] [NAME=VALUE ...] [NAME=]
                                       load the page, change the named fields, send its form with the button
                                       NAME (default "save" or "Submit"); NAME= clears a field or a checkbox;
                                       NAME=@KEY takes the value of KEY from /root/lab.env (it is not printed)
      text PAGE [REGEX]                the visible text of the page, or only the lines that match
    PAGE is the path as the menu has it, for example "/interfaces.php?if=wan" or "/ui/unbound/forward".

    Legacy pages (*.php) accept no API key, only a session: the login is user root with the factory
    password, which is this lab's GUI login (lab README section 1). MVC pages (/ui/...) are read here for
    their labels only; their settings go through the API (bash lab.sh api).
    Exit status: 0 done, 1 the page reported an error (printed), 2 usage or no login.
"""
import html
import http.client
import http.cookiejar
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

BASE = os.environ.get('GUI_BASE', 'https://10.99.0.2')
USER = os.environ.get('GUI_USER', 'root')
PASSWORD = os.environ.get('GUI_PASS', 'opnsense')


class Field:
    def __init__(self, name, kind, value, label, checked=None, options=None, disabled=False):
        self.name, self.kind, self.value, self.label = name, kind, value, label
        self.checked, self.options, self.disabled = checked, options or [], disabled


class Forms(HTMLParser):
    """ Collects the forms of a page. The label of a field is the text of the first cell of its table row. """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []         # each: dict(attrs, fields, buttons)
        self.form = None
        self.cells = []         # text of the cells of the current row
        self.in_cell = False
        self.select = None
        self.option = None
        self.textarea = None
        self.skip = 0
        self.text = []

    def label(self):
        return re.sub(r'\s+', ' ', self.cells[0]).strip() if self.cells else ''

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ('script', 'style'):
            self.skip += 1
        elif tag == 'form':
            self.form = {'attrs': a, 'fields': [], 'buttons': []}
            self.forms.append(self.form)
        elif tag == 'tr':
            self.cells = []
        elif tag in ('td', 'th'):
            self.cells.append('')
            self.in_cell = True
        elif self.form is None:
            return
        elif tag == 'input':
            kind = (a.get('type') or 'text').lower()
            name = a.get('name')
            if not name:
                return
            if kind in ('submit', 'button', 'image'):
                self.form['buttons'].append((name, a.get('value', '')))
            elif kind in ('checkbox', 'radio'):
                self.form['fields'].append(Field(name, kind, a.get('value', 'on'), self.label(), checked='checked' in a,
                                                 disabled='disabled' in a))
            else:
                self.form['fields'].append(Field(name, kind, a.get('value', ''), self.label(), disabled='disabled' in a))
        elif tag == 'button':
            if a.get('name') and (a.get('type') or 'submit').lower() == 'submit':
                self.form['buttons'].append((a['name'], a.get('value', '')))
        elif tag == 'select' and a.get('name'):
            self.select = Field(a['name'], 'select-multiple' if 'multiple' in a else 'select', [], self.label(),
                                disabled='disabled' in a)
            self.form['fields'].append(self.select)
        elif tag == 'option' and self.select is not None:
            self.option = [a.get('value'), '', 'selected' in a]
            self.select.options.append(self.option)
        elif tag == 'textarea' and a.get('name'):
            self.textarea = Field(a['name'], 'textarea', '', self.label(), disabled='disabled' in a)
            self.form['fields'].append(self.textarea)

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.skip = max(0, self.skip - 1)
        elif tag == 'form':
            self.form = None
        elif tag in ('td', 'th'):
            self.in_cell = False
        elif tag == 'select' and self.select is not None:
            chosen = [o[0] if o[0] is not None else o[1].strip() for o in self.select.options if o[2]]
            if not chosen and self.select.kind == 'select' and self.select.options:
                first = self.select.options[0]
                chosen = [first[0] if first[0] is not None else first[1].strip()]
            self.select.value = chosen
            self.select = None
        elif tag == 'option':
            self.option = None
        elif tag == 'textarea':
            self.textarea = None

    def handle_data(self, data):
        if self.skip:
            return
        if self.option is not None:
            self.option[1] += data
        elif self.textarea is not None:
            self.textarea.value += data
        elif self.in_cell and self.cells:
            self.cells[-1] += data
        if data.strip():
            self.text.append(re.sub(r'\s+', ' ', data).strip())


class Gui:
    def __init__(self):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE     # the lab box has its self-signed certificate
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context),
                                                  urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.opener.addheaders = [('User-Agent', 'os-clat-lab-guiform')]

    def get(self, path):
        with self.opener.open(BASE + path, timeout=120) as reply:
            return reply.read().decode('utf-8', 'replace')

    def send(self, path, pairs):
        request = urllib.request.Request(BASE + path, data=urllib.parse.urlencode(pairs).encode(),
                                         headers={'Referer': BASE + path})
        with self.opener.open(request, timeout=300) as reply:
            return reply.read().decode('utf-8', 'replace')

    def login(self):
        page = parse(self.get('/'))
        form = next((f for f in page.forms if any(x.name == 'usernamefld' for x in f['fields'])), None)
        if form is None:
            sys.exit('guiform: no login form at %s' % BASE)
        pairs = [(x.name, x.value) for x in form['fields'] if x.kind == 'hidden']
        pairs += [('usernamefld', USER), ('passwordfld', PASSWORD), ('login', '1')]
        after = parse(self.send('/', pairs))
        if any(x.name == 'usernamefld' for f in after.forms for x in f['fields']):
            print('guiform: the login as %s was refused' % USER, file=sys.stderr)
            sys.exit(2)


def parse(text):
    forms = Forms()
    forms.feed(text)
    return forms


def main_form(page, button=None):
    """ The form that has the button, or else the one with the most fields. """
    candidates = [f for f in page.forms if button is None or any(b[0] == button for b in f['buttons'])]
    if not candidates:
        return None
    return max(candidates, key=lambda f: len(f['fields']))


def lab_env(key):
    """ The value of KEY in /root/lab.env; quotes are tolerated. """
    with open('/root/lab.env') as handle:
        for line in handle:
            match = re.match(r'(?:export\s+)?%s=(.*)' % re.escape(key), line.strip())
            if match:
                return match.group(1).strip('"\'')
    sys.exit('guiform: /root/lab.env has no %s' % key)


def messages(text):
    """ What a legacy page prints after a POST: input errors and notices. """
    found = []
    for block in re.findall(r'<div class="alert alert-(?:danger|warning|info)[^"]*"[^>]*>(.*?)</div>', text, re.S):
        plain = re.sub(r'\s+', ' ', html.unescape(re.sub(r'<[^>]+>', ' ', block))).strip()
        if plain:
            found.append(plain)
    return found


def show_fields(form):
    for x in form['fields']:
        if x.kind == 'hidden' and len(x.name) > 20 and x.label == '':
            continue            # the CSRF token of the session
        if x.kind in ('checkbox', 'radio'):
            value = '%s [%s]' % (x.value, 'checked' if x.checked else 'clear')
        elif x.kind.startswith('select'):
            texts = [o[1].strip() for o in x.options if o[2]] or ['(first) ' + x.options[0][1].strip() if x.options else '']
            value = '%s = %s' % (','.join(str(v) for v in x.value), ' | '.join(texts))
        else:
            value = 'set (not shown)' if x.kind == 'password' and x.value else x.value
        print('%-28s %-9s %-34s %s%s' % (x.name, x.kind, value, x.label, '  (disabled)' if x.disabled else ''))
    print('buttons: %s' % ', '.join('%s=%s' % b for b in form['buttons']))


def main(argv):
    if len(argv) < 2 or argv[0] not in ('fields', 'post', 'text'):
        print(__doc__, file=sys.stderr)
        return 2
    verb, path, rest = argv[0], argv[1], argv[2:]
    gui = Gui()
    gui.login()
    body = gui.get(path)
    page = parse(body)
    if verb == 'text':
        pattern = re.compile(rest[0], re.I) if rest else None
        for line in page.text:
            if pattern is None or pattern.search(line):
                print(line)
        return 0
    button = None
    changes = []
    while rest:
        item = rest.pop(0)
        if item == '--submit':
            button = rest.pop(0)
        elif '=' in item:
            changes.append(item.split('=', 1))
        else:
            print('guiform: not NAME=VALUE: %s' % item, file=sys.stderr)
            return 2
    if verb == 'fields':
        form = main_form(page, button)
        if form is None:
            print('guiform: no form on %s' % path, file=sys.stderr)
            return 1
        show_fields(form)
        return 0
    form = main_form(page, button) if button else (main_form(page, 'save') or main_form(page, 'Submit') or main_form(page))
    if form is None:
        print('guiform: no form with the button %s on %s' % (button, path), file=sys.stderr)
        return 1
    if button is None:
        button = next((b[0] for b in form['buttons'] if b[0] in ('save', 'Submit')), form['buttons'][0][0] if form['buttons'] else None)
    known = {x.name for x in form['fields']}
    for name, _value in changes:
        if name not in known:
            print('guiform: the form of %s has no field %s' % (path, name), file=sys.stderr)
            return 2
    wanted = {}
    for name, value in changes:
        wanted.setdefault(name, []).append(lab_env(value[1:]) if value.startswith('@') else value)
    pairs = []
    done = set()
    for x in form['fields']:
        if x.disabled:
            continue
        if x.name in wanted:
            if x.name in done:
                continue
            done.add(x.name)
            for value in wanted[x.name]:
                if x.kind in ('checkbox', 'radio') and value == '':
                    continue            # cleared: a browser sends nothing
                if x.kind == 'checkbox' and value in ('1', 'on', 'yes'):
                    value = x.value
                if value != '' or x.kind not in ('select', 'select-multiple'):
                    pairs.append((x.name, value))
        elif x.kind in ('checkbox', 'radio'):
            if x.checked:
                pairs.append((x.name, x.value))
        elif x.kind.startswith('select'):
            pairs += [(x.name, v) for v in x.value]
        else:
            pairs.append((x.name, x.value))
    if button:
        pairs.append((button, dict(form['buttons']).get(button, '')))
    target = form['attrs'].get('action') or path
    if not target.startswith('/'):
        target = path
    try:
        answer = gui.send(target, pairs)
    except (http.client.HTTPException, urllib.error.URLError, OSError) as exc:
        # An apply that brings the WAN up restarts the web GUI, which then drops this request (seen 2026-10-12).
        # The apply itself goes on: wait, log in again and see whether the page still offers the button.
        if button != 'apply':
            raise
        print('the GUI closed the connection during the apply (%s); looking at the page again' % type(exc).__name__)
        for _attempt in range(12):
            time.sleep(10)
            try:
                gui = Gui()
                gui.login()
                answer = gui.get(path)
                break
            except (http.client.HTTPException, urllib.error.URLError, OSError):
                answer = None
        if answer is None or main_form(parse(answer), 'apply') is not None:
            print('guiform: the page still offers "Apply changes"', file=sys.stderr)
            return 1
    notes = messages(answer)
    for name, value in changes:
        print('sent %s=%s' % (name, value))
    print('button %s on %s' % (button, target))
    for note in notes:
        print('page says: %s' % note)
    bad = [n for n in notes if re.search(r'input errors|error', n, re.I)]
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
