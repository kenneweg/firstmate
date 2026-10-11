#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)
SIBLING_PID=
trap '[ -z "$SIBLING_PID" ] || { kill "$SIBLING_PID" 2>/dev/null || true; wait "$SIBLING_PID" 2>/dev/null || true; }; fm_test_cleanup' EXIT

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# A home opted into the supervision host whose checkpoint runs a stub host in
# a fixture code root: the stub records the bound it was given, then closes
# the way $FM_HOME/host-kind says.
make_host_home() {  # <name>
  local home
  home=$(make_home "$1")
  mkdir -p "$home/root/bin"
  cp "$CHECKPOINT" "$home/root/bin/fm-watch-checkpoint.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$home/root/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/root/bin/fm-supervision-engine-lib.sh"
  cat > "$home/root/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\nprimary=%s\npark=%s\nlimit=%s\n' "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" > "$FM_HOME/host-env"
case "$(cat "$FM_HOME/host-kind")" in
  boundary) printf 'supervision-host: cycle boundary - fixture\n' ;;
  handback)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    printf 'signal: demo.status\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\n'
    ;;
  timed-out) printf 'signal: partial-host-output\n'; exit 124 ;;
  stood-down) printf 'supervision-host stood down: this session no longer owns supervision\n' ;;
esac
SH
  chmod +x "$home/root/bin/fm-watch-checkpoint.sh" "$home/root/bin/fm-supervision-host.sh"
  : > "$home/config/supervision-host"
  printf '%s\n' "$home"
}

run_host_checkpoint() {  # <home> <kind> [checkpoint args...]; sets STATUS
  local home=$1
  printf '%s\n' "$2" > "$home/host-kind"
  shift 2
  STATUS=0
  FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" "$@" >"$home/out.txt" 2>"$home/err.txt" || STATUS=$?
}

test_host_checkpoint_bounds_the_park_by_posture() {
  local home f
  home=$(make_host_home host-bound)
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a host park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 5s" "the boundary must read as the ordinary quiet line"
  assert_contains "$(cat "$home/host-env")" $'args=park\nprimary=codex\npark=5\nlimit=1235' \
    "attended, the host must park for the checkpoint's own bound with the codex pin and a turn limit past it"
  : > "$home/state/.afk-contract"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "an away park that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 3600s" "away, the bound must be raised"
  assert_contains "$(cat "$home/host-env")" 'park=3600' "away, the host must park for the away bound"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 5
  assert_contains "$(cat "$home/host-env")" 'park=900' "the away bound must be configurable"
  FM_CODEX_WATCH_CHECKPOINT_AWAY=900 run_host_checkpoint "$home" boundary --seconds 1000
  assert_contains "$(cat "$home/host-env")" 'park=1000' "the away bound must never shorten a longer checkpoint"
  # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
  # QUIET), so the checkpoint keeps its attended bound beside it.
  for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$home/root/bin/$f"; done
  rm -f "$home/state/.afk-contract"
  FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  run_host_checkpoint "$home" boundary --seconds 5
  expect_code 124 "$STATUS" "a park beside a quiet record that reached its bound is a quiet checkpoint"
  assert_contains "$(cat "$home/host-env")" 'park=5' "beside a quiet record the host must park for the attended bound"
  pass "checkpoint: an opted-in home runs the host for the checkpoint's bound, raised only while away"
}

test_host_checkpoint_passes_a_handback_and_reports_a_stand_down() {
  local home
  home=$(make_host_home host-handback)
  run_host_checkpoint "$home" handback --seconds 5
  expect_code 0 "$STATUS" "a handed-back wake is an actionable checkpoint"
  assert_contains "$(cat "$home/out.txt")" $'signal: demo.status\nsupervision-host: the away session could not take this wake' \
    "the wake and its host line must pass through"
  assert_not_contains "$(cat "$home/out.txt")" "watcher: started" "the host's cycle status is not part of the wake"
  run_host_checkpoint "$home" stood-down --seconds 5
  expect_code 1 "$STATUS" "a host that stood down is a failed checkpoint"
  assert_contains "$(cat "$home/out.txt")" "supervision-host stood down" "the stand-down must be shown"
  run_host_checkpoint "$home" timed-out --seconds 5
  expect_code 1 "$STATUS" "a host timeout must fail despite partial wake output"
  assert_contains "$(cat "$home/err.txt")" 'outlived its own bound' "host timeout was not explained"
  pass "checkpoint: a handed-back wake passes through, and a host stand-down is a failure"
}

