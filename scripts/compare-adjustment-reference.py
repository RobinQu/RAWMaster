#!/usr/bin/env python3
"""Bounded offline 021 comparison. Own equations/code; NumPy, Pillow ICC metadata only.

Never uses Pillow's RGB TIFF/PNG pixel conversion (which can truncate RGB16).
Inputs stay read-only. Decoded rows and metric fields live in an exclusive scratch
directory; quantiles use an in-place disk mapping, not a full-image RAM copy.
Local/statistical/geometry qualification is deliberately unsupported.
"""
import argparse
import binascii
import contextlib
import copy
import hashlib
import json
import math
import mmap
import os
from pathlib import Path
import resource
import shutil
import struct
import sys
import tempfile
import zlib

import numpy as np
from PIL import ImageCms

MATRIX = np.array([[.4124564, .3575761, .1804375],
                   [.2126729, .7151522, .0721750],
                   [.0193339, .1191920, .9503041]], dtype=np.float64)
WHITE = np.array([.95047, 1., 1.08883])
MAX_STRIP = 64 * 1024**2
MAX_PIXELS = 64_000_000
MEMORY_LIMIT = 1024**3
DATA_URL = 'https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/dataNprograms/ciede2000testdata.txt'
DATA_SHA = '44aebb39107128328add54fbef5ac8ee89909e50508f448a1580adea2058a4b8'
PROTOCOL_SHA = 'fa0ba8429444befd42fd3baa99a33e2bc81721abd4bfac7052d451f70aa4bb15'
LEGACY_SRGB_V2_SHA = '2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e'


class Unsupported(ValueError):
    pass


def require(test, message):
    if not test:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024**2), b''):
            h.update(block)
    return h.hexdigest()


def memory_check():
    # Darwin ru_maxrss is bytes; Linux is KiB. This is sampled process high water,
    # not a hard OS cap or child-process accounting. Crossing the budget is a failure.
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    peak = int(peak if sys.platform == 'darwin' else peak * 1024)
    require(peak <= MEMORY_LIMIT, 'Measured process high water exceeds 1GiB tool budget')
    return peak


def srgb_decode(rgb):
    return np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055)**2.4)


def lab_from_linear(rgb):
    xyz = (rgb @ MATRIX.T) / WHITE
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), ((24389 / 27) * xyz + 16) / 116)
    return np.stack((116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])), axis=-1)


def ciede2000(first, second):
    """CIEDE2000 kL=kC=kH=1, independently expressed from the published equations."""
    l1, a1, b1 = np.moveaxis(np.asarray(first, dtype=np.float64), -1, 0)
    l2, a2, b2 = np.moveaxis(np.asarray(second, dtype=np.float64), -1, 0)
    c1, c2 = np.hypot(a1, b1), np.hypot(a2, b2)
    c = (c1 + c2) / 2
    g = .5 * (1 - np.sqrt(c**7 / (c**7 + 25**7)))
    ap1, ap2 = (1 + g) * a1, (1 + g) * a2
    cp1, cp2 = np.hypot(ap1, b1), np.hypot(ap2, b2)
    hp1 = np.mod(np.degrees(np.arctan2(b1, ap1)), 360)
    hp2 = np.mod(np.degrees(np.arctan2(b2, ap2)), 360)
    hp1, hp2 = np.where(cp1 == 0, 0, hp1), np.where(cp2 == 0, 0, hp2)
    dl, dc = l2 - l1, cp2 - cp1
    dh = hp2 - hp1
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(cp1 * cp2 == 0, 0, dh)
    dH = 2 * np.sqrt(cp1 * cp2) * np.sin(np.radians(dh / 2))
    lm, cm = (l1 + l2) / 2, (cp1 + cp2) / 2
    hm = np.where(np.abs(hp1 - hp2) <= 180, (hp1 + hp2) / 2,
                  np.where(hp1 + hp2 < 360, (hp1 + hp2 + 360) / 2, (hp1 + hp2 - 360) / 2))
    hm = np.where(cp1 * cp2 == 0, hp1 + hp2, hm)
    t = (1 - .17 * np.cos(np.radians(hm - 30)) + .24 * np.cos(np.radians(2 * hm))
         + .32 * np.cos(np.radians(3 * hm + 6)) - .20 * np.cos(np.radians(4 * hm - 63)))
    sl = 1 + .015 * (lm - 50)**2 / np.sqrt(20 + (lm - 50)**2)
    sc, sh = 1 + .045 * cm, 1 + .015 * cm * t
    rt = -2 * np.sqrt(cm**7 / (cm**7 + 25**7)) * np.sin(np.radians(60 * np.exp(-((hm - 275) / 25)**2)))
    x, y, z = dl / sl, dc / sc, dH / sh
    return np.sqrt(np.maximum(0, x*x + y*y + z*z + rt*y*z))


GAUSS = np.exp(-np.arange(-5, 6, dtype=np.float64)**2 / (2 * 1.5**2))
GAUSS /= GAUSS.sum()


def gaussian_valid(a):
    require(a.shape[0] >= 11 and a.shape[1] >= 11, 'SSIM requires 11x11 neighborhoods')
    horizontal = np.zeros((a.shape[0], a.shape[1] - 10), dtype=np.float64)
    for k, weight in enumerate(GAUSS):
        horizontal += weight * a[:, k:k + horizontal.shape[1]]
    result = np.zeros((a.shape[0] - 10, a.shape[1] - 10), dtype=np.float64)
    for k, weight in enumerate(GAUSS):
        result += weight * horizontal[k:k + result.shape[0]]
    return result


