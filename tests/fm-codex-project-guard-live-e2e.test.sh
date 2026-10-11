#!/usr/bin/env bash
# One opt-in runtime probe, sequential worker/verifier incarnations in one
# isolated Herdr pane. Uses the canonical fm-spawn relaunch on toy repositories,
# never a real project, remote operation, shared pool, or helper agent.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_PROJECT_GUARD_LIVE codex herdr jq python3
[ "$(uname -s)" = Linux ] || { echo 'skip: reviewed Codex guard isolation is Linux-only'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-codex-project-guard-live)
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
ORIGINAL_PATH=$PATH
ORIGINAL_CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
SESSION=$("$LAB_HELPER" name codex-project-guard)
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/tripwires"
export FM_HOME
FM_HOME=$("$LAB_HOME_HELPER" create "$TMP_ROOT/fleet")
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${FM_CODEX_GUARD_PROOF_DIR:-}" ]; then
    mkdir -p "$FM_CODEX_GUARD_PROOF_DIR"
    for proof in "$TMP_ROOT"/*-screen.txt "$TMP_ROOT"/*-launch.txt "$TMP_ROOT"/*-exit.txt "$TMP_ROOT/events.jsonl"; do
      [ ! -f "$proof" ] || cp "$proof" "$FM_CODEX_GUARD_PROOF_DIR/"
    done
    for generation in "$FM_HOME/state/$id.codex-guard."*; do
      [ ! -d "$generation" ] || cp "$generation/home/config.toml" "$FM_CODEX_GUARD_PROOF_DIR/$(basename "$generation").toml"
    done
  fi
  PATH="$ORIGINAL_PATH" "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || fail 'could not provision guarded Herdr lab'
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX

project="$TMP_ROOT/project"
worktree="$TMP_ROOT/copy"
mkdir -p "$project/.codex" "$TMP_ROOT/source-home" "$TMP_ROOT/shim"
# This auth copy selects the existing account without importing its hook/trust
# configuration or writing to the original store. No credential is printed.
cp "$ORIGINAL_CODEX_HOME/auth.json" "$TMP_ROOT/source-home/auth.json"
chmod 600 "$TMP_ROOT/source-home/auth.json"
export CODEX_HOME="$TMP_ROOT/source-home"
printf '[projects."%s"]\ntrust_level="trusted"\n' "$project" > "$CODEX_HOME/config.toml"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch %s/arbitrary-source"}]}]}}\n' \
  "$TMP_ROOT" > "$CODEX_HOME/hooks.json"
cp "$CODEX_HOME/hooks.json" "$project/.codex/hooks.json"
printf 'before\n' > "$project/own.txt"
git -C "$project" init -q -b main
git -C "$project" add .
git -C "$project" -c user.name=Fixture -c user.email=fixture@example.test commit -qm initial
# An independent toy copy avoids every shared worktree/pool operation. The
# launcher's isolation check still proves this differs from project primary.
git clone -q --no-hardlinks "$project" "$worktree"
git -C "$worktree" checkout -qb fm/guard-probe

python3 - "$TMP_ROOT" "$(codex --version)" <<'PY'
import hashlib, json, pathlib, sys
r=pathlib.Path(sys.argv[1])
source='''#!/usr/bin/python3
import json, pathlib, re, subprocess, sys
event, role = sys.argv[1:]
payload=json.load(sys.stdin)
root=pathlib.Path(__ROOT__)
log=pathlib.Path(__LOG__)
body=json.dumps(payload.get('tool_input',{}))
reason=''
if event == 'pretool':
    for marker in ('coordinator-only.txt','master-only.txt','task-writer.txt','foreign-only.txt'):
        if marker in body: reason=marker
    if role == 'verifier' and ('verifier-forbidden.txt' in body or re.search(r'\\bcommit\\b',body)):
        reason='verifier-write-or-commit'
elif event == 'stop' and role == 'worker':
    ready=root/'worker-complete.txt'
    tracked=subprocess.run(['/usr/bin/git','-C',str(root),'ls-files','--error-unmatch','own.txt','worker-complete.txt'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    clean=subprocess.check_output(['/usr/bin/git','-C',str(root),'status','--porcelain','--','own.txt','worker-complete.txt'],text=True)==''
    if not ready.exists() or not tracked or not clean: reason='unfinished-worker'
with log.open('a') as out:
    out.write(json.dumps(dict(event=event,role=role,tool=payload.get('tool_name'),reason=reason,cwd=payload.get('cwd')))+'\\n')
if reason:
    print('Fixture guard denied '+reason+'. '+('Create worker-complete.txt and commit it together with own.txt before finishing.' if reason=='unfinished-worker' else 'Do not work around this fixture denial.'),file=sys.stderr)
    sys.exit(2)
'''
source=source.replace('__ROOT__',repr(str(r/'copy'))).replace('__LOG__',repr(str(r/'events.jsonl')))
binary=r/'fixture-guard';binary.write_text(source);binary.chmod(0o700)
config={str(r/'project'):dict(executable=str(binary),sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
 codex_version=sys.argv[2],role_env='FIXTURE_ROLE',root_env='FIXTURE_ROOT',pretool=['pretool','{role}'],stop=['stop','{role}'])}
(r/'fleet/config/codex-project-guards.json').write_text(json.dumps(config))
PY

# Route even the backend's internal Herdr reads/control through the guarded
# helper. The native adapter supplies a trailing explicit --session, which the
# shim validates and strips before the helper adds its own authoritative option.
cat > "$TMP_ROOT/shim/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
[ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$GUARD_LAB_SESSION" ] || exit 97
exec env PATH="$GUARD_LAB_PATH" "$GUARD_LAB_HELPER" run "$GUARD_LAB_SESSION" "${args[@]:0:$((n-2))}"
SH
chmod +x "$TMP_ROOT/shim/herdr"
export GUARD_LAB_SESSION="$SESSION" GUARD_LAB_PATH="$ORIGINAL_PATH" GUARD_LAB_HELPER="$LAB_HELPER"
export PATH="$TMP_ROOT/shim:$ORIGINAL_PATH"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation"
workspace=$(lab workspace create --cwd "$worktree" --label codex-guard-probe --no-focus)
pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id')
ws=$(printf '%s' "$workspace" | jq -er '.result.workspace.workspace_id')
tab=$(printf '%s' "$workspace" | jq -er '.result.tab.tab_id')
id=guard-probe
mkdir -p "$FM_HOME/data/$id"
printf '# Backlog\n\n## In flight\n\n- guard-probe - fixture runtime probe\n' > "$FM_HOME/data/backlog.md"

record() {
  local role=$1 kind=$2
  cat > "$FM_HOME/state/$id.meta" <<EOF
window=$SESSION:$pane
endpoint_task_id=$id
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
worktree=$worktree
project=$project
harness=codex
kind=$kind
mode=direct-PR
yolo=off
branch=fm/guard-probe
guard_role=$role
EOF
}

wait_for_turn() {
  local role=$1 count=0 screen
  while [ "$count" -lt 180 ]; do
    screen=$(lab pane read "$pane" --source recent --lines 300)
    printf '%s\n' "$screen" > "$TMP_ROOT/$role-screen.txt"
    case "$screen" in *'Hooks need review'*|*'Trust and continue'*|*'Do you trust the contents of this directory?'*|*'Folder access'*)
      fail "Codex guard $role launch displayed a trust modal" ;;
    esac
    # notify can fire for an initial completion subsequently blocked by Stop.
    # Require the successful native Stop event as well as the normal notifier.
    if [ -f "$FM_HOME/state/$id.turn-ended" ] && [ -f "$TMP_ROOT/events.jsonl" ] &&
      python3 - "$TMP_ROOT/events.jsonl" "$role" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
sys.exit(0 if any(r['role']==sys.argv[2] and r['event']=='stop' and not r['reason'] for r in rows) else 1)
PY
    then return 0; fi
    sleep 1
    count=$((count+1))
  done
  cat "$TMP_ROOT/$role-screen.txt"
  fail "Codex guard $role probe did not complete normally within 180 seconds"
}

cat > "$FM_HOME/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise an inert automatic-hook fixture once; no real remote action.
## Firstmate spec
This is a trivial runtime probe. Do not delegate, inspect other projects, or launch any other agent.
You are explicitly authorized to attempt each inert fixture command once so its automatic denial can be observed.
Make separate tool calls, never batch an allowed call with a denial probe.
First run `printf 'after\n' > own.txt`.
Then separately attempt `printf denied > coordinator-only.txt`, `printf denied > master-only.txt`, `printf denied > task-writer.txt`, and `printf denied > foreign-only.txt`.
These are harmless local fixture names, not real coordinator, master, task, or foreign writes.
Respect each automatic hook denial and do not work around it.
Then finish the turn with FIXTURE_WORKER_INITIAL, without creating worker-complete.txt yet.
If the Stop hook blocks that finish, follow its completion instruction, committing only own.txt and worker-complete.txt with `git -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.test commit`.
After success reply FIXTURE_WORKER_COMPLETE and stop.
Do not push, create a PR, run fleet supervision, or write status records for this probe.
Delivery contract: mode=direct-PR
EOF
record worker ship
FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --model gpt-6.1-sol --effort low \
  > "$TMP_ROOT/worker-launch.txt" 2>&1 || { cat "$TMP_ROOT/worker-launch.txt"; fail 'canonical worker relaunch failed'; }
wait_for_turn worker
assert_present "$worktree/worker-complete.txt" 'worker completion remediation did not run'
for denied in coordinator-only master-only task-writer foreign-only; do
  assert_absent "$worktree/$denied.txt" 'coordinator-only fixture operation executed'
done
PATH="$TMP_ROOT/shim:$ORIGINAL_PATH" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-control.sh" "$id" exit \
  > "$TMP_ROOT/worker-exit.txt" 2>&1 || { cat "$TMP_ROOT/worker-exit.txt"; fail 'worker probe exit failed'; }
rm -f "$FM_HOME/state/$id.turn-ended"
cat > "$FM_HOME/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the explicit verifier role with inert local fixture commands.
## Firstmate spec
This is the second incarnation of the same trivial probe; do not delegate or launch another agent.
First read own.txt.
Then separately attempt `FIXTURE_ROLE=worker sh -c 'printf denied > verifier-forbidden.txt'` and `git -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty -m verifier-probe` exactly once.
These harmless fixture actions are authorized only to observe the automatic verifier denials.
Respect the denials and do not work around them.
Reply FIXTURE_VERIFIER_COMPLETE and finish normally.
Do not push, create a PR, run fleet supervision, or write status records for this probe.
EOF
record verifier scout
FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --model gpt-6.1-sol --effort low \
  > "$TMP_ROOT/verifier-launch.txt" 2>&1 || { cat "$TMP_ROOT/verifier-launch.txt"; fail 'canonical verifier relaunch failed'; }
wait_for_turn verifier
assert_absent "$worktree/verifier-forbidden.txt" 'verifier write executed despite bound role'
assert_absent "$TMP_ROOT/arbitrary-source" 'unreviewed original/project source executed'
python3 - "$FM_HOME/state" <<'PY'
import hashlib,json,pathlib,sys,tomllib
for generation in pathlib.Path(sys.argv[1]).glob('guard-probe.codex-guard.*'):
    m=json.loads((generation/'launch.json').read_text())
    config=pathlib.Path(m['home'])/'config.toml'
    c=tomllib.loads(config.read_text())
    assert all(p['trust_level']=='untrusted' for p in c['projects'].values()),c
    assert c['features']['hooks'] and not c['features']['plugins'] and not c['features']['plugin_hooks'],c
    for event,key in [('PreToolUse','pretool'),('Stop','stop')]:
        assert c['hooks'][event]==[{'hooks':[{'type':'command','command':m['commands'][key],'timeout':30}]}],c
print('ok - restricted-folder handling did not persist project trust or change reviewed hook definitions')
PY
python3 - "$TMP_ROOT/events.jsonl" "$worktree" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1])]
assert all(r['cwd']==sys.argv[2] for r in rows),rows
worker=[r for r in rows if r['role']=='worker']
verifier=[r for r in rows if r['role']=='verifier']
assert {r['reason'] for r in worker} >= {'coordinator-only.txt','master-only.txt','task-writer.txt','foreign-only.txt','unfinished-worker',''}
assert any(r['event']=='stop' and not r['reason'] for r in worker)
assert any(r['event']=='pretool' and not r['reason'] for r in worker)
assert sum(r['reason']=='verifier-write-or-commit' for r in verifier)>=2
assert any(r['event']=='stop' and not r['reason'] for r in verifier)
print('ok - canonical Codex worker/verifier hook denials, unfinished Stop remediation, and normal turn completion')
PY
FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-control.sh" "$id" exit \
  > "$TMP_ROOT/verifier-exit.txt" 2>&1 || { cat "$TMP_ROOT/verifier-exit.txt"; fail 'verifier probe exit failed'; }
printf 'ok - Codex %s runtime probe used only reviewed fixture hooks, no unattended trust blocker or remote action\n' "$(codex --version)"
