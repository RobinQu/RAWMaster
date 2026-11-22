#!/usr/bin/env python3
"""Qualify nagadomi's trained native photographic 2× upconvolution on a FlashRaw RGBF16 source."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import resource
import sys
import threading
from time import perf_counter

import coremltools as ct
from coremltools.converters.mil import Builder as mb
import numpy as np


REVISION = "cc385f97a9debfe611316aabfd5d8bb30ba2dbeb"
PIN = "deb2c288f635bed4a0ffc0be9ca8f6a735233b530ad5b2c392c5b2e6c5fe30ad"


def sha(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda:stream.read(1 << 20), b""):
            digest.update(block)
        return digest.hexdigest()


def load_model(weights, side, store, units):
    file = store / f"PhotoUpconv7_{side}_{PIN[:12]}_F32.mlpackage"
    if not file.exists():
        store.mkdir(exist_ok=True, parents=True)
        @mb.program(input_specs=[mb.TensorSpec(shape=(1,3,side+14,side+14))],opset_version=ct.target.macOS13)
        def network(image):
            v = image
            for layer in weights[:-1]:
                v = mb.conv(x=v,weight=np.asarray(layer["weight"],dtype=np.float32),
                            bias=np.asarray(layer["bias"],dtype=np.float32),pad_type="valid")
                v = mb.leaky_relu(x=v,alpha=.1)
            tail = weights[-1]
            v = mb.conv_transpose(x=v,weight=np.asarray(tail["weight"],dtype=np.float32),
                bias=np.asarray(tail["bias"],dtype=np.float32),strides=[2,2],pad_type="custom",pad=[3,3,3,3])
            return mb.clip(x=v,alpha=0.,beta=1.,name="upscaled")
        compiled = ct.convert(network,convert_to="mlprogram",compute_precision=ct.precision.FLOAT32,skip_model_load=True)
        compiled.author = "nagadomi. Converted by RAWMaster."
        compiled.license = "MIT"
        compiled.user_defined_metadata["checkpoint_sha256"] = PIN
        compiled.save(str(file))
    return ct.models.MLModel(str(file),compute_units=units)


def srgb(x):
    return np.where(x <= .0031308,12.92*x,1.055*np.maximum(x,0)**(1/2.4)-.055).astype(np.float32)


def linear(x):
    return np.where(x <= .04045,x/12.92,((x+.055)/1.055)**2.4).astype(np.float32)


def tile(model, source, x, y, side, low, high):
    h,w = source.shape[:2]
    ys = np.clip(np.arange(y-7,y+side+7),0,h-1)
    xs = np.clip(np.arange(x-7,x+side+7),0,w-1)
    patch = source[np.ix_(ys,xs)].astype(np.float32)
    # One scale for the entire image. Each tile, highlight and shadow shares the same trained input domain.
    encoded = srgb(np.clip((patch-low)/(high-low),0,1))
    output = model.predict({"image":encoded.transpose(2,0,1)[None].copy()})["upscaled"][0].transpose(1,2,0)
    if output.shape != (2*side,2*side,3):
        raise ValueError("Invalid model scale or phase")
    decoded = linear(output)*(high-low)+low
    cells = decoded.reshape(side,2,side,2,3)
    # Keep the three measured native channel means. The model supplies all four subpixel
    # deviations within the cell. This maintains source exposure and extended linear values.
    center = patch[7:-7,7:-7]
    detail = cells - cells.mean(axis=(1,3))[:,None,:,None,:]
    # Transpose-convolution can produce a slight four-position texture even in a perfectly
    # uniform field. Limit the zero-mean prediction to the genuine local source envelope.
    lower,upper = center.copy(),center.copy()
    for oy in range(-1,2):
        for ox in range(-1,2):
            neighbor=patch[7+oy:7+oy+side,7+ox:7+ox+side]
            np.minimum(lower,neighbor,out=lower); np.maximum(upper,neighbor,out=upper)
    gain = np.ones_like(center)
    for room,extreme in [(upper-center,detail.max(axis=(1,3))),(center-lower,-detail.min(axis=(1,3)))]:
        ratio=np.ones_like(center)
        np.divide(room,extreme,out=ratio,where=extreme>0)
        np.minimum(gain,ratio,out=gain)
    cells[:] = center[:,None,:,None,:] + detail*gain[:,None,:,None,:]
    return decoded[:2*min(side,h-y),:2*min(side,w-x)]


def bilinear(source):
    h,w = source.shape[:2]
    ys = (np.arange(2*h)+.5)/2-.5
    xs = (np.arange(2*w)+.5)/2-.5
    x0,y0 = np.floor(xs).astype(int),np.floor(ys).astype(int)
    dx,dy=(xs-x0)[None,:,None],(ys-y0)[:,None,None]
    def grid(ix,iy): return source[np.ix_(np.clip(iy,0,h-1),np.clip(ix,0,w-1))]
    return (1-dy)*((1-dx)*grid(x0,y0)+dx*grid(x0+1,y0))+dy*((1-dx)*grid(x0,y0+1)+dx*grid(x0+1,y0+1))


def measures(a,b):
    diff=np.abs(a-b)
    return {"mean":float(diff.mean()),"p95":float(np.quantile(diff,.95)),"maximum":float(diff.max())}

def sample_metal_allocation(stop, peak):
    metal=ctypes.CDLL("/System/Library/Frameworks/Metal.framework/Metal")
    objc=ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    metal.MTLCreateSystemDefaultDevice.restype=ctypes.c_void_p
    objc.sel_registerName.argtypes=[ctypes.c_char_p];objc.sel_registerName.restype=ctypes.c_void_p
    objc.objc_msgSend.argtypes=[ctypes.c_void_p,ctypes.c_void_p];objc.objc_msgSend.restype=ctypes.c_uint64
    device=metal.MTLCreateSystemDefaultDevice()
    selector=objc.sel_registerName(b"currentAllocatedSize")
    while not stop.is_set():
        peak[0]=max(peak[0],objc.objc_msgSend(device,selector))
        stop.wait(.05)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights",type=Path,required=True)
    parser.add_argument("--raw",type=Path,required=True)
    parser.add_argument("--plane",type=Path,required=True,help="Upright FlashRaw linear RGBF16, row-major")
    parser.add_argument("--width",type=int,required=True)
    parser.add_argument("--height",type=int,required=True)
    parser.add_argument("--model-cache",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--full-tiff",type=Path,help="Optional complete source-linear FP16 TIFF for round-trip verification")
    parser.add_argument("--full-side",type=int,default=192)
    parser.add_argument("--compute",choices=["cpu","cpu-gpu"],default="cpu")
    args=parser.parse_args()
    if args.output.exists() or (args.full_tiff and args.full_tiff.exists()):
        sys.exit("Use unused output paths")
    if sha(args.weights)!=PIN or args.plane.stat().st_size!=args.width*args.height*6:
        sys.exit("Wrong weights or source plane")
    weights=json.loads(args.weights.read_bytes())
    units=ct.ComputeUnit.CPU_ONLY if args.compute=="cpu" else ct.ComputeUnit.CPU_AND_GPU
    stop=threading.Event();peak=[0]
    sampler=threading.Thread(target=sample_metal_allocation,args=(stop,peak),daemon=True)
    sampler.start()
    src=np.memmap(args.plane,dtype="<f2",shape=(args.height,args.width,3),mode="r")
    low,high=float(src.min()),float(src.max())
    if not np.isfinite(low+high) or high<=low:sys.exit("Invalid source range")
    origin=(args.width//2-64,args.height//2-64)
    x,y=origin
    t=perf_counter()
    small=load_model(weights,64,args.model_cache,units); large=load_model(weights,128,args.model_cache,units)
    whole=tile(large,src,x,y,128,low,high)
    stitched=np.vstack([np.hstack([tile(small,src,x+dx,y+dy,64,low,high) for dx in [0,64]]) for dy in [0,64]])
    patch=src[y:y+128,x:x+128].astype(np.float32)
    recovered=whole.reshape(128,2,128,2,3).mean((1,3))
    inside=np.s_[4:-4,4:-4]
    report={"model":"waifu2x upconv_7/photo/scale2.0x_model, native 2×","upstream":REVISION,
            "sourceWeightsSHA256":PIN,"license":"MIT (author confirmation for weights)",
            "rawSHA256":sha(args.raw),"linearPlaneSHA256":sha(args.plane),"sourceWidth":args.width,"sourceHeight":args.height,
            "sourceLinearRange":[low,high],"nativeROI":[x,y,128,128],"modelOutput":[256,256],
            "computeUnits":args.compute,"upstreamWeights":"FP32 legible JSON","colorPolicy":"globally mapped display RGB in; 2x2 mean anchored to each native linear channel; details bounded by its local 3x3 source range",
            "interiorVsBilinear":measures(whole[inside],bilinear(patch)[inside]),
            "tiledVsWhole":measures(stitched,whole),"recoveredNativeVsSource":measures(recovered,patch),
            "probeElapsedS":perf_counter()-t}
    controls=[]
    for value in [low,0.,.18,.5,1.,high]:
        chart=np.full((64,64,3),value,np.float32)
        restored=tile(small,chart,0,0,64,low,high)
        controls.append({"input":value,"mean":float(restored.mean()),"centerMinMax":[float(restored[8:-8,8:-8].min()),float(restored[8:-8,8:-8].max())]})
    report["uniformControls"]=controls
    chart=np.zeros((64,64,3),np.float32)
    chart[:]=[-.002,.005,.18];chart[31,43]=[high,.69,.27]
    impulse=tile(small,chart,0,0,64,low,high)
    bright=np.argwhere(impulse[...,0]>=high-1e-6)
    report["asymmetricImpulse"]={"sourceXY":[43,31],"sourceRGB":chart[31,43].tolist(),
        "brightOutputXY":[[int(px),int(py)] for py,px in bright],
        "minMax":[float(impulse.min()),float(impulse.max())]}
    if set(map(tuple,report["asymmetricImpulse"]["brightOutputXY"]))!={(86,62),(87,62),(86,63),(87,63)}:
        raise ValueError("Upsampling changed the asymmetric source coordinate")
    if args.full_tiff:
        import tifffile
        side=args.full_side
        predictor=load_model(weights,side,args.model_cache,units)
        width,height=2*args.width,2*args.height
        out=tifffile.memmap(args.full_tiff,shape=(height,width,3),dtype="<f2",photometric="rgb",
            metadata=None,description="Extended linear sRGB. IEEE binary16 channels. Trained native 2x photographic upconvolution.")
        began=perf_counter()
        for row in range(0,args.height,side):
            for col in range(0,args.width,side):
                values=tile(predictor,src,col,row,side,low,high)
                out[2*row:2*row+values.shape[0],2*col:2*col+values.shape[1]]=values
        out.flush(); del out
        elapsed=perf_counter()-began
        reread=tifffile.memmap(args.full_tiff,mode="r")
        if reread.shape!=(height,width,3) or reread.dtype!=np.float16:raise ValueError("Full TIFF is not native FP16 RGB")
        nativeError=0.; extMin=np.inf;extMax=-np.inf
        for iy in range(0,args.height,32):
            n=min(32,args.height-iy)
            strip=reread[2*iy:2*(iy+n)].astype(np.float32)
            nativeError=max(nativeError,float(abs(strip.reshape(n,2,args.width,2,3).mean((1,3))-src[iy:iy+n]).max()))
            extMin=min(extMin,float(strip.min()));extMax=max(extMax,float(strip.max()))
        report["fullDiagnosticFloatTIFF"]={"width":width,"height":height,"bitsPerChannel":16,"sampleFormat":"IEEEFP",
            "byteCount":args.full_tiff.stat().st_size,"sha256":sha(args.full_tiff),"fullInferenceAndWriteS":elapsed,
            "decodedRange":[extMin,extMax],"allNativeBlockMeansMaxErrorAfterFP16Write":nativeError}
    report["maxRSSBytes"]=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    stop.set();sampler.join()
    report["peakMetalAllocationSampledBytes"]=peak[0]
    report["metalAllocationBoundary"]="Public per-process MTLDevice.currentAllocatedSize sampled every 50 ms; Core ML service allocations may live elsewhere"
    args.output.write_text(json.dumps(report,indent=2,allow_nan=False)+"\n")
