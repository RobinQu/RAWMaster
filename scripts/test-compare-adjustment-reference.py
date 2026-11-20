#!/usr/bin/env python3
"""Small CPU-only independent test fixtures; does not qualify any Photos effect."""
import importlib.util
import io
import json
import copy
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

import numpy as np
from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('adjustment_compare',ROOT/'scripts/compare-adjustment-reference.py')
m = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(m)
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()


def png(path, pixels, bits=16, filters=False):
    h,w,c = pixels.shape
    def chunk(kind, data):
        import binascii
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',binascii.crc32(kind+data)&0xffffffff)
    rows = bytearray(); previous = bytes(w*c*(bits//8)); bpp = c*(bits//8)
    for index,row in enumerate(pixels):
        raw = row.astype('>u2' if bits == 16 else 'u1').tobytes(); mode = index%5 if filters else 0
        filtered = bytearray(len(raw))
        for j,x in enumerate(raw):
            a,b,cc = raw[j-bpp] if j>=bpp else 0,previous[j],previous[j-bpp] if j>=bpp else 0
            if mode == 0: prediction = 0
            elif mode == 1: prediction = a
            elif mode == 2: prediction = b
            elif mode == 3: prediction = (a+b)//2
            else:
                p = a+b-cc; pa,pb,pc = abs(p-a),abs(p-b),abs(p-cc)
                prediction = a if pa<=pb and pa<=pc else (b if pb<=pc else cc)
            filtered[j] = (x-prediction)&255
        rows.extend(bytes([mode])+filtered); previous = raw
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,bits,6 if c==4 else 2,0,0,0))
                     +chunk(b'sRGB',b'\0')+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))


