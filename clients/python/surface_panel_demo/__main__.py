"""Run synthetic display-only panel feedback against an explicitly selected host."""
import argparse
import json
import os
import select
import signal
import stat
import sys
import time

from surface_control import SurfaceError, require
from surface_panel_demo import DisplayClient, ReferenceSource, load_mapping, run


class QuietParser(argparse.ArgumentParser):
    def error(self, _message):
        raise SurfaceError("invalid_arguments")


def read_token(fd, timeout=2):
    """A dedicated anonymous descriptor containing only the display token, closed by its writer."""
    require(type(fd) is int and fd >= 0 and stat.S_ISFIFO(os.fstat(fd).st_mode), "invalid_credential_pipe")
    data = b""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0 and bool(select.select([fd], [], [], remaining)[0]), "invalid_credential_pipe")
        part = os.read(fd, 16385 - len(data))
        if not part:
            break
        data += part
        require(len(data) <= 16384, "invalid_credential_pipe")
    token = data.decode("ascii").strip()
    require(token and all(33 <= ord(c) < 127 for c in token) and not token.startswith(("{", "[")), "invalid_credential_pipe")
    return token


def main(argv=None):
    handlers = {}
    interrupted = False

    def stop(_number, _frame):
        nonlocal interrupted
        interrupted = True

    try:
        parser = QuietParser(description=__doc__)
        for key in ("url", "instance-id", "mapping"):
            parser.add_argument("--" + key, required=True)
        parser.add_argument("--token-fd", type=int, required=True)
        parser.add_argument("--source", choices=("simulation", "hardware"), default="simulation")
        parser.add_argument("--protocol", choices=("2025-11-25", "2026-07-28"), default="2025-11-25")
        parser.add_argument("--provider-id")
        parser.add_argument("--provider-header")
        parser.add_argument("--hz", type=float, default=1)
        parser.add_argument("--duration", type=float, default=15)
        parser.add_argument("--max-age", type=float, default=1)
        parser.add_argument("--source-stops-after", type=float)
        args = parser.parse_args(argv)
        token = read_token(args.token_fd)
        os.close(args.token_fd)
        client = DisplayClient(args.url, token, args.instance_id, protocol=args.protocol, accepted_sources=(args.source,), provider_id=args.provider_id, provider_header=args.provider_header)
        mapping = load_mapping(args.mapping)
        for number in (signal.SIGINT, signal.SIGTERM):
            handlers[number] = signal.signal(number, stop)
        report = run(client, mapping, source=ReferenceSource(stop_after=args.source_stops_after), hz=args.hz,
                     duration=args.duration, max_age=args.max_age, stopped=lambda: interrupted)
        print(json.dumps(report, sort_keys=True))
        return report["exit_code"]
    except (OSError, ValueError, TypeError, KeyError, SurfaceError):
        # Do not render remote errors, argv, paths or credentials, even on malformed input.
        print(json.dumps({"qualification": "synthetic-display-demo-only", "reason": "invalid_configuration", "exit_code": 2}), file=sys.stderr)
        return 2
    finally:
        for number, handler in handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
