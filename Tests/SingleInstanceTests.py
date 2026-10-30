"""Process-level contention and crash recovery, using only a temporary lock."""
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='qishi-lock-test-') as folder:
    path = str(pathlib.Path(folder) / 'instance.lock')
    args = [sys.argv[1], '--lock', path]
    processes = [subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
    outcomes = [p.stdout.readline().strip() for p in processes]
    assert outcomes.count('ACQUIRED') == 1, outcomes
    assert outcomes.count('BLOCKED') == 7, outcomes
    holder = processes[outcomes.index('ACQUIRED')]
    holder.kill()
    for p in processes:
        p.wait(timeout=5)
    restarted = subprocess.run(args, capture_output=True, text=True, check=True, timeout=5)
    assert restarted.stdout.strip() == 'ACQUIRED', restarted
    print('PASS: 8 simultaneous launches admit exactly one process; killed owner leaves no stale lock')
