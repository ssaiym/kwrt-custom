import re
import struct
import os
import tempfile

PO = r"D:/Downloads/项目文件/Kwrt-25.12/devices/mediatek_filogic/diy/package/luci-app-wifiproxy/po/zh_Hans/wifiproxy.po"

MASK = 0xFFFFFFFF


def sfh_get16(d, i):
    return d[i] | (d[i + 1] << 8)


def sfh_hash(data):
    length = len(data)
    if length <= 0:
        return 0
    h = length & MASK
    rem = length & 3
    n = length >> 2
    i = 0
    for _ in range(n):
        h = (h + sfh_get16(data, i)) & MASK
        tmp = ((sfh_get16(data, i + 2) << 11) & MASK) ^ h
        h = ((h << 16) & MASK) ^ tmp
        i += 4
        h = (h + (h >> 11)) & MASK
    if rem == 3:
        h = (h + sfh_get16(data, i)) & MASK
        h = (h ^ ((h << 16) & MASK)) & MASK
        b = data[i + 2]
        if b >= 128:
            b -= 256
        h = (h ^ ((b << 18) & MASK)) & MASK
        h = (h + (h >> 11)) & MASK
    elif rem == 2:
        h = (h + sfh_get16(data, i)) & MASK
        h = (h ^ ((h << 11) & MASK)) & MASK
        h = (h + (h >> 17)) & MASK
    elif rem == 1:
        b = data[i]
        if b >= 128:
            b -= 256
        h = (h + (b & MASK)) & MASK
        h = (h ^ ((h << 10) & MASK)) & MASK
        h = (h + (h >> 1)) & MASK
    h = (h ^ ((h << 3) & MASK)) & MASK
    h = (h + (h >> 5)) & MASK
    h = (h ^ ((h << 4) & MASK)) & MASK
    h = (h + (h >> 17)) & MASK
    h = (h ^ ((h << 25) & MASK)) & MASK
    h = (h + (h >> 6)) & MASK
    return h


def canon(s):
    # lmo_canon_hash: collapse whitespace runs to single space, trim both ends
    out = []
    prev = " "
    for ch in s:
        if ch.isspace():
            if not prev.isspace():
                out.append(" ")
        else:
            out.append(ch)
        prev = ch
    r = "".join(out)
    if r.endswith(" "):
        r = r[:-1]
    return r


po = open(PO, "r", encoding="utf-8").read()
entries = []
pattern = r'msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"'
for m in re.finditer(pattern, po):
    msgid, msgstr = m.group(1), m.group(2)
    if msgid == "" or not msgstr:
        continue
    entries.append((msgid, msgstr))

records = []
for msgid, msgstr in entries:
    key = sfh_hash(canon(msgid).encode("utf-8"))
    data = msgstr.encode("utf-8")
    records.append((key, data))
records.sort(key=lambda r: r[0])

out = b""
offset = 0
for key, data in records:
    pad = (4 - (len(data) % 4)) % 4
    out += data + b"\x00" * pad
    offset += len(data) + pad

index = b""
for key, data in records:
    index += struct.pack(">IIII", key, 1, offset, len(data))
    offset += 0  # offsets already accumulated above; recompute below instead

# recompute: po2lmo stores data offsets accumulated during data writes
out = b""
off = 0
index_entries = []
for key, data in records:
    index_entries.append((key, off, len(data)))
    pad = (4 - (len(data) % 4)) % 4
    out += data + b"\x00" * pad
    off += len(data) + pad

index = b""
for key, doff, dlen in sorted(index_entries, key=lambda e: e[0]):
    index += struct.pack(">IIII", key, 1, doff, dlen)

idx_offset = len(out)
out += index + struct.pack(">I", idx_offset)

dst = os.path.join(tempfile.gettempdir(), "wifiproxy.zh-cn.lmo")
open(dst, "wb").write(out)
print(len(records), "entries ->", dst)
for key, doff, dlen in sorted(index_entries, key=lambda e: e[0])[:3]:
    print(hex(key), doff, dlen)
