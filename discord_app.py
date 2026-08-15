"""
Diskord — standalone desktop app that opens the real Discord web client
(https://discord.com/app) inside its own native window using an embedded
WebView (Microsoft Edge WebView2 on Windows), instead of a browser tab.

Run directly:
    python discord_app.py

Or build a real double-click .exe: run "Установить Discord.bat" (see README.md).
It installs to %LOCALAPPDATA%\\Discord_v2 so this source folder can be
deleted afterwards without breaking the installed app.

If something goes wrong, see diskord_error.log written next to this
script (or next to Discord.exe). It also logs a timestamp (seconds since
process start) on every line, so slow-startup reports show exactly which
phase is slow: Python/WebView2 engine start vs. the actual Discord page
finishing its network load.
"""
import os
import sys
import threading
import time
import traceback

_T0 = time.perf_counter()

DISCORD_URL = "https://discord.com/app"
WINDOW_TITLE = "Discord"
WINDOW_WIDTH = 1280
WINDOW_HEIGHT = 820

# Shown instantly while WebView2 spins up and Discord's page is still
# fetching (roughly the first ~1-2 seconds) so the window never looks
# blank/frozen -- just a plain spinner, no network requests of its own.
LOADING_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  html,body{height:100%;margin:0;background:#1e1f22;
    display:flex;align-items:center;justify-content:center;
    font-family:Segoe UI,Arial,sans-serif;color:#949ba4}
  .wrap{text-align:center}
  .spinner{width:36px;height:36px;margin:0 auto 14px;
    border:3px solid #3f4147;border-top-color:#5865f2;border-radius:50%;
    animation:spin 0.8s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
</style></head>
<body><div class="wrap"><div class="spinner"></div>Загрузка Discord…</div></body></html>"""

# Same as LOADING_HTML but with an extra note, shown only the very first time
# the app runs (or right after a reinstall, since that wipes the WebView2
# cache folder). On a fresh cache Discord's page has nothing local to load
# from and has to fetch its whole JS/CSS bundle over the network, so this
# first load is genuinely much slower than every later one -- the extra line
# just sets that expectation instead of the window going blank with no
# explanation.
LOADING_HTML_FIRST_RUN = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  html,body{height:100%;margin:0;background:#1e1f22;
    display:flex;align-items:center;justify-content:center;
    font-family:Segoe UI,Arial,sans-serif;color:#949ba4;text-align:center}
  .wrap{text-align:center}
  .spinner{width:36px;height:36px;margin:0 auto 14px;
    border:3px solid #3f4147;border-top-color:#5865f2;border-radius:50%;
    animation:spin 0.8s linear infinite}
  .hint{font-size:12px;margin-top:8px;color:#6d7076}
  @keyframes spin{to{transform:rotate(360deg)}}
</style></head>
<body><div class="wrap"><div class="spinner"></div>Загрузка Discord…
<div class="hint">Первый запуск после установки — это может занять чуть больше времени</div>
</div></body></html>"""

WEBVIEW2_DOWNLOAD_URL = (
    "https://developer.microsoft.com/microsoft-edge/webview2/"
    "#download-section"
)


def _base_dir():
    # Next to the .exe when frozen by PyInstaller, next to the .py otherwise.
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def _resource_path(name):
    # Location of bundled data files (like icon.ico) at runtime -- NOT the
    # same as _base_dir(). When frozen by PyInstaller, data files added via
    # --add-data are unpacked under sys._MEIPASS, which for this project's
    # --onedir build resolves to the app's own _internal folder next to
    # Discord.exe, not the top-level folder _base_dir() points at. Falls
    # back to _base_dir() when running from source (python discord_app.py).
    base = getattr(sys, "_MEIPASS", None) or _base_dir()
    return os.path.join(base, name)


LOG_PATH = os.path.join(_base_dir(), "diskord_error.log")


def log(message):
    elapsed = time.perf_counter() - _T0
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{elapsed:6.2f}s] {message}\n")
    except Exception:
        pass


def show_fatal_error(title, message):
    """Best-effort native error dialog using stdlib tkinter (no extra deps)."""
    try:
        import tkinter
        from tkinter import messagebox

        root = tkinter.Tk()
        root.withdraw()
        messagebox.showerror(title, message)
        root.destroy()
    except Exception:
        print(f"{title}\n{message}", file=sys.stderr)


def _apply_webview2_settings():
    # Persistent, guaranteed-writable user data folder (instead of a fresh
    # temp profile each run). This is what makes the *second* launch faster
    # than the first: Discord's JS/CSS bundles, fonts and service-worker
    # cache stay on disk between runs instead of being re-downloaded. It's
    # also where the login session (cookies) needs to live for Discord to
    # stay logged in between runs.
    #
    # NOTE: pywebview's edgechromium/winforms backend does NOT read the
    # WEBVIEW2_USER_DATA_FOLDER env var -- it always sets the WebView2
    # CoreWebView2EnvironmentOptions.UserDataFolder itself from its own
    # internal cache_dir, which defaults to %APPDATA%\pywebview unless we
    # pass storage_path=... to webview.start() (see main()). So this
    # function only computes the path and reports whether it's a first
    # run -- the actual wiring to WebView2 happens via storage_path.
    local_app_data = os.environ.get("LOCALAPPDATA") or _base_dir()
    user_data_dir = os.path.join(local_app_data, "Discord_v2", "WebView2")
    first_run = not os.path.isdir(user_data_dir)
    try:
        os.makedirs(user_data_dir, exist_ok=True)
        log(f"WebView2 profile: {user_data_dir} (first run: {first_run})")
    except Exception:
        log("Could not create WebView2 user data folder, using default")
    # Bump the disk cache size so Discord's (large) JS/CSS bundles and
    # fonts don't get evicted between runs -- eviction would show up as
    # "still slow every time" even though a persistent profile is set.
    #
    # --use-fake-ui-for-media-stream auto-accepts the "discord.com wants to
    # use your microphone" browser permission prompt instead of showing it
    # -- this only skips the popup, it does NOT fake the actual audio: the
    # real microphone is still used for voice calls. (Do not confuse this
    # with --use-fake-device-for-media-stream, a different flag that
    # replaces the real mic/camera with a synthetic test tone/pattern --
    # that one would break real voice chat, so it's deliberately not used.)
    os.environ.setdefault(
        "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
        "--disk-cache-size=314572800 --use-fake-ui-for-media-stream",
    )
    return first_run, user_data_dir


def _apply_native_window_icon():
    """Force the taskbar/title-bar icon to the one built into the .exe.

    PyInstaller bakes icon.ico into Discord.exe as a Win32 resource (via
    --icon), but pywebview's window doesn't reliably pick that up -- it can
    keep showing a generic placeholder icon in the taskbar even though the
    .exe file itself has the right icon in Explorer. Pulling the icon back
    out of the running .exe and pushing it onto the window with the
    standard WM_SETICON message fixes this without depending on any
    pywebview internals (just the window's title, which we control).
    """
    if sys.platform != "win32" or not getattr(sys, "frozen", False):
        return
    try:
        import ctypes

        hwnd = ctypes.windll.user32.FindWindowW(None, WINDOW_TITLE)
        if not hwnd:
            log("Could not find native window handle to set its icon")
            return

        large = ctypes.c_void_p()
        small = ctypes.c_void_p()
        ctypes.windll.shell32.ExtractIconExW(
            sys.executable, 0, ctypes.byref(large), ctypes.byref(small), 1
        )

        WM_SETICON = 0x0080
        ICON_BIG, ICON_SMALL = 1, 0
        if large.value:
            ctypes.windll.user32.SendMessageW(hwnd, WM_SETICON, ICON_BIG, large.value)
        if small.value:
            ctypes.windll.user32.SendMessageW(hwnd, WM_SETICON, ICON_SMALL, small.value)
        log("Applied .exe icon to the native window/taskbar")
    except Exception:
        log("Could not set native window icon:\n" + traceback.format_exc())


def _run_tray(window, state):
    """Runs a system tray icon for the lifetime of the app (Diskord's own
    icon, in the "hidden icons" area), so closing the window with the X
    button hides it instead of quitting -- the same behaviour as Discord's
    own desktop client, Slack, etc. Call this in its own daemon thread;
    pystray's Icon.run() blocks the calling thread until icon.stop() is
    called from the "Exit" menu item below.

    The click callbacks below only ever call window.show()/hide()/destroy()
    -- never window.load_url(). That distinction matters here: pywebview's
    winforms backend marshals show()/hide()/destroy() onto the UI thread
    internally (they each check/Invoke() under the hood), so calling them
    from this background thread is safe. load_url() does NOT do that
    marshaling, which is why it has to run on the same thread as the
    'loaded' event instead (see the on_loaded() comment above).
    """
    try:
        import pystray
        from PIL import Image
    except Exception:
        log("Tray: pystray/Pillow not available, skipping tray icon:\n" + traceback.format_exc())
        return

    try:
        image = Image.open(_resource_path("icon.ico"))
    except Exception:
        log("Tray: could not load icon.ico, using a plain fallback square:\n" + traceback.format_exc())
        image = Image.new("RGB", (64, 64), "#5865f2")

    def on_open(icon_obj, item):
        log("Tray: 'Open Discord' selected")
        window.show()

    def on_exit(icon_obj, item):
        log("Tray: 'Exit' selected -> closing for real")
        state["quitting"] = True
        icon_obj.stop()
        window.destroy()

    tray_icon = pystray.Icon(
        "Diskord",
        image,
        WINDOW_TITLE,
        menu=pystray.Menu(
            pystray.MenuItem("Открыть Discord", on_open, default=True),
            pystray.MenuItem("Выход", on_exit),
        ),
    )
    log("Tray icon starting")
    try:
        tray_icon.run()
    except Exception:
        log("Tray icon crashed:\n" + traceback.format_exc())
    log("Tray icon stopped")


def main():
    try:
        open(LOG_PATH, "w", encoding="utf-8").close()
    except Exception:
        pass
    log("--- Diskord starting ---")
    first_run, user_data_dir = _apply_webview2_settings()

    log("Importing webview module...")
    import webview  # imported after env vars are set on purpose

    log("Creating window (hidden)...")
    # The native OS window can appear *before* WebView2 has painted
    # anything into it at all -- including our own local loading screen --
    # which is exactly the "blank white window" everyone keeps seeing.
    # Fix: create the window hidden, wait for the first 'loaded' event
    # (fired once the local loading-screen HTML has actually rendered),
    # THEN reveal the window and kick off the real navigation. That way
    # the very first frame the user ever sees already has the spinner on
    # it -- never a blank/white frame.
    window = webview.create_window(
        WINDOW_TITLE,
        html=LOADING_HTML_FIRST_RUN if first_run else LOADING_HTML,
        width=WINDOW_WIDTH,
        height=WINDOW_HEIGHT,
        min_size=(480, 360),
        text_select=True,
        confirm_close=False,
        hidden=True,
    )

    state = {"revealed": False, "quitting": False, "tray_started": False}

    def navigate_to_discord():
        # Must run synchronously on the same (native UI/COM) thread that
        # fired the 'loaded' event -- see the on_loaded() note below for why.
        log("Navigating to " + DISCORD_URL)
        try:
            window.load_url(DISCORD_URL)
        except Exception:
            log("load_url FAILED:\n" + traceback.format_exc())

    def on_loaded():
        # Fires once for the local loading screen, once for Discord's
        # initial navigation, and again on any later in-app navigation
        # Discord itself triggers (e.g. after login).
        try:
            url = window.get_current_url()
        except Exception:
            url = None
        log(f"'loaded' event fired, url = {url}")

        if not state["revealed"]:
            state["revealed"] = True
            log("Loading screen painted -> revealing window")
            window.show()
            _apply_native_window_icon()

            # IMPORTANT: call navigate_to_discord() directly, right here,
            # inline in this event callback -- do NOT defer it via
            # threading.Timer (or any other background thread). Earlier
            # versions delayed the *first* navigation this way (to let the
            # "first run" loading screen stay up a bit longer), and that is
            # the prime suspect for the permanent-blank-page bug: WebView2
            # is a native WinForms/COM control, and calling window.load_url()
            # from a background Python thread instead of the thread that
            # owns the control is an unsupported cross-thread COM call. It
            # doesn't throw -- it can even still report 'loaded' -- but the
            # page never actually paints, and nothing recovers it afterwards.
            # Every navigation this app makes must happen on this same
            # callback thread, which is why this is called directly instead
            # of scheduled.
            navigate_to_discord()
        else:
            # This fires after the REAL navigation (to Discord itself, or
            # any later in-app navigation Discord triggers, e.g. after
            # login) finishes loading. Even with the synchronous navigation
            # above, this has still been reproduced on a brand new WebView2
            # profile folder: the page reports 'loaded' right here, but the
            # control never actually paints anything -- the window just
            # stays blank/white forever, even though every signal says the
            # navigation succeeded. This matches a known class of
            # WebView2/Chromium-embedding bug where the compositor gets
            # stuck and won't paint until something forces a layout
            # recompute -- an actual resize does that reliably. Nudging the
            # window by 1px and immediately back isn't visible to the user
            # (well under a single visible frame) but forces that recompute.
            try:
                window.resize(WINDOW_WIDTH + 1, WINDOW_HEIGHT)
                window.resize(WINDOW_WIDTH, WINDOW_HEIGHT)
                log("Nudged window size to force a repaint")
            except Exception:
                log("Resize nudge FAILED:\n" + traceback.format_exc())

            if not state["tray_started"]:
                state["tray_started"] = True
                # Deliberately started here -- only after the real Discord
                # page has actually loaded -- and NOT earlier in main()
                # before webview.start(). Starting it earlier put pystray's
                # own background win32 message loop running concurrently
                # with WebView2's most fragile moment (first-run environment
                # + GPU/compositor init), and that reintroduced the exact
                # permanent-blank-page bug the resize nudge above was
                # already fixing on its own. By this point that fragile
                # window has passed, so it's safe to start.
                tray_thread = threading.Thread(target=_run_tray, args=(window, state), daemon=True)
                tray_thread.start()

    window.events.loaded += on_loaded

    def on_closing():
        # Fires when the user clicks the window's own X button. Hide
        # instead of actually closing -- the tray icon (started in
        # on_loaded above) keeps the app running and reachable, matching
        # how Discord's own desktop client behaves. state["quitting"] is
        # only set True by the tray's "Exit" item (see _run_tray above),
        # which is the one case where the close should really go through;
        # returning False here is what tells pywebview to cancel the close.
        if state["quitting"]:
            log("Window closing for real")
            return
        log("Close button clicked -> hiding to tray instead of exiting")
        window.hide()
        return False

    window.events.closing += on_closing

    # 'edgechromium' = Microsoft Edge WebView2 (Chromium engine). Discord's
    # web app needs a modern Chromium engine — the legacy 'mshtml' (Internet
    # Explorer) fallback pywebview would otherwise silently pick on Windows
    # cannot render it at all. Require it explicitly and surface any
    # failure loudly instead of silently degrading to a blank window.
    gui = "edgechromium" if sys.platform == "win32" else None

    log("Calling webview.start()...")
    try:
        # private_mode=False is the fix for "Discord asks me to log in every
        # time": pywebview defaults to private_mode=True (like an incognito
        # window), which throws away cookies/local storage -- i.e. the login
        # session -- after every run.
        #
        # storage_path=user_data_dir is what actually points WebView2 at our
        # own persistent folder (AppData\Local\Discord_v2\WebView2). This
        # was removed in an earlier version because it was mistakenly
        # blamed for the permanent-blank-page bug -- but pywebview's own
        # source shows the real cause was elsewhere: without storage_path,
        # pywebview silently falls back to its own default profile folder
        # (%APPDATA%\pywebview), completely disconnected from the folder
        # this app tracks/cleans up. The actual blank-page bug was the
        # background-thread navigation call fixed above in on_loaded(), so
        # storage_path is safe to use again.
        webview.start(gui=gui, private_mode=False, storage_path=user_data_dir)
        log("webview.start returned normally (window closed)")
    except Exception as exc:
        log("webview.start FAILED:\n" + traceback.format_exc())
        show_fatal_error(
            "Diskord — не удалось запустить WebView2",
            "Не получилось открыть встроенный браузер (Microsoft Edge "
            "WebView2).\n\n"
            "Чаще всего причина — не установлен WebView2 Runtime.\n"
            f"Скачайте и установите его отсюда:\n{WEBVIEW2_DOWNLOAD_URL}\n\n"
            f"Техническая информация сохранена в:\n{LOG_PATH}\n\n"
            f"Ошибка: {exc}",
        )
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # last-resort safety net
        log("UNHANDLED EXCEPTION:\n" + traceback.format_exc())
        show_fatal_error("Diskord — непредвиденная ошибка", f"{exc}\n\nСм. {LOG_PATH}")
        sys.exit(1)
