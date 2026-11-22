"""Stock curve chart, numeric editor, keyboard and channel-reset controls."""

import hashlib
import json
import time

from lightflow_gestures import mouse
from lightflow_panel_tools import click, show_panel


CONTROLS = {
    "curve-input-output": "First trusted replacement of Input and Output through Return, the committed linear point and the original graph's selected point.",
    "curve-keyboard": "Trusted keyboard arrow through the original selected point, its node curve and the graph's displayed coordinates.",
    "curve-reset-channel": "Trusted reset on a previously edited channel through linear endpoints and the independent blue channel's intact curve.",
    "curve-parametric": "Trusted Parametric tab selection through the original four controls and the changed curve canvas readback.",
}
CUSTOM = '[aria-label="Curve type"] [aria-label="Custom YRGB curves"]'
PARAMETRIC = '[aria-label="Curve type"] [aria-label="Lightroom region curve"]'
GRAPH = 'lightflow-curve[data-id="curves.tone.{channel}"] canvas'
CHANNEL = '[aria-label="Curve channel"] [aria-label="{label}"]'
POINTS = """(()=>{const a=window.__lightflow,asset=a.stores.catalog.get().active,
  curves=a.editOf(asset).grade.nodes.find(n=>n.kind==='corrector').tools.curves??{};
  return Object.fromEntries(['master','red','green','blue'].map(k=>[k,curves[k]??[[0,0],[1,1]]]));})()"""


def key(cdp, name):
    numbers = {"Enter": 13, "Tab": 9, "ArrowUp": 38, "ArrowDown": 40}
    for phase in ("keyDown", "keyUp"):
        cdp.call(
            "Input.dispatchKeyEvent",
            {
                "type": phase,
                "key": name,
                "code": name,
                "windowsVirtualKeyCode": numbers[name],
                "nativeVirtualKeyCode": numbers[name],
            },
        )


def choose(cdp, channel):
    click(cdp, CHANNEL.format(label=channel.capitalize()))
    return GRAPH.format(channel=channel)


def reset(cdp, channel):
    selector = (
        f'lightflow-curve-panel [data-tooltip="Reset {channel.capitalize()} curve"]'
    )
    if not cdp.evaluate("!!document.querySelector(" + json.dumps(selector) + ")"):
        selector = (
            f'lightflow-curve-panel [aria-label="Reset {channel.capitalize()} curve"]'
        )
    click(cdp, selector)


def create_point(cdp, channel, wait, u=0.4, v=0.45):
    canvas = choose(cdp, channel)
    if len(cdp.evaluate(POINTS)[channel]) > 2:
        reset(cdp, channel)
    box = cdp.evaluate(
        "(()=>{const el=document.querySelector(" + json.dumps(canvas) + ");"
        "el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return [b.x,b.y,b.width,b.height]})()"
    )
    x, y = box[0] + 6 + (box[2] - 12) * u, box[1] + 6 + (box[3] - 12) * (1 - v)
    mouse(cdp, "mouseMoved", x, y)
    mouse(cdp, "mousePressed", x, y)
    mouse(cdp, "mouseReleased", x, y)
    wait(
        cdp,
        f"({POINTS}).{channel}.length===3",
        "Click did not add an actual source curve point",
    )
    return canvas


def point_state(cdp, channel):
    canvas = json.dumps(GRAPH.format(channel=channel))
    return cdp.evaluate(
        "(()=>{const el=document.querySelector(" + canvas + ");"
        "return {selected:+el.dataset.selected,displayed:JSON.parse(el.dataset.points),curves:"
        + POINTS
        + "};})()"
    )


def checked(state, channel):
    points = state["curves"][channel]
    shown = state["displayed"]
    if len(points) != len(shown) or any(
        abs(a - b) > 0.000501 for p, q in zip(points, shown) for a, b in zip(p, q)
    ):
        raise ValueError("Displayed and committed channel point coordinates differ")
    return points


def fill(cdp, selector, value):
    cdp.evaluate(
        "(()=>{const e=document.querySelector(" + json.dumps(selector) + ");"
        "if(!e)throw Error('Missing editable field');e.focus();e.select();})()"
    )
    cdp.call("Input.insertText", {"text": str(value)})


async_canvas = """(async()=>{const chart=document.querySelector('lightflow-parametric canvas[role=img]'),
  fields=[...document.querySelectorAll('lightflow-parametric lightflow-slider [role=slider]')].map(s=>
    [s.getAttribute('aria-label'),+s.getAttribute('aria-valuenow')]);
  const a=window.__lightflow,asset=a.stores.catalog.get().active;
  if (!chart || fields.length!==4) throw Error('No four-zone original graph');
  await new Promise(requestAnimationFrame);
  const ctx=chart.getContext('2d'),pixels=ctx.getImageData(0,0,chart.width,chart.height).data;
  const hash=await crypto.subtle.digest('SHA-256',pixels);
  return {width:chart.width,height:chart.height,fields,
    parametric:a.editOf(asset).grade.nodes.find(n=>n.kind==='corrector').tools.curves?.parametric??{},
    hash:Array.from(new Uint8Array(hash),v=>v.toString(16).padStart(2,'0')).join('')};})()"""


