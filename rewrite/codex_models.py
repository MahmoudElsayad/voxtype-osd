"""Bounded Codex model discovery over the installed app-server's stdio protocol."""
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}


def cli_path(name):
    candidates = [os.path.expanduser(f"~/.local/bin/{name}"), f"/opt/homebrew/bin/{name}",
                  f"/usr/local/bin/{name}"]
    if name == "codex":
        candidates.append("/Applications/Codex.app/Contents/Resources/codex")
    candidates.append(shutil.which(name))
    return next((p for p in candidates if p and os.access(p, os.X_OK)), None)


def clean_environment():
    # Keep login location and the macOS keychain context; discard API keys and agent overrides.
    keys = ("HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME")
    return {k: os.environ[k] for k in keys if k in os.environ}


def stop(process):
    # Every child starts in its own session. Never signal another application's process group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def parse_models(entries):
    models = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("hidden"):
            continue
        slug = entry.get("model")
        if not isinstance(slug, str) or not slug.strip():
            continue
        descriptors = entry.get("supportedReasoningEfforts")
        descriptors = descriptors if isinstance(descriptors, list) else []
        efforts = [x.get("reasoningEffort") for x in descriptors
                   if isinstance(x, dict) and isinstance(x.get("reasoningEffort"), str)
                   and x["reasoningEffort"] in EFFORTS]
        default = entry.get("defaultReasoningEffort")
        models.append({"slug": slug, "name": entry["displayName"] if isinstance(entry.get("displayName"), str) and entry["displayName"] else slug,
                       "efforts": efforts, "defaultEffort": default if isinstance(default, str) and default in efforts else None,
                       "isDefault": entry.get("isDefault") is True})
    models.sort(key=lambda m: not m.pop("isDefault"))
    return models


def discover(timeout=8):
    executable = cli_path("codex")
    if not executable:
        raise RuntimeError("Install Codex and sign in")
    # app-server lacks exec's --ignore-user-config. Isolate its configuration entirely.
    with tempfile.TemporaryDirectory(prefix="voxtype-models-") as directory:
        env = clean_environment()
        auth_home = env.get("CODEX_HOME", os.path.expanduser("~/.codex"))
        auth = os.path.join(auth_home, "auth.json")
        if os.path.isfile(auth):
            shutil.copyfile(auth, os.path.join(directory, "auth.json"))
            os.chmod(os.path.join(directory, "auth.json"), 0o600)
        env["CODEX_HOME"] = directory
        process = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   env=env, cwd=directory, start_new_session=True)
        deadline = time.monotonic() + timeout
        pending = bytearray()

        def send(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            process.stdin.flush()

        def response(request_id):
            while True:
                while b"\n" in pending:
                    line, _, rest = pending.partition(b"\n")
                    pending[:] = rest
                    item = json.loads(line)
                    if item.get("id") == request_id:
                        if "error" in item:
                            raise RuntimeError("Codex model discovery failed")
                        return item["result"]
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                    raise TimeoutError("Codex model discovery timed out")
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("Codex model discovery stopped")
                pending.extend(chunk)
                if len(pending) > 4 * 1024 * 1024:
                    raise RuntimeError("Codex model response is too large")

        try:
            send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "voxtype-osd", "version": "0.1.0"}}})
            response(1)
            send({"method": "initialized"})
            entries, cursor = [], None
            for page in range(20):
                request_id = page + 2
                send({"id": request_id, "method": "model/list", "params": {"cursor": cursor, "limit": 100}})
                result = response(request_id)
                entries.extend(result.get("data", []))
                cursor = result.get("nextCursor")
                if not cursor:
                    return parse_models(entries)
            raise RuntimeError("Codex model list has too many pages")
        finally:
            stop(process)
            process.stdin.close()
            process.stdout.close()


if __name__ == "__main__":
    try:
        models = discover()
        if not models:
            raise RuntimeError("No Codex models available")
        print(json.dumps(models))
    except (OSError, ValueError, RuntimeError, TimeoutError):
        sys.exit(1)
