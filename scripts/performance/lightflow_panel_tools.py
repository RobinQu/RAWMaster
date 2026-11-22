"""Normal interactions with the stock Color Mixer and the stock CUBE file chooser."""

from datetime import datetime, timezone
import base64
import hashlib
from io import BytesIO
import json
from pathlib import Path
import platform
import tempfile
import time

from PIL import Image

from lightflow_gestures import center, mouse


CASES = ("mixer-hsl-mode", "mixer-eight-colors", "grading-lut-import")
COLORS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]


def show_panel(cdp, section, selector):
    return cdp.evaluate(
        """(async ([section, selector])=>{
      const app=window.__lightflow, photo=app.stores.catalog.get().active;
      const node=app.editOf(photo).grade.nodes.find(n=>n.kind==='corrector');
      app.stores.develop.set({target:{kind:'node',id:node.id}});
      app.develop.showSection(section);
      for (let i=0;i<100;i++) {
        if(document.querySelector(selector))return node.id;
        await new Promise(requestAnimationFrame);
      }
      throw Error('Missing panel '+selector);
    })("""
        + json.dumps([section, selector])
        + ")"
    )


def click(cdp, selector):
    x, y = center(cdp, selector)
    mouse(cdp, "mouseMoved", x, y)
    mouse(cdp, "mousePressed", x, y)
    mouse(cdp, "mouseReleased", x, y)


def observe_group(cdp, mode):
    cdp.evaluate(
        """(mode=>{
      const group=document.querySelector('lightflow-hsl[data-id="mixer.hsl"]');
      const selector='lightflow-hsl-group[data-prop="'+mode+'"] lightflow-slider';
      let start=null,up=false,complete;
      window.rawmasterMixerGroup=new Promise(done=>{complete=done});
      const down=e=>{if(e.isTrusted&&start===null)start=performance.now()};
      const release=e=>{if(e.isTrusted){up=true;queueMicrotask(check)}};
      function check(){
        if(!up||start===null||group.dataset.tab!==mode)return;
        const rows=[...group.querySelectorAll(selector)].map(el=>{
          const s=el.querySelector('[role=slider]');
          return {id:el.dataset.id,label:s.getAttribute('aria-label'),value:+s.getAttribute('aria-valuenow'),
            min:+s.getAttribute('aria-valuemin'),max:+s.getAttribute('aria-valuemax')};});
        if(rows.length!==8)return;
        finish({start,end:performance.now(),mode,rows});
      }
      function finish(value){
        clearTimeout(timer);watch.disconnect();document.removeEventListener('pointerdown',down,true);
        document.removeEventListener('pointerup',release,true);complete(value);
      }
      const watch=new MutationObserver(check);
      watch.observe(group,{subtree:true,childList:true,attributes:true});
      document.addEventListener('pointerdown',down,true);document.addEventListener('pointerup',release,true);
      const timer=setTimeout(()=>finish({error:'No eight-field update for '+mode}),3000);
    })("""
        + json.dumps(mode)
        + ")"
    )


