"""Display-only example driven by a recording of reference simulator actuals.

This is synthetic data, not an observation of hardware or a connected business system.
"""
from __future__ import annotations

import math
import re
from importlib.resources import files
import time

from surface_control import Client, SurfaceError, admits, decode, finite, require

TOOLS = frozenset(("surface_control_discover", "surface_control_snapshot", "surface_control_feedback"))
FIELDS = frozenset((*("joint." + str(i) for i in range(1, 7)), "speed", "steering", "phase", "fault", "fresh"))
REASONS = frozenset(("complete", "interrupted", "source_stale", "invalid_source", "invalid_mapping", "invalid_clock",
                     "unsupported_profile", "unsupported_feedback", "link_disconnected", "display_rejected", "display_unknown"))


class DisplayClient(Client):
    """A transport fence: even an accidental input/renew/reset cannot reach RPC."""
    def call(self, name, arguments=None):
        require(name in TOOLS, "display_only")
        return super().call(name, arguments)


def resource(name):
    return decode(files(__package__).joinpath(name).read_bytes())


class ReferenceSource:
    """Loop the bundled actual recording with fresh local publication timestamps.

    Both ends are at rest. A deliberate stop stops publication instead of making old
    values fresh again. The simulator's original time remains separate from local age.
    """
    def __init__(self, *, stop_after=None):
        require(stop_after is None or finite(stop_after) and stop_after >= 0, "invalid_source")
        self.trace = resource("reference_actual.json")
        require(self.trace.get("source") == "synthetic-reference-simulators", "invalid_source")
        self.stop_after = stop_after
        self.start = None

    def sample(self, now):
        if self.start is None:
            self.start = now
        elapsed = now - self.start
        if self.stop_after is not None and elapsed >= self.stop_after:
            return None
        position = elapsed % self.trace["period_s"]
        frame = max((f for f in self.trace["frames"] if f["time_s"] <= position), key=lambda f: f["time_s"])
        values = {"joint." + str(i + 1): value for i, value in enumerate(frame["joints_rad"])}
        values.update(speed=frame["speed_m_s"], steering=frame["steering_rad"], phase=frame["phase"], fault=frame["fault"], fresh=True)
        return {"published_at": now, "values": values}


def load_mapping(path_or_name):
    """A caller path, or a packaged mapping name; never a MIDI address table."""
    if re.fullmatch(r"[a-z0-9-]{1,40}", path_or_name):
        return resource("mappings/" + path_or_name + ".json")
    with open(path_or_name, "rb") as stream:
        raw = stream.read(65537)
    require(len(raw) <= 65536, "invalid_mapping")
    return decode(raw)


def _profile_mapping(client, document):
    require(isinstance(document, dict) and set(document) == {"schema_version", "profiles"}
            and document["schema_version"] == 1 and isinstance(document["profiles"], list), "invalid_mapping")
    matches = [row for row in document["profiles"] if isinstance(row, dict)
               and row.get("source") == client.source and row.get("profile_id") == client.profile["id"]
               and row.get("profile_version") == client.profile["version"]]
    require(len(matches) == 1, "unsupported_profile")
    row = matches[0]
    require(set(row) == {"source", "profile_id", "profile_version", "targets"}
            and isinstance(row["targets"], list) and 1 <= len(row["targets"]) <= 24, "invalid_mapping")
    targets, identities, fresh = [], set(), 0
    for item in row["targets"]:
        require(isinstance(item, dict), "invalid_mapping")
        base = {"control_id", "kind", "field", "rest"}
        numeric = item.get("kind") == "value"
        allowed = base | ({"source_range", "output_range"} if numeric else ({"equals"} if item.get("field") not in ("fresh", "fault") else set()))
        require(set(item) == allowed and item.get("field") in FIELDS and item.get("kind") in ("value", "indicator"), "invalid_mapping")
        ident = item["control_id"]
        require(isinstance(ident, str) and ident not in identities, "invalid_mapping")
        identities.add(ident)
        control = client.control(ident)
        require(item["kind"] in control.get("feedback_kinds", []), "unsupported_feedback")
        if item["field"] == "fresh":
            fresh += 1
            # A numeric ring's zero need not be dark in its current hardware style.
            require(not numeric and item["rest"] == "off", "invalid_mapping")
        if numeric:
            for key in ("source_range", "output_range"):
                value = item[key]
                require(isinstance(value, list) and len(value) == 2 and all(finite(n) for n in value) and value[0] < value[1], "invalid_mapping")
            if item["field"] in ("fresh", "fault"):
                require(item["source_range"] == [0, 1], "invalid_mapping")
            r = control.get("feedback_range", control.get("range"))
            require(isinstance(r, dict), "unsupported_feedback")
            feedback_control = {**control, "range": r}
            require(all(admits(feedback_control, n) for n in (*item["output_range"], item["rest"])), "invalid_mapping")
        else:
            require(item["rest"] == "off" and ("equals" not in item or finite(item["equals"])), "invalid_mapping")
        targets.append((item, control))
    require(fresh == 1, "invalid_mapping")
    return targets


