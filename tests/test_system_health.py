"""Deterministic end-to-end checks of the Bash collector and rotating output."""

import fcntl
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/system_health.sh"


@pytest.fixture
def health_runner(tmp_path):
    proc = tmp_path / "proc"
    (proc / "self").mkdir(parents=True)
    (proc / "loadavg").write_text("0.25 0.50 0.75 1/10 123\n")
    (proc / "self/mounts").write_text(
        "/dev/sda1 / ext4 rw 0 0\n"
        "tmpfs /virtual tmpfs rw 0 0\n"
        '/dev/sdb1 /mnt/space\\040and\\040"quote ext4 rw 0 0\n'
        "/dev/loop0 /snapshot squashfs ro 0 0\n"
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    commands = {
        "sleep": "import os,shutil; shutil.copyfile(os.environ['HEALTH_NEXT_STAT'], os.environ['HEALTH_PROC_STAT'])",
        "ps": "print('101 4096 20.0 a\"quoted\\\\process\\n102 2048 10.0 two words\\n103 1024 5.0 third\\n104 512 2.5 fourth\\n105 256 1.2 fifth\\n106 128 0.6 sixth')",
        "df": """import os,sys
mount = sys.argv[-1]
if os.environ.get('FAIL_DF') == '1' and mount == '/':
    sys.exit(1)
print('1B-blocks Used Available Use%')
if mount == '/snapshot':
    print('1000 1000 0 100%')
elif mount == '/virtual':
    print('0 0 0 -')
else:
    percent = int(os.environ['HEALTH_DISK_PERCENT'])
    print(f'1000 {percent*10} {1000-percent*10} {percent}%')
""",
    }
    for name, body in commands.items():
        target = fake_bin / name
        target.write_text(f"#!{sys.executable}\n{body}\n")
        target.chmod(0o755)

    def run(*args, cpu=10, mem=20, disk=30, fail_df=False):
        (proc / "stat").write_text("cpu 100 0 0 900 0 0 0 0 0 0\n")
        next_stat = tmp_path / "next-stat"
        next_stat.write_text(f"cpu {100 + cpu} 0 0 {1000 - cpu} 0 0 0 0 0 0\n")
        (proc / "meminfo").write_text(f"MemTotal: 1000 kB\nMemAvailable: {1000 - mem * 10} kB\n")
        env = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "HEALTH_NEXT_STAT": str(next_stat),
            "HEALTH_PROC_STAT": str(proc / "stat"),
            "HEALTH_DISK_PERCENT": str(disk),
            "FAIL_DF": "1" if fail_df else "0",
        }
        return subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--proc-root",
                str(proc),
                "--sample-seconds",
                "0.01",
                "--log-file",
                str(tmp_path / "health_log.txt"),
                *args,
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )

    return run, tmp_path


def test_json_metrics_all_mounts_and_top_five(health_runner):
    run, directory = health_runner
    result = run("--json")
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert data["cpu"]["usage_percent"] == 10
    assert data["memory"]["usage_percent"] == 20
    assert data["load_average"] == {"1m": 0.25, "5m": 0.5, "15m": 0.75}
    assert len(data["filesystems"]) == 4
    assert data["filesystems"][3]["read_only"] is True
    assert data["filesystems"][3]["usage_percent"] == 100
    assert data["filesystems"][1]["usage_percent"] is None
    assert data["filesystems"][2]["mountpoint"] == '/mnt/space and "quote'
    assert len(data["top_processes"]) == 5
    assert data["top_processes"][0]["command"] == 'a"quoted\\process'
    assert data["top_processes"][1]["command"] == "two words"
    assert data["status"] == "healthy"
    assert result.stderr == ""
    assert (directory / "health_log.txt").read_text() == result.stdout


