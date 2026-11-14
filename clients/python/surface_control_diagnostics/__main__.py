"""Bounded read-only capture and offline verification; software diagnostics, not device qualification."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from surface_control import SurfaceError
from surface_control_diagnostics import (DEFAULT_LIMITS, MAX_CAPTURE_BYTES, QUALIFICATION, ReadOnlyClient,
                                         capture, check, encoded, load_capture, safe_code, verify)


class QuietParser(argparse.ArgumentParser):
    def error(self, _message):
        # argparse's default message may repeat user values. Never print argument contents.
        raise SurfaceError("invalid_arguments")


def save(path, value):
    """Private atomic artifact; never leave a partially written report or capture."""
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".surface-diagnostic-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(encoded(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    token = None
    try:
        parser = QuietParser(description=__doc__)
        commands = parser.add_subparsers(dest="command", required=True, parser_class=QuietParser)
        collect = commands.add_parser("capture")
        for name in ("url", "token-file", "instance-id", "profile-id", "profile-version", "output"):
            collect.add_argument("--" + name, required=True)
        collect.add_argument("--accept-hardware", action="store_true")
        collect.add_argument("--require-control", action="append", dest="required_controls")
        collect.add_argument("--protocol", choices=("2025-11-25", "2026-07-28"), default="2025-11-25")
        for name, default in DEFAULT_LIMITS.items():
            collect.add_argument("--" + name.replace("_", "-"), type=int if name.startswith("max_") and name != "max_age_s" else float, default=default)
        collect.add_argument("--report")
        offline = commands.add_parser("verify")
        offline.add_argument("--capture", required=True)
        offline.add_argument("--report")
        args = parser.parse_args(argv)
        if args.command == "capture":
            token_path, output = Path(args.token_file), Path(args.output)
            check(token_path.resolve() != output.resolve(), "invalid_output_path")
            if args.report:
                check(Path(args.report).resolve() not in (token_path.resolve(), output.resolve()), "invalid_output_path")
            token = token_path.read_text().strip()
            client = ReadOnlyClient(args.url, token, args.instance_id, protocol=args.protocol,
                                    accepted_sources=("hardware",) if args.accept_hardware else ("simulation",))
            result = capture(client, args.profile_id, args.profile_version, required_controls=args.required_controls,
                             limits={key: getattr(args, key) for key in DEFAULT_LIMITS})
            # Refuse to publish a capture the offline verifier cannot account for.
            report = verify(result)
            save(output, result)
        else:
            if args.report:
                check(Path(args.report).resolve() != Path(args.capture).resolve(), "invalid_output_path")
            with Path(args.capture).open("rb") as stream:
                result = load_capture(stream.read(MAX_CAPTURE_BYTES + 1))
            report = verify(result)
        if args.report:
            save(args.report, report)
        print(json.dumps(report, sort_keys=True))
        return report["exit_code"]
    except (OSError, ValueError, TypeError, KeyError, AttributeError, IndexError, RecursionError, OverflowError, StopIteration, SurfaceError) as error:
        code = safe_code(error, token) if isinstance(error, SurfaceError) else "invalid_capture_or_configuration"
        print(json.dumps({"qualification": QUALIFICATION, "capture_integrity": "not_verified", "exit_code": 2, "code": code}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
