#!/usr/bin/env bash
# Portable behavior regressions for the reviewed Codex guard launch adapter.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "$(uname -s)" = Linux ] || { echo 'skip: guard isolation is Linux-only'; exit 0; }
python3 -c 'import tomllib' 2>/dev/null || { echo 'skip: Python 3.11 required'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-codex-guard)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HELPER="$ROOT/bin/fm-codex-guard.py"
export CODEX_HOME="$TMP_ROOT/original"
mkdir -p "$CODEX_HOME" "$TMP_ROOT/project"
printf '{}\n' > "$CODEX_HOME/auth.json"
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/guard"
chmod +x "$TMP_ROOT/guard"
cat > "$FAKEBIN/codex" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys, tomllib
if sys.argv[1:] == ['--version']:
    print('codex-fixture 1')
elif sys.argv[1] == 'app-server':
    home = pathlib.Path(os.environ['CODEX_HOME'])
    c = tomllib.loads((home/'config.toml').read_text())
    for line in sys.stdin:
        request = json.loads(line)
        if request['method'] == 'initialize':
            print(json.dumps({'id':request['id'],'result':{}}), flush=True)
        elif request['method'] == 'hooks/list':
            hooks = []
            for name, event in [('PreToolUse','preToolUse'),('Stop','stop')]:
                hooks.append(dict(eventName=event, command=c['hooks'][name][0]['hooks'][0]['command'],
                                  source='user', sourcePath=str(home/'config.toml'),
                                  isManaged=False, enabled=True, matcher=None, async_=False,
                                  handlerType='command'))
            mode = os.environ.get('GUARD_FIXTURE_MODE','')
            if mode == 'managed': hooks[0]['isManaged'] = True
            if mode == 'extra': hooks.append(dict(hooks[0], source='project'))
            if mode == 'wrong-source': hooks[0]['sourcePath'] = '/other/config.toml'
            if mode == 'wrong-command': hooks[0]['command'] = 'unreviewed'
            if mode == 'disabled': hooks[0]['enabled'] = False
            result = {'data':[dict(hooks=hooks, warnings=[], errors=[], cwd=request['params']['cwds'][0])]}
            print(json.dumps({'id':request['id'],'result':result}), flush=True)
else:
    pathlib.Path(os.environ['GUARD_FIXTURE_LAUNCHED']).write_text(json.dumps(dict(
        argv=sys.argv[1:], role=os.environ['FIXTURE_ROLE'], root=os.environ['FIXTURE_ROOT'],
        home=os.environ['CODEX_HOME'])))
PY
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
export GUARD_FIXTURE_LAUNCHED="$TMP_ROOT/launched.json"
python3 - "$TMP_ROOT" <<'PY'
import hashlib,json,pathlib,sys
r=pathlib.Path(sys.argv[1])
(r/'approved.json').write_text(json.dumps({str(r/'project'):dict(
 executable=str(r/'guard'),sha256=hashlib.sha256((r/'guard').read_bytes()).hexdigest(),
 codex_version='codex-fixture 1',role_env='FIXTURE_ROLE',root_env='FIXTURE_ROOT',
 pretool=['pretool','{role}'],stop=['stop','{role}'])}))
PY

rejected() {
  if "$@" >"$TMP_ROOT/rejection.log" 2>&1; then fail "unsafe guard launch succeeded"; fi
}

printf 'Folder access\nOpening will not change saved trust.\n› 1. Open restricted\n  2. Quit\n' |
  python3 "$HELPER" startup-choice | grep -qx restricted || fail 'restricted consent not recognized'
for unsafe in 'Hooks need review' 'Trust and continue' 'Folder access Open restricted Quit' \
  'Folder access Opening will not change saved trust. 1. Open restricted › 2. Quit'; do
  if printf '%s' "$unsafe" | python3 "$HELPER" startup-choice >/dev/null 2>&1; then
    fail 'unverified trust choice could receive Enter'
  fi
done
pass 'Codex startup accepts only the selected non-persisting restricted-folder choice'

rejected python3 "$HELPER" check "$TMP_ROOT/approved.json" "$TMP_ROOT/project" ''
rejected python3 "$HELPER" check "$TMP_ROOT/approved.json" "$TMP_ROOT/project" coordinator
rejected python3 "$HELPER" check "$TMP_ROOT/missing.json" "$TMP_ROOT/project" worker
python3 "$HELPER" check "$TMP_ROOT/missing.json" "$TMP_ROOT/project" '' | grep -qx off \
  || fail "absent opt-in changed default launch behavior"
pass "Codex guard opt-in requires a configured project and explicit restrictive role"

for role in worker verifier; do
  dir="$TMP_ROOT/$role"
  python3 "$HELPER" prepare "$TMP_ROOT/approved.json" "$TMP_ROOT/project" "$TMP_ROOT/project" "$role" "$dir"
  rejected python3 "$HELPER" prepare "$TMP_ROOT/approved.json" "$TMP_ROOT/project" "$TMP_ROOT/project" "$role" "$dir"
  python3 "$HELPER" launch "$dir" -- --model fixture
  jq -e --arg role "$role" --arg root "$TMP_ROOT/project" --arg home "$dir/home" \
    '.role == $role and .root == $root and .home == $home and (.argv | index("--enable")) != null and (.argv | index("--dangerously-bypass-hook-trust")) != null' \
    "$GUARD_FIXTURE_LAUNCHED" >/dev/null || fail "launcher did not bind native role/source flags"
  cmp "$CODEX_HOME/auth.json" "$dir/home/auth.json" || fail "authentication copy changed"
  [ ! -e "$CODEX_HOME/config.toml" ] || fail "original trust/config store was written"
done
pass "Codex guard launcher binds worker/verifier and leaves original authentication/trust untouched"

for mode in extra managed wrong-source wrong-command disabled; do
  rm -f "$GUARD_FIXTURE_LAUNCHED"
  rejected env GUARD_FIXTURE_MODE="$mode" python3 "$HELPER" launch "$TMP_ROOT/worker" -- --model fixture
  assert_absent "$GUARD_FIXTURE_LAUNCHED" "unsafe inventory reached the native launch"
done
pass "Codex guard inventory rejects additional, managed, substituted, or disabled hooks"

chmod u+w "$TMP_ROOT/worker/home/config.toml"
printf '\n# changed\n' >> "$TMP_ROOT/worker/home/config.toml"
rejected python3 "$HELPER" launch "$TMP_ROOT/worker" -- --model fixture
chmod u+w "$TMP_ROOT/verifier/guard"
printf '\n# changed\n' >> "$TMP_ROOT/verifier/guard"
rejected python3 "$HELPER" launch "$TMP_ROOT/verifier" -- --model fixture
printf '\n# changed\n' >> "$TMP_ROOT/guard"
rejected python3 "$HELPER" check "$TMP_ROOT/approved.json" "$TMP_ROOT/project" worker
pass "Codex guard refuses source or implementation changes before trust bypass"