def cube_asset(path, index):
    size = 17
    title = f"RAW benchmark {index:02d}"
    header = [f'TITLE "{title}"', f"LUT_3D_SIZE {size}", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
    rows = []
    for b in range(size):
        for g in range(size):
            for r in range(size):
                rgb = [r / (size - 1), g / (size - 1), b / (size - 1)]
                if index % 2:
                    rgb = [rgb[2], rgb[1], rgb[0]]
                rows.append(" ".join(f"{v:.6f}" for v in rgb))
    data = ("\n".join(header + rows) + "\n").encode()
    path.write_bytes(data)
    return title, hashlib.sha256(data).hexdigest(), len(data)


def photo_witness(cdp, photo):
    cdp.evaluate("window.__lightflow.waitForRender(5000)")
    x, y, w, h = photo
    blob = cdp.call(
        "Page.captureScreenshot",
        {
            "format": "png",
            "fromSurface": True,
            "clip": {"x": x, "y": y, "width": w, "height": h, "scale": 96 / w},
        },
    )["data"]
    with Image.open(BytesIO(base64.b64decode(blob))) as im:
        colors = im.convert("RGB")
        if colors.size != (96, 64):
            raise ValueError("Unexpected sampled photo region")
        return hashlib.sha256(colors.tobytes()).hexdigest()


def capture(cdp, session, args, driver):
    devtools, commit, geometry, set_zoom, view = driver
    if session.get("visible") or args.output.exists() or args.samples < 10:
        raise ValueError("A fresh background experiment requires 10+ samples")
    with args.raw.open("rb") as f:
        source = hashlib.file_digest(f, "sha256").hexdigest()
    if source != session["sourceSHA256"]:
        raise ValueError("Wrong RAW file")
    set_zoom(cdp, 2368)
    viewport, photo, _ = geometry(view(cdp))
    if view(cdp)["dpr"] != 1:
        raise ValueError("This inspector experiment requires DPR 1")
    output = {
        "schemaVersion": 1,
        "application": "LightFlow",
        "build": session["build"],
        "sourceSHA256": source,
        "uiSHA256": session["uiSHA256"],
        "browserBinarySHA256": session["browserBinarySHA256"],
        "system": platform.platform(),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "samples": args.samples,
        "protocol": "lightflow-editor-panel-actions-v1",
        "viewportPixels": viewport,
        "photoRectPixels": photo,
        "operations": [],
    }

    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, indent=2, allow_nan=False) + "\n")

    for key in args.operations or CASES:
        row = {"id": key, "featureIds": [key], "trials": [], "status": "inconclusive"}
        output["operations"].append(row)
        try:
            if key == "grading-lut-import":
                node = show_panel(cdp, "effects", '[data-id="effects.lutImport"]')
                chooser = devtools(session["tab"])
                chooser.call("Page.enable")
                chooser.call("Page.setInterceptFileChooserDialog", {"enabled": True})
                row["boundary"] = (
                    "Host submission of chosen .cube bytes via file input to observing the original editor recipe select its content-addressed asset. File chooser opening and photo observation are outside the timer."
                )
                seen = [set(), set()]
                try:
                    with tempfile.TemporaryDirectory(prefix="lf-stock-cubes-") as folder:
                        for i in range(args.samples + 2):
                            path = Path(folder) / f"Look-{i:02d}.cube"
                            title, digest, size = cube_asset(path, i)
                            wanted = "lut-" + digest[:24]
                            click(cdp, '[data-id="effects.lutImport"]')
                            while True:
                                msg = json.loads(chooser.ws.recv())
                                if msg.get("method") == "Page.fileChooserOpened":
                                    break
                            backend = msg["params"]["backendNodeId"]
                            started = time.monotonic_ns()
                            chooser.call(
                                "DOM.setFileInputFiles", {"files": [str(path)], "backendNodeId": backend}
                            )
                            found = cdp.evaluate(
                                """(async ([node,wanted])=>{
                              const app=window.__lightflow,p=app.stores.catalog.get().active;
                              for(let i=0;i<140;i++){
                                const lut=app.editOf(p).grade.nodes.find(n=>n.id===node).tools.effects?.lut;
                                if(lut?.asset===wanted)return lut;
                                await new Promise(requestAnimationFrame);
                              }
                              throw Error('The imported asset was not selected');
                            })("""
                                + json.dumps([node, wanted])
                                + ")"
                            )
                            elapsed = (time.monotonic_ns() - started) / 1_000_000
                            if found["name"] != title or found["asset"] != wanted:
                                raise ValueError("Imported CUBE did not match its file content")
                            pixels = photo_witness(cdp, photo)
                            seen[i % 2].add(pixels)
                            row["trials"].append(
                                dict(
                                    state=i % 2,
                                    phase="first" if i < 2 else "warm",
                                    ms=elapsed,
                                    sourceTableSize=17,
                                    sourceBytes=size,
                                    sourceCubeSHA256=digest,
                                    returned=found,
                                    digest=pixels,
                                    verified=True,
                                )
                            )
                finally:
                    chooser.call("Page.setInterceptFileChooserDialog", {"enabled": False})
                    chooser.ws.close()
                if any(len(group) != 1 for group in seen) or seen[0] == seen[1]:
                    raise ValueError("The two imported transforms did not produce repeatable distinct photos")
            else:
                node = show_panel(cdp, "mixer", 'lightflow-hsl[data-id="mixer.hsl"]')
                prop = '[aria-label="Mixer property"] [role="radio"]'
                click(cdp, prop + '[aria-label="Saturation"]')
                if key == "mixer-eight-colors":
                    click(cdp, prop + '[aria-label="Hue"]')
                row["boundary"] = (
                    "First trusted press to actual 8-property DOM rows after release"
                    if key == "mixer-hsl-mode"
                    else "Host submit of trusted Return on a prepared eight-band Hue number input to the stock node recipe and visible value"
                )
                for i in range(args.samples + 2):
                    state = i % 2
                    if key == "mixer-hsl-mode":
                        mode = ["hue", "sat"][state]
                        observe_group(cdp, mode)
                        click(cdp, prop + f'[aria-label="{["Hue", "Saturation"][state]}"]')
                        result = cdp.evaluate("window.rawmasterMixerGroup")
                        if "error" in result:
                            raise ValueError(result["error"])
                        ids = [field["id"] for field in result["rows"]]
                        if ids != [f"hsl-{mode}-{c}" for c in COLORS] or any(
                            (r["min"], r["max"]) != (-100, 100) for r in result["rows"]
                        ):
                            raise ValueError("Missing named hue bands or erroneous limits")
                        elapsed = result["end"] - result["start"]
                    else:
                        color = ["aqua", "magenta"][state]
                        loc = json.dumps(f'lightflow-slider[data-id="hsl-hue-{color}"]')
                        label = cdp.evaluate(
                            f"document.querySelector({loc}).querySelector('input').getAttribute('aria-label')"
                        )
                        read = (
                            """(node=>window.__lightflow.editOf(window.__lightflow.stores.catalog.get().active).grade.nodes.find(n=>n.id===node).tools.mixer?.hue || {})("""
                            + json.dumps(node)
                            + ")"
                        )
                        before = cdp.evaluate(read)
                        target = [36, -46][state]
                        if before.get(color, 0) == target:
                            commit(cdp, loc, label, 0)
                            before = cdp.evaluate(read)
                        answer = commit(cdp, loc, label, target)
                        got = cdp.evaluate(read)
                        end = time.monotonic_ns()
                        if (
                            not answer["accepted"]
                            or set(got) != set(COLORS)
                            or got[color] != target
                            or any(got[c] != before.get(c, 0) for c in COLORS if c != color)
                        ):
                            raise ValueError("The real HSL command failed to change only its selected band")
                        elapsed = (end - answer["sentNs"]) / 1_000_000
                        result = {
                            "color": color,
                            "before": before,
                            "after": got,
                            "actualFieldValue": answer["actual"],
                        }
                    row["trials"].append(
                        {
                            "state": state,
                            "phase": "first" if i < 2 else "warm",
                            "ms": elapsed,
                            "observed": result,
                            "verified": True,
                        }
                    )
            for trial in row["trials"]:
                if "observed" in trial:
                    observation = trial["observed"]
                    if key == "mixer-hsl-mode":
                        witness = {name: observation[name] for name in ["mode", "rows"]}
                    else:
                        channel = observation["color"]
                        witness = {"channel": channel, "value": observation["after"][channel]}
                    encoded = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
                    trial["digest"] = hashlib.sha256(encoded).hexdigest()
            state_digests = [{t["digest"] for t in row["trials"] if t["state"] == state} for state in (0, 1)]
            if any(len(digests) != 1 for digests in state_digests) or state_digests[0] == state_digests[1]:
                raise ValueError(
                    "The two requested actions did not produce distinct, repeatable observations"
                )
            row["status"] = "measured"
        except (ValueError, KeyError, RuntimeError, TimeoutError) as error:
            row["reason"] = str(error)
            for t in row["trials"]:
                t["verified"] = False
        save()
        print(key, row["status"], row.get("reason", ""), flush=True)
    with args.raw.open("rb") as f:
        output["sourceSHA256After"] = hashlib.file_digest(f, "sha256").hexdigest()
    if output["sourceSHA256After"] != source:
        raise ValueError("RAW source changed")
    save()