def _project(item, control, values):
    require(isinstance(values, dict) and item["field"] in values, "invalid_source")
    value = values[item["field"]]
    if item["kind"] == "indicator":
        if item["field"] in ("fresh", "fault"):
            require(type(value) is bool, "invalid_source")
            active = value
        else:
            require(finite(value), "invalid_source")
            active = value == item["equals"]
        return "on" if active else "off"
    if item["field"] in ("fresh", "fault"):
        require(type(value) is bool, "invalid_source")
        value = int(value)
    require(finite(value), "invalid_source")
    low, high = item["source_range"]
    lo, hi = item["output_range"]
    x = lo + (min(high, max(low, value)) - low) / (high - low) * (hi - lo)
    r = control.get("feedback_range", control.get("range"))
    step = r.get("step")
    if step is not None:
        candidates = [lo, hi, math.floor(x / step) * step, math.ceil(x / step) * step]
        x = min((n for n in candidates if lo <= n <= hi), key=lambda n: (abs(n - x), n))
    return int(x) if x == int(x) else x


def run(client, mapping, *, source=None, hz=1, duration=15, max_age=1, clock=time.monotonic, sleep=time.sleep, stopped=lambda: False):
    """One pinned session; no reconnect, replay, mutation retry or role escalation.

    Cleanup is a new intentional rest write, even after an unknown display outcome.
    It retains the original expected identity. A changed/disconnected session may
    reject cleanup; the returned nonzero result then states that rest was not proved.
    """
    require(isinstance(client, DisplayClient), "display_only")
    require(finite(hz) and 0 < hz <= 10 and finite(duration) and 0 < duration <= 3600
            and finite(max_age) and 0 < max_age <= 10, "invalid_argument")
    source = source or ReferenceSource()
    written, previous = {}, {}
    result = {"qualification": "synthetic-display-demo-only", "reason": "complete", "frames": 0,
              "accepted": 0, "ignored": 0, "cleanup_attempted": 0, "cleanup_failed": 0, "exit_code": 0}
    last_time, last_sample = None, None

    def now():
        nonlocal last_time
        value = clock()
        require(finite(value) and (last_time is None or value >= last_time), "invalid_clock")
        last_time = value
        return value

    def write(item, value):
        # Record the attempt first: a lost response can still have changed the display.
        key = (item["control_id"], item["kind"])
        written[key] = item
        # An earlier acknowledgement cannot describe the result of this new attempt.
        # In particular, an old acknowledged rest must not hide a lost non-rest reply.
        previous.pop(key, None)
        reply = client.feedback(key[0], key[1], value, sequenced=False)
        if reply["disposition"] == "accepted":
            result["accepted"] += 1
        else:
            result["ignored"] += 1
            # An ignored/suppressed display is not evidence that the device accepted it.
            require(reply.get("reason") == "no_change", "display_rejected")
        previous[key] = value

    try:
        client.discover()
        require("feedback.unsequenced" in client.profile.get("capabilities", []), "unsupported_feedback")
        targets = _profile_mapping(client, mapping)
        snapshot = client.snapshot()
        require(client.source != "hardware" or snapshot["link"]["state"] == "connected", "link_disconnected")
        start = now()
        while True:
            at = now()
            if stopped():
                result["reason"] = "interrupted"
                break
            if at - start >= duration:
                break
            sample = source.sample(at)
            if sample is not None:
                require(isinstance(sample, dict) and set(sample) == {"published_at", "values"}
                        and finite(sample["published_at"]) and sample["published_at"] <= at
                        and (last_sample is None or sample["published_at"] >= last_sample["published_at"]), "invalid_source")
                last_sample = sample
            require(last_sample is not None and at - last_sample["published_at"] <= max_age, "source_stale")
            # Validate an entire projection before writing any part of this frame.
            plan = [(item, _project(item, control, last_sample["values"])) for item, control in targets]
            for item, value in plan:
                if stopped():
                    raise KeyboardInterrupt
                require(now() - last_sample["published_at"] <= max_age, "source_stale")
                if previous.get((item["control_id"], item["kind"])) != value:
                    write(item, value)
            result["frames"] += 1
            sleep(max(0, min(1 / hz, duration - (now() - start))))
    except KeyboardInterrupt:
        result["reason"] = "interrupted"
    except SurfaceError as error:
        result["reason"] = error.code if error.code in REASONS else ("display_unknown" if error.code == "transport_unknown" else "display_rejected")
        result["exit_code"] = 1
    except (OSError, ValueError, TypeError, KeyError):
        result["reason"] = "invalid_source"
        result["exit_code"] = 1
    finally:
        # Freshness goes dark before the remaining targets return to rest.
        rows = sorted(written.values(), key=lambda item: item["field"] != "fresh")
        for item in rows:
            key = (item["control_id"], item["kind"])
            if previous.get(key) == item["rest"]:
                continue  # Its last acknowledged display value is already the requested rest.
            result["cleanup_attempted"] += 1
            try:
                reply = client.feedback(item["control_id"], item["kind"], item["rest"], sequenced=False)
                if reply["disposition"] != "accepted" and reply.get("reason") != "no_change":
                    result["cleanup_failed"] += 1
            except (SurfaceError, OSError):
                result["cleanup_failed"] += 1
        if result["cleanup_failed"]:
            result["exit_code"] = 1
    return result
