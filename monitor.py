#!/usr/bin/env python3
"""Monitor btb job progress. Checks every hour."""
import subprocess, os, time, sys
from datetime import datetime

COORDINATOR = "ec2-user@3.144.45.199"
SSH_KEY = os.path.expanduser("~/.ssh/btb.pem")
SLEEP_INTERVAL = 3600  # 1 hour

def ssh(cmd, timeout=30):
    try:
        r = subprocess.run(
            ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
             "-o", "ConnectTimeout=10", COORDINATOR, cmd],
            capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return f"ERROR: {e}", 1

def scp_to(local, remote):
    subprocess.run(
        ["scp", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
         local, f"{COORDINATOR}:{remote}"],
        capture_output=True, text=True, timeout=30
    )

def check():
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n{'='*60}")
    print(f"CHECK @ {ts}")
    print(f"{'='*60}")

    # Get job status from dashboard API
    out, rc = ssh(
        "curl -sk https://localhost:8443/api/jobs 2>/dev/null "
        "| python3 -c \""
        "import sys,json; jobs=json.load(sys.stdin); "
        "j=jobs[0] if jobs else {}; "
        "print('Job:', j.get('id','?')[:8], ' Status:', j.get('status','?'), "
        "' Spec:', j.get('spec_name','?'), ' Started:', j.get('started_at','?'))"
        "\""
    )
    print(f"\n{out}")

    # Get worker instance state
    out, rc = ssh(
        "python3 -c \""
        "import boto3; ec2=boto3.client('ec2',region_name='us-east-2'); "
        "r=ec2.describe_instances(InstanceIds=['i-0acb15395bc809a30']); "
        "print('Worker:', r['Reservations'][0]['Instances'][0]['State']['Name'])"
        "\""
    )
    print(out)
    worker_running = "running" in out.lower()

    if not worker_running:
        print("Worker not running — job may be queued or finished.")
        return

    # Write a check script to coordinator, then run it via SSM
    check_script = r"""#!/usr/bin/env python3
import boto3, time
ssm = boto3.client('ssm', region_name='us-east-2')
WORKER = 'i-0acb15395bc809a30'
script = r'''#!/bin/bash
set +e
JOB_DIR=$(ls -td /var/btb/jobs/*/repo 2>/dev/null | head -1)
if [ -z "$JOB_DIR" ]; then echo "No job dir found"; exit 0; fi
echo "Job dir: $JOB_DIR"

TASK_FILE=$(find "$JOB_DIR" -path "*/specs/*/tasks.md" 2>/dev/null | head -1)
if [ -n "$TASK_FILE" ]; then
    DONE=$(grep -c '\[x\]' "$TASK_FILE" 2>/dev/null || echo 0)
    TOTAL=$(grep -c '\[.\]' "$TASK_FILE" 2>/dev/null || echo 0)
    echo "Tasks: $DONE/$TOTAL complete"
fi

echo ""
echo "Active workers:"
ps aux 2>/dev/null | grep 'worker.sh' | grep -v grep | awk '{print "  PID", $2}' | head -10

DEBUG_LOG=$(ls -t "$JOB_DIR"/.ralph-logs/debug_*.log 2>/dev/null | head -1)
if [ -n "$DEBUG_LOG" ]; then
    echo ""
    echo "Last 15 debug log lines:"
    tail -15 "$DEBUG_LOG" 2>&1
fi

echo ""
echo "Task log activity (last modified):"
for f in $(ls -t "$JOB_DIR"/.ralph-logs/task_*.log 2>/dev/null | head -10); do
    BASENAME=$(basename "$f")
    MOD=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( (NOW - MOD) / 60 ))
    SIZE=$(wc -c < "$f" 2>/dev/null || echo 0)
    echo "  $BASENAME: ${AGE}m ago, ${SIZE} bytes"
done
'''
resp = ssm.send_command(
    InstanceIds=[WORKER],
    DocumentName='AWS-RunShellScript',
    Parameters={'commands': [script], 'executionTimeout': ['30']},
    TimeoutSeconds=30,
)
cmd_id = resp['Command']['CommandId']
for _ in range(12):
    time.sleep(3)
    try:
        inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=WORKER)
        if inv['Status'] in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
            print(inv.get('StandardOutputContent', ''))
            break
    except:
        pass
"""
    with open("/tmp/btb-check.py", "w") as f:
        f.write(check_script)
    scp_to("/tmp/btb-check.py", "/tmp/btb-check.py")
    out, rc = ssh("python3 /tmp/btb-check.py", timeout=90)
    print(out)
    ssh("rm -f /tmp/btb-check.py")

# Main loop
cycle = 0
while True:
    cycle += 1
    print(f"\n>>> Cycle {cycle}")
    check()
    print(f"\nNext check in {SLEEP_INTERVAL // 60} minutes...")
    sys.stdout.flush()
    time.sleep(SLEEP_INTERVAL)
