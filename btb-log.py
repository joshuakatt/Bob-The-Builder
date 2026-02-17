#!/usr/bin/env python3
import boto3, time
ssm = boto3.client('ssm', region_name='us-east-2')
WORKER = 'i-0acb15395bc809a30'
JOB_ID = '8e8fff5c-4287-47cc-9f17-9e7a807e7999'
REPO = f'/var/btb/jobs/{JOB_ID}/repo'

script = f"""#!/bin/bash
set +e
LOG=$(ls -t {REPO}/.ralph-logs/task_2_2_*.log 2>/dev/null | head -1)
if [ -n "$LOG" ]; then
    echo "=== Log file: $LOG ==="
    echo "=== Size: $(wc -c < $LOG) bytes ==="
    cat "$LOG"
else
    echo "No task 2.2 log found"
fi
"""

resp = ssm.send_command(
    InstanceIds=[WORKER],
    DocumentName='AWS-RunShellScript',
    Parameters={
        'commands': [script],
        'executionTimeout': ['60'],
    },
    TimeoutSeconds=60,
)
cmd_id = resp['Command']['CommandId']
for _ in range(20):
    time.sleep(3)
    try:
        inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=WORKER)
        if inv['Status'] in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
            out = inv.get('StandardOutputContent', '')
            print(out)
            err = inv.get('StandardErrorContent', '')
            if err:
                print('STDERR:', err)
            break
    except Exception:
        pass