@pytest.mark.parametrize("metric,threshold", [("cpu", 90), ("mem", 85), ("disk", 80)])
def test_warning_boundaries(health_runner, metric, threshold):
    run, _ = health_runner
    result = run("--json", **{metric: threshold})
    assert result.returncode == 1, result.stderr
    assert json.loads(result.stdout)["status"] == "warning"
    assert "[WARNING]" in result.stderr
    assert "[WARNING]" not in result.stdout


@pytest.mark.parametrize("metric", ["cpu", "mem", "disk"])
def test_critical_boundaries(health_runner, metric):
    run, _ = health_runner
    result = run("--json", **{metric: 95})
    assert result.returncode == 2, result.stderr
    data = json.loads(result.stdout)
    assert data["status"] == "critical"
    assert "[CRITICAL]" in result.stderr


def test_custom_thresholds_and_highest_severity(health_runner):
    run, _ = health_runner
    result = run("--json", "--cpu", "20", "--critical-cpu", "30", cpu=35, disk=85)
    assert result.returncode == 2
    assert {a["severity"] for a in json.loads(result.stdout)["alerts"]} == {"warning", "critical"}


def test_collection_failure_is_logged_as_critical(health_runner):
    run, _ = health_runner
    result = run("--json", fail_df=True)
    assert result.returncode == 2
    data = json.loads(result.stdout)
    assert data["filesystems"][0]["error"] == "unavailable or timed out"
    assert data["filesystems"][0]["usage_percent"] is None


def test_bounded_rotation_preserves_json_records(health_runner):
    run, directory = health_runner
    first = run("--json")
    assert first.returncode == 0
    limit = len(first.stdout.encode()) + 20
    for _ in range(4):
        result = run("--json", "--max-log-bytes", str(limit), "--keep-logs", "2")
        assert result.returncode == 0, result.stderr
    for name in ("health_log.txt", "health_log.txt.1", "health_log.txt.2"):
        path = directory / name
        assert path.stat().st_size <= limit
        assert json.loads(path.read_text())["status"] == "healthy"
    assert not (directory / "health_log.txt.3").exists()


def test_refuses_symlink_log(health_runner):
    run, directory = health_runner
    target = directory / "other-file"
    target.write_text("preserve")
    (directory / "health_log.txt").symlink_to(target)
    assert run("--json").returncode == 2
    assert target.read_text() == "preserve"


def test_oversized_record_is_not_appended(health_runner):
    run, directory = health_runner
    result = run("--json", "--max-log-bytes", "10")
    assert result.returncode == 2
    assert "One snapshot exceeds" in result.stderr
    assert not (directory / "health_log.txt").exists()


def test_text_output_and_normalized_interval(health_runner):
    run, _ = health_runner
    result = run()
    assert result.returncode == 0
    assert "status=healthy" in result.stdout
    assert "CPU=10.00%" in result.stdout
    assert (
        json.loads(run("--json", "--sample-seconds", "00.01").stdout)["cpu"]["sample_seconds"]
        == 0.01
    )


@pytest.mark.parametrize(
    "arguments",
    [
        ["--unknown"],
        ["--cpu"],
        ["--cpu", "-1"],
        ["--mem", "101"],
        ["--disk", "bad"],
        ["--cpu", "96"],
        ["--sample-seconds", "0"],
        ["--keep-logs", "0"],
        ["--df-timeout", "61"],
    ],
)
def test_invalid_arguments(arguments):
    result = subprocess.run(["bash", str(SCRIPT), *arguments], capture_output=True, text=True)
    assert result.returncode == 2
    assert "[CRITICAL]" in result.stderr


def test_help():
    result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "--critical-disk" in result.stdout


def test_waits_for_an_existing_log_writer(health_runner):
    run, directory = health_runner
    with (directory / "health_log.txt.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(run, "--json")
            time.sleep(0.1)
            assert not future.done()
            assert not (directory / "health_log.txt").exists()
            fcntl.flock(lock, fcntl.LOCK_UN)
            assert future.result(timeout=10).returncode == 0
