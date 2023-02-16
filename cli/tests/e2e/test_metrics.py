"""
Tests for semgrep.metrics and associated command-line arguments.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import uuid
from typing import Iterator

import dateutil.tz
import freezegun.api
import pytest
from semgrep.cli import cli
from semgrep.profiling import ProfilingData

from tests.conftest import TESTS_PATH
from tests.semgrep_runner import SemgrepRunner

# Test data to avoid making web calls in test code

USELESS_EQEQ = """rules:
- id: python.lang.correctness.useless-eqeq.useless-eqeq
  patterns:
  - pattern-not-inside: |
      def __eq__(...):
          ...
  - pattern-not-inside: |
      def __cmp__(...):
          ...
  - pattern-not-inside: assert(...)
  - pattern-not-inside: assert ..., ...
  - pattern-not-inside: assertTrue(...)
  - pattern-not-inside: assertFalse(...)
  - pattern-either:
    - pattern: $X == $X
    - pattern: $X != $X
  - pattern-not: 1 == 1
  message: 'This expression is always True: `$X == $X` or `$X != $X`. If testing for
    floating point NaN, use `math.isnan($X)`, or `cmath.isnan($X)` if the number is
    complex.'
  languages:
  - python
  severity: ERROR
  metadata:
    category: correctness
    license: Commons Clause License Condition v1.0[LGPL-2.1-only]
    source: https://semgrep.dev/r/python.lang.correctness.useless-eqeq.useless-eqeq
