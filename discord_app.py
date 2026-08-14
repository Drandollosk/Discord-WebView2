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
import time
import traceback

_T0 = time.perf_counter()

DISCORD_URL = "https://discord.com/app"
WINDOW_TITLE = "Discord"

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

WEBVIEW2_DOWNLOAD_URL = (
    "https://developer.microsoft.com/microsoft-edge/webview2/"
    "#download-section"
)


def _base_dir():
    # Next to the .exe when frozen by PyInstaller, next to the .py otherwise.
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


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
    # cache stay on disk between runs instead of being re-downloaded.
    local_app_data = os.environ.get("LOCALAPPDATA") or _base_dir()
    user_data_dir = os.path.join(local_app_data, "Discord_v2", "WebView2")
    try:
        os.makedirs(user_data_dir, exist_ok=True)
        os.environ.setdefault("WEBVIEW2_USER_DATA_FOLDER", user_data_dir)
        log(f"WebView2 profile: {user_data_dir}")
    except Exception:
        log("Could not create WebView2 user data folder, using default")
    # Bump the disk cache size so Discord's (large) JS/CSS bundles and
    # fonts don't get evicted between runs -- eviction would show up as
    # "still slow every time" even though a persistent profile is set.
    os.environ.setdefault("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "--disk-cache-size=314572800")
    # NOTE: earlier builds disabled GPU rendering (--disable-gpu ...) as a
    # blank-screen workaround. That turned out not to be the cause (it was
    # just slow script loading over the network) and forcing software
    # rendering only makes Discord's heavy UI slower, so it's removed now.


def main():
    try:
        open(LOG_PATH, "w", encoding="utf-8").close()
    except Exception:
        pass
    log("--- Diskord starting ---")
    _apply_webview2_settings()

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
        html=LOADING_HTML,
        width=1280,
        height=820,
        min_size=(480, 360),
        text_select=True,
        confirm_close=False,
        hidden=True,
    )

    state = {"revealed": False}

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
            log("Loading screen painted -> revealing window, navigating to " + DISCORD_URL)
            window.show()
            try:
                window.load_url(DISCORD_URL)
            except Exception:
                log("load_url FAILED:\n" + traceback.format_exc())

    window.events.loaded += on_loaded

    # 'edgechromium' = Microsoft Edge WebView2 (Chromium engine). Discord's
    # web app needs a modern Chromium engine — the legacy 'mshtml' (Internet
    # Explorer) fallback pywebview would otherwise silently pick on Windows
    # cannot render it at all. Require it explicitly and surface any
    # failure loudly instead of silently degrading to a blank window.
    gui = "edgechromium" if sys.platform == "win32" else None

    log("Calling webview.start()...")
    try:
        webview.start(gui=gui)
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
