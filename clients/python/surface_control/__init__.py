"""Optional Surface Control client for contracts 1.0, 1.1, 1.2 and 1.3. Standard library only; no command retries.

This is the single shared SDK source (SurfacePlugins `clients/python`). Hosts copy it from their
managed dependency into their delivery; they do not keep their own copy. It is separate from any
host provider protocol and contains no profile names, ranges, or business roles: callers supply them.

Snapshots initialize a cursor. Only subsequent, fresh, accepted input edges are intents.
"""

from __future__ import annotations

import json
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = "1.3.0"
CONTRACT_VERSIONS = ("1.0", "1.1", "1.2", "1.3")
PROTOCOL = "2025-11-25"
PROTOCOLS = ("2025-11-25", "2026-07-28")
MAX_BYTES = 8 * 1024 * 1024
EVENT_KINDS = ("input", "feedback")
IDENTITY_KEYS = ("instance_id", "epoch", "mapping_revision", "profile_id", "profile_version")
HEADER_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}")


class SurfaceError(RuntimeError):
    def __init__(self, code, message="Surface operation rejected; no automatic retry"):
        super().__init__(message)
        self.code = code


def require(condition, code):
    if not condition:
        raise SurfaceError(code)


def cursor(value):
    require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value) is not None, "invalid_sequence")
    require(int(value) <= 2**64 - 1, "invalid_sequence")
    return int(value)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def decode(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("nonfinite JSON")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


# Contract 1.1 mapping revision. Must match SurfaceControlContracts.ControlCanonicalJSON exactly.
def _canonical(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if type(value) in (int, float):
        require(math.isfinite(value), "invalid_profile")
        number = float(value)
        if number.is_integer() and abs(number) < 2**53:
            return str(int(number))
        return repr(number)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ",".join(_canonical(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" + _canonical(value[key]) for key in sorted(value)) + "}"
    raise SurfaceError("invalid_profile")


def mapping_document(profile):
    """Sorted-key, whitespace-free JSON of every control's mapping-relevant fields, ordered by control ID."""
    controls = profile.get("controls") if isinstance(profile, dict) else None
    require(isinstance(controls, list), "invalid_profile")
    rows = []
    for control in controls:
        require(isinstance(control, dict), "invalid_profile")
        row = {key: control[key] for key in ("id", "input_kind", "encoding") if key in control}
        kinds = control.get("feedback_kinds", [])
        require(isinstance(kinds, list) and all(isinstance(kind, str) for kind in kinds), "invalid_profile")
        row["feedback_kinds"] = sorted(kinds)
        for key in ("range", "feedback_range"):
            if control.get(key) is not None:
                require(isinstance(control[key], dict), "invalid_profile")
                row[key] = {name: control[key][name] for name in ("minimum", "maximum", "step") if name in control[key]}
        if control.get("mapping") is not None:
            require(isinstance(control["mapping"], dict), "invalid_profile")
            row["mapping"] = {name: control["mapping"].get(name) for name in ("kind", "id")}
        if "accepts_input" in control:
            require(type(control["accepts_input"]) is bool, "invalid_profile")
            row["accepts_input"] = control["accepts_input"]
        if control.get("hold") is not None:
            require(isinstance(control["hold"], dict), "invalid_profile")
            row["hold"] = {name: control["hold"].get(name) for name in ("rest_value", "max_hold_s")}
        require(isinstance(row.get("id"), str), "invalid_profile")
        rows.append(row)
    rows.sort(key=lambda row: row["id"])
    return _canonical(rows)


def mapping_revision(profile):
    """FNV-1a 64 of `mapping_document`, as 16 lowercase hex digits."""
    value = 0xCBF29CE484222325
    for byte in mapping_document(profile).encode("utf-8"):
        value = ((value ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return format(value, "016x")


def admits(control, value):
    """True when `value` is a valid, unclamped input for the control descriptor."""
    encoding = control.get("encoding")
    if encoding == "boolean":
        return type(value) is bool
    if encoding not in ("scalar", "signedDelta") or not finite(value):
        return False
    span = control.get("range") or {}
    low, high, step = span.get("minimum"), span.get("maximum"), span.get("step")
    if not (finite(low) and finite(high) and low <= value <= high):
        return False
    if step is None or value in (low, high):
        return True
    return finite(step) and step > 0 and round(value / step) * step == value


def accepts_input(control):
    """Return True/False for a declared input policy, or None for legacy undeclared policy."""
    require(isinstance(control, dict), "invalid_profile")
    if "accepts_input" not in control:
        return None
    require(type(control["accepts_input"]) is bool, "invalid_profile")
    return control["accepts_input"]


def validate_input_declarations(profile):
    """Reject partial declarations or fields without controls.input_declared capability."""
    declared = "controls.input_declared" in profile.get("capabilities", [])
    for control in profile["controls"]:
        require((accepts_input(control) is not None) == declared, "invalid_profile")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if fp is not None:
            fp.close()
        raise SurfaceError("redirect_refused")


class Client:
    """Explicit endpoint + instance pin. Transport failures leave write outcomes unknown.

    `provider_id` pins a host-specific response identity header named by `provider_header`
    (both or neither). The SDK does not know any host's header name.
    """

    def __init__(
        self, url, token, instance_id, *, timeout=2, provider_id=None, provider_header=None, protocol=PROTOCOL
    ):
        parsed = urllib.parse.urlsplit(url)
        require(
            parsed.scheme == "http"
            and parsed.hostname == "127.0.0.1"
            and parsed.port is not None
            and 1024 <= parsed.port <= 65535
            and parsed.path == "/mcp"
            and not parsed.query
            and not parsed.fragment
            and parsed.username is None
            and parsed.password is None,
            "invalid_url",
        )
        require(
            isinstance(token, str) and token and len(token) <= 16384 and all(33 <= ord(c) < 127 for c in token),
            "invalid_credential",
        )
        require(isinstance(instance_id, str) and instance_id and len(instance_id) <= 128, "invalid_instance")
        require((provider_id is None) == (provider_header is None), "invalid_provider")
        if provider_id is not None:
            require(
                isinstance(provider_header, str)
                and HEADER_NAME.fullmatch(provider_header) is not None
                and isinstance(provider_id, str)
                and provider_id
                and len(provider_id) <= 256
                and all(33 <= ord(c) < 127 for c in provider_id),
                "invalid_provider",
            )
        self.url, self.token, self.instance_id, self.timeout = url, token, instance_id, timeout
        self.provider_id, self.provider_header = provider_id, provider_header
        require(protocol in PROTOCOLS, "unsupported_protocol")
        self.protocol, self.session, self.connected = protocol, None, False
        self.sequence = 0
        self.expected = None
        self.contract_version = None
        self.profile = None
        self.latest_sequence = None
        self.latest_input_sequence = None
        self.server_time = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def _headers(self, method):
        headers = {
            "Authorization": "Bearer " + self.token,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": self.protocol,
            "Mcp-Method": method,
        }
        if self.session is not None:
            headers["Mcp-Session-Id"] = self.session
        if self.provider_id is not None:
            headers[self.provider_header] = self.provider_id
        return headers

    def rpc(self, method, params):
        if self.protocol == "2025-11-25" and not self.connected and method != "initialize":
            initialized = self.rpc(
                "initialize",
                {
                    "protocolVersion": self.protocol,
                    "capabilities": {},
                    "clientInfo": {"name": "surface-control-sdk", "version": __version__},
                },
            )
            require(initialized.get("protocolVersion") == self.protocol, "unsupported_protocol")
            self.connected = True
            self._initialized()
        self.sequence += 1
        if self.protocol == "2026-07-28":
            params = {
                **params,
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": self.protocol,
                    "io.modelcontextprotocol/clientCapabilities": {},
                },
            }
        raw = json.dumps(
            {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}, allow_nan=False
        ).encode()
        headers = self._headers(method)
        if method == "tools/call":
            headers["Mcp-Name"] = params["name"]
        try:
            with self.opener.open(
                urllib.request.Request(self.url, raw, headers, method="POST"), timeout=self.timeout
            ) as response:
                require(response.headers.get_content_type() == "application/json", "invalid_response")
                if self.provider_id is not None:
                    require(response.headers.get(self.provider_header) == self.provider_id, "provider_mismatch")
                session = response.headers.get("Mcp-Session-Id")
                if session is not None:
                    require(self.session is None or self.session == session, "session_changed")
                    self.session = session
                body = response.read(MAX_BYTES + 1)
                require(len(body) <= MAX_BYTES, "invalid_response")
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
            raise SurfaceError("http_" + str(code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SurfaceError("transport_unknown", "Outcome may be unknown; reconcile before any new write") from None
        try:
            reply = decode(body)
        except (ValueError, UnicodeError):
            raise SurfaceError("invalid_response") from None
        require(
            isinstance(reply, dict)
            and reply.get("jsonrpc") == "2.0"
            and type(reply.get("id")) is int
            and reply["id"] == self.sequence
            and "error" not in reply
            and isinstance(reply.get("result"), dict),
            "rpc_error",
        )
        return reply["result"]

    def _initialized(self):
        raw = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}).encode()
        try:
            with self.opener.open(
                urllib.request.Request(self.url, raw, self._headers("notifications/initialized"), method="POST"),
                timeout=self.timeout,
            ) as response:
                require(response.status in (200, 202, 204), "initialization_failed")
                require(not response.read(MAX_BYTES + 1), "invalid_response")
        except (urllib.error.URLError, TimeoutError, OSError):
            raise SurfaceError("initialization_failed") from None

    def call(self, name, arguments=None):
        require(name.startswith("surface_control_"), "unsupported_tool")
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        value = result.get("structuredContent")
        require(isinstance(value, dict) and type(result.get("isError", False)) is bool, "invalid_response")
        if result.get("isError"):
            raise SurfaceError(value.get("code", "tool_error"))
        return value

    def discover(self, profiles=None, versions=CONTRACT_VERSIONS, profile_versions=None):
        """Discover and pin the instance context.

        `profiles` / `profile_versions` are caller-owned allowlists of profile IDs and versions;
        None accepts any well-formed value. `versions` are accepted contract versions and must be
        a subset of the versions this SDK implements. Contract 1.1 discovery must carry the
        deterministic mapping revision of its profile.
        """
        versions = tuple(versions)
        require(versions and set(versions) <= set(CONTRACT_VERSIONS), "unsupported_contract")
        value = self.call("surface_control_discover")
        require(
            value.get("schema_version") == 1
            and value.get("contract_version") in versions
            and value.get("source") == "simulation",
            "unsupported_contract",
        )
        expected, profile = value.get("expected"), value.get("profile")
        require(
            isinstance(expected, dict)
            and set(expected) == set(IDENTITY_KEYS)
            and all(isinstance(v, str) and v for v in expected.values()),
            "invalid_identity",
        )
        require(expected["instance_id"] == self.instance_id, "instance_mismatch")
        require(
            isinstance(profile, dict)
            and isinstance(profile.get("id"), str)
            and isinstance(profile.get("version"), str)
            and (profiles is None or profile["id"] in profiles)
            and (profile_versions is None or profile["version"] in profile_versions)
            and profile["id"] == expected["profile_id"]
            and profile["version"] == expected["profile_version"]
            and isinstance(profile.get("controls"), list)
            and isinstance(profile.get("capabilities", []), list)
            and all(isinstance(item, str) and item for item in profile.get("capabilities", [])),
            "unsupported_profile",
        )
        if value["contract_version"] in ("1.1", "1.2", "1.3"):
            require(mapping_revision(profile) == expected["mapping_revision"], "invalid_identity")
        validate_input_declarations(profile)
        if value["contract_version"] != "1.3":
            require(not {"input.independent_sequence", "events.writer_id", "writes.independent_limits"}.intersection(profile.get("capabilities", [])), "unsupported_contract")
        latest = cursor(value.get("latest_sequence"))
        require(self.latest_sequence is None or latest >= cursor(self.latest_sequence), "sequence_rollback")
        if self.expected is not None:
            require(self.expected == expected, "context_changed")
        latest_input = self._read_input_sequence(value, profile=profile)
        self._validate_write_limits(value, profile)
        require(self.latest_input_sequence is None or latest_input is not None and cursor(latest_input) >= cursor(self.latest_input_sequence), "sequence_rollback")
        self.expected, self.latest_sequence = expected, value["latest_sequence"]
        self.latest_input_sequence = latest_input
        self.contract_version, self.profile = value["contract_version"], profile
        return value

    def _read_input_sequence(self, value, *, key="latest_input_sequence", global_key="latest_sequence", profile=None):
        profile = self.profile if profile is None else profile
        supported = "input.independent_sequence" in profile.get("capabilities", [])
        require((key in value) == supported, "invalid_input_sequence")
        if not supported:
            return None
        require(cursor(value[key]) <= cursor(value.get(global_key)), "invalid_input_sequence")
        return value[key]

    def _validate_write_limits(self, value, profile):
        supported = "writes.independent_limits" in profile.get("capabilities", [])
        require(("write_limits" in value) == supported, "invalid_write_limits")
        if supported:
            limits = value["write_limits"]
            require(isinstance(limits, dict) and set(limits) == {"window_s", "input_per_window", "feedback_per_window", "renew_per_window", "admin_per_window"}, "invalid_write_limits")
            require(type(limits["window_s"]) is int and limits["window_s"] == 1, "invalid_write_limits")
            require(all(type(limits[key]) is int and 1 <= limits[key] <= 10000 for key in limits if key != "window_s"), "invalid_write_limits")

    def _validate_writer(self, event):
        supported = "events.writer_id" in self.profile.get("capabilities", [])
        require(("writer_id" in event) == supported, "invalid_writer")
        if supported:
            value = event["writer_id"]
            require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", value) is not None, "invalid_writer")

    def control(self, control_id):
        require(self.profile is not None, "not_initialized")
        rows = [row for row in self.profile["controls"] if isinstance(row, dict) and row.get("id") == control_id]
        require(len(rows) == 1, "unsupported_control")
        return rows[0]

    def accepts_input(self, control_id):
        """True/False declaration, or None when the host leaves input policy undeclared."""
        return accepts_input(self.control(control_id))

    def _observe_time(self, value):
        require(finite(value) and (self.server_time is None or value >= self.server_time), "time_rollback")
        self.server_time = value

    def snapshot(self):
        require(self.expected is not None, "not_initialized")
        value = self.call("surface_control_snapshot", {"instance_id": self.instance_id})
        require(value.get("discovery", {}).get("expected") == self.expected, "context_changed")
        require(
            value["discovery"].get("source") == "simulation" and finite(value.get("server_time")), "invalid_snapshot"
        )
        latest = cursor(value.get("latest_sequence"))
        require(self.latest_sequence is None or latest >= cursor(self.latest_sequence), "sequence_rollback")
        self._observe_time(value["server_time"])
        require(isinstance(value.get("inputs"), dict) and isinstance(value.get("feedback"), dict), "invalid_snapshot")
        holds = value.get("holds", {})
        require(isinstance(holds, dict) and all(finite(item) for item in holds.values()), "invalid_snapshot")
        latest_input = self._read_input_sequence(value)
        discovery_input = self._read_input_sequence(value["discovery"])
        require(latest_input == discovery_input, "invalid_input_sequence")
        require(self.latest_input_sequence is None or latest_input is not None and cursor(latest_input) >= cursor(self.latest_input_sequence), "sequence_rollback")
        self.latest_sequence = value["latest_sequence"]
        self.latest_input_sequence = latest_input
        return value

    def refresh_sequence(self):
        """Read one snapshot and return its highwater. Never replay a mutation.

        stale_sequence means the input was not executed. The caller may explicitly submit a
        new input after this read. A transport failure is an unknown outcome; never retry it.
        Existing identity, monotonic time and sequence fences are checked by snapshot().
        """
        return self.snapshot()["latest_sequence"]

    def refresh_input_sequence(self):
        """Read one snapshot and return independent input CAS; never submit or replay an input."""
        require(self.profile is not None and "input.independent_sequence" in self.profile.get("capabilities", []), "unsupported_input_sequence")
        return self.snapshot()["latest_input_sequence"]

    def mutate(self, suffix, fields, extra=None, *, sequenced=True, input_cas=False):
        require(self.expected is not None and self.latest_sequence is not None, "not_initialized")
        before = cursor(self.latest_sequence)
        before_input = cursor(self.latest_input_sequence) if self.latest_input_sequence is not None else None
        arguments = {"expected": self.expected, **fields, **(extra or {})}
        if input_cas:
            require(before_input is not None and suffix == "input", "unsupported_input_sequence")
            arguments["expected_input_sequence"] = self.latest_input_sequence
        elif sequenced:
            arguments["expected_sequence"] = self.latest_sequence
        value = self.call("surface_control_" + suffix, arguments)
        if suffix == "reset":
            require(
                value.get("source") == "simulation"
                and value.get("expected", {}).get("instance_id") == self.instance_id,
                "invalid_response",
            )
            require(
                value["expected"].get("epoch") != self.expected["epoch"]
                and all(
                    value["expected"].get(key) == self.expected[key]
                    for key in ("instance_id", "profile_id", "profile_version")
                )
                and value.get("latest_sequence") == "0",
                "invalid_response",
            )
            if value.get("contract_version") in ("1.1", "1.2", "1.3"):
                require(mapping_revision(value.get("profile")) == value["expected"].get("mapping_revision"), "invalid_identity")
            next_profile = value.get("profile", self.profile)
            next_input = self._read_input_sequence(value, profile=next_profile)
            require(next_input in (None, "0"), "invalid_response")
            self._validate_write_limits(value, next_profile)
            self.expected, self.latest_sequence = value["expected"], "0"
            self.profile = next_profile
            self.latest_input_sequence = next_input
        else:
            require(
                value.get("expected") == self.expected
                and value.get("source") == "simulation"
                and (cursor(value.get("sequence")) == before + 1 if sequenced and not input_cas else cursor(value.get("sequence")) > before)
                and finite(value.get("time"))
                and value.get("origin") == "remote"
                and value.get("kind") == suffix
                and value.get("disposition") in {"accepted", "ignored"}
                and all(value.get(key) == item for key, item in fields.items() if key != "kind")
                and (suffix != "feedback" or value.get("encoding") == fields["kind"])
                and (value.get("hold_deadline") is None or finite(value["hold_deadline"])),
                "invalid_response",
            )
            next_input = self._read_input_sequence(value, key="input_sequence", global_key="sequence")
            self._validate_writer(value)
            if before_input is not None:
                actual = cursor(next_input)
                if suffix == "input":
                    require(actual == before_input + 1, "invalid_input_sequence")
                elif sequenced:
                    require(actual == before_input, "invalid_input_sequence")
                else:
                    require(actual >= before_input, "sequence_rollback")
            self.latest_sequence = value["sequence"]
            self.latest_input_sequence = next_input
        return value

    def input(self, control_id, encoding, value, hold_s=None, *, cas="auto"):

        """Submit one input. `hold_s` (contract 1.1) requests a lease; the host returns `hold_deadline`."""
        extra = None
        if hold_s is not None:
            require(finite(hold_s) and hold_s > 0 and self.contract_version in ("1.1", "1.2", "1.3"), "unsupported_hold")
            extra = {"hold_s": hold_s}
        require(cas in ("auto", "global", "input"), "invalid_argument")
        supported = self.profile is not None and "input.independent_sequence" in self.profile.get("capabilities", [])
        require(cas != "input" or supported, "unsupported_input_sequence")
        return self.mutate("input", {"control_id": control_id, "encoding": encoding, "value": value}, extra,
                           input_cas=supported and cas != "global")

    def feedback(self, control_id, kind, value, *, sequenced=None):
        """Default to no CAS when feedback.unsequenced is advertised; still consumes a sequence.

        sequenced=True explicitly retains legacy CAS. False requires the advertised capability.
        The returned event may skip local sequences when another writer committed concurrently.
        """
        require(self.profile is not None, "not_initialized")
        supported = "feedback.unsequenced" in self.profile.get("capabilities", [])
        require(sequenced is None or type(sequenced) is bool, "invalid_argument")
        sequenced = not supported if sequenced is None else sequenced
        require(sequenced or supported, "unsupported_feedback")
        return self.mutate("feedback", {"control_id": control_id, "kind": kind, "value": value}, sequenced=sequenced)

    def reset(self):
        return self.mutate("reset", {})

    def renew(self, control_id, hold_s):
        """Contract 1.1 silent lease renewal. Consumes no sequence, writes no event, never retried.

        `hold_expired` means the lease is gone: the host restored the rest value. Prepare a new input.
        """
        require(self.expected is not None and self.contract_version in ("1.1", "1.2", "1.3"), "unsupported_hold")
        require(finite(hold_s) and hold_s > 0, "invalid_argument")
        value = self.call(
            "surface_control_renew", {"expected": self.expected, "control_id": control_id, "hold_s": hold_s}
        )
        require(
            set(value) == {"control_id", "hold_deadline", "server_time"}
            and value["control_id"] == control_id
            and finite(value["hold_deadline"])
            and finite(value["server_time"])
            and value["hold_deadline"] > value["server_time"],
            "invalid_response",
        )
        self._observe_time(value["server_time"])
        return value


class EventCursor:
    """Neutral journal cursor: contiguous sequence, pinned epoch, monotonic times, freshness.

    Any failure permanently invalidates the cursor; recover by creating a new one after explicit
    preparation. It interprets no control and no business role.
    """

    def __init__(self, client, *, clock=time.monotonic, max_age=2, limit=1024):
        require(finite(max_age) and max_age > 0 and type(limit) is int and 1 <= limit <= 1024, "invalid_argument")
        self.client, self.clock, self.max_age, self.limit = client, clock, max_age, limit
        self.sequence = None
        self.input_sequence = None
        self.expected = None
        self.invalidated = False
        self.last_clock = None
        self.last_event_time = None
        self.holds = {}
        self.holds_server_time = None
        self.holds_request_started_monotonic = None
        self.holds_received_monotonic = None

    def bootstrap(self, snapshot):
        """Start after a snapshot's highwater. Historical events are deliberately discarded."""
        require(self.sequence is None and not self.invalidated, "recovery_required")
        require(snapshot.get("discovery", {}).get("expected") == self.client.expected, "context_changed")
        self.expected = dict(self.client.expected)
        self.sequence = cursor(snapshot["latest_sequence"])
        value = self.client._read_input_sequence(snapshot)
        self.input_sequence = cursor(value) if value is not None else None
        self.tick()

    def tick(self):
        now = self.clock()
        require(finite(now) and (self.last_clock is None or now >= self.last_clock), "invalid_clock")
        self.last_clock = now
        return now

    def poll(self):
        """Return entries {event, age_s, received_monotonic, expires_monotonic} for every new event."""
        require(self.sequence is not None and not self.invalidated, "recovery_required")
        try:
            return self._poll()
        except Exception:
            self.invalidated = True
            raise

    def _poll(self):
        expected = self.expected
        require(self.client.expected == expected, "context_changed")
        started = self.tick()
        page = self.client.call(
            "surface_control_events",
            {
                "instance_id": self.client.instance_id,
                "epoch": expected["epoch"],
                "after_sequence": str(self.sequence),
                "limit": self.limit,
            },
        )
        received = self.tick()
        require(received - started <= self.max_age, "input_stale")
        require(page.get("expected") == expected and finite(page.get("server_time")), "context_changed")
        self.client._observe_time(page["server_time"])
        require(cursor(page.get("latest_sequence")) >= cursor(self.client.latest_sequence), "sequence_rollback")
        events = page.get("events")
        require(isinstance(events, list) and len(events) <= self.limit, "invalid_events")
        entries = []
        for event in events:
            require(
                isinstance(event, dict)
                and event.get("expected") == expected
                and event.get("source") == "simulation"
                and cursor(event.get("sequence")) == self.sequence + 1,
                "event_gap",
            )
            require(
                event.get("kind") in EVENT_KINDS
                and event.get("disposition") in {"accepted", "ignored"}
                and event.get("origin") in {"interface", "remote"}
                and isinstance(event.get("control_id"), str)
                and finite(event.get("time"))
                and (self.last_event_time is None or event["time"] >= self.last_event_time)
                and event["time"] <= page["server_time"]
                and (event.get("hold_deadline") is None or finite(event["hold_deadline"]))
                and (event.get("reason") is None or (isinstance(event["reason"], str) and 0 < len(event["reason"]) <= 128)),
                "invalid_event",
            )
            if event["disposition"] == "ignored":
                require(event.get("reason") is not None, "invalid_event")
            event_input = self.client._read_input_sequence(event, key="input_sequence", global_key="sequence")
            self.client._validate_writer(event)
            if self.input_sequence is not None:
                require(cursor(event_input) == self.input_sequence + (event["kind"] == "input"), "invalid_input_sequence")
                self.input_sequence = cursor(event_input)
            self.last_event_time = event["time"]
            self.sequence += 1
            age = page["server_time"] - event["time"]
            entries.append(
                {
                    "event": event,
                    "age_s": age,
                    "received_monotonic": received,
                    # Server-side age plus local request time both consume the freshness budget.
                    "expires_monotonic": started + self.max_age - age,
                }
            )
        latest = cursor(page.get("latest_sequence"))
        require(latest >= self.sequence and (events or latest == self.sequence), "event_gap")
        holds = page.get("holds", {})
        require(isinstance(holds, dict) and all(isinstance(key, str) and finite(item) for key, item in holds.items()), "invalid_events")
        self.holds = dict(holds)
        self.holds_server_time = page["server_time"]
        self.holds_request_started_monotonic = started
        self.holds_received_monotonic = received
        page_input = self.client._read_input_sequence(page)
        if self.input_sequence is not None:
            current = cursor(page_input)
            require(current >= self.input_sequence and current >= cursor(self.client.latest_input_sequence), "sequence_rollback")
            require(self.sequence != latest or current == self.input_sequence, "invalid_input_sequence")
        self.client.latest_sequence = str(latest)
        self.client.latest_input_sequence = page_input
        return entries

    def fresh(self, entry, now=None):
        now = self.clock() if now is None else now
        return finite(now) and entry["age_s"] >= 0 and entry["received_monotonic"] <= now <= entry["expires_monotonic"]


class BinaryRoleCursor:
    """Map caller-named roles to two-state values from explicitly mapped controls.

    `mapping` is {role: mapping target id}. Each target must resolve to exactly one control whose
    `mapping.kind` is `mapping_kind`. Absolute scalar controls are on at or above their range
    midpoint; button controls are on when true. No range, threshold, or role name is assumed.
    """

    def __init__(self, client, mapping, *, clock=time.monotonic, max_age=2, mapping_kind="parameter", discover=None):
        require(
            isinstance(mapping, dict)
            and mapping
            and all(isinstance(k, str) and k and isinstance(v, str) and v for k, v in mapping.items())
            and len(set(mapping.values())) == len(mapping),
            "invalid_mapping",
        )
        self.client, self.clock, self.max_age, self.mapping_kind = client, clock, max_age, mapping_kind
        self.mapping = dict(mapping)
        self.discover_options = dict(discover or {})
        self.events = EventCursor(client, clock=clock, max_age=max_age)
        self.values = {name: 0 for name in mapping}
        self.controls = {}

    @property
    def sequence(self):
        return self.events.sequence

    @property
    def invalidated(self):
        return self.events.invalidated

    def binary(self, control, raw):
        require(admits(control, raw), "invalid_input")
        if control["encoding"] == "boolean":
            return int(raw)
        span = control["range"]
        return int(raw >= (span["minimum"] + span["maximum"]) / 2)

    def bootstrap(self):
        require(self.events.sequence is None and not self.events.invalidated, "recovery_required")
        discovery = self.client.discover(**self.discover_options)
        descriptors = discovery["profile"].get("controls")
        require(isinstance(descriptors, list), "invalid_profile")
        by_target, ids = {}, set()
        for row in descriptors:
            require(
                isinstance(row, dict) and isinstance(row.get("id"), str) and row["id"] not in ids, "invalid_profile"
            )
            ids.add(row["id"])
            mapping = row.get("mapping") or {}
            if mapping.get("kind") == self.mapping_kind:
                by_target.setdefault(mapping.get("id"), []).append(row)
        for name, target in self.mapping.items():
            rows = by_target.get(target, [])
            require(len(rows) == 1, "invalid_mapping")
            row = rows[0]
            span = row.get("range") or {}
            require(
                (row.get("input_kind"), row.get("encoding")) == ("button", "boolean")
                or (
                    (row.get("input_kind"), row.get("encoding")) == ("absolute", "scalar")
                    and finite(span.get("minimum"))
                    and finite(span.get("maximum"))
                    and span["minimum"] < span["maximum"]
                ),
                "unsupported_encoding",
            )
            self.controls[row["id"]] = (name, row)
        snapshot = self.client.snapshot()
        for control, (name, row) in self.controls.items():
            raw = snapshot["inputs"].get(control)
            require(admits(row, raw), "unknown_input")
            self.values[name] = self.binary(row, raw)
        self.events.bootstrap(snapshot)
        return dict(self.values)

    def poll(self):
        require(self.events.sequence is not None and not self.events.invalidated, "recovery_required")
        entries = self.events.poll()
        try:
            return self._edges(entries)
        except Exception:
            self.events.invalidated = True
            raise

    def _edges(self, entries):
        samples = []
        for position, entry in enumerate(entries):
            event = entry["event"]
            if event["kind"] != "input" or event["disposition"] != "accepted" or event["control_id"] not in self.controls:
                continue
            name, row = self.controls[event["control_id"]]
            require(event.get("encoding") == row["encoding"], "invalid_input")
            value = self.binary(row, event.get("value"))
            require(0 <= entry["age_s"] <= self.max_age, "input_stale")
            if value == self.values[name]:
                continue  # Neither identical samples nor same-side ticks renew an old intent.
            self.values[name] = value
            samples.append(
                {
                    "values": dict(self.values),
                    "expected": dict(self.events.expected),
                    "sequence": event["sequence"],
                    "source": "simulation",
                    "origin": event["origin"],
                    "reason": event.get("reason"),
                    "received_monotonic": entry["received_monotonic"],
                    "expires_monotonic": entry["expires_monotonic"],
                    "_position": position,
                }
            )
        # A sample is only current if nothing later superseded it in the same page.
        last = str(self.events.sequence)
        for sample in samples:
            sample.pop("_position")
            sample["superseded"] = sample["sequence"] != last
        return samples

    def verify(self, sample):
        require(not self.events.invalidated, "recovery_required")
        try:
            return self._verify(sample)
        except Exception:
            self.events.invalidated = True
            raise

    def _check_clock(self, sample):
        now = self.events.tick()
        require(sample["received_monotonic"] <= now <= sample["expires_monotonic"], "input_stale")

    def _verify(self, sample):
        require(
            sample.get("expected") == self.client.expected
            and sample.get("values") == self.values
            and sample.get("sequence") == str(self.events.sequence),
            "input_superseded",
        )
        self._check_clock(sample)
        snapshot = self.client.snapshot()
        require(cursor(snapshot["latest_sequence"]) == self.events.sequence, "input_superseded")
        for control, (name, row) in self.controls.items():
            raw = snapshot["inputs"].get(control)
            require(admits(row, raw) and self.binary(row, raw) == self.values[name], "input_superseded")
        self._check_clock(sample)


class CommandCursor(BinaryRoleCursor):
    """Compatibility wrapper for the original four-role consumer (arm/start/pause/cancel)."""

    ROLES = ("arm", "start", "pause", "cancel")

    def __init__(self, client, mapping, **options):
        require(isinstance(mapping, dict) and set(mapping) == set(self.ROLES), "invalid_mapping")
        super().__init__(client, mapping, **options)


__all__ = [
    "BinaryRoleCursor",
    "CONTRACT_VERSIONS",
    "Client",
    "CommandCursor",
    "EventCursor",
    "SurfaceError",
    "admits",
    "accepts_input",
    "validate_input_declarations",
    "mapping_document",
    "mapping_revision",
    "__version__",
]
