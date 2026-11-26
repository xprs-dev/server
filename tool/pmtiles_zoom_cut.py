#!/usr/bin/env python3
"""Cut the low zoom levels of a PMTiles v3 archive into a new archive.

    pmtiles_zoom_cut.py SOURCE OUT MAXZOOM

SOURCE is a local path or an https URL (read by range requests, so a remote
planet is never downloaded whole). OUT gets every tile of zoom 0..MAXZOOM,
byte for byte, with the source's metadata and a clustered directory, as the
PMTiles v3 specification describes (github.com/protomaps/PMTiles, spec/v3).

A clustered archive stores its tiles in tile-id order and tile ids grow with
the zoom, so the tiles of zoom 0..MAXZOOM are one leading stretch of the
source's tile data: they are copied in a single sequential pass. Only the
directory entries are held in memory (arrays, about 40 bytes an entry).
"""
import array, gzip, io, json, os, struct, sys, urllib.request

HEADER = 127
ROOT_MAX = 16384 - HEADER   # the spec: header and root directory in the first 16 KiB


class Source:
    def __init__(self, where):
        self.where = where
        self.remote = where.startswith(('http://', 'https://'))
        self.f = None if self.remote else open(where, 'rb')

    def read(self, off, n):
        if n <= 0:
            return b''
        if not self.remote:
            self.f.seek(off)
            return self.f.read(n)
        req = urllib.request.Request(self.where, headers={
            'User-Agent': 'pmtiles-reader', 'Range': 'bytes=%d-%d' % (off, off + n - 1)})
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read()


def varints(b):
    i, n = 0, len(b)
    while i < n:
        v = s = 0
        while True:
            c = b[i]
            i += 1
            v |= (c & 0x7f) << s
            s += 7
            if c < 0x80:
                break
        yield v


def put_varint(out, v):
    while v >= 0x80:
        out.append((v & 0x7f) | 0x80)
        v >>= 7
    out.append(v)


def read_dir(b):
    it = varints(b)
    n = next(it)
    ids, last = [], 0
    for _ in range(n):
        last += next(it)
        ids.append(last)
    runs = [next(it) for _ in range(n)]
    lens = [next(it) for _ in range(n)]
    offs = []
    for k in range(n):
        o = next(it)
        offs.append(offs[k - 1] + lens[k - 1] if o == 0 and k > 0 else o - 1)
    return ids, runs, lens, offs


def write_dir(ids, runs, lens, offs, lo, hi):
    out = bytearray()
    put_varint(out, hi - lo)
    last = 0
    for k in range(lo, hi):
        put_varint(out, ids[k] - last)
        last = ids[k]
    for k in range(lo, hi):
        put_varint(out, runs[k])
    for k in range(lo, hi):
        put_varint(out, lens[k])
    for k in range(lo, hi):
        if k > lo and offs[k] == offs[k - 1] + lens[k - 1]:
            put_varint(out, 0)
        else:
            put_varint(out, offs[k] + 1)
    return gzip.compress(bytes(out), mtime=0)


def directories(ids, runs, lens, offs):
    """Root and leaf directories for the entries, the root within ROOT_MAX."""
    n = len(ids)
    root = write_dir(ids, runs, lens, offs, 0, n)
    if len(root) <= ROOT_MAX:
        return root, b''
    leaf_size = 4096
    while True:
        leaves = bytearray()
        rids, rruns, rlens, roffs = [], [], [], []
        for lo in range(0, n, leaf_size):
            hi = min(n, lo + leaf_size)
            leaf = write_dir(ids, runs, lens, offs, lo, hi)
            rids.append(ids[lo]); rruns.append(0); rlens.append(len(leaf)); roffs.append(len(leaves))
            leaves += leaf
        root = write_dir(rids, rruns, rlens, roffs, 0, len(rids))
        if len(root) <= ROOT_MAX:
            return root, bytes(leaves)
        leaf_size *= 2


