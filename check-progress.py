#!/usr/bin/env python3
import boto3, time
ssm = boto3.client('ssm', region_name='us-east-2')
WORKER = 'i-0acb15395bc809a30'
JOB_ID = '8e8fff5c-4287-47cc-9f17-9e7a807e7999'
REPO = f'/var/btb/jobs/{JOB_ID}/repo'

script = (
    "set +e; "
    "echo '=== Task progress ==='; "
    f"TASK_FILE=$(find {REPO} -path '*/specs/*/tasks.md' 2>/dev/null | head -1); "
    "if [ -n \"$TASK_FILE\" ]; then "
    "  DONE=$(grep -c '\\[x\\]' $TASK_FILE 2>/dev/null || echo 0); "
    "  TOTAL=$(grep -c '\\[.\\]' $TASK_FILE 2>/dev/null || echo 0); "
    "  echo \"Tasks: $DONE/$TOTAL\"; "
    "fi; "
    "echo; echo '=== Active btb/kiro processes ==='; "
    "ps aux | grep -E 'worker.sh|kiro-cli|btb.sh' | grep -v grep; "
    "echo; echo '=== Debug log tail ==='; "
    f"DLOG=$(ls -t {REPO}/.ralph-logs/debug_*.log 2>/dev/null | head -1); "
    "if [ -n \"$DLOG\" ]; then tail -20 $DLOG; else echo 'No debug log'; fi; "
    "echo; echo '=== output.log last 15 lines ==='; "
    f"tail -15 /var/btb/jobs/{JOB_ID}/output.log 2>/dev/null || echo 'No output.log'"
)

resp = ssm.send_command(
    InstanceIds=[WORKER],
    DocumentName='AWS-RunShellScript',
    Parameters={'commands': [script], 'executionTimeout': ['30']},
    TimeoutSeconds=30,
)
cmd_id = resp['Command']['CommandId']
for _ in range(15):
    time.sleep(3)
    try:
        inv = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=WORKER)
        if inv['Status'] in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
            print(inv.get('StandardOutputContent', ''))
            err = inv.get('StandardErrorContent', '')
            if err:
                print('STDERR:', err)
            break
    except Exception:
        pass
