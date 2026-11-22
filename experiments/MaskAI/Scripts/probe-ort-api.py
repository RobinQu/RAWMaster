import ctypes
from pathlib import Path

library = Path(__file__).resolve().parents[1] / "Vendor" / "ONNXRuntime" / "lib" / "libonnxruntime.1.27.0.dylib"
ort = ctypes.CDLL(str(library))

class ApiBase(ctypes.Structure):
    _fields_ = [
        ("get_api", ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_uint32)),
        ("get_version", ctypes.CFUNCTYPE(ctypes.c_char_p)),
    ]

ort.OrtGetApiBase.restype = ctypes.POINTER(ApiBase)
base = ort.OrtGetApiBase().contents
print("Runtime:", base.get_version().decode())
supported = [version for version in range(1, 34) if base.get_api(version)]
print("Supported API versions:", supported)
print("Maximum supported API:", max(supported))
