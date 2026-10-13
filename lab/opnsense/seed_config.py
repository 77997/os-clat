#!/usr/bin/env python3
"""Replace the factory config.xml inside an OPNsense nano raw image, in place.

    seed_config.py IMAGE.raw [CONFIG.xml]

Without CONFIG.xml it only reports what it finds (dry run).

Why this works: the nano image has no /conf/config.xml.  On first boot
"opnsense-importer -b" waits 7 seconds for a key and then copies
/usr/local/etc/config.xml to /conf/config.xml (core src/sbin/opnsense-importer,
bootstrap_and_exit).  The file is small, so its data is one contiguous run in
the UFS2 file system, and UFS2 has no data checksums.  Overwriting exactly the
same number of bytes therefore changes the file content and nothing else.

Which file is replaced: the one configuration that carries the factory mark
(<trigger_initial_wizard/>), the mark of the nano build (serial console first),
starts on a sector boundary and names the factory devices mismatch0 and
mismatch1.  There must be exactly one.

Changed on 2026-10-12 against the version printed in the OPNsense sheet 5.2:
that version also demanded "exactly 2 files with the factory mark" (the nano
config and config.xml.sample).  The dry run on the real 26.7 nano image found
four (.work/results/assets-prefetch.txt): those two, and two unit-test fixtures
of core that the image ships.  The count is therefore reported and no longer a
condition; the target has to pass the stricter test above instead.

Not tested on a booted system: that OPNsense starts with the seeded file is for
the first boot to show (PLAN.md M4).
"""
import hashlib
import re
import sys
import xml.etree.ElementTree as ET

HEAD = b'<?xml version="1.0"?>\n<opnsense>'
TAIL = b'</opnsense>\n'
FACTORY_MARK = b'<trigger_initial_wizard/>'
NANO_MARK = re.compile(rb'<primaryconsole>\s*serial\s*</primaryconsole>')
DEVICE_MARKS = (b'<if>mismatch0</if>', b'<if>mismatch1</if>')
CHUNK = 32 * 1024 * 1024
MAXLEN = 32768          # one UFS2 block: a file below this size is contiguous


def find_all(path, needle):
    found, pos, prev = [], 0, b''
    with open(path, 'rb') as handle:
        while True:
            buf = handle.read(CHUNK)
            if not buf:
                break
            data = prev + buf
            base = pos - len(prev)
            idx = data.find(needle)
            while idx != -1:
                found.append(base + idx)
                idx = data.find(needle, idx + 1)
            prev = data[-(len(needle) - 1):]
            pos += len(buf)
    return found


def candidates(path):
    out = []
    with open(path, 'rb') as handle:
        for off in find_all(path, HEAD):
            handle.seek(off)
            data = handle.read(MAXLEN)
            end = data.find(TAIL)
            if end == -1:
                continue
            body = data[:end + len(TAIL)]
            out.append({
                'offset': off,
                'length': len(body),
                'factory': FACTORY_MARK in body,
                'nano': bool(NANO_MARK.search(body)),
                'aligned': off % 512 == 0,
                'devices': all(mark in body for mark in DEVICE_MARKS),
                'sha256': hashlib.sha256(body).hexdigest(),
            })
    return out


def minify(path):
    root = ET.parse(path).getroot()          # also proves well-formedness
    if root.tag != 'opnsense':
        raise SystemExit('root element is <%s>, expected <opnsense>' % root.tag)
    for node in root.iter():
        if node.text is not None and not node.text.strip():
            node.text = None
        if node.tail is not None and not node.tail.strip():
            node.tail = None
    text = ET.tostring(root, encoding='unicode', short_empty_elements=True)
    return b'<?xml version="1.0"?>\n' + text.encode('utf-8')


def main(argv):
    if len(argv) not in (2, 3):
        raise SystemExit(__doc__)
    image = argv[1]
    found = candidates(image)
    for item in found:
        print('candidate offset=%(offset)d length=%(length)d factory=%(factory)s '
              'nano=%(nano)s aligned=%(aligned)s devices=%(devices)s sha256=%(sha256)s' % item)
    targets = [c for c in found if c['factory'] and c['nano'] and c['aligned'] and c['devices']]
    factory = [c for c in found if c['factory']]
    if len(targets) != 1:
        raise SystemExit('STOP: expected exactly 1 nano factory config (factory mark, serial console first, '
                         'sector aligned, devices mismatch0 and mismatch1), found %d among %d files with the '
                         'factory mark. Do not boot this image unattended; use the fallback.'
                         % (len(targets), len(factory)))
    target = targets[0]
    print('target offset=%d length=%d; %d other file(s) carry the factory mark and stay as they are '
          '(config.xml.sample, test fixtures of core)' % (target['offset'], target['length'], len(factory) - 1))
    if len(argv) == 2:
        print('dry run: would replace %(length)d bytes at offset %(offset)d' % target)
        return
    new = minify(argv[2])
    if b'@@' in new:
        raise SystemExit('STOP: the new config still has a @@PLACEHOLDER@@')
    room = target['length'] - len(new) - 1
    if room < 0:
        raise SystemExit('STOP: new config is %d bytes too long (%d available)'
                         % (-room, target['length'] - 1))
    close = b'</opnsense>'
    if not new.endswith(close):
        raise SystemExit('STOP: unexpected serialisation')
    new = new[:-len(close)] + b' ' * room + close + b'\n'
    assert len(new) == target['length']
    with open(image, 'r+b') as handle:
        handle.seek(target['offset'])
        handle.write(new)
        handle.flush()
    with open(image, 'rb') as handle:          # read back and parse again
        handle.seek(target['offset'])
        back = handle.read(target['length'])
    ET.fromstring(back.decode('utf-8'))
    if back != new:
        raise SystemExit('STOP: read-back differs')
    print('replaced %d bytes at offset %d (%d bytes of padding), new sha256=%s'
          % (target['length'], target['offset'], room, hashlib.sha256(back).hexdigest()))


if __name__ == '__main__':
    main(sys.argv)