# The Codex owner stays file-gated: without config/supervision-host, or with
# config/supervision-host-off, the checkpoint never runs the host.
test_host_checkpoint_needs_the_file_and_honors_off() {
  local home line
  home=$(make_host_home host-gate)
  for line in - off; do
    rm -f "$home/config/supervision-host" "$home/config/supervision-host-off" "$home/host-env"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    run_host_checkpoint "$home" boundary --seconds 1
    [ ! -e "$home/host-env" ] || fail "a Codex home whose config/supervision-host is ${line/-/absent} ran the supervision host"
  done
  pass "checkpoint: a Codex home without config/supervision-host, or with an off file, never runs the host"
}

# The real host under a fake Codex harness that holds the home's session lock.
# shellcheck disable=SC2016 # the fake harness's script expands in its own shell
test_real_host_checkpoint_ends_quietly_at_its_bound() {
  local home fakebin status
  home=$(make_home host-real)
  : > "$home/config/supervision-host"
  fakebin="$TMP_ROOT/host-real-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$fakebin/codex" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$0" --seconds 4
  ' "$CHECKPOINT" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 124 "$status" "a quiet host checkpoint: $(cat "$home/out.txt" "$home/err.txt")"
  assert_contains "$(cat "$home/out.txt")" "checkpoint: no actionable wake within 4s" "the real host's boundary must read as the quiet line"
  assert_grep '	boundary	' "$home/state/.supervision-host.log" "the host must have ended its own park"
  if [ -e "$home/state/.watch.lock/pid" ] && kill -0 "$(cat "$home/state/.watch.lock/pid")" 2>/dev/null; then
    fail "a host checkpoint left its watcher running"
  fi
  pass "checkpoint: the real host ends its park at the checkpoint bound as a quiet checkpoint"
}

# The fixture exposes only its own script and processes; partial reason output
# must not turn a TERM-resistant deadline stop into successful supervision.
test_term_resistant_checkpoint_is_bounded_and_abnormal() {
  local home status started elapsed mechanism path tool
  home=$(make_host_home resistant)
  rm "$home/config/supervision-host"
  cat > "$home/root/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf 'signal: partial-fixture-output\n'
printf 'retained\n' > "$FM_HOME/state/recovery-evidence"
while :; do sleep 1; done
SH
  chmod +x "$home/root/bin/fm-watch.sh"
  for mechanism in perl timeout gtimeout; do
    path=$PATH
    if [ "$mechanism" != perl ]; then
      command -v timeout >/dev/null 2>&1 || continue
      path="$home/$mechanism-bin"
      mkdir -p "$path"
      for tool in bash dirname mktemp grep cat rm sleep; do
        ln -s "$(command -v "$tool")" "$path/$tool"
      done
      if [ "$mechanism" = timeout ]; then
        ln -s "$(command -v timeout)" "$path/timeout"
      else
        # A multicall coreutils binary may reject argv[0]=gtimeout; preserve
        # its real name while exercising the library's gtimeout selection.
        printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$(command -v timeout)" > "$path/gtimeout"
        chmod +x "$path/gtimeout"
      fi
    fi
    started=$SECONDS
    status=0
    PATH="$path" FM_HOME="$home" "$home/root/bin/fm-watch-checkpoint.sh" --seconds 1 >"$home/out" 2>"$home/err" || status=$?
    elapsed=$((SECONDS - started))
    expect_code 1 "$status" "$mechanism forced stop must fail, even with partial wake output"
    [ "$elapsed" -ge 8 ] && [ "$elapsed" -le 13 ] || fail "$mechanism resistant checkpoint took ${elapsed}s"
    assert_contains "$(cat "$home/err")" 'did not close cleanly' "forced stop was not explained"
    assert_not_contains "$(cat "$home/out")" 'no actionable wake' "forced stop was presented as quiet"
    assert_present "$home/state/recovery-evidence" "forced stop lost recovery evidence"
  done
  pass "TERM-resistant checkpoint escalates within its grace and reports an abnormal stop"

}

wait_fixture_file() {
  local file=$1 i=0
  while [ ! -s "$file" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$file" ] || fail "fixture did not publish $file"
}

fixture_process_running() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$state" in ''|*Z*) return 1 ;; *) return 0 ;; esac
}

