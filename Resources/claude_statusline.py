#!/usr/bin/env python3
"""Claude Code statusLine wrapper for Herdr Notch.

Claude Code pipes a JSON description of the session to the statusLine
command, including `rate_limits` (5-hour / 7-day subscription usage) once the
API has reported them. This records that block for the notch, then runs the
user's own statusline command with the identical input so the visible status
line is unchanged. Recording never blocks or breaks the status line.

settings.json:
  "statusLine": {"type": "command",
    "command": "python3 '<this file>' --wrap '<your previous statusline command>'"}
"""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

STATE = Path(os.environ.get('HERDR_NOTCH_STATE') or Path.home() / 'Library/Application Support/Herdr Notch')


def record(data):
    limits = data.get('rate_limits')
    if not isinstance(limits, dict) or not limits:
        return
    entry = dict(rate_limits=limits, updated=time.time(),
                 model=(data.get('model') or {}).get('display_name'), version=data.get('version'))
    STATE.mkdir(parents=True, exist_ok=True)
    # Atomic replace: concurrent sessions and the notch never see a torn file.
    fd, temporary = tempfile.mkstemp(dir=STATE, prefix='.claude-usage.')
    with os.fdopen(fd, 'w') as handle:
        json.dump(entry, handle, ensure_ascii=False)
    os.replace(temporary, STATE / 'claude-usage.json')


def fallback(data):
    model = (data.get('model') or {}).get('display_name') or 'Claude'
    used = (data.get('context_window') or {}).get('used_percentage')
    return f'[{model}]' + (f' context {used:.0f}%' if isinstance(used, (int, float)) else '')


def main():
    raw = sys.stdin.buffer.read()
    try:
        data = json.loads(raw)
    except ValueError:
        data = {}
    try:
        record(data)
    except Exception:
        pass
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == '--wrap' and args[1].strip():
        result = subprocess.run(['/bin/sh', '-c', args[1]], input=raw)
        sys.exit(result.returncode)
    print(fallback(data))


if __name__ == '__main__':
    main()
