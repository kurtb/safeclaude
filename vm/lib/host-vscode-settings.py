"""Read-only check of host VS Code settings used for devvm Remote-SSH.

Usage: host-vscode-settings.py USER_DIR...  (e.g. ~/.config/Code/User)
Exit 0 when at least one profile sets every required value. This does not
show which profile a connection uses or which accounts are signed in. The
guest controls the VS Code server and its machine settings, so these are
only checked on the host.
"""
import json
import os
import sys

REQUIRED = (
    "remote.autoForwardPorts",
    "git.terminalAuthentication",
    "github.gitAuthentication",
    "git.useIntegratedAskPass",
)


def _scan(text, handle):
    """Copy JSON strings verbatim and pass other positions to handle."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            i = handle(text, i, out)
    return "".join(out)


def _comment(text, i, out):
    if text.startswith("//", i):
        j = text.find("\n", i)
        return len(text) if j < 0 else j
    if text.startswith("/*", i):
        j = text.find("*/", i + 2)
        return len(text) if j < 0 else j + 2
    out.append(text[i])
    return i + 1


def _trailing_comma(text, i, out):
    if text[i] != "," or text[i + 1:].lstrip()[:1] not in ("}", "]"):
        out.append(text[i])
    return i + 1


def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas outside strings."""
    return _scan(_scan(text, _comment), _trailing_comma)


def load(path):
    try:
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    text = strip_jsonc(text).strip()
    if not text:
        return {}
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("settings is not a JSON object")
    return data


def profiles(user_dir):
    yield "Default", os.path.join(user_dir, "settings.json")
    names = {}
    try:
        storage = load(os.path.join(user_dir, "globalStorage", "storage.json"))
        for entry in storage.get("userDataProfiles") or []:
            if isinstance(entry, dict) and isinstance(entry.get("location"), str):
                names[entry["location"]] = entry.get("name") or entry["location"]
    except (OSError, ValueError):
        pass
    root = os.path.join(user_dir, "profiles")
    found = sorted(os.listdir(root)) if os.path.isdir(root) else []
    for location in sorted(set(found) | set(names)):
        yield names.get(location, location), os.path.join(root, location, "settings.json")


def main(user_dirs):
    good = []
    for user_dir in user_dirs:
        app = os.path.basename(os.path.dirname(os.path.normpath(user_dir)))
        for name, path in profiles(user_dir):
            label = f"{app} profile '{name}'"
            try:
                settings = load(path)
            except (OSError, ValueError) as e:
                print(f"      {label}: cannot parse {path}: {e}")
                continue
            missing = [k for k in REQUIRED if settings.get(k) is not False]
            if missing:
                print(f"      {label} needs: " + ", ".join(f'"{k}": false' for k in missing))
            else:
                good.append(label)
    for label in good:
        print(f"      {label} sets all required values")
    return 0 if good else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: host-vscode-settings.py USER_DIR...")
    sys.exit(main(sys.argv[1:]))
