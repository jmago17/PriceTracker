#!/usr/bin/env python3
"""After run-core-tests.py, exercise a restart using two separate test processes.
Only unique synthetic SQLite/JSON files under the requested test package are used.
"""
import os, subprocess, pathlib, uuid
package = pathlib.Path(os.environ['PRICETRACKER_TEST_BUILD'])
fixture = package/('process-recovery-'+str(uuid.uuid4()))
fixture.mkdir()
for phase in ['1', '2']:
    env = dict(os.environ, PRICETRACKER_OUTBOX_PROCESS_FIXTURE=str(fixture), PRICETRACKER_OUTBOX_PROCESS_PHASE=phase)
    command = ['xcrun', 'swift', 'test', '--package-path', str(package), '--skip-build', '--filter', 'OutboxProcessRecoveryTests']
    print('Separate process, phase '+phase, flush=True)
    subprocess.run(command, env=env, check=True, timeout=120)
print('PASS: restart between committed append and ack; stable IDs/sentAt and equal-price retry', flush=True)
