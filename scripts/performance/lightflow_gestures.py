"""Trusted input on the stock editor, observed through its original controls and recipe."""

from datetime import datetime, timezone
import hashlib
import json
import platform


CASES = {
    "light-numeric-reset": "Double-click the original Exposure label from +1.25 / −1.75 EV",
    "light-auto-single": "Shift-double-click the original Exposure label from +1.25 / −1.75 EV",
    "light-histogram-drag": "Drag the center histogram exposure zone +24 / −24 CSS pixels from zero exposure",
    "color-wb-picker": "Use the W tool at source coordinates (0.29,0.31) / (0.73,0.69) from 5500 K and +16 tint",
}


def mouse(cdp, kind, x, y, *, count=1, shift=False, pressed=False):
    held = pressed or kind == "mousePressed"
    cdp.call(
        "Input.dispatchMouseEvent",
        {
            "type": kind,
            "x": x,
            "y": y,
            "button": "left" if held or kind == "mouseReleased" else "none",
            "buttons": int(held),
            "clickCount": count,
            "modifiers": 8 if shift else 0,
            "pointerType": "mouse",
        },
    )


def center(cdp, selector):
    return cdp.evaluate(
        """(selector=>{
      const element=document.querySelector(selector);
      if (!element) throw Error('Missing surface '+selector);
      element.scrollIntoView({block:'nearest'});
      const b=element.getBoundingClientRect();
      if (!(b.width>0 && b.height>0)) throw Error('Hidden surface '+selector);
      return [b.x+b.width/2,b.y+b.height/2];
    })("""
        + json.dumps(selector)
        + ")"
    )


def observe(cdp, fields, releases, timeout=3500):
    # Both endpoints come from the page's monotonic clock. The test observer reads
    # the real DOM and normal app state, and has no setter for the editor's values.
    return cdp.evaluate(
        """(([fields, releases, timeout])=>{
      const app=window.__lightflow, who=app.stores.catalog.get().active;
      const element=k=>document.querySelector('lightflow-slider[data-id="base.'+k+'"] [role=slider]');
      const recipe=()=>app.editOf(who).base;
      const read=()=>Object.fromEntries(fields.map(k=>[k,Number(element(k)?.getAttribute('aria-valuenow'))]));
      if (fields.some(k=>!element(k))) throw Error('Expected stock fields '+fields);
      const before=read(), original=recipe(), initial=Object.fromEntries(fields.map(k=>[k,original[k]]));
      let start=null, count=0, resolve, finished=false, first=null;
      window.rawmasterGestureResult=new Promise(done=>{resolve=done});
      const scope=document.querySelector('lightflow-app') || document.body;
      function stop(result) {
        if (finished) return;
        finished=true;clearTimeout(timer);observer.disconnect();
        document.removeEventListener('pointerdown', down, true);
        document.removeEventListener('pointerup', up, true);
        resolve(result);
      }
      function down(event) {
        if (event.isTrusted && start===null) {start=performance.now();first={x:event.clientX,y:event.clientY};}
      }
      function up(event) {
        if (!event.isTrusted) return;count++;queueMicrotask(check);
      }
      function check() {
        if (start===null || count<releases) return;
        const after=read(), committed=recipe();
        if (fields.every(k=>Number.isFinite(after[k]) && Math.abs(after[k]-committed[k])<0.0051) &&
            fields.some(k=>Math.abs(after[k]-before[k])>0.005)) {
          const end=performance.now();
          stop({start,end,ms:end-start,before,after,initial,first,releaseCount:count,
            committed:Object.fromEntries(fields.map(k=>[k,committed[k]])),wbMode:committed.wbMode});
        }
      }
      const observer=new MutationObserver(check);
      observer.observe(scope,{attributes:true,attributeFilter:['aria-valuenow'],subtree:true});
      document.addEventListener('pointerdown',down,true);document.addEventListener('pointerup',up,true);
      const timer=setTimeout(()=>stop({error:'Timed out waiting for release and changed stock fields',before,
        latest:read(),base:recipe(),releaseCount:count,start}),timeout);
      return before;
    })("""
        + json.dumps([fields, releases, timeout])
        + ")"
    )