"""


@pytest.fixture()
def _mock_config_request(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "semgrep.config_resolver.ConfigLoader._make_config_request",
        lambda s: USELESS_EQEQ,
    )


@pytest.mark.kinda_slow()
@pytest.mark.parametrize(
    ("config", "metrics_flag", "metrics_env", "should_send"),
    [
        ("rules/eqeq.yaml", None, None, False),
        ("r/python.lang.correctness.useless-eqeq.useless-eqeq", None, None, True),
        ("rules/eqeq.yaml", "auto", None, False),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            "auto",
            None,
            True,
        ),
        ("rules/eqeq.yaml", "on", None, True),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            "on",
            None,
            True,
        ),
        ("rules/eqeq.yaml", "off", None, False),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            "off",
            None,
            False,
        ),
        ("rules/eqeq.yaml", None, "auto", False),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            None,
            "auto",
            True,
        ),
        ("rules/eqeq.yaml", None, "off", False),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            None,
            "off",
            False,
        ),
        ("rules/eqeq.yaml", None, "on", True),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            None,
            "on",
            True,
        ),
        (
            "rules/eqeq.yaml",
            "auto",
            "on",
            False,
        ),
        (
            "r/python.lang.correctness.useless-eqeq.useless-eqeq",
            "auto",
            "off",
            True,
        ),
    ],
)
def test_flags(
    run_semgrep_in_tmp,
    mock_config_request,
    config,
    metrics_flag,
    metrics_env,
    should_send,
):
    """
    Test that we try to send metrics when we should be
    """
    options = ["--metrics", metrics_flag] if metrics_flag is not None else []
    env = {"SEMGREP_SEND_METRICS": metrics_env} if metrics_env is not None else {}
    _, stderr = run_semgrep_in_tmp(
        config,
        options=[*options, "--debug"],
        force_metrics_off=False,
        env=env,
    )
    if should_send:
        assert "Sending pseudonymous metrics" in stderr
        assert "Not sending pseudonymous metrics" not in stderr
    else:
        assert "Sending pseudonymous metrics" not in stderr
        assert "Not sending pseudonymous metrics" in stderr


@pytest.mark.kinda_slow()
def test_flags_actual_send(run_semgrep_in_tmp):
    """
    Test that the server for metrics sends back success
    """
    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--debug"],
        env={"SEMGREP_SEND_METRICS": "on"},
        force_metrics_off=False,
    )
    assert "Sending pseudonymous metrics" in stderr
    assert "Failed to send pseudonymous metrics" not in stderr


@pytest.mark.slow()
def test_legacy_flags(run_semgrep_in_tmp):
    """
    Test metrics sending respects legacy flags. Flags take precedence over envvar
    """
    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--debug", "--enable-metrics"],
        force_metrics_off=False,
    )
    assert "Sending pseudonymous metrics" in stderr

    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--debug", "--enable-metrics"],
        env={"SEMGREP_SEND_METRICS": ""},
        force_metrics_off=False,
    )
    assert "Sending pseudonymous metrics" in stderr

    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--debug", "--disable-metrics"],
        force_metrics_off=False,
    )
    assert "Sending pseudonymous metrics" not in stderr

    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--disable-metrics"],
        env={"SEMGREP_SEND_METRICS": "1"},
        force_metrics_off=False,
        assert_exit_code=2,
    )
    assert (
        "--enable-metrics/--disable-metrics can not be used with either --metrics or SEMGREP_SEND_METRICS"
        in stderr
    )

    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--disable-metrics"],
        env={"SEMGREP_SEND_METRICS": "off"},
        force_metrics_off=False,
    )
    assert (
        "--enable-metrics/--disable-metrics can not be used with either --metrics or SEMGREP_SEND_METRICS"
        not in stderr
    )

    _, stderr = run_semgrep_in_tmp(
        "rules/eqeq.yaml",
        options=["--enable-metrics"],
        env={"SEMGREP_SEND_METRICS": "on"},
        force_metrics_off=False,
    )
    assert (
        "--enable-metrics/--disable-metrics can not be used with either --metrics or SEMGREP_SEND_METRICS"
        not in stderr
    )


def _mask_version(value: str) -> str:
    return re.sub(r"\d+", "x", value)


@pytest.mark.quick()
@pytest.mark.freeze_time("2017-03-03")
@pytest.mark.skipif(
    sys.version_info < (3, 8),
    reason="snapshotting mock call kwargs doesn't work on py3.7",
)
@pytest.mark.parametrize("pro_flag", [["--pro"], []])
def test_metrics_payload(tmp_path, snapshot, mocker, monkeypatch, pro_flag):
    # make the formatted timestamp strings deterministic
    mocker.patch.object(
        freezegun.api, "tzlocal", return_value=dateutil.tz.gettz("Asia/Tokyo")
    )
    original_tz = os.environ.get("TZ")
    os.environ["TZ"] = "Asia/Tokyo"
    time.tzset()

    # make the rule, file timings, and memory usage deterministic
    mocker.patch.object(ProfilingData, "set_file_times")
    mocker.patch.object(ProfilingData, "set_rules_parse_time")
    mocker.patch.object(ProfilingData, "set_max_memory_bytes")

    # make the event ID deterministic
    mocker.patch("uuid.uuid4", return_value=uuid.UUID("0" * 32))

    mock_post = mocker.patch("requests.post")

    (tmp_path / ".settings.yaml").write_text(
        f"anonymous_user_id: {str(uuid.UUID('1' * 32))}"
    )
    (tmp_path / "code.py").write_text("5 == 5")
    (tmp_path / "rule.yaml").symlink_to(TESTS_PATH / "e2e" / "rules" / "eqeq.yaml")
    monkeypatch.chdir(tmp_path)

    runner = SemgrepRunner(
        env={"SEMGREP_SETTINGS_FILE": str(tmp_path / ".settings.yaml")}
    )
    runner.invoke(
        cli, ["scan", "--config=rule.yaml", "--metrics=on", "code.py", *pro_flag]
    )

    payload = json.loads(mock_post.call_args.kwargs["data"])
    payload["environment"]["version"] = _mask_version(payload["environment"]["version"])
    payload["environment"]["isAuthenticated"] = False

    snapshot.assert_match(
        json.dumps(payload, indent=2, sort_keys=True), "metrics-payload.json"
    )

    if original_tz is not None:
        os.environ["TZ"] = original_tz
    else:
        del os.environ["TZ"]
    time.tzset()