def ssim_valid(a, b):
    ma, mb = gaussian_valid(a), gaussian_valid(b)
    va = np.maximum(0, gaussian_valid(a*a) - ma*ma)
    vb = np.maximum(0, gaussian_valid(b*b) - mb*mb)
    cov = gaussian_valid(a*b) - ma*mb
    return ((2*ma*mb + .01**2) * (2*cov + .03**2)
            / ((ma*ma + mb*mb + .01**2) * (va + vb + .03**2)))


def profile_info(icc, srgb_chunk=False, assume=False):
    if icc:
        require(len(icc) <= 4 * 1024**2, 'ICC too large')
        import io
        try: profile = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        except Exception as error: raise Unsupported('Unreadable ICC profile: '+str(error)) from error
        description = ImageCms.getProfileDescription(profile).strip()
        require(profile.profile.xcolor_space.strip() == 'RGB', 'ICC must describe RGB')
        # Different legitimate sRGB ICC byte strings exist. Check colorants/TRCs,
        # not the mutable description string. Unknown profiles require a separately
        # reviewed ColorSync/LCMS conversion; this tool never silently converts them.
        require(len(icc) >= 132 and icc[16:20] == b'RGB ' and icc[20:24] == b'XYZ ', 'Unsupported ICC data/PCS')
        tags = {}; count = struct.unpack('>I',icc[128:132])[0]
        require(count <= 256 and 132+count*12 <= len(icc),'Malformed ICC tag table')
        for i in range(count):
            tag,offset,size = struct.unpack('>4sII',icc[132+i*12:144+i*12])
            require(offset+size <= len(icc),'ICC tag outside profile'); tags[tag] = icc[offset:offset+size]
        require(not any(t in tags for t in (b'A2B0',b'A2B1',b'A2B2',b'B2A0',b'B2A1',b'B2A2',b'D2B0',b'B2D0')),
                'ICC LUT/multiprocess profiles require a separately reviewed conversion')
        def fixed(data): return struct.unpack('>'+str(len(data)//4)+'i',data)
        def xyz(tag):
            data = tags.get(tag,b''); require(data[:4] == b'XYZ ' and len(data) >= 20,'Missing ICC XYZ colorant')
            return np.array(fixed(data[8:20]),dtype=np.float64)/65536
        actual = np.stack([xyz(t) for t in (b'rXYZ',b'gXYZ',b'bXYZ')],axis=1)
        d50_srgb = np.array([[.4360747,.3850649,.1430804],[.2225045,.7168786,.0606169],[.0139322,.0971045,.7141733]])
        matrix_error = float(np.max(np.abs(actual-d50_srgb)))
        white_error = float(np.max(np.abs(xyz(b'wtpt')-np.array([.9642,1,.8249]))))
        legacy_v2 = hashlib.sha256(icc).hexdigest() == LEGACY_SRGB_V2_SHA
        if legacy_v2:
            # Exactly the frozen Photos legacy profile, never a description/D65
            # wildcard. ICC White Paper6 describes v2 media-white ambiguity and
            # older sRGB profiles lacking chad. The protocol evaluates nominal
            # encoded sRGB, not absolute-colorimetric ICC/CMM appearance.
            require(len(icc) == 3144 and icc[4:8] == b'Lino' and icc[8:12] == bytes.fromhex('02100000')
                    and icc[12:16] == b'mntr' and icc[36:40] == b'acsp'
                    and fixed(icc[68:80]) == (63190,65536,54061)
                    and fixed(tags[b'wtpt'][8:20]) == (62289,65536,71372) and b'chad' not in tags,
                    'Frozen legacy ICCv2 header/media-white identity mismatch')
        require(matrix_error <= .0006 and (legacy_v2 or white_error <= .0006),
                'ICC is not recognized D50-adapted sRGB colorimetry; conversion unsupported')
        x = np.linspace(0,1,4097); target = srgb_decode(x); errors = []
        for tag in (b'rTRC',b'gTRC',b'bTRC'):
            data = tags.get(tag,b''); require(len(data) >= 12,'Missing ICC TRC')
            if data[:4] == b'curv':
                n = struct.unpack('>I',data[8:12])[0]
                require(12+2*n <= len(data) and n <= 65536,'Malformed ICC curve')
                if n == 0: values = x
                elif n == 1: values = x**(struct.unpack('>H',data[12:14])[0]/256)
                else:
                    table = np.frombuffer(data[12:12+2*n],dtype='>u2').astype(np.float64)/65535
                    values = np.interp(x,np.linspace(0,1,n),table)
            elif data[:4] == b'para':
                kind = struct.unpack('>H',data[8:10])[0]; counts = {0:1,1:3,2:4,3:5,4:7}
                require(kind in counts and len(data) >= 12+counts[kind]*4,'Unsupported ICC parametric TRC')
                p = np.array(fixed(data[12:12+counts[kind]*4]),dtype=np.float64)/65536
                g = p[0]
                if kind == 0: values = x**g
                elif kind in (1,2):
                    _,a,b = p[:3]; require(a > 0,'Invalid ICC curve coefficient')
                    c = p[3] if kind == 2 else 0
                    values = np.where(x >= -b/a,np.maximum(a*x+b,0)**g+c,c)
                else:
                    _,a,b,c,d = p[:5]; e,f = p[5:7] if kind == 4 else (0,0)
                    values = np.where(x >= d,np.maximum(a*x+b,0)**g+e,c*x+f)
            else: raise Unsupported('Unsupported ICC TRC representation')
            errors.append(float(np.max(np.abs(values-target))))
        require(max(errors) <= .0001,'ICC transfer function is not recognized sRGB; conversion unsupported')
        return {'status': 'parameter-verified-sRGB-ICC', 'description': description, 'sha256': hashlib.sha256(icc).hexdigest(),
                'recognition':{'D50ColorantMaxAbsError':matrix_error,'D50WhiteMaxAbsError':white_error,
                               'TRCMaxAbsErrors4097Samples':errors,'matrixWhiteTolerance':.0006,'TRCTolerance':.0001,
                               'whitePointPolicy':'exact frozen legacyv2 SHA/header/D65-wtpt/no-chad' if legacy_v2 else 'D50 within original tolerance',
                               'legacyExactIdentity':legacy_v2},
                'recognitionSources':(['https://registry.color.org/rgb-registry/srgbprofiles',
                    'https://www.color.org/whitepapers/ICC_White_Paper_6_v2_and_v4_display_profile_differences-updated.pdf'] if legacy_v2 else []),
                'conversion':'none; recognized sRGB semantics use frozen protocol D65 matrix, not ICC PCS Lab'}
    if srgb_chunk:
        return {'status': 'PNG-sRGB-chunk', 'sha256': None}
    if assume:
        return {'status': 'UNVERIFIED-user-assumed-sRGB', 'sha256': None}
    raise Unsupported('No verified sRGB ICC / PNG sRGB chunk; use explicit --assume-srgb only for UNVERIFIED diagnostics')


def lzw_decode(data, expected):
    """TIFF MSB LZW, early-change=1, bounded dictionary and decoded strip."""
    table = [bytes([i]) for i in range(256)] + [None, None]
    bit, width, previous = 0, 9, None
    out = bytearray()
    while bit + width <= len(data) * 8:
        start, shift = bit // 8, bit % 8
        code = (int.from_bytes(data[start:start + 3], 'big') >> (24 - shift - width)) & ((1 << width) - 1) if start + 3 <= len(data) else (int.from_bytes(data[start:], 'big') >> (8*(len(data)-start) - shift - width)) & ((1 << width)-1)
        bit += width
        if code == 256:
            table = [bytes([i]) for i in range(256)] + [None, None]
            width, previous = 9, None
            continue
        if code == 257:
            require(len(out) == expected, 'LZW decoded size mismatch')
            return out
        if code < len(table) and table[code] is not None:
            current = table[code]
        elif code == len(table) and previous is not None:
            current = previous + previous[:1]
        else:
            raise ValueError('Invalid TIFF LZW code')
        out.extend(current)
        require(len(out) <= expected, 'LZW decoded strip overflow')
        if previous is not None and len(table) < 4096:
            table.append(previous + current[:1])
            if len(table) == (1 << width) - 1 and width < 12:
                width += 1
        previous = current
    raise ValueError('Missing TIFF LZW end code')


class Raster:
    def __init__(self, path, scratch, name, assume=False):
        self.source = Path(path).resolve(strict=True)
        self.before = self.source.stat()
        self.raw = scratch / (name + '.rgba16')
        self.bits = self.width = self.height = 0
        self.alpha = 'opaque-RGB'
        self.profile = None
        self._sha = None
        with self.source.open('rb') as f, self.raw.open('xb') as out:
            magic = f.read(8); f.seek(0)
            if magic == b'\x89PNG\r\n\x1a\n':
                self._png(f, out, assume)
            elif magic[:2] in (b'II', b'MM'):
                self._tiff(f, out, assume)
            else:
                raise Unsupported('Only TIFF strip RGB/RGBA8/16 and noninterlaced PNG RGB/RGBA8/16 supported')
            out.flush(); os.fsync(out.fileno())
        require(self.raw.stat().st_size == self.width*self.height*8, 'Decoded row size mismatch')
        self.verify()

    def dimensions(self, w, h, channels, bits):
        require(0 < w and 0 < h and w*h <= MAX_PIXELS and w <= 16384 and h <= 16384, 'Image dimensions exceed fixed 64MP/16384 bounds')
        require(channels in (3, 4) and bits in (8, 16), 'Only RGB/RGBA unsigned 8/16-bit supported')
        self.width, self.height, self.bits = w, h, bits

    def write_rows(self, values, out):
        require(values.ndim == 3 and values.shape[1] == self.width, 'Invalid raster rows')
        if self.bits == 8:
            values = values.astype('<u2') * 257
        else:
            values = values.astype('<u2', copy=False)
        if values.shape[-1] == 3:
            rgba = np.full(values.shape[:2] + (4,), 65535, dtype='<u2'); rgba[..., :3] = values
        else:
            rgba = values
        if self.alpha == 'associated-RGBA':
            # Associated alpha cannot preserve hidden RGB at alpha zero. Mark that
            # limitation, never fabricate straight-RGB-under-zero qualification.
            alpha = rgba[..., 3].astype(np.float64)
            rgb = rgba[..., :3].astype(np.float64)
            require(np.all(rgb <= alpha[...,None]), 'Associated-alpha input contains RGB greater than alpha')
            rgb = np.divide(rgb * 65535, alpha[..., None], out=np.zeros_like(rgb), where=alpha[..., None] != 0)
            rgba = rgba.copy(); rgba[..., :3] = np.rint(np.clip(rgb, 0, 65535)).astype('<u2')
        out.write(rgba.tobytes())

    def _tiff(self, f, out, assume):
        header = f.read(8); endian = '<' if header[:2] == b'II' else '>'
        require(struct.unpack(endian+'H', header[2:4])[0] == 42, 'BigTIFF is unsupported, not silently converted')
        f.seek(struct.unpack(endian+'I', header[4:8])[0]); count = struct.unpack(endian+'H', f.read(2))[0]
        require(count <= 512, 'Too many TIFF tags')
        tags = {}
        types = {1: ('B', 1), 2: ('s', 1), 3: ('H', 2), 4: ('I', 4), 7: ('B', 1)}
        for _ in range(count):
            entry = f.read(12); require(len(entry) == 12, 'Truncated TIFF IFD')
            tag, kind, n = struct.unpack(endian+'HHI', entry[:8])
            if tag not in {256,257,258,259,262,273,274,277,278,279,284,317,322,323,324,325,338,339,34675}:
                continue
            require(kind in types and n <= 4*1024**2, 'Unsupported/oversized TIFF tag')
            fmt, unit = types[kind]; size = n*unit
            if size <= 4:
                raw = entry[8:8+size]
            else:
                position = f.tell(); f.seek(struct.unpack(endian+'I', entry[8:])[0]); raw = f.read(size); f.seek(position)
            require(len(raw) == size, 'Truncated TIFF tag')
            tags[tag] = raw if tag == 34675 else list(struct.unpack(endian+str(n)+fmt, raw))
        def one(tag, default=None):
            return tags.get(tag, [default])[0]
        require(not any(k in tags for k in (322,323,324,325)), 'Tiled TIFF unsupported')
        require(one(262) == 2 and one(284,1) == 1 and one(274,1) == 1, 'TIFF must be oriented top-left chunky RGB')
        channels, bits = one(277), tags.get(258, [])
        require(channels in (3,4) and len(bits) == channels and len(set(bits)) == 1, 'Mixed TIFF precision unsupported')
        self.dimensions(one(256), one(257), channels, bits[0])
        require(all(x == 1 for x in tags.get(339, [1])), 'Only unsigned integer TIFF supported')
        if channels == 4:
            extra = tags.get(338)
            require(extra in ([1], [2]), 'TIFF alpha association must be explicit')
            self.alpha = 'associated-RGBA' if extra == [1] else 'straight-RGBA'
        self.profile = profile_info(tags.get(34675), assume=assume)
        compression, predictor = one(259,1), one(317,1)
        require(compression in (1,5), 'Only uncompressed/LZW TIFF strips supported')
        require(predictor in (1,2), 'Unsupported TIFF predictor')
        rows = one(278, self.height); require(rows > 0, 'Invalid TIFF strip rows')
        offsets, lengths = tags.get(273, []), tags.get(279, [])
        require(len(offsets) == len(lengths) == math.ceil(self.height / rows), 'Invalid TIFF strip table')
        for i, (offset, length) in enumerate(zip(offsets, lengths)):
            n = min(rows, self.height-i*rows); expected = n*self.width*channels*(self.bits//8)
            if compression == 1:
                require(length == expected, 'Uncompressed TIFF strip size mismatch')
                f.seek(offset)
                for first in range(0,n,32):
                    nr = min(32,n-first); size = nr*self.width*channels*(self.bits//8)
                    data = f.read(size); require(len(data) == size,'Truncated TIFF rows')
                    values = np.frombuffer(data,dtype=endian+('u2' if self.bits == 16 else 'u1')).reshape(nr,self.width,channels)
                    if predictor == 2: values = np.cumsum(values,axis=1,dtype=np.uint32).astype('<u2' if self.bits == 16 else 'u1')
                    self.write_rows(values,out); memory_check()
                continue
            require(expected <= MAX_STRIP and 0 < length <= MAX_STRIP, 'Compressed TIFF strip exceeds 64MiB bounded decoder; re-export with bounded strips')
            f.seek(offset); data = f.read(length); require(len(data) == length, 'Truncated TIFF strip')
            decoded = data if compression == 1 else lzw_decode(data, expected)
            require(len(decoded) == expected, 'TIFF strip byte length mismatch')
            values = np.frombuffer(decoded, dtype=endian+('u2' if self.bits == 16 else 'u1')).reshape(n,self.width,channels)
            if predictor == 2:
                values = np.cumsum(values, axis=1, dtype=np.uint32).astype('<u2' if self.bits == 16 else 'u1')
            self.write_rows(values, out); memory_check()

    def _png(self, f, out, assume):
        require(f.read(8) == b'\x89PNG\r\n\x1a\n', 'Bad PNG')
        decompressor, buffer, previous, rows = zlib.decompressobj(), bytearray(), None, 0
        icc, srgb, started, ended = None, False, False, False
        channels = bpp = rowbytes = None
        while True:
            header = f.read(8); require(len(header) == 8, 'Missing PNG IEND')
            length, kind = struct.unpack('>I4s', header)
            require(length <= MAX_STRIP, 'PNG chunk exceeds 64MiB decoder bound')
            if kind == b'IDAT':
                require(channels is not None and not ended, 'Invalid PNG IDAT ordering')
                if not started:
                    self.profile = profile_info(icc, srgb_chunk=srgb, assume=assume)
                started = True; crc = binascii.crc32(kind)
                remaining = length
                while remaining:
                    data = f.read(min(65536, remaining)); require(data, 'Truncated PNG IDAT'); remaining -= len(data)
                    crc = binascii.crc32(data, crc)
                    pending = data
                    while pending:
                        buffer.extend(decompressor.decompress(pending, rowbytes+1-len(buffer)))
                        pending = decompressor.unconsumed_tail
                        if len(buffer) == rowbytes+1:
                            require(rows < self.height, 'PNG decoded overflow')
                            filtered = np.frombuffer(buffer[1:], dtype=np.uint8).copy(); mode = buffer[0]
                            if previous is None: previous = np.zeros(rowbytes, dtype=np.uint8)
                            if mode == 1:
                                filtered = np.cumsum(filtered.reshape(-1,bpp), axis=0, dtype=np.uint32).astype(np.uint8).reshape(-1)
                            elif mode == 2:
                                filtered += previous
                            elif mode in (3,4):
                                for x in range(rowbytes):
                                    a = int(filtered[x-bpp]) if x >= bpp else 0
                                    b = int(previous[x]); c = int(previous[x-bpp]) if x >= bpp else 0
                                    if mode == 3: prediction = (a+b)//2
                                    else:
                                        p = a+b-c; pa,pb,pc = abs(p-a),abs(p-b),abs(p-c)
                                        prediction = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                                    filtered[x] = (int(filtered[x])+prediction) & 255
                            else:
                                require(mode == 0, 'Unknown PNG row filter')
                            values = filtered.view('>u2' if self.bits == 16 else 'u1').reshape(1,self.width,channels)
                            self.write_rows(values, out); previous = filtered; rows += 1; buffer.clear()
                require(struct.unpack('>I', f.read(4))[0] == crc & 0xffffffff, 'PNG CRC mismatch')
            else:
                data = f.read(length); require(len(data) == length, 'Truncated PNG chunk')
                require(struct.unpack('>I', f.read(4))[0] == binascii.crc32(data, binascii.crc32(kind)) & 0xffffffff, 'PNG CRC mismatch')
                if started: ended = True
                if kind == b'IHDR':
                    require(length == 13 and channels is None, 'Bad PNG IHDR')
                    w,h,bits,color,compression,filtering,interlace = struct.unpack('>IIBBBBB', data)
                    require(color in (2,6) and compression == filtering == interlace == 0, 'PNG must be noninterlaced RGB/RGBA8/16')
                    channels = 3 if color == 2 else 4; self.dimensions(w,h,channels,bits)
                    self.alpha = 'straight-RGBA' if channels == 4 else 'opaque-RGB'
                    bpp = channels*(bits//8); rowbytes = w*bpp
                elif kind == b'iCCP':
                    require(not started and icc is None and b'\0' in data, 'Bad PNG ICC ordering')
                    _, payload = data.split(b'\0',1); require(payload[:1] == b'\0', 'Unknown PNG ICC compression')
                    stream = zlib.decompressobj(); icc = stream.decompress(payload[1:], 4*1024**2+1)
                    require(stream.eof and len(icc) <= 4*1024**2, 'Oversized/truncated ICC')
                elif kind == b'sRGB':
                    require(not started and len(data) == 1 and data[0] <= 3, 'Invalid PNG sRGB'); srgb = True
                elif kind == b'IEND':
                    require(length == 0, 'Bad PNG IEND'); break
                elif kind[:1].isupper() and kind not in (b'IHDR',):
                    raise Unsupported('Unsupported critical PNG chunk '+repr(kind))
        require(started and rows == self.height and not buffer and decompressor.eof and not decompressor.unused_data, 'PNG decoded size/stream mismatch')

    def read(self, top, bottom):
        with self.raw.open('rb') as f:
            f.seek(top*self.width*8); data = f.read((bottom-top)*self.width*8)
        return np.frombuffer(data, dtype='<u2').reshape(bottom-top,self.width,4)

    def verify(self):
        after = self.source.stat()
        require((self.before.st_dev,self.before.st_ino,self.before.st_size,self.before.st_mtime_ns,self.before.st_ctime_ns)
                == (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns), 'Input changed during comparison')

    def info(self):
        if self._sha is None:
            self.verify(); self._sha = digest(self.source); self.verify()
        return {'path':str(self.source), 'sha256':self._sha, 'width':self.width, 'height':self.height,
                'bitsPerSample':self.bits, 'alpha':self.alpha, 'profile':self.profile,
                'decodedLayout':'packed top-left little-endian straight RGBA16; 8-bit inputs multiplied by257 exactly'}


def regions(protocol, width, height):
    result = {'whole':(0,0,width,height)}
    for name, box in protocol['quality']['ROIs'].items():
        require(len(box) == 4 and 0 <= box[0] < box[2] <= 1 and 0 <= box[1] < box[3] <= 1, 'Invalid frozen ROI')
        result[name] = (math.floor(box[0]*width),math.floor(box[1]*height),math.ceil(box[2]*width),math.ceil(box[3]*height))
    return result


def exact_stats(field, shape, box, scratch, name, quantiles=(.5,.95)):
    l,t,r,b = box
    if r <= l or b <= t:
        return {'status':'UNMEASURABLE-no-valid-window-centers','count':0}
    n = (r-l)*(b-t); target = scratch/(name+'.quantile')
    with open(field,'rb') as src, target.open('xb') as dst:
        for y in range(t,b):
            src.seek((y*shape[1]+l)*8); data = src.read((r-l)*8)
            require(len(data) == (r-l)*8, 'Truncated metric field'); dst.write(data)
    values = np.memmap(target, mode='r+', dtype='<f8', shape=(n,))
    # NumPy's linear quantile rule, exact order statistics, no approximate histogram.
    kth = sorted(set(k for q in quantiles for k in (math.floor((n-1)*q),math.ceil((n-1)*q))))
    mean = float(np.mean(values, dtype=np.float64)); maximum = float(np.max(values)); minimum = float(np.min(values))
    values.partition(kth)
    result = {'status':'measured','count':n,'mean':mean,'min':minimum,'max':maximum}
    for q in quantiles:
        position = (n-1)*q; lo,hi = math.floor(position),math.ceil(position)
        result['p'+str(int(q*100))] = float(values[lo]*(hi-position)+values[hi]*(position-lo)) if hi != lo else float(values[lo])
    values.flush(); values._mmap.close(); target.unlink(); memory_check()
    return result


def histogram_quantile(hist, q):
    n = int(hist.sum()); x = (n-1)*q; lo,hi = math.floor(x),math.ceil(x)
    cumulative = np.cumsum(hist)
    a,b = int(np.searchsorted(cumulative,lo+1)),int(np.searchsorted(cumulative,hi+1))
    return a if lo == hi else a*(hi-x)+b*(x-lo)


def compare(reference, candidate, protocol, scratch, category, rows=32, *, reuse_opaque_metrics=True):
    require((reference.width,reference.height) == (candidate.width,candidate.height), 'Canvas/geometry mismatch; no resampling is permitted')
    w,h = reference.width,reference.height
    require(w >= 11 and h >= 11, 'Image smaller than SSIM window; no pretend SSIM pass')
    boxes = regions(protocol,w,h)
    output = {}; alpha_coverage = {'referenceZero':0,'candidateZero':0,'referenceFractional':0,'candidateFractional':0}
    any_metric_reuse = False
    for variant in ('straight','blackComposite','whiteComposite'):
        # Eligibility comes only after the first complete actual alpha scan. No
        # metadata shortcut: even one alpha65534 outside allROIs takes the old path.
        reuse_metrics = reuse_opaque_metrics and variant != 'straight' and not any(alpha_coverage.values())
        any_metric_reuse |= reuse_metrics
        de_path, ss_path = scratch/(variant+'.de'), scratch/(variant+'.ssim')
        hist = {name:np.zeros((4,65536), dtype=np.int64) for name in boxes}
        max_error = {name:np.zeros(4) for name in boxes}
        zero_alpha_count = 0
        with contextlib.ExitStack() as files:
            de_file = None if reuse_metrics else files.enter_context(de_path.open('xb'))
            ss_file = None if reuse_metrics else files.enter_context(ss_path.open('xb'))
            for top in range(0,h,rows):
                bottom = min(top+rows,h)
                a,b = reference.read(top,bottom),candidate.read(top,bottom)
                aa,ba = a[...,3:4].astype(np.float64)/65535,b[...,3:4].astype(np.float64)/65535
                ar,br = srgb_decode(a[...,:3].astype(np.float64)/65535),srgb_decode(b[...,:3].astype(np.float64)/65535)
                require(np.isfinite(ar).all() and np.isfinite(br).all(), 'Nonfinite decoded linear RGB')
                if variant != 'straight':
                    bg = 0 if variant == 'blackComposite' else 1
                    ar,br = ar*aa+bg*(1-aa),br*ba+bg*(1-ba)
                    error = np.concatenate((np.abs(ar-br)*65535,np.abs(aa-ba)*65535),axis=-1)
                else:
                    error = np.abs(a.astype(np.int32)-b.astype(np.int32))
                    zero_alpha_count += int(((a[...,3] == 0) | (b[...,3] == 0)).sum())
                    for label,image in (('reference',a),('candidate',b)):
                        alpha_coverage[label+'Zero'] += int((image[...,3] == 0).sum())
                        alpha_coverage[label+'Fractional'] += int(((image[...,3] > 0) & (image[...,3] < 65535)).sum())
                if not reuse_metrics:
                    delta = ciede2000(lab_from_linear(ar),lab_from_linear(br))
                    require(np.isfinite(delta).all(), 'Nonfinite DeltaE')
                    de_file.write(delta.astype('<f8',copy=False).tobytes())
                for name,(l,t,r,bb) in boxes.items():
                    start,end = max(top,t),min(bottom,bb)
                    if start >= end: continue
                    block = error[start-top:end-top,l:r]
                    for channel in range(4):
                        max_error[name][channel] = max(max_error[name][channel],float(block[...,channel].max()))
                        # Quantize errors only for exact integer neutral straight channels.
                        # Composites remain continuous; their exact p99 is calculated below.
                        if variant == 'straight':
                            hist[name][channel] += np.bincount(block[...,channel].reshape(-1),minlength=65536)
                memory_check()
            for top in (() if reuse_metrics else range(5,h-5,rows)):
                bottom = min(top+rows,h-5)
                a,b = reference.read(top-5,bottom+5),candidate.read(top-5,bottom+5)
                def luminance(rgba):
                    rgb = srgb_decode(rgba[...,:3].astype(np.float64)/65535)
                    if variant != 'straight':
                        alpha = rgba[...,3:4].astype(np.float64)/65535
                        rgb = rgb*alpha+(0 if variant == 'blackComposite' else 1)*(1-alpha)
                    return rgb @ MATRIX[1]
                score = ssim_valid(luminance(a),luminance(b))
                require(np.isfinite(score).all(), 'Nonfinite SSIM')
                ss_file.write(score.astype('<f8',copy=False).tobytes()); memory_check()
        measured = {}
        for name,(l,t,r,b) in boxes.items():
            if reuse_metrics:
                # Only bounded scalar dictionaries survive; no shared memmap/field.
                # LSB errors below remain independently evaluated for each variant.
                de = copy.deepcopy(output['straight']['regions'][name]['deltaE2000'])
                ss = copy.deepcopy(output['straight']['regions'][name]['linearYSSIM'])
            else:
                de = exact_stats(de_path,(h,w),(l,t,r,b),scratch,variant+'-'+name+'-de')
                # Full-image neighborhoods; ROI selects centers, not cropped/filter-padded input.
                ss_box = (max(l,5)-5,max(t,5)-5,min(r,w-5)-5,min(b,h-5)-5)
                ss = exact_stats(ss_path,(h-10,w-10),ss_box,scratch,variant+'-'+name+'-ss')
            neutral = {'maxRGBA16LSB':max_error[name].tolist()}
            if variant == 'straight': neutral['p99RGBA16LSB'] = [histogram_quantile(x,.99) for x in hist[name]]
            else:
                # Continuous linear composite errors require actual exact p99, not rounded bins.
                p99 = []
                for channel in range(4):
                    field = scratch/(variant+'-error-'+str(channel))
                    with field.open('xb') as f:
                        for top in range(t,b,rows):
                            bottom = min(top+rows,b); a,bb = reference.read(top,bottom),candidate.read(top,bottom)
                            if channel == 3: err = np.abs(a[...,3].astype(np.float64)-bb[...,3])
                            else:
                                bg = 0 if variant == 'blackComposite' else 1
                                aa,ba = a[...,3].astype(np.float64)/65535,bb[...,3].astype(np.float64)/65535
                                ar,br = srgb_decode(a[...,channel].astype(np.float64)/65535),srgb_decode(bb[...,channel].astype(np.float64)/65535)
                                err = np.abs(ar*aa+bg*(1-aa)-br*ba-bg*(1-ba))*65535
                            f.write(err[:,l:r].astype('<f8',copy=False).tobytes())
                    p99.append(exact_stats(field,(b-t,r-l),(0,0,r-l,b-t),scratch,variant+'-'+name+'-err',(.99,))['p99']); field.unlink()
                neutral['p99RGBA16LSB'] = p99
            measured[name] = {'deltaE2000':de,'linearYSSIM':ss,'neutralErrors':neutral}
        output[variant] = {'regions':measured,'zeroAlphaPixelsEitherInput':zero_alpha_count if variant == 'straight' else None}
        if not reuse_metrics:
            de_path.unlink(); ss_path.unlink()
    verified_profile = all(not x.profile['status'].startswith('UNVERIFIED') for x in (reference,candidate))
    issues = []
    if not verified_profile: issues.append('sRGB identity unverified')
    if category == 'neutral':
        if reference.bits != 16 or candidate.bits != 16: issues.append('Neutral RGBA16 gate requires actual16-bit inputs')
        if reference.alpha != 'straight-RGBA' or candidate.alpha != 'straight-RGBA':
            issues.append('Full transparent straight-RGBA equivalence unverified: RGB-only/associated input cannot prove hidden straight RGB')
        if not any(alpha_coverage.values()): issues.append('No actual nonopaque pixels: opaque samples do not qualify transparent export equivalence')
        limit = protocol['quality']['neutralRoundtrip']
        checks = [max(v['neutralErrors']['maxRGBA16LSB']) <= limit['maxRGB16LSB'] and max(v['neutralErrors']['p99RGBA16LSB']) <= limit['p99RGB16LSB']
                  for x in output.values() for v in x['regions'].values()]
    else:
        limit = protocol['quality']['pointwiseTarget' if category == 'pointwise' else 'spatialTarget']
        checks = [v['deltaE2000']['p50'] <= limit['medianDeltaE2000'] and v['deltaE2000']['p95'] <= limit['p95DeltaE2000']
                  and (category != 'spatial' or (v['linearYSSIM']['status'] == 'measured' and v['linearYSSIM']['mean'] >= limit['luminanceSSIM']))
                  for x in output.values() for v in x['regions'].values()]
        # Color similarity must not conceal an alpha mismatch. These are the
        # already frozen neutral RGBA limits, not a new color tolerance.
        alpha_limit = protocol['quality']['neutralRoundtrip']
        checks.extend(v['neutralErrors']['maxRGBA16LSB'][3] <= alpha_limit['maxRGB16LSB']
                      and v['neutralErrors']['p99RGBA16LSB'][3] <= alpha_limit['p99RGB16LSB']
                      for v in output['straight']['regions'].values())
    return {'variants':output,'category':category,'alphaCoverage':alpha_coverage,
            'opaqueDeltaEAndSSIMReused':bool(any_metric_reuse), # Diagnostic only, never a verdict input.
            'premultipliedFinite':'Integer input normalized to[0,1]; straight RGB*alpha and both composites checked finite in float64',
            'qualification':'FAIL' if not all(checks) else ('UNVERIFIED' if issues else 'PASS'),
            'allMeasuredGatesPass':bool(all(checks)), 'unverified':issues,
            'interpretation':'Metrics compare these exact files only; self-comparison or synthetic PASS is not Photos effect qualification'}


def atomic_json(path, value):
    path = Path(path); require(not path.exists() and not path.is_symlink(), 'Output exists; refusing overwrite')
    with path.open('x') as f:
        json.dump(value,f,indent=2,allow_nan=False); f.write('\n'); f.flush(); os.fsync(f.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference',type=Path,required=True); parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--reference-sha256',help='Required frozen reference-file identity for actual qualification; not taken from candidate')
    parser.add_argument('--protocol',type=Path,required=True); parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--scratch-parent',type=Path,required=True)
    parser.add_argument('--category',choices=['neutral','pointwise','spatial','local','statistical','geometry'],required=True)
    parser.add_argument('--assume-srgb',action='store_true',help='Diagnostic only; forces UNVERIFIED without profile identity')
    parser.add_argument('--synthetic-diagnostic',action='store_true',help='Permit a tiny non-native canvas, always UNVERIFIED; never Photos qualification')
    args = parser.parse_args()
    require(not args.output.exists() and not args.output.is_symlink(),'Output must not exist')
    require(args.output.resolve() not in [args.reference.resolve(),args.candidate.resolve(),args.protocol.resolve()],'Output aliases input')
    if args.category in ('local','statistical','geometry'):
        atomic_json(args.output,{'status':'UNSUPPORTED','category':args.category,'qualification':'UNVERIFIED',
                                'reason':'Source masks/statistical/geometry replay interfaces not implemented; no generic PASS substituted'})
        return 2
    require(args.synthetic_diagnostic or (args.reference_sha256 is not None and len(args.reference_sha256) == 64
            and all(c in '0123456789abcdef' for c in args.reference_sha256)),
            'Actual comparison requires explicit pre-frozen --reference-sha256')
    protocol = json.loads(args.protocol.read_text())
    require(digest(args.protocol) == PROTOCOL_SHA,'Protocol identity differs from frozen021v2; no implicit gate changes')
    require(str(protocol.get('revision','')).startswith('2,'),'Requires frozen 021 protocol revision2')
    require(len(protocol['quality']['ROIs']) == 5, 'Requires fixed five ROIs')
    scratch = Path(tempfile.mkdtemp(prefix='adjustment-reference-',dir=args.scratch_parent))
    os.chmod(scratch,0o700)
    try:
        # Up to2 decoded RGBA16+two metrics+one quantile field, not RAM. Reserve conservatively.
        needed = 7*MAX_PIXELS*8 + 256*1024**2
        require(shutil.disk_usage(scratch).free >= needed,'Insufficient owned scratch space (about3.9GB worst case)')
        ref, cand = Raster(args.reference,scratch,'reference',args.assume_srgb),Raster(args.candidate,scratch,'candidate',args.assume_srgb)
        require((ref.before.st_dev,ref.before.st_ino) != (cand.before.st_dev,cand.before.st_ino),
                'Same physical input is a mathematical self-check, not an actual candidate/reference comparison')
        reference_info = ref.info()
        if args.reference_sha256 is not None:
            require(reference_info['sha256'] == args.reference_sha256,'Reference file differs from declared frozen identity')
        require(args.synthetic_diagnostic or [ref.width,ref.height] == protocol['references']['commonInput']['pixels'],
                'Native common-input canvas required; smaller proxy cannot qualify by comparing equal dimensions')
        report = compare(ref,cand,protocol,scratch,args.category)
        if args.synthetic_diagnostic:
            report['qualification'] = 'UNVERIFIED'
            report['unverified'].append('Explicit synthetic diagnostic, not actual Photos/reference effect acceptance')
        report.update({'reference':reference_info,'declaredFrozenReferenceSHA256':args.reference_sha256,'candidate':cand.info(),'protocol':{'path':str(args.protocol.resolve()),'sha256':digest(args.protocol)},
                       'toolSHA256':digest(Path(__file__)),'quantileMethod':'Exact linear order statistic; bounded row reads and disk-backed in-place partition',
                       'SSIM':'linearY normalized Gaussian11 sigma1.5 population/dataRange1/valid centers; ROI full-image neighborhoods',
                       'mathDtype':'float64 sRGB decode/XYZ/Lab/DE2000/SSIM/composites; input integers retain exact8/16-bit precision; disk metric float64',
                       'channelOrder':['R','G','B','A'],
                       'alphaSemantics':'straight RGB includes alpha0 hidden RGB; integer alpha reported separately. Associated input unpremultiplies only alpha>0 and cannot qualify hidden RGB at0. Black/white composites are linearRGB; all valid image pixels included.',
                       'DEValidation':{'source':DATA_URL,'testDataSHA256':DATA_SHA,'required34PairMaxError':5e-5,
                                       'note':'Run companion tiny test before qualification; source hash is not a runtime claim that tests ran'},
                       'sourceChangeChecks':'size/device/inode/mtime/ctime before decoding and after complete comparison; atime excluded',
                       'sampledProcessHighWaterBytes':memory_check(),'memoryBudgetBytes':MEMORY_LIMIT,
                       'scratchPolicy':'Exclusive0700 temporary directory; decoded files/metrics removed after result; inputs read-only'})
        ref.verify(); cand.verify(); atomic_json(args.output,report)
        return 0 if report['qualification'] == 'PASS' else 1
    finally:
        shutil.rmtree(scratch)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError,OSError,KeyError) as error:
        print(json.dumps({'status':'ERROR','qualification':'UNVERIFIED','error':str(error)}),file=sys.stderr)
        sys.exit(2)