def capture(cdp, session, args, driver):
    select, commit, geometry, set_zoom, view = driver
    if session.get("visible") or args.samples < 10 or args.output.exists():
        raise ValueError("A windowless session, ten or more observations, and a new output path are required")
    with args.raw.open("rb") as stream:
        source = hashlib.file_digest(stream, "sha256").hexdigest()
    if source != session["sourceSHA256"]:
        raise ValueError("Editor RAW and requested RAW differ")
    set_zoom(cdp, 2368)
    viewport, photo, _ = geometry(view(cdp))
    result = {
        "schemaVersion": 1,
        "application": "LightFlow",
        "build": session["build"],
        "sourceSHA256": source,
        "uiSHA256": session["uiSHA256"],
        "browserBinarySHA256": session["browserBinarySHA256"],
        "protocol": "lightflow-ui-gesture-value-v1",
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "system": platform.platform(),
        "viewportPixels": viewport,
        "photoRectPixels": photo,
        "devicePixelRatio": view(cdp)["dpr"],
        "samples": args.samples,
        "operations": [],
        "boundary": "Trusted first pointerdown capture to released gesture and changed visible control values matching the original editor recipe, page performance.now().",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")

    for key in args.operations or list(CASES):
        row = {"id": key, "featureIds": [key], "input": CASES[key], "status": "inconclusive", "trials": []}
        result["operations"].append(row)
        try:
            wb = key == "color-wb-picker"
            fields = ["temperature", "tint"] if wb else ["exposure"]
            controls = {field: select(cdp, "base", field) for field in fields}
            states = [set(), set()]
            for i in range(args.samples + 2):
                state = i % 2
                initial = (
                    [5500, 16] if wb else [0] if key == "light-histogram-drag" else [[1.25, -1.75][state]]
                )
                for field, value in zip(fields, initial):
                    loc, control = controls[field]
                    answer = commit(cdp, loc, control["label"], value)
                    if not answer["accepted"]:
                        raise ValueError(f"Original {field} rejected {value}: {answer['actual']}")
                if wb:
                    cdp.evaluate("document.activeElement.blur()")
                    if cdp.evaluate("window.__lightflow.stores.develop.get().tool") != "wb-picker":
                        for phase in ["keyDown", "keyUp"]:
                            cdp.call(
                                "Input.dispatchKeyEvent",
                                {
                                    "type": phase,
                                    "key": "w",
                                    "code": "KeyW",
                                    "windowsVirtualKeyCode": 87,
                                    "nativeVirtualKeyCode": 87,
                                },
                            )
                    if cdp.evaluate("window.__lightflow.stores.develop.get().tool") != "wb-picker":
                        raise ValueError("Original W command did not select the WB picker")
                    r = result["devicePixelRatio"]
                    u, v = [(0.29, 0.31), (0.73, 0.69)][state]
                    x, y = (photo[0] + photo[2] * u) / r, (photo[1] + photo[3] * v) / r
                elif key == "light-histogram-drag":
                    x, y = center(cdp, 'lightflow-histogram[data-adjust="true"]')
                else:
                    x, y = center(cdp, 'lightflow-slider[data-id="base.exposure"] lightflow-slider-label')
                mouse(cdp, "mouseMoved", x, y)
                double = key in ("light-numeric-reset", "light-auto-single")
                before = observe(cdp, fields, 2 if double else 1)
                if list(before.values()) != initial:
                    raise ValueError("Starting field values changed")
                if double:
                    for count in [1, 2]:
                        for phase in ["mousePressed", "mouseReleased"]:
                            mouse(cdp, phase, x, y, count=count, shift=key == "light-auto-single")
                else:
                    mouse(cdp, "mousePressed", x, y)
                    if key == "light-histogram-drag":
                        x += [24, -24][state]
                        mouse(cdp, "mouseMoved", x, y, pressed=True)
                    mouse(cdp, "mouseReleased", x, y)
                event = cdp.evaluate("window.rawmasterGestureResult")
                if "error" in event:
                    raise ValueError(json.dumps(event))
                after = event["after"]
                if key == "light-numeric-reset" and after["exposure"] != 0:
                    raise ValueError("Wrong reset value")
                if key == "light-histogram-drag" and abs(after["exposure"] - [0.36, -0.36][state]) > 0.006:
                    raise ValueError("Drag did not produce the original zone calibration")
                if wb and event["wbMode"] != "custom":
                    raise ValueError("Picker did not select Custom white balance")
                h = hashlib.sha256(
                    json.dumps(after, sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()
                states[state].add(h)
                row["trials"].append(
                    dict(event, phase="first" if i < 2 else "warm", state=state, digest=h, verified=True)
                )
            if (
                any(len(group) != 1 for group in states)
                or (wb or key == "light-histogram-drag")
                and states[0] == states[1]
            ):
                raise ValueError("Targets were not repeatable or did not depend on position")
            row["status"] = "measured"
        except (RuntimeError, ValueError, KeyError) as error:
            row["reason"] = str(error)
        save()
        print(key, row["status"], row.get("reason", ""), flush=True)
    with args.raw.open("rb") as stream:
        result["sourceSHA256After"] = hashlib.file_digest(stream, "sha256").hexdigest()
    if result["sourceSHA256After"] != source:
        raise ValueError("Original photo changed")
    save()