test_forced_watcher_stop_cleans_owned_child_and_recovers() {
  local home sibling checkpoint watcher child descendant i status started
  home=$(make_home forced-real)
  # A live process in another home is never a signaling target.
  sibling=$(make_home live-sibling)
  sleep 60 &
  SIBLING_PID=$!
  printf '%s\n' "$SIBLING_PID" > "$sibling/state/.lock"
  cat > "$home/state/resistant.check.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/child.pid"
sleep 100 &
printf '%s\n' "$!" > "$FM_HOME/descendant.pid"
wait
SH
  chmod 0700 "$home/state/resistant.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" resistant >/dev/null || fail "register fixture"
  started=$SECONDS
  FM_HOME="$home" FM_CHECK_INTERVAL=1 FM_POLL=1 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 4 >"$home/out" 2>"$home/err" &
  checkpoint=$!
  wait_fixture_file "$home/child.pid"
  child=$(cat "$home/child.pid")
  wait_fixture_file "$home/descendant.pid"
  descendant=$(cat "$home/descendant.pid")
  watcher=$(cat "$home/state/.watch.lock/pid")
  [ "$(ps -o pgid= -p "$child" | tr -d ' ')" != "$(ps -o pgid= -p "$watcher" | tr -d ' ')" ] || fail "fixture child must have a separate group"
  # STOP is a deterministic stand-in for the unknown initiating stall, not a
  # claimed reproduction. Only this fixture's lock-owning watcher is stopped.
  kill -STOP "$watcher" || fail "stop fixture watcher"
  status=0
  wait "$checkpoint" || status=$?
  expect_code 1 "$status" "stalled real watcher must fail its checkpoint"
  [ "$((SECONDS - started))" -le 16 ] || fail "real checkpoint exceeded bound plus grace"
  i=0
  while fixture_process_running "$child" && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
  if fixture_process_running "$child"; then kill -KILL "$child"; fail "separate check group survived owner death"; fi
  if fixture_process_running "$descendant"; then kill -KILL "$descendant"; fail "check descendant survived group cleanup"; fi
  assert_present "$home/state/.watch.lock/pid" "forced stop must retain dead lock evidence"
  kill -0 "$SIBLING_PID" || fail "sibling home process was signaled"
  # The next real checkpoint owns reclaim/recovery; the parent never erases
  # the stale lock or pretends it was a clean close.
  status=0
  FM_HOME="$home" FM_CHECK_INTERVAL=999999 FM_POLL=1 "$CHECKPOINT" --seconds 5 >"$home/recovered" 2>"$home/recovered.err" || status=$?
  expect_code 0 "$status" "recovery must produce a real wake: $(cat "$home/recovered.err")"
  assert_contains "$(cat "$home/recovered")" 'check: rearm-resurface' "retained evidence was not resurfaced"
  kill -0 "$SIBLING_PID" || fail "recovery signaled a sibling"
  kill "$SIBLING_PID"
  wait "$SIBLING_PID" 2>/dev/null || true
  SIBLING_PID=
  pass "forced watcher stop cleans its separate child group, retains evidence and recovers without signaling a sibling"
}


test_normal_close_cleans_a_term_resistant_check_group() {
  local home child descendant status i
  home=$(make_home clean-resistant)
  cat > "$home/state/resistant.check.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/child.pid"
sleep 100 &
printf '%s\n' "$!" > "$FM_HOME/descendant.pid"
wait
SH
  chmod 0700 "$home/state/resistant.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" resistant >/dev/null || fail "register fixture"
  status=0
  FM_HOME="$home" FM_CHECK_INTERVAL=1 FM_POLL=1 FM_HEARTBEAT=999999 "$CHECKPOINT" --seconds 4 >"$home/out" 2>"$home/err" || status=$?
  expect_code 124 "$status" "a cooperative watcher must close cleanly despite a resistant check: $(cat "$home/err")"
  wait_fixture_file "$home/descendant.pid"
  child=$(cat "$home/child.pid")
  descendant=$(cat "$home/descendant.pid")
  for i in "$child" "$descendant"; do
    if fixture_process_running "$i"; then kill -KILL "$i"; fail "clean watcher close left process $i running"; fi
  done
  assert_absent "$home/state/.watch.lock/pid" "clean close left a singleton lock"
  assert_contains "$(cat "$home/out")" 'no actionable wake' "clean close lost quiet classification"
  pass "normal watcher close stops a resistant check and its descendant before reporting quiet"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_host_checkpoint_bounds_the_park_by_posture
test_host_checkpoint_passes_a_handback_and_reports_a_stand_down
test_host_checkpoint_needs_the_file_and_honors_off
test_real_host_checkpoint_ends_quietly_at_its_bound

test_term_resistant_checkpoint_is_bounded_and_abnormal
test_forced_watcher_stop_cleans_owned_child_and_recovers

test_normal_close_cleans_a_term_resistant_check_group