def cut(src_where, out_path, maxzoom):
    src = Source(src_where)
    h = src.read(0, HEADER)
    if h[:7] != b'PMTiles' or h[7] != 3:
        sys.exit('not a PMTiles v3 archive: %s' % src_where)
    (rdo, rdl, mdo, mdl, ldo, ldl, tdo, tdl,
     _addressed, _entries, _contents) = struct.unpack('<11Q', h[8:96])
    clustered, icomp, tcomp, ttype, minz, maxz = h[96:102]
    bounds = h[102:118]
    if not clustered:
        sys.exit('the source is not clustered')
    if icomp != 2:
        sys.exit('only gzip directories are handled (internal compression %d)' % icomp)
    limit = sum(4 ** z for z in range(maxzoom + 1))   # first tile id past MAXZOOM

    ids, runs = array.array('Q'), array.array('Q')
    lens, offs = array.array('Q'), array.array('Q')

    def walk(b):
        d_ids, d_runs, d_lens, d_offs = read_dir(gzip.decompress(b))
        for k in range(len(d_ids)):
            tid = d_ids[k]
            if tid >= limit:
                return False
            if d_runs[k] == 0:
                if not walk(src.read(ldo + d_offs[k], d_lens[k])):
                    return False
            else:
                ids.append(tid)
                runs.append(min(d_runs[k], limit - tid))   # a run may cross into MAXZOOM+1
                lens.append(d_lens[k])
                offs.append(d_offs[k])
        return True

    walk(src.read(rdo, rdl))
    if not ids:
        sys.exit('no tiles at zoom 0..%d' % maxzoom)

    # New tile data: each distinct source stretch once, in first-seen order
    # (which, clustered, is source order), so the copy is one forward pass.
    new_off, remap, end = array.array('Q'), {}, 0
    for k in range(len(ids)):
        o = offs[k]
        if o not in remap:
            remap[o] = end
            end += lens[k]
        new_off.append(remap[o])
    contents = len(remap)
    addressed = sum(runs)
    del remap

    root, leaves = directories(ids, runs, lens, new_off)
    meta_raw = src.read(mdo, mdl)
    meta = json.loads(gzip.decompress(meta_raw) if icomp == 2 else meta_raw)
    meta['maxzoom'] = maxzoom
    for layer in meta.get('vector_layers') or []:
        if isinstance(layer, dict) and layer.get('maxzoom', 0) > maxzoom:
            layer['maxzoom'] = maxzoom
    meta_b = gzip.compress(json.dumps(meta, separators=(',', ':')).encode(), mtime=0)

    root_off = HEADER
    meta_off = root_off + len(root)
    leaf_off = meta_off + len(meta_b)
    data_off = leaf_off + len(leaves)
    center_zoom = min(h[118], maxzoom)
    header = (b'PMTiles' + bytes([3]) +
              struct.pack('<11Q', root_off, len(root), meta_off, len(meta_b), leaf_off, len(leaves),
                          data_off, end, addressed, len(ids), contents) +
              bytes([1, 2, tcomp, ttype, minz, min(maxz, maxzoom)]) + bounds +
              bytes([center_zoom]) + h[119:127])
    assert len(header) == HEADER

    tmp = out_path + '.part'
    with open(tmp, 'wb') as out:
        out.write(header); out.write(root); out.write(meta_b); out.write(leaves)
        # Each distinct stretch once, in source order (clustered: the order
        # new_off gave them), neighbours merged into reads of up to 8 MiB.
        step = 8 << 20
        kept = sorted(set(offs))
        lens_of = {}
        for k in range(len(ids)):
            lens_of[offs[k]] = lens[k]
        i = 0
        while i < len(kept):
            a = kept[i]
            b = a + lens_of[a]
            j = i + 1
            while j < len(kept) and kept[j] == b and b - a < step:
                b += lens_of[kept[j]]
                j += 1
            out.write(src.read(tdo + a, b - a))
            i = j
        del lens_of
    os.replace(tmp, out_path)
    print('%s: zoom 0..%d, %d tiles, %d entries, %d contents, %.1f MB' %
          (out_path, maxzoom, addressed, len(ids), contents, os.path.getsize(out_path) / 1e6))


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    cut(sys.argv[1], sys.argv[2], int(sys.argv[3]))
