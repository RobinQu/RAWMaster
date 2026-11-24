"""Produce an independently signed application and embedded App Sandbox XPC service."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess as sp
import tempfile

HERE = Path(__file__).resolve().parent


def run(args, **kwargs):
    return sp.run(args, check=True, **kwargs)


def sign(bundle, entitlements=None):
    opts = ["--entitlements", entitlements] if entitlements else []
    run(
        [
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--options",
            "runtime",
            *opts,
            bundle,
        ]
    )
    run(["/usr/bin/codesign", "--verify", "--strict", bundle])
    sig = run(
        ["/usr/bin/codesign", "-dvvv", bundle], capture_output=True, text=True
    ).stderr
    assert (
        "Signature=adhoc" in sig
        and "runtime" in re.search(r"^CodeDirectory .+$", sig, re.M)[0]
    )
    return re.search(r"^CDHash=([a-f0-9]{40})$", sig, re.M)[1]


def make_bundle(bundle, name, ident, kind, extra):
    exe = bundle / "Contents/MacOS" / name
    exe.parent.mkdir(parents=True, exist_ok=True)
    (bundle / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            dict(
                CFBundleExecutable=name,
                CFBundleName=name,
                CFBundleIdentifier=ident,
                CFBundlePackageType=kind,
                CFBundleVersion="1",
                CFBundleShortVersionString="1.0",
                **extra,
            )
        )
    )
    return exe


def build(out, core):
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    nonce = out / "build-identifier"
    if not nonce.exists():
        if any(out.iterdir()):
            raise ValueError("Use a new empty XPC fixture bundle directory")
        nonce.write_text(secrets.token_hex(6))
    if not re.fullmatch(r"[0-9a-f]{12}", nonce.read_text()):
        raise ValueError("Invalid generated fixture identifier")
    prefix = "org.rawmaster.fixture.aa." + nonce.read_text().strip()
    hid, sid = prefix + ".host", prefix + ".worker"
    app = out / "CatalogAuthority.app"
    alt = out / "OtherCaller.app"
    policy = out / "peer-policy.json"
    sub = Path("Contents/XPCServices") / (sid + ".xpc")
    service = app / sub
    h = make_bundle(app, "CatalogAuthority", hid, "APPL", {"LSBackgroundOnly": True})
    v = make_bundle(
        service,
        "CatalogWorker",
        sid,
        "XPC!",
        {"XPCService": {"ServiceType": "Application"}},
    )
    ent = out / "worker-entitlements.plist"
    ent.write_bytes(
        plistlib.dumps(
            {
                "com.apple.security.app-sandbox": True,
                "com.apple.security.temporary-exception.files.absolute-path.read-only": [
                    str(policy)
                ],
            }
        )
    )
    with tempfile.TemporaryDirectory(prefix="signing-", dir=out) as tmp:
        priv = Path(tmp) / "authority.pem"
        run(
            [
                "/usr/bin/openssl",
                "ecparam",
                "-genkey",
                "-name",
                "prime256v1",
                "-noout",
                "-out",
                priv,
            ]
        )
        key = run(
            ["/usr/bin/openssl", "ec", "-in", priv, "-pubout", "-outform", "DER"],
            capture_output=True,
        ).stdout
        pub = key[-65:]
        assert len(pub) == 65 and pub[0] == 4
        (out / "aa-config.h").write_text(
            "#define AA_HOST_ID "
            + json.dumps(hid)
            + "\n#define AA_SERVICE_ID "
            + json.dumps(sid)
            + "\n#define AA_POLICY "
            + json.dumps(str(policy))
            + "\n#define AA_PUBLIC_BYTES {"
            + ",".join(map(str, pub))
            + "}\n"
        )
        flags = [
            "xcrun",
            "clang",
            "-O1",
            "-fblocks",
            "-D_DARWIN_C_SOURCE",
            "-I",
            out,
            "-framework",
            "Foundation",
            "-framework",
            "Security",
        ]
        run([*flags, HERE / "service.m", core, "-liconv", "-o", v])
        run([*flags, HERE / "host.m", "-DAA_VARIANT=0", "-o", h])
        scd = sign(service, ent)
        hcd = sign(app)
        shutil.copytree(app, alt, dirs_exist_ok=True)
        av = alt / "Contents/MacOS/CatalogAuthority"
        run([*flags, HERE / "host.m", "-DAA_VARIANT=1", "-o", av])
        acd = sign(alt)
        assert hcd != acd and scd != hcd
        signed = run(
            ["/usr/bin/openssl", "dgst", "-sha256", "-sign", priv],
            input=f"RawMaster-AA peer\n{hid}\n{hcd}\n".encode(),
            capture_output=True,
        ).stdout
        if policy.exists():
            os.chmod(policy, 0o600)
        policy.write_text(
            json.dumps({"hash": hcd, "signature": base64.b64encode(signed).decode()})
            + "\n"
        )
        os.chmod(policy, 0o400)
    result = {
        "host": str(h),
        "otherHost": str(av),
        "worker": str(v),
        "hostID": hid,
        "workerID": sid,
        "hostCDHash": hcd,
        "otherHostCDHash": acd,
        "workerCDHash": scd,
        "workerEntitlements": plistlib.loads(ent.read_bytes()),
        "staticCoreSHA256": hashlib.file_digest(core.open("rb"), "sha256").hexdigest(),
        "workerSHA256": hashlib.file_digest(v.open("rb"), "sha256").hexdigest(),
        "authorityKeySHA256": hashlib.sha256(pub).hexdigest(),
    }
    (out / "subjects.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


if __name__ == "__main__":
    q = argparse.ArgumentParser()
    q.add_argument("--build-dir", type=Path, required=True)
    q.add_argument("--core-static", type=Path, required=True)
    a = q.parse_args()
    print(json.dumps(build(a.build_dir.resolve(), a.core_static.resolve())))