def tiff(path, pixels, endian='<', predictor=False):
    h,w,c = pixels.shape; bits = 16 if pixels.dtype.itemsize == 2 else 8
    fields = [(256,4,[w]),(257,4,[h]),(258,3,[bits]*c),(259,3,[1]),(262,3,[2]),
              (273,4,[0]),(274,3,[1]),(277,3,[c]),(278,4,[h]),(279,4,[h*w*c*(bits//8)]),(284,3,[1]),
              (317,3,[2 if predictor else 1]),(34675,7,ICC)]
    if c == 4: fields.append((338,3,[2]))
    fields.sort(); extra = bytearray(); base = 8+2+12*len(fields)+4
    entries = []
    for tag,kind,values in fields:
        data = values if kind == 7 else struct.pack(endian+str(len(values))+('H' if kind==3 else 'I'),*values)
        if len(data) > 4:
            value = struct.pack(endian+'I',base+len(extra)); extra.extend(data)
        else: value = data.ljust(4,b'\0')
        entries.append([tag,kind,len(data) if kind==7 else len(values),value])
    pixel_offset = base+len(extra)
    for entry in entries:
        if entry[0] == 273: entry[3] = struct.pack(endian+'I',pixel_offset)
    data = pixels.copy()
    if predictor:
        data[:,1:] = (pixels[:,1:].astype(np.int32)-pixels[:,:-1].astype(np.int32)).astype(pixels.dtype)
    header = (b'II' if endian=='<' else b'MM')+struct.pack(endian+'HI',42,8)
    path.write_bytes(header+struct.pack(endian+'H',len(entries))
                     +b''.join(struct.pack(endian+'HHI',tag,kind,n)+value for tag,kind,n,value in entries)
                     +struct.pack(endian+'I',0)+extra+data.astype(endian+('u2' if bits==16 else 'u1')).tobytes())


class ComparisonTests(unittest.TestCase):
    def test_34_original_author_pairs(self):
        path = ROOT/'output/validation/021-photos-editor/metric-tool/ciede2000testdata.txt'
        self.assertEqual(m.digest(path),m.DATA_SHA)
        values = np.loadtxt(path); self.assertEqual(values.shape,(34,7))
        error = np.abs(m.ciede2000(values[:,:3],values[:,3:6])-values[:,6])
        self.assertLess(float(error.max()),5e-5)
        self.pair_max_error = float(error.max())

    def test_11x11_identity_and_population_definition(self):
        x = np.arange(121,dtype=np.float64).reshape(11,11)/120
        np.testing.assert_allclose(m.ssim_valid(x,x),[[1]],rtol=0,atol=1e-14)
        y = x*.8
        weights = np.outer(m.GAUSS,m.GAUSS)
        mx,my = (x*weights).sum(),(y*weights).sum()
        vx,vy = (x*x*weights).sum()-mx*mx,(y*y*weights).sum()-my*my
        cov = (x*y*weights).sum()-mx*my
        expected = (2*mx*my+.01**2)*(2*cov+.03**2)/((mx*mx+my*my+.01**2)*(vx+vy+.03**2))
        self.assertAlmostEqual(float(m.ssim_valid(x,y)[0,0]),expected,places=14)

    def test_d65_gray_and_profile_parameters_not_description(self):
        lab = m.lab_from_linear(np.array([[1.,1.,1.],[0.,0.,0.]]))
        np.testing.assert_allclose(lab,[[100,0,0],[0,0,0]],atol=2e-5)
        info = m.profile_info(ICC)
        self.assertIn('recognition',info)
        bad = bytearray(ICC)
        n = struct.unpack('>I',bad[128:132])[0]
        for i in range(n):
            tag,offset,size = struct.unpack('>4sII',bad[132+i*12:144+i*12])
            if tag == b'rXYZ':
                bad[offset+8:offset+12] = struct.pack('>i',int(.9*65536)); break
        with self.assertRaises(ValueError): m.profile_info(bytes(bad))

    def test_exact_legacy_v2_identity_and_every_byte_position_mutation_rejected(self):
        path = ROOT/'output/validation/021-photos-editor/metric-tool/legacy-srgb-v2-2b3aa164.icc'
        data = path.read_bytes()
        self.assertEqual(m.digest(path),m.LEGACY_SRGB_V2_SHA)
        info = m.profile_info(data)
        self.assertTrue(info['recognition']['legacyExactIdentity'])
        self.assertEqual(info['recognition']['matrixWhiteTolerance'],.0006)
        self.assertEqual(info['recognition']['TRCTolerance'],.0001)
        self.assertGreater(info['recognition']['D50WhiteMaxAbsError'],.2)
        # One bit at every3144 byte positions, covering header/descriptions,
        # colorants/TRCs and unused padding. SHA identity covers other byte values.
        for i in range(len(data)):
            bad = bytearray(data); bad[i] ^= 1
            with self.subTest(byte=i),self.assertRaises(ValueError):
                m.profile_info(bytes(bad))
        # The existing standard-D50 branch remains independent of this exception.
        self.assertFalse(m.profile_info(ICC)['recognition']['legacyExactIdentity'])
        unknown_d65 = bytearray(ICC)
        for i in range(struct.unpack('>I',ICC[128:132])[0]):
            tag,offset,size = struct.unpack('>4sII',ICC[132+i*12:144+i*12])
            if tag == b'wtpt': unknown_d65[offset+8:offset+20] = struct.pack('>3i',62289,65536,71372)
        with self.assertRaises(ValueError): m.profile_info(bytes(unknown_d65))

    def test_tiff16_and_png16_do_not_round_257_to_8bit(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            pixels = (np.arange(17*19*4,dtype=np.uint16).reshape(17,19,4)*31) % 65535
            pixels[...,3] = np.arange(17*19,dtype=np.uint16).reshape(17,19)*173
            for name,endian,predictor in [('a','<',False),('b','>',False),('c','<',True),('d','>',True)]:
                file = p/(name+'.tif'); tiff(file,pixels,endian,predictor)
                raster = m.Raster(file,p,name)
                self.assertEqual(raster.bits,16); np.testing.assert_array_equal(raster.read(0,17),pixels)
            png(p/'a.png',pixels,filters=True)
            raster = m.Raster(p/'a.png',p,'png')
            np.testing.assert_array_equal(raster.read(0,17),pixels)

    def test_unsupported_precision_or_profile_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); pixels = np.zeros((13,17,4),dtype=np.uint16)
            png(p/'a.png',pixels)
            data = bytearray((p/'a.png').read_bytes()); data[-1] ^= 1; (p/'bad.png').write_bytes(data)
            with self.assertRaises(ValueError): m.Raster(p/'bad.png',p,'bad')
            with self.assertRaises(m.Unsupported): m.profile_info(None)
            self.assertTrue(m.profile_info(None,assume=True)['status'].startswith('UNVERIFIED'))

    def test_png8_exact_expansion_and_filters(self):
        rng = np.random.default_rng(42)
        pixels = rng.integers(0,256,(19,23,4),dtype=np.uint8)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            file = p/'a.png'; Image.fromarray(pixels).save(file,icc_profile=ICC)
            raster = m.Raster(file,p,'png')
            self.assertEqual(raster.bits,8)
            np.testing.assert_array_equal(raster.read(0,19),pixels.astype(np.uint16)*257)

    def test_lzw_16bit_against_actual_pillow_encoded_strip(self):
        # Pillow's TIFF encoder supplies an independent LZW bitstream, but its
        # pixel decoder is never used as the production RGB16 read path.
        pixels = np.random.default_rng(9).integers(0,65536,(32,64),dtype=np.uint16)
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp)/'gray-lzw.tif'; Image.fromarray(pixels).save(file,compression='tiff_lzw')
            with Image.open(file) as image:
                offset,length = image.tag_v2[273][0],image.tag_v2[279][0]
            with file.open('rb') as f: f.seek(offset); data = f.read(length)
            raw = m.lzw_decode(data,pixels.nbytes)
            np.testing.assert_array_equal(np.frombuffer(raw,dtype='<u2').reshape(pixels.shape),pixels)

    def test_exact_quantiles_and_roi_ssim_full_neighborhood(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); a = np.arange(17*19,dtype=np.float64).reshape(17,19)
            file = p/'metric'; a.tofile(file)
            result = m.exact_stats(file,a.shape,(2,3,17,13),p,'q',(.5,.95,.99))
            for q in (.5,.95,.99): self.assertEqual(result['p'+str(int(q*100))],float(np.quantile(a[3:13,2:17],q)))
            x = a/a.max(); score = m.ssim_valid(x,x*.9)
            ss = p/'ss'; score.tofile(ss)
            # ROI x[6:9],y[6:10] picks centers from globally evaluated windows.
            measured = m.exact_stats(ss,score.shape,(1,1,4,5),p,'ssq')
            self.assertAlmostEqual(measured['mean'],float(score[1:5,1:4].mean()),places=14)

    def test_neutral_transparent_and_hidden_rgb_fail_not_masked(self):
        protocol = json.loads((ROOT/'output/validation/021-photos-editor/reference-protocol.json').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); y,x = np.mgrid[:13,:17]
            pixels = np.zeros((13,17,4),dtype=np.uint16)
            pixels[...,:3] = ((x+y)*1500)[...,None]
            pixels[...,3] = 65535; pixels[0,0,3] = 0; pixels[2,3,3] = 32768
            png(p/'a.png',pixels); png(p/'b.png',pixels)
            a,b = m.Raster(p/'a.png',p,'a'),m.Raster(p/'b.png',p,'b')
            result = m.compare(a,b,protocol,p,'neutral',rows=3)
            self.assertEqual(result['qualification'],'PASS')
            self.assertEqual(result['alphaCoverage']['referenceZero'],1)
            altered = pixels.copy(); altered[0,0,0] += 3; png(p/'c.png',altered)
            c = m.Raster(p/'c.png',p,'c')
            result = m.compare(a,c,protocol,p,'neutral',rows=4)
            self.assertEqual(result['qualification'],'FAIL')
            self.assertEqual(result['variants']['straight']['regions']['whole']['neutralErrors']['maxRGBA16LSB'][0],3)
            self.assertEqual(result['variants']['blackComposite']['regions']['whole']['neutralErrors']['maxRGBA16LSB'][0],0)

    def test_opaque_reuse_full_output_metrics_equal_original_and_last_pixel_fallback(self):
        protocol = json.loads((ROOT/'output/validation/021-photos-editor/reference-protocol.json').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); rng = np.random.default_rng(211)
            first = rng.integers(0,65536,(21,29,4),dtype=np.uint16)
            second = rng.integers(0,65536,(21,29,4),dtype=np.uint16)
            first[...,3] = second[...,3] = 65535
            first[1,1,:3] = 10000; second[1,1,:3] = 10032
            png(p/'a.png',first); png(p/'b.png',second)
            a,b = m.Raster(p/'a.png',p,'a'),m.Raster(p/'b.png',p,'b')
            original = m.compare(a,b,protocol,p,'neutral',rows=4,reuse_opaque_metrics=False)
            reused = m.compare(a,b,protocol,p,'neutral',rows=4)
            self.assertFalse(original['opaqueDeltaEAndSSIMReused'])
            self.assertTrue(reused['opaqueDeltaEAndSSIMReused'])
            def metrics_only(value):
                result = copy.deepcopy(value); result.pop('opaqueDeltaEAndSSIMReused'); return result
            self.assertEqual(metrics_only(original),metrics_only(reused))
            # Encoding-domain LSB values are not aliased to the linear composites.
            region = reused['variants']
            self.assertNotEqual(region['straight']['regions']['whole']['neutralErrors'],
                                region['blackComposite']['regions']['whole']['neutralErrors'])
            self.assertFalse(any(p.glob('*.de'))); self.assertFalse(any(p.glob('*.ssim')))
            for side in ('reference','candidate'):
                # Last pixel lies outside all five namedROIs; full alpha scan matters.
                aa,bb = first.copy(),second.copy()
                (aa if side == 'reference' else bb)[-1,-1,3] = 65534
                png(p/(side+'-a.png'),aa); png(p/(side+'-b.png'),bb)
                ar = m.Raster(p/(side+'-a.png'),p,side+'a')
                br = m.Raster(p/(side+'-b.png'),p,side+'b')
                slow = m.compare(ar,br,protocol,p,'neutral',rows=5,reuse_opaque_metrics=False)
                fallback = m.compare(ar,br,protocol,p,'neutral',rows=5)
                self.assertFalse(fallback['opaqueDeltaEAndSSIMReused'])
                self.assertEqual(metrics_only(slow),metrics_only(fallback))


if __name__ == '__main__':
    unittest.main()