def capture_curve(cdp, operation, samples, wait, commit):
    show_panel(cdp, "curves", '[aria-label="Curve type"]')
    click(cdp, CUSTOM)
    if operation == "curve-reset-channel":
        create_point(cdp, "blue", wait, 0.3, 0.67)
    elif operation in ("curve-input-output", "curve-keyboard"):
        create_point(cdp, "red", wait)
    trials = []
    seen = [set(), set()]
    for i in range(samples + 2):
        state = i % 2
        if operation == "curve-reset-channel":
            channel = ["red", "green"][state]
            create_point(cdp, channel, wait, 0.4, 0.35 if not state else 0.7)
            before = point_state(cdp, channel)
            started = time.monotonic_ns()
            reset(cdp, channel)
            after = point_state(cdp, channel)
            ended = time.monotonic_ns()
            points = checked(after, channel)
            if (
                points != [[0, 0], [1, 1]]
                or len(before["curves"][channel]) != 3
                or len(after["curves"]["blue"]) != 3
                or any(
                    after["curves"][k] != v
                    for k, v in before["curves"].items()
                    if k != channel
                )
            ):
                raise ValueError(
                    "Reset changed another channel or left a non-linear channel"
                )
            observed = {
                "changedChannel": channel,
                "before": before["curves"],
                "after": after["curves"],
            }
            witness = [channel, after["curves"]]
        elif operation == "curve-parametric":
            click(cdp, PARAMETRIC)
            locator = json.dumps('lightflow-slider[data-id="param-shadows"]')
            label = cdp.evaluate(
                f"document.querySelector({locator}).querySelector('input').getAttribute('aria-label')"
            )
            value = [-40, 40][state]
            accepted = commit(cdp, locator, label, value)
            if not accepted["accepted"]:
                raise ValueError("Original parametric shadow input rejected")
            if not cdp.evaluate("window.__lightflow.waitForRender(5000)"):
                raise ValueError("Photo and histogram source failed to settle")
            reference = cdp.evaluate(async_canvas)
            click(cdp, CUSTOM)
            started = time.monotonic_ns()
            click(cdp, PARAMETRIC)
            observed = cdp.evaluate(async_canvas)
            attempts = [
                {
                    "digest": observed["hash"],
                    "hostMs": (time.monotonic_ns() - started) / 1_000_000,
                }
            ]
            while observed["hash"] != reference["hash"] and len(attempts) < 12:
                observed = cdp.evaluate(async_canvas)
                attempts.append(
                    {
                        "digest": observed["hash"],
                        "hostMs": (time.monotonic_ns() - started) / 1_000_000,
                    }
                )
            ended = time.monotonic_ns()
            observed["preparedHistogramCurveSHA256"] = reference["hash"]
            observed["framesAfterTabSelection"] = attempts
            if (
                observed["parametric"].get("shadows") != value
                or dict(observed["fields"]).get("Shadows") != value
                or observed["hash"] != reference["hash"]
            ):
                raise ValueError(
                    "Original displayed parametric shadows and node recipe differ"
                )
            witness = [value, observed["hash"]]
        else:
            channel = "red"
            graph = GRAPH.format(channel=channel)
            before = point_state(cdp, channel)
            cdp.evaluate("document.querySelector(" + json.dumps(graph) + ").focus()")
            if operation == "curve-keyboard":
                started = time.monotonic_ns()
                key(cdp, ["ArrowUp", "ArrowDown"][state])
            else:
                key(cdp, "Enter")
                entry = 'lightflow-curve-readout input[aria-label="Input of the selected point"]'
                output = 'lightflow-curve-readout input[aria-label="Output of the selected point"]'
                wait(
                    cdp,
                    "!!document.querySelector(" + json.dumps(entry) + ")",
                    "Original selected numeric point editor did not open",
                )
                x, y = [(95, 140), (130, 90)][state]
                started = time.monotonic_ns()
                fill(cdp, entry, x)
                fill(cdp, output, y)
                key(cdp, "Enter")
            after = point_state(cdp, channel)
            ended = time.monotonic_ns()
            points = checked(after, channel)
            if (
                after["selected"] != 1
                or len(points) != 3
                or before["curves"][channel] == points
            ):
                raise ValueError("Curve selection or point failed to change")
            p, q = before["curves"][channel][1], points[1]
            if operation == "curve-keyboard":
                if (
                    abs(q[0] - p[0]) > 1e-8
                    or abs((q[1] - p[1]) * 255 - [1, -1][state]) > 1e-5
                ):
                    raise ValueError(
                        "Original keyboard did not move the selected point by one level"
                    )
            elif abs(q[0] * 255 - x) > 1e-5 or abs(q[1] * 255 - y) > 1e-5:
                raise ValueError(
                    "Original Input/Output numbers did not persist to the selected point"
                )
            observed = {"before": before, "after": after}
            witness = q
        encoded = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(encoded).hexdigest()
        seen[state].add(digest)
        trials.append(
            {
                "state": state,
                "phase": "first" if i < 2 else "warm",
                "ms": (ended - started) / 1_000_000,
                "observed": observed,
                "digest": digest,
                "verified": True,
            }
        )
    stable = all(len(s) == 1 for s in seen) and seen[0] != seen[1]
    return {
        "id": operation,
        "featureIds": [operation],
        "status": "measured" if stable else "inconclusive",
        "boundary": CONTROLS[operation],
        "trials": trials,
        **(
            {}
            if stable
            else {"reason": "Original A/B state or curve raster was not repeatable"}
        ),
    }
