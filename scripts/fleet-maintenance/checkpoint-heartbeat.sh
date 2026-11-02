#!/usr/bin/env bash
# Tell paphos that the latest Mother checkpoint verified. Runs on loving-kypris
# as ExecStartPost of mother-recovery-checkpoint.service. paphos alerts when
# the heartbeat is older than 36 hours (modules/paphos/ops.nix).
set -euo pipefail

state="${HOME}/.local/state/fleet-maintenance/mother-checkpoint/checkpoint.json"

# Send only for a verified run that finished in the last 6 hours. The exit code
# of the scheduler alone does not prove a verified checkpoint.
python3 - "$state" <<'PY'
import datetime, json, sys
state = json.load(open(sys.argv[1]))
finished = datetime.datetime.fromisoformat(state["finished_at"])
age = (datetime.datetime.now(datetime.timezone.utc) - finished).total_seconds()
sys.exit(0 if state.get("status") == "verified" and 0 <= age <= 6 * 3600 else 1)
PY

# The key on paphos has a forced command. "true" is ignored.
exec timeout 60 ssh -i "${HOME}/.ssh/fleet-heartbeat-paphos" -o IdentitiesOnly=yes \
  -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
  fleet-heartbeat@192.168.99.104 true
