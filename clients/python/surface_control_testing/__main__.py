"""TEST DOUBLE ONLY — not hardware; cannot be acceptance evidence."""
import argparse
import json
from pathlib import Path
import threading
import time
from surface_control_testing import TestOnlyHardwareHost, TEST_DOUBLE_ID, WARNING


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--instance-id", default="test-double-instance")
    args = parser.parse_args()
    script = json.loads(Path(args.script).read_text())
    if not isinstance(script, list):
        parser.error("script must be a list of trusted timed steps")
    host = TestOnlyHardwareHost(Path(args.token_file).read_text().strip(), instance_id=args.instance_id).start(args.port)
    print(WARNING, flush=True)
    Path(args.ready_file).write_text(json.dumps({"artifact": TEST_DOUBLE_ID, "qualification": "test-only", "url": host.url, "instance_id": host.instance_id, "source": "hardware", "contract_version": "1.4", "warning": WARNING}) + "\n")
    stopped = threading.Event()
    def replay():
        started = time.monotonic()
        try:
            for step in script:
                stopped.wait(max(0, step["at_s"] - (time.monotonic() - started)))
                if stopped.is_set():
                    break
                host.apply_step(step)
        except Exception:
            print("TEST DOUBLE script failed; stopping test server", flush=True)
            stopped.set()
    thread = threading.Thread(target=replay, daemon=True)
    thread.start()
    try:
        while not stopped.wait(0.5):
            pass
    except KeyboardInterrupt:
        pass
    finally:
        stopped.set()
        host.close()
        thread.join()


if __name__ == "__main__":
    main()
