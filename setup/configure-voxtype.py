"""Sets the Voxtype options that VoxtypeOSD needs, keeping every other line of config.toml.

Voxtype's own `voxtype config set` changes only the engine, so this edits the file. Running it
again leaves the file unchanged.
"""

import os
import re
import sys

CONFIG = os.path.expanduser("~/Library/Application Support/voxtype/config.toml")
APP_RESOURCES = os.path.expanduser("~/Applications/VoxtypeOSD.app/Contents/Resources")

SETTINGS = [
    # VoxtypeOSD owns the keys and drives Voxtype through `voxtype record`.
    ("hotkey", "enabled", "false"),
    # Voxtype has no unlimited value, and 0 stops a recording at once. 24 hours is effectively none.
    ("audio", "max_duration_secs", "86400"),
    # The Claude rewrite. The script passes text through unchanged while the switch is off.
    ("output.post_process", "command", f'"{APP_RESOURCES}/voxtype-rewrite"'),
    ("output.post_process", "timeout_ms", "15000"),
]


def set_value(text, section, key, value):
    header = re.search(rf"^\[{re.escape(section)}\][ \t]*$", text, re.M)
    line = f"{key} = {value}"
    if not header:
        return text.rstrip("\n") + f"\n\n[{section}]\n{line}\n"
    body_start = header.end() + 1
    next_header = re.compile(r"^\[", re.M).search(text, body_start)
    body_end = next_header.start() if next_header else len(text)
    body = text[body_start:body_end]
    existing = re.search(rf"^{re.escape(key)}[ \t]*=.*$", body, re.M)
    if existing:
        body = body[:existing.start()] + line + body[existing.end():]
    else:
        body = line + "\n" + body
    return text[:body_start] + body + text[body_end:]


def main():
    if not os.path.exists(CONFIG):
        sys.exit(f"No Voxtype configuration at {CONFIG}. Run `voxtype setup --download` first.")
    with open(CONFIG, encoding="utf-8") as file:
        original = file.read()
    text = original
    for section, key, value in SETTINGS:
        text = set_value(text, section, key, value)
    if text == original:
        print("Voxtype configuration already set.")
        return
    with open(CONFIG + ".before-voxtype-osd", "w", encoding="utf-8") as file:
        file.write(original)
    with open(CONFIG, "w", encoding="utf-8") as file:
        file.write(text)
    print(f"Updated {CONFIG} (previous version saved as config.toml.before-voxtype-osd).")


main()
