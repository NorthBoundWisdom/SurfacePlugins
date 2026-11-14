"""Command line entry point. Credential contents never enter reports or diagnostics."""
import argparse
import json
from pathlib import Path
import sys

from surface_control import Client, SurfaceError
from surface_conformance import CheckFailure, run_fixture, safe_error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("url", "token-file", "instance-id", "fixture", "roles", "report"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--protocol", default="2025-11-25", choices=("2025-11-25", "2026-07-28"))
    parser.add_argument("--provider-id")
    parser.add_argument("--provider-header")
    parser.add_argument("--accept-hardware", action="store_true", help="explicitly accept contract 1.4 hardware source")
    parser.add_argument("--allow-hardware-feedback", action="store_true", help="authorize display-only feedback (hardware opt-in also required)")
    args = parser.parse_args()
    if args.allow_hardware_feedback and not args.accept_hardware:
        parser.error("--allow-hardware-feedback requires --accept-hardware")
    token = None
    try:
        token = Path(args.token_file).read_text().strip()
        client = Client(args.url, token, args.instance_id, protocol=args.protocol, provider_id=args.provider_id, provider_header=args.provider_header, accepted_sources=("hardware",) if args.accept_hardware else ("simulation",))
        report = run_fixture(client, Path(args.fixture).read_bytes(), json.loads(Path(args.roles).read_bytes()), allow_hardware_feedback=args.allow_hardware_feedback)
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    except (OSError, ValueError, KeyError, TypeError, SurfaceError, CheckFailure) as exc:
        # Do not stringify arbitrary exceptions: third-party transport messages may include credentials.
        print("conformance configuration or discovery failed: " + (safe_error(exc, token) if isinstance(exc, SurfaceError) else type(exc).__name__), file=sys.stderr)
        return 2
    print(json.dumps(report["counts"], sort_keys=True))
    return 1 if report["counts"]["fail"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
