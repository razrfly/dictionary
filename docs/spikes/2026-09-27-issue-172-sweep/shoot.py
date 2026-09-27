# #172 final sweep, 2026-09-27: produced docs/discovery/issue-172-sweep-*-2026-09-27.jpg (the empty-note four were retaken by shoot_empty.py).
"""Screenshots for #172 build B through CDP device emulation.

python3 shoot.py OUT_DIR  — writes one JPEG per (shot, width, theme) and prints
the layout width check for each.
"""
import base64, json, os, subprocess, sys, tempfile, time, urllib.request
import websocket

OUT = sys.argv[1]
PORT = 9333
BASE = "http://localhost:4172"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# (file stem, path, element to crop to, open the About first)
SHOTS = [
    ("issue-172-sweep-bunny-word-level-quotes", "/define/bunny", "#culture-shelf-quote", False),
    ("issue-172-sweep-bunny-word-level-artworks", "/define/bunny", "#culture-shelf-artwork", False),
    ("issue-172-sweep-bunny-word-level-images", "/define/bunny", "#culture-shelf-image", False),
    ("issue-172-sweep-grief-promoted-quotes", "/define/grief", "#culture-shelf-quote", False),
    ("issue-172-sweep-situationship-empty-note", "/define/situationship", "#culture-about", True),
]
WIDTHS = [375, 1024]
THEMES = ["light", "dark"]

profile = tempfile.mkdtemp()
chrome = subprocess.Popen([CHROME, "--headless=new", f"--remote-debugging-port={PORT}",
                           f"--user-data-dir={profile}", "--remote-allow-origins=*",
                           "--hide-scrollbars", "about:blank"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try:
            targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json"))
            page = next(t for t in targets if t["type"] == "page")
            break
        except Exception:
            time.sleep(0.2)
    ws = websocket.create_connection(page["webSocketDebuggerUrl"], timeout=60)
    seq = [0]

    def call(method, **params):
        seq[0] += 1
        ws.send(json.dumps({"id": seq[0], "method": method, "params": params}))
        while True:
            msg = json.loads(ws.recv())
            if msg.get("id") == seq[0]:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def js(expr):
        r = call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        return r.get("result", {}).get("value")

    call("Page.enable")
    for stem, path, selector, about in SHOTS:
        for width in WIDTHS:
            for theme in THEMES:
                call("Emulation.setDeviceMetricsOverride", width=width, height=900,
                     deviceScaleFactor=2, mobile=width < 768)
                call("Emulation.setEmulatedMedia",
                     features=[{"name": "prefers-color-scheme", "value": theme}])
                call("Page.navigate", url=BASE + path)
                for _ in range(100):
                    time.sleep(0.2)
                    if js(f"!!document.querySelector('[data-phx-main].phx-connected') && !!document.querySelector('{selector}')"):
                        break
                time.sleep(1.2)
                if about:
                    js("document.querySelector('#culture-about').open = true")
                    time.sleep(0.4)
                # Page-level horizontal overflow, the no-sideways-scroll check.
                widths = js("[document.documentElement.scrollWidth, window.innerWidth]")
                rect = js(f"""(() => {{
                    const el = document.querySelector('{selector}');
                    window.scrollTo(0, 0);
                    const r = el.getBoundingClientRect();
                    return {{x: 0, y: r.top + window.scrollY - 12, w: window.innerWidth,
                             h: Math.min(r.height + 24, 2400)}};
                }})()""")
                time.sleep(0.6)
                shot = call("Page.captureScreenshot", format="jpeg", quality=82,
                            captureBeyondViewport=True,
                            clip={"x": rect["x"], "y": rect["y"], "width": rect["w"],
                                  "height": rect["h"], "scale": 1})
                name = f"{stem}-{width}-{theme}-2026-09-27.jpg"
                with open(os.path.join(OUT, name), "wb") as f:
                    f.write(base64.b64decode(shot["data"]))
                print(name, "scrollWidth/innerWidth", widths)
    ws.close()
finally:
    chrome.terminate()
