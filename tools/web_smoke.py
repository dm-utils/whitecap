"""Web build smoke test.

"It loads with no errors" is not a test: a build once passed that and froze completely.
This serves the exported web build, opens it in headless Chromium and checks that:
  1. the engine starts and the loader disappears,
  2. frames keep coming (the canvas changes over time),
  3. the debug entry ?scene=match&seed=123 lands in the match scene,
  4. no page errors were thrown.

Usage: python -I tools/web_smoke.py build/web [screenshot_dir]
"""
import functools
import hashlib
import http.server
import os
import socketserver
import sys
import threading

from playwright.sync_api import sync_playwright


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass


def serve(directory: str) -> tuple[socketserver.TCPServer, int]:
    handler = functools.partial(QuietHandler, directory=directory)
    httpd = socketserver.TCPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def canvas_hash(page) -> str:
    return hashlib.sha256(page.locator("#canvas").screenshot()).hexdigest()


def main() -> int:
    build = sys.argv[1]
    shots = sys.argv[2] if len(sys.argv) > 2 else None
    httpd, port = serve(build)
    errors: list[str] = []
    failures: list[str] = []
    with sync_playwright() as p:
        # SMOKE_CHANNEL=chrome uses the installed Chrome (local); CI uses Playwright's own Chromium.
        browser = p.chromium.launch(channel=os.environ.get("SMOKE_CHANNEL") or None, args=["--mute-audio", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
        page = browser.new_page(viewport={"width": 1280, "height": 720})
        page.on("pageerror", lambda e: errors.append(str(e)))

        page.goto(f"http://127.0.0.1:{port}/index.html")
        try:
            page.wait_for_selector("#loader.done", state="attached", timeout=60000)
        except Exception:
            failures.append("engine did not start within 60 s (loader never finished)")
        page.wait_for_timeout(1500)
        if shots:
            page.screenshot(path=f"{shots}/web-boot.png")
        hashes = set()
        for _ in range(4):
            hashes.add(canvas_hash(page))
            page.wait_for_timeout(400)
        if len(hashes) < 2:
            failures.append("canvas did not change for 1.6 s: frames are not coming")

        # compare only the static top part: the waves at the bottom always move
        top = {"x": 0, "y": 0, "width": 1280, "height": 420}
        before = hashlib.sha256(page.screenshot(clip=top)).hexdigest()
        page.mouse.click(640, 360)
        page.wait_for_timeout(1200)
        if shots:
            page.screenshot(path=f"{shots}/web-menu.png")
        if hashlib.sha256(page.screenshot(clip=top)).hexdigest() == before:
            failures.append("tapping the start screen did not open the menu")

        # the daily challenge button: asks the leaderboards service (or falls back offline) and starts the match
        before = hashlib.sha256(page.screenshot(clip=top)).hexdigest()
        page.mouse.click(1052, 537)
        page.wait_for_timeout(6000)
        if shots:
            page.screenshot(path=f"{shots}/web-daily.png")
        if hashlib.sha256(page.screenshot(clip=top)).hexdigest() == before:
            failures.append("the daily challenge button did not start a match")
        page.goto(f"http://127.0.0.1:{port}/index.html")
        page.wait_for_selector("#loader.done", state="attached", timeout=60000)
        page.wait_for_timeout(1500)
        page.mouse.click(640, 360)
        page.wait_for_timeout(1200)

        # the real match through the debug entry, with a fast tide (4 s per phase) to see it rise
        console: list[str] = []
        page.on("console", lambda msg: console.append(msg.text))
        page.goto(f"http://127.0.0.1:{port}/index.html?scene=match&seed=123&tide=4&god=1")
        try:
            page.wait_for_selector("#loader.done", state="attached", timeout=60000)
        except Exception:
            failures.append("debug entry: engine did not start")
        page.wait_for_timeout(2500)  # intro (drop-in) is 1.6 s
        if shots:
            page.screenshot(path=f"{shots}/web-match-start.png")
        hashes = set()
        page.keyboard.down("KeyD")
        page.keyboard.down("Space")
        for _ in range(5):
            hashes.add(canvas_hash(page))
            page.wait_for_timeout(300)
        page.keyboard.up("KeyD")
        page.keyboard.up("Space")
        if len(hashes) < 3:
            failures.append("match: the canvas barely changed while playing (frames not coming?)")
        page.wait_for_timeout(9000)
        if shots:
            page.screenshot(path=f"{shots}/web-match-tide.png")
        fps = [line for line in console if line.startswith("fps ")]
        print("match console:", "; ".join(fps) or "no fps lines")

        # settings (account, controls) and the report overlay (F8 anywhere)
        page.goto(f"http://127.0.0.1:{port}/index.html?scene=settings")
        try:
            page.wait_for_selector("#loader.done", state="attached", timeout=60000)
        except Exception:
            failures.append("settings: engine did not start")
        page.wait_for_timeout(1500)
        if shots:
            page.screenshot(path=f"{shots}/web-settings.png")
        before = hashlib.sha256(page.screenshot(clip=top)).hexdigest()
        page.mouse.click(640, 360)
        page.keyboard.press("F8")
        page.wait_for_timeout(1000)
        if shots:
            page.screenshot(path=f"{shots}/web-report.png")
        if hashlib.sha256(page.screenshot(clip=top)).hexdigest() == before:
            failures.append("F8 did not open the report overlay")

        # phone layout: touch controls inside a fake safe area; left thumb walks, right thumb holds attack
        page.goto(f"http://127.0.0.1:{port}/index.html?scene=match&seed=123&god=1&controls=touch&safe=60,0,60,30")
        page.wait_for_selector("#loader.done", state="attached", timeout=60000)
        page.wait_for_timeout(2500)  # past the drop-in intro
        cdp = page.context.new_cdp_session(page)
        k = 1280 / 1920  # game units -> CSS px (the canvas fills the 1280 x 720 page)
        attack = ((1920 - 60 - 60 - 60 - 115 + 60) * k, (1080 - 30 - 50 - 115) * k)
        thumb = (300 * k, 700 * k)
        def touch(kind, points):
            cdp.send("Input.dispatchTouchEvent", {"type": kind, "touchPoints": [{"x": x, "y": y, "id": i} for i, (x, y) in points]})
        before = canvas_hash(page)
        touch("touchStart", [(0, thumb)])
        touch("touchStart", [(0, thumb), (1, attack)])
        for step in range(1, 9):
            touch("touchMove", [(0, (thumb[0] + step * 12, thumb[1] - step * 6)), (1, attack)])
            page.wait_for_timeout(120)
        if shots:
            page.screenshot(path=f"{shots}/web-touch.png")
        page.wait_for_timeout(800)
        touch("touchEnd", [])
        if canvas_hash(page) == before:
            failures.append("touch: nothing changed while two thumbs were down")

        # Dutch: texts are ~30 % longer, so the layouts must still fit (checked by eye in the contact sheet)
        for scene, extra, name in [("menu", "&lang=nl", "web-menu-nl"), ("settings", "&lang=nl", "web-settings-nl"),
                                   ("match", "&lang=nl&seed=123&god=1", "web-match-nl"), ("zoo", "", "web-zoo"),
                                   ("fx", "", "web-fx"), ("leaderboard", "&lang=nl", "web-leaderboard-nl"),
                                   ("leaderboard", "&lang=nl&dialog=friends", "web-friends-nl"),
                                   ("settings", "&lang=nl&dialog=privacy", "web-privacy-nl")]:
            page.goto(f"http://127.0.0.1:{port}/index.html?scene={scene}{extra}")
            try:
                page.wait_for_selector("#loader.done", state="attached", timeout=60000)
            except Exception:
                failures.append(f"{name}: engine did not start")
            page.wait_for_timeout(2500)
            if shots:
                page.screenshot(path=f"{shots}/{name}.png")
        browser.close()
    httpd.shutdown()

    for e in errors:
        failures.append("page error: " + e)
    for f in failures:
        print("FAIL:", f)
    print("web smoke:", "OK" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
