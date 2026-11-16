"""Display-only demo: real loopback fake transport and real signal interruption."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from surface_control import SurfaceError
from surface_control_testing import TestOnlyHardwareHost
from surface_panel_demo import DisplayClient, ReferenceSource, TOOLS, _profile_mapping, load_mapping, run
from surface_panel_demo.__main__ import main, read_token

TOKEN = "synthetic-panel-test-token"


class Clock:
    def __init__(self):
        self.time = 100.0
    def __call__(self):
        return self.time
    def sleep(self, dt):
        self.time += dt


def mapping(profile):
    return {"schema_version": 1, "profiles": [{"source": "hardware", "profile_id": profile["id"], "profile_version": profile["version"], "targets": [
        {"control_id": "axis", "kind": "value", "field": "speed", "source_range": [-1, 1], "output_range": [0, 127], "rest": 0},
        {"control_id": "button", "kind": "indicator", "field": "fresh", "rest": "off"}]}]}


class PanelDemoTests(unittest.TestCase):
    def client(self, host):
        return DisplayClient(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))

    def execute(self, host, **kwargs):
        clock = Clock()
        return run(self.client(host), mapping(host.profile), hz=10, duration=0.4, clock=clock, sleep=clock.sleep, **kwargs)

    def assert_rest(self, host):
        self.assertEqual(host.feedback_values, {"axis": {"value": 0}, "button": {"indicator": "off"}})
        self.assertTrue(set(host.requests) <= TOOLS)
        self.assertEqual(host.inputs, {})

    def test_real_http_writes_actual_projection_and_cleans_freshness_first(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            result = self.execute(host)
            self.assertEqual(result["exit_code"], 0)
            self.assertGreater(result["frames"], 1)
            self.assertEqual(result["cleanup_attempted"], 2)
            self.assertEqual(result["cleanup_failed"], 0)
            self.assertTrue(any(row["control_id"] == "axis" and row["value"] > 63 for row in host.records))
            self.assertEqual([(r["control_id"], r["value"]) for r in host.records[-2:]], [("button", "off"), ("axis", 0)])
            self.assert_rest(host)

    def test_source_stop_ages_out_and_cleans_without_reconnecting(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            result = self.execute(host, source=ReferenceSource(stop_after=0.1), max_age=0.15)
            self.assertEqual(result["reason"], "source_stale")
            self.assertEqual(result["exit_code"], 1)
            self.assertEqual(host.requests.count("surface_control_discover"), 1)
            self.assert_rest(host)

    def test_keyboard_interrupt_and_source_exception_both_clear(self):
        for failure in (KeyboardInterrupt, ValueError):
            with self.subTest(failure=failure), TestOnlyHardwareHost(TOKEN) as host:
                source = ReferenceSource()
                sample = source.sample
                calls = [0]
                def interrupted(now):
                    calls[0] += 1
                    if calls[0] == 2:
                        raise failure()
                    return sample(now)
                source.sample = interrupted
                result = self.execute(host, source=source)
                self.assertEqual(result["reason"], "interrupted" if failure is KeyboardInterrupt else "invalid_source")
                self.assertEqual(result["cleanup_failed"], 0)
                self.assert_rest(host)

    def test_epoch_change_retains_original_pin_and_reports_failed_cleanup(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            clock = Clock()
            def change(dt):
                clock.sleep(dt)
                if host.generation == 1:
                    host.apply_step({"operation": "disconnect"})
            result = run(self.client(host), mapping(host.profile), hz=10, duration=0.4, clock=clock, sleep=change)
            self.assertEqual(result["exit_code"], 1)
            self.assertGreater(result["cleanup_failed"], 0)
            self.assertEqual(host.requests.count("surface_control_discover"), 1)
            self.assertEqual(host.records, [])

    def test_transport_rejection_still_clears_the_attempted_target(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            host.reject_next_feedback()
            result = self.execute(host)
            self.assertEqual(result["exit_code"], 1)
            self.assertEqual(result["cleanup_attempted"], 1)
            self.assertEqual(host.feedback_values, {"axis": {"value": 0}})

    def test_lost_successful_reply_is_not_retried_and_attempted_target_is_cleared(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            class LostReply(DisplayClient):
                lost = False
                def call(self, name, arguments=None):
                    result = super().call(name, arguments)
                    if name == "surface_control_feedback" and not self.lost:
                        self.lost = True
                        raise SurfaceError("transport_unknown")
                    return result
            client = LostReply(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
            clock = Clock()
            result = run(client, mapping(host.profile), hz=10, duration=0.4, clock=clock, sleep=clock.sleep)
            self.assertEqual(result["reason"], "display_unknown")
            self.assertEqual(result["cleanup_failed"], 0)
            self.assertEqual([(r["control_id"], r["value"]) for r in host.records], [("axis", 63), ("axis", 0)])

    def test_lost_nonrest_after_acknowledged_rest_invalidates_old_rest_cache(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            class Source:
                calls = 0
                def sample(self, now):
                    self.calls += 1
                    return {"published_at": now, "values": {"speed": -1 if self.calls == 1 else 1, "fresh": True}}
            class LostNonRest(DisplayClient):
                lost = False
                def call(self, name, arguments=None):
                    result = super().call(name, arguments)
                    if name == "surface_control_feedback" and arguments["control_id"] == "axis" and arguments["value"] == 127 and not self.lost:
                        self.lost = True
                        raise SurfaceError("transport_unknown")
                    return result
            client = LostNonRest(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
            clock = Clock()
            result = run(client, mapping(host.profile), source=Source(), hz=10, duration=0.4, clock=clock, sleep=clock.sleep)
            self.assertEqual(result["reason"], "display_unknown")
            self.assertEqual(result["cleanup_failed"], 0)
            self.assertEqual([(r["control_id"], r["value"]) for r in host.records],
                             [("axis", 0), ("button", "on"), ("axis", 127), ("button", "off"), ("axis", 0)])
            self.assertEqual(host.requests.count("surface_control_discover"), 1)
            self.assert_rest(host)

    def test_interruption_or_staleness_during_a_frame_cleans_before_freshness_is_lit(self):
        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt), TestOnlyHardwareHost(TOKEN) as host:
                clock, stopped = Clock(), [False]
                class MidFrame(DisplayClient):
                    def call(self, name, arguments=None):
                        result = super().call(name, arguments)
                        if name == "surface_control_feedback":
                            if interrupt:
                                stopped[0] = True
                            else:
                                clock.time += 2
                        return result
                client = MidFrame(host.url, TOKEN, host.instance_id, accepted_sources=("hardware",))
                result = run(client, mapping(host.profile), duration=0.4, clock=clock, sleep=clock.sleep, stopped=lambda: stopped[0])
                self.assertEqual(result["reason"], "interrupted" if interrupt else "source_stale")
                self.assertEqual(host.feedback_values, {"axis": {"value": 0}})
                self.assertEqual(result["cleanup_attempted"], 1)

    def test_display_fence_rejects_input_renew_reset_before_transport(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            client = self.client(host)
            for suffix in ("input", "renew", "reset", "events"):
                with self.assertRaises(SurfaceError) as error:
                    client.call("surface_control_" + suffix)
                self.assertEqual(error.exception.code, "display_only")
            self.assertEqual(host.requests, [])

    def test_invalid_mapping_and_unknown_profile_cause_zero_writes(self):
        for mutation in (lambda m: m["profiles"][0].update(profile_version="wrong"),
                         lambda m: m["profiles"][0]["targets"][0].update(output_range=[0, 128]),
                         lambda m: m["profiles"][0]["targets"][0].update(control_id="touch"),
                         lambda m: m["profiles"][0]["targets"][1].update(field="fault")):
            with self.subTest(mutation=mutation), TestOnlyHardwareHost(TOKEN) as host:
                value = mapping(host.profile); mutation(value)
                result = run(self.client(host), value, duration=0.1)
                self.assertEqual(result["exit_code"], 1)
                self.assertEqual(result["cleanup_attempted"], 0)
                self.assertEqual(host.records, [])

    def test_future_or_invalid_source_frame_is_rejected_before_any_write(self):
        for sample in ({"published_at": 101, "values": {}}, {"published_at": 100, "values": {"speed": float("nan"), "fresh": True}}):
            with self.subTest(sample=sample), TestOnlyHardwareHost(TOKEN) as host:
                class Source:
                    def sample(self, _now):
                        return sample
                result = self.execute(host, source=Source())
                self.assertEqual(result["exit_code"], 1)
                self.assertEqual(host.records, [])

    def test_wall_clock_rollback_is_not_used_and_monotonic_rollback_fails(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            clock = Clock()
            def rollback(_dt):
                clock.time -= 1
            result = run(self.client(host), mapping(host.profile), hz=10, duration=1, clock=clock, sleep=rollback)
            self.assertEqual(result["reason"], "invalid_clock")
            self.assert_rest(host)

    def test_bundled_maps_use_only_declared_targets_and_disjoint_freshness(self):
        for name, count in (("bcr", 10), ("compact", 16)):
            document = load_mapping(name)
            for variant in document["profiles"]:
                with self.subTest(mapping=name, source=variant["source"]):
                    client = DisplayClient("http://127.0.0.1:8000/mcp", TOKEN, "test")
                    client.source = variant["source"]
                    controls = []
                    for row in variant["targets"]:
                        c = {"id": row["control_id"], "input_kind": "button" if row["kind"] == "indicator" else "absolute", "encoding": "boolean" if row["kind"] == "indicator" else "scalar", "feedback_kinds": [row["kind"]]}
                        if row["kind"] == "value":
                            c["range"] = {"minimum": 0, "maximum": 127, "step": 1}
                            if name == "compact" and variant["source"] == "hardware":
                                c["feedback_range"] = {"minimum": 0, "maximum": 28, "step": 1}
                        controls.append(c)
                    client.profile = {"id": variant["profile_id"], "version": variant["profile_version"], "controls": controls}
                    self.assertEqual(len(_profile_mapping(client, document)), count)
                    self.assertFalse(any("fader" in row["control_id"] for row in variant["targets"]))
                    self.assertEqual(sum(row["field"] == "fresh" for row in variant["targets"]), 1)

    def test_rotary_map_has_visible_group_and_a_real_extinguishable_freshness_target(self):
        for variant in load_mapping("bcr")["profiles"]:
            top = [row["control_id"] for row in variant["targets"] if row["control_id"].startswith("pushEncoder.")]
            self.assertEqual(top, ["pushEncoder.1." + str(i) for i in range(1, 9)])
            self.assertEqual(variant["targets"][-2]["control_id"], "encoder.1.1")
            self.assertEqual(variant["targets"][-1], {"control_id": "button.1.1", "kind": "indicator", "field": "fresh", "rest": "off"})
            # The default hardware profile's empty button feedback declaration must fail preflight.
            if variant["source"] == "hardware":
                client = DisplayClient("http://127.0.0.1:8000/mcp", TOKEN, "test")
                client.source = "hardware"
                client.profile = {"id": variant["profile_id"], "version": variant["profile_version"], "controls": [
                    {"id": row["control_id"], "encoding": "scalar", "range": {"minimum": 0, "maximum": 127, "step": 1}, "feedback_kinds": [] if row["field"] == "fresh" else ["value"]}
                    for row in variant["targets"]]}
                with self.assertRaises(SurfaceError) as error:
                    _profile_mapping(client, load_mapping("bcr"))
                self.assertEqual(error.exception.code, "unsupported_feedback")

    def test_missing_default_button_feedback_is_a_real_http_zero_write_preflight(self):
        document = load_mapping("bcr")
        variant = document["profiles"][1]
        controls = []
        for row in variant["targets"]:
            button = row["kind"] == "indicator"
            control = {"id": row["control_id"], "input_kind": "button" if button else "absolute", "encoding": "boolean" if button else "scalar",
                       "feedback_kinds": [] if button else ["value"], "accepts_input": False}
            if not button:
                control["range"] = {"minimum": 0, "maximum": 127, "step": 1}
            controls.append(control)
        profile = {"id": variant["profile_id"], "version": variant["profile_version"], "controls": controls,
                   "capabilities": ["hardware", "controls.input_declared", "input.absolute", "input.button", "feedback.value", "feedback.unsequenced"]}
        with TestOnlyHardwareHost(TOKEN, profile=profile) as host:
            result = run(self.client(host), document, duration=0.1)
            self.assertEqual(result["reason"], "unsupported_feedback")
            self.assertEqual(host.requests, ["surface_control_discover"])
            self.assertEqual(host.records, [])

    def test_numeric_freshness_mapping_cannot_claim_that_ring_zero_is_dark(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            value = mapping(host.profile)
            value["profiles"][0]["targets"] = [{"control_id": "axis", "kind": "value", "field": "fresh", "source_range": [0, 1], "output_range": [0, 127], "rest": 0}]
            result = run(self.client(host), value, duration=0.1)
            self.assertEqual(result["reason"], "invalid_mapping")
            self.assertEqual(host.records, [])

    def test_only_changed_values_are_sent_between_cleanups(self):
        with TestOnlyHardwareHost(TOKEN) as host:
            class Constant:
                def sample(self, now):
                    return {"published_at": now, "values": {"speed": 0, "fresh": True}}
            result = self.execute(host, source=Constant())
            self.assertGreater(result["frames"], 1)
            self.assertEqual(len(host.records), 4)
            self.assert_rest(host)

    def test_token_pipe_rejects_files_and_full_role_record(self):
        with tempfile.TemporaryFile() as file:
            with self.assertRaises(SurfaceError):
                read_token(file.fileno())
        for payload, valid in ((TOKEN.encode(), True), (b'{"display":"example"}', False), (b"", False)):
            read, write = os.pipe()
            try:
                os.write(write, payload); os.close(write)
                if valid:
                    self.assertEqual(read_token(read), TOKEN)
                else:
                    with self.assertRaises(SurfaceError):
                        read_token(read)
            finally:
                os.close(read)

    def test_cli_signal_interrupt_clears_display_in_real_subprocess(self):
        for interruption in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=interruption), TestOnlyHardwareHost(TOKEN) as host, tempfile.TemporaryDirectory() as scratch:
                map_path = Path(scratch) / "mapping.json"
                map_path.write_text(json.dumps(mapping(host.profile)))
                read, write = os.pipe()
                os.write(write, TOKEN.encode()); os.close(write)
                env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(Path(__file__).resolve().parents[1])}
                process = subprocess.Popen([sys.executable, "-B", "-m", "surface_panel_demo", "--url", host.url, "--instance-id", host.instance_id,
                                            "--mapping", str(map_path), "--source", "hardware", "--duration", "10", "--hz", "10", "--token-fd", str(read)],
                                           pass_fds=(read,), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                os.close(read)
                try:
                    deadline = time.monotonic() + 3
                    while host.feedback_values.get("button", {}).get("indicator") != "on" and time.monotonic() < deadline:
                        time.sleep(0.005)
                    self.assertEqual(host.feedback_values.get("button", {}).get("indicator"), "on")
                    process.send_signal(interruption)
                    stdout, stderr = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 0, stderr)
                    result = json.loads(stdout)
                    self.assertEqual(result["reason"], "interrupted")
                    self.assertEqual(result["cleanup_failed"], 0)
                    self.assertNotIn(TOKEN.encode(), stdout + stderr)
                    self.assert_rest(host)
                finally:
                    if process.poll() is None:
                        process.kill(); process.communicate()

    def test_cli_invalid_arguments_do_not_reflect_values(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(main(["--unrecognized", TOKEN]), 2)
        self.assertNotIn(TOKEN, output.getvalue())

    def test_demo_runs_from_sdk_zip_without_checkout_or_swift(self):
        with TestOnlyHardwareHost(TOKEN) as host, tempfile.TemporaryDirectory() as scratch:
            root = Path(__file__).resolve().parents[1]
            archive_path = Path(scratch) / "sdk.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for package in ("surface_control", "surface_panel_demo"):
                    for source in sorted((root / package).rglob("*")):
                        if source.suffix in (".py", ".json"):
                            archive.write(source, str(source.relative_to(root)))
            map_path = Path(scratch) / "map.json"
            map_path.write_text(json.dumps(mapping(host.profile)))
            read, write = os.pipe()
            os.write(write, TOKEN.encode()); os.close(write)
            env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(archive_path)}
            try:
                result = subprocess.run([sys.executable, "-B", "-m", "surface_panel_demo", "--url", host.url, "--instance-id", host.instance_id,
                                         "--mapping", str(map_path), "--source", "hardware", "--duration", "0.1", "--hz", "10", "--token-fd", str(read)],
                                        pass_fds=(read,), capture_output=True, env=env, cwd=scratch, timeout=3)
            finally:
                os.close(read)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["cleanup_failed"], 0)
            self.assertNotIn(TOKEN.encode(), result.stdout + result.stderr)
            self.assert_rest(host)


if __name__ == "__main__":
    unittest.main()
