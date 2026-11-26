#!/usr/bin/env bash
set -euo pipefail

omarchy_path=${1:?Pass the built Omarchy path}
service_script=${2:?Pass the built Superwhisper service script}
den_apps=${3:?Pass the built den app script}
fuser_path=${4:?Pass the built fuser path}
autostart_script=${5:?Pass the built Superwhisper autostart script}
install_script=$omarchy_path/bin/omarchy-install-dictation-superwhisper
remove_script=$omarchy_path/bin/omarchy-remove-dictation-superwhisper
dictation_script=$omarchy_path/bin/omarchy-dictation-superwhisper
test_dir=$(mktemp -d)
real_sleep=$(command -v sleep)
real_jq=$(command -v jq)
lock_holder_pid=
setup_pid=

cleanup() {
  result=$?
  if ((result)) && [[ -n ${XDG_STATE_HOME:-} ]]; then
    daemon_log=$XDG_STATE_HOME/superwhisper/guix-daemon.log
    [[ ! -f $daemon_log ]] || cat "$daemon_log" >&2
  fi
  if [[ -n $lock_holder_pid ]]; then
    kill -TERM "$lock_holder_pid" >/dev/null 2>&1 || true
    wait "$lock_holder_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n $setup_pid ]]; then
    [[ -z ${SW_TEST_DEPLOY_RELEASE:-} ]] || : >"$SW_TEST_DEPLOY_RELEASE"
    kill -TERM "$setup_pid" >/dev/null 2>&1 || true
    wait "$setup_pid" >/dev/null 2>&1 || true
  fi
  bash "$service_script" stop >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/runtime"
export HOME="$test_dir/home" XDG_CONFIG_HOME="$test_dir/home/config"
export XDG_STATE_HOME="$test_dir/home/state" XDG_RUNTIME_DIR="$test_dir/runtime"
export SW_TEST_CALLS="$test_dir/calls" SW_TEST_PREF_AT_START="$test_dir/preferences-at-start"
export SW_TEST_FUSER_CALLED="$test_dir/fuser-called"
export SW_TEST_REAL_SLEEP=$real_sleep SW_TEST_REAL_JQ=$real_jq
export PATH="$test_dir/bin:$PATH"
unset DEN_DIR SUPERWHISPER_RUNTIME
touch "$SW_TEST_CALLS"

printf '#!%s\n' "$BASH" >"$test_dir/bin/stub"
cat >>"$test_dir/bin/stub" <<'EOF'
set -euo pipefail
name=${0##*/}
printf '%s %s\n' "$name" "$*" >>"$SW_TEST_CALLS"
case $name in
  superwhisper|omarchy-restart-hyprctl)
    if [[ -e /proc/$$/fd/8 ]]; then
      echo "Unexpected app-list lock descriptor in $name" >&2
      exit 98
    fi
    ;;
esac
case $name in
  jq)
    [[ ${SW_TEST_JQ_FAIL:-0} != 1 ]] || exit 1
    exec "$SW_TEST_REAL_JQ" "$@"
    ;;
  gum)
    if [[ $1 == choose ]]; then
      [[ ${SW_TEST_CANCEL_CHOOSE:-0} != 1 ]] || exit 130
      echo "${SW_TEST_MODE:-Offline}"
    else [[ ${SW_TEST_DECLINE:-0} != 1 ]]; fi ;;
  just)
    if [[ -n ${SW_TEST_DEPLOY_READY:-} ]]; then
      : >"$SW_TEST_DEPLOY_READY"
      for ((attempt=0; attempt<100; attempt++)); do
        [[ -e ${SW_TEST_DEPLOY_RELEASE:?} ]] && break
        "$SW_TEST_REAL_SLEEP" .05
      done
      [[ -e ${SW_TEST_DEPLOY_RELEASE:?} ]] || exit 124
    fi
    [[ ${SW_TEST_DEPLOY_FAIL:-0} != 1 ]]
    ;;
  superwhisper)
    runtime=$XDG_RUNTIME_DIR/superwhisper
    case $1 in
      status) [[ -S $runtime/control.sock ]] ;;
      daemon)
        [[ ${SW_TEST_DAEMON_FAIL:-0} != 1 ]]
        cp "$XDG_CONFIG_HOME/superwhisper/preferences.json" "$SW_TEST_PREF_AT_START"
        exec python3 - "$runtime/control.sock" <<'PY'
import os, signal, socket, sys
path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
def stop(*_):
    sock.close()
    os.unlink(path)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
signal.pause()
PY
        ;;
      models) [[ ${SW_TEST_MODEL_FAIL:-0} != 1 ]] ;;
    esac
    ;;
  omarchy-i18n) echo "$1" ;;
  omarchy-restart-hyprctl)
    if [[ ${SW_TEST_CHANGE_SELECTION_ON_RESTART:-0} == 1 ]]; then
      printf '%s\n' whisper-cpp >"$XDG_CONFIG_HOME/omarchy/defaults/dictation"
    fi
    [[ ${SW_TEST_RESTART_FAIL:-0} != 1 ]]
    ;;
  sleep)
    if [[ ${SW_TEST_NO_SLEEP:-0} != 1 ]]; then "$SW_TEST_REAL_SLEEP" "$@"; fi
    ;;
  nix|systemctl|nixarchy-app-enable|nixarchy-app-disable|nixarchy-apply)
    echo "Unexpected NixOS command: $name $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$test_dir/bin/stub"
for name in gum just superwhisper omarchy-i18n omarchy-restart-hyprctl \
  omarchy-notification-send sleep jq nix systemctl nixarchy-app-enable nixarchy-app-disable nixarchy-apply; do
  ln -s stub "$test_dir/bin/$name"
done
printf '#!%s\n' "$BASH" >"$test_dir/bin/fuser"
cat >>"$test_dir/bin/fuser" <<'EOF'
set -euo pipefail
touch "$SW_TEST_FUSER_CALLED"
kill -TERM "$SW_TEST_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
exit 1
EOF
chmod +x "$test_dir/bin/fuser"
sed "s|$fuser_path|$test_dir/bin/fuser|g" "$service_script" >"$test_dir/service-racing-fuser"
chmod +x "$test_dir/service-racing-fuser"
printf '#!%s\n' "$BASH" >"$test_dir/hold-lock"
cat >>"$test_dir/hold-lock" <<'EOF'
set -euo pipefail
touch "$1"
exec python3 -c 'import signal; signal.pause()'
EOF
chmod +x "$test_dir/hold-lock"
ln -s "$omarchy_path/bin/omarchy-dictation-use" "$test_dir/bin/omarchy-dictation-use"
ln -s "$omarchy_path/bin/omarchy-default-dictation" "$test_dir/bin/omarchy-default-dictation"
ln -s "$omarchy_path/bin/omarchy-cmd-present" "$test_dir/bin/omarchy-cmd-present"

app_source=$test_dir/configured-source
main_source=$HOME/.config/home-manager
mkdir -p "$app_source/modules" "$main_source/modules" "$XDG_STATE_HOME/den"
echo '[]' >"$app_source/modules/omarchy-apps.json"
echo '[]' >"$main_source/modules/omarchy-apps.json"
ln -s "$app_source" "$XDG_STATE_HOME/den/app-source"

preferences=$XDG_CONFIG_HOME/superwhisper/preferences.json
selection=$XDG_CONFIG_HOME/omarchy/defaults/dictation
runtime=$XDG_RUNTIME_DIR/superwhisper
fail() { echo "FAILED: $*" >&2; exit 1; }

export SW_TEST_DECLINE=1
bash "$install_script" --background
[[ ! -e $preferences && ! -e $selection ]] || fail 'declining setup changed user settings'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'declining setup changed the app list'
! rg -q '^just ' "$SW_TEST_CALLS" || fail 'declining setup deployed the app list'
unset SW_TEST_DECLINE

export SW_TEST_CANCEL_CHOOSE=1
bash "$install_script" --background
[[ ! -e $preferences && ! -e $selection ]] || fail 'cancelling the mode choice changed user settings'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'cancelling the mode choice changed the app list'
unset SW_TEST_CANCEL_CHOOSE

mkdir -p "${preferences%/*}"
echo '{"keep":"yes","errorLoggingEnabled":true}' >"$preferences"
export SW_TEST_JQ_FAIL=1
if bash "$install_script" --background 2>"$test_dir/preferences-failure.err"; then
  fail 'a preference-write failure returned success'
fi
unset SW_TEST_JQ_FAIL
rg -q 'The crash-report preference was not updated' "$test_dir/preferences-failure.err" \
  || fail 'a preference-write failure did not explain the unchanged crash-report setting'
! rg -q 'Crash reports remain disabled' "$test_dir/preferences-failure.err" \
  || fail 'a preference-write failure falsely claimed crash reports were disabled'
jq -e '.keep == "yes" and .errorLoggingEnabled == true' "$preferences" >/dev/null \
  || fail 'a preference-write failure changed existing preferences'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a preference-write failure changed the app list'
[[ ! -S $runtime/control.sock ]] || fail 'a preference-write failure started the daemon'

bash "$install_script" --background
jq -e '.keep == "yes" and .errorLoggingEnabled == false' "$SW_TEST_PREF_AT_START" >/dev/null
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'setup ignored the configured app source'
jq -e '. == []' "$main_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'setup changed the inactive main checkout'
rg -qx 'superwhisper models select offline' "$SW_TEST_CALLS"
[[ $(cat "$selection") == superwhisper ]] || fail 'successful setup did not select Superwhisper'

export SW_TEST_MODE=Cloud
bash "$install_script" --background
rg -qx 'superwhisper models select cloud' "$SW_TEST_CALLS"
unset SW_TEST_MODE

bash "$service_script" stop
echo voxtype >"$selection"
echo '[]' >"$app_source/modules/omarchy-apps.json"
: >"$SW_TEST_CALLS"
export SW_TEST_DEPLOY_READY=$test_dir/first-setup-deploy-ready
export SW_TEST_DEPLOY_RELEASE=$test_dir/first-setup-deploy-release
bash "$install_script" --background >"$test_dir/first-setup.out" 2>"$test_dir/first-setup.err" &
setup_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -e $SW_TEST_DEPLOY_READY ]] && break
  "$SW_TEST_REAL_SLEEP" .05
done
[[ -e $SW_TEST_DEPLOY_READY ]] || fail 'the first concurrent setup did not reach app deployment'
if bash "$install_script" --background >"$test_dir/second-setup.out" 2>"$test_dir/second-setup.err"; then
  fail 'a concurrent setup unexpectedly ran while the first setup held the lock'
fi
rg -q 'Another Superwhisper setup or removal is already running' "$test_dir/second-setup.err" \
  || fail 'a concurrent setup did not report the active setup lock'
if bash "$remove_script" 2>"$test_dir/concurrent-removal.err"; then
  fail 'removal unexpectedly ran while setup held the lock'
fi
rg -q 'A Superwhisper setup or removal is already running' "$test_dir/concurrent-removal.err" \
  || fail 'removal did not report the active setup lock'
app_status=0
(
  exec 8>&-
  DEN_APPS_SETUP_LOCKED=1 "$den_apps" add nixarchy-apps.superwhisper
) 2>"$test_dir/setup-lock-env-leak.err" || app_status=$?
[[ $app_status == 75 ]] || fail 'an exported setup-lock variable bypassed app-list locking without fd 8'
rg -q 'The app list is busy' "$test_dir/setup-lock-env-leak.err" \
  || fail 'an exported setup-lock variable did not honor the active app-list lock'
app_status=0
(
  exec 8>"$test_dir/unrelated-lock"
  DEN_APPS_SETUP_LOCKED=1 "$den_apps" add nixarchy-apps.superwhisper
) 2>"$test_dir/setup-lock-unrelated-fd.err" || app_status=$?
[[ $app_status == 75 ]] || fail 'an unrelated fd 8 bypassed app-list locking'
rg -q 'The app list is busy' "$test_dir/setup-lock-unrelated-fd.err" \
  || fail 'an unrelated fd 8 did not honor the active app-list lock'
app_status=0
"$den_apps" add nixarchy-apps.superwhisper 2>"$test_dir/concurrent-app-add.err" || app_status=$?
if ((app_status == 0)); then
  fail 'a generic app-list operation ran while setup held the lock'
fi
[[ $app_status == 75 ]] || fail 'app-list lock contention did not return its reserved status'
rg -q 'The app list is busy' "$test_dir/concurrent-app-add.err" \
  || fail 'a generic app-list operation did not explain the setup lock'
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a rejected concurrent setup or removal changed the first setup app entry'
: >"$SW_TEST_DEPLOY_RELEASE"
if ! wait "$setup_pid"; then fail 'the first setup did not complete after deployment resumed'; fi
setup_pid=
unset SW_TEST_DEPLOY_READY SW_TEST_DEPLOY_RELEASE
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'the successful first setup lost its app entry after a concurrent attempt'
[[ $(cat "$selection") == superwhisper ]] || fail 'the successful first setup did not select Superwhisper'

DEN_DIR=$main_source "$den_apps" add jq
jq -e '. == ["jq"]' "$main_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'the app script ignored explicit DEN_DIR'
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null

echo '{invalid' >"$app_source/modules/omarchy-apps.json"
expected_jq_status=0
"$SW_TEST_REAL_JQ" -r '.[]' "$app_source/modules/omarchy-apps.json" >/dev/null 2>&1 || expected_jq_status=$?
((expected_jq_status != 0)) || fail 'the malformed app list did not make jq fail'
app_status=0
"$den_apps" list >"$test_dir/invalid-app-list.out" 2>"$test_dir/invalid-app-list.err" || app_status=$?
[[ $app_status == "$expected_jq_status" ]] || fail 'the app wrapper did not preserve the jq parse failure status'
! rg -q 'The app list is busy' "$test_dir/invalid-app-list.err" \
  || fail 'a jq parse failure was reported as lock contention'
echo '["nixarchy-apps.superwhisper"]' >"$app_source/modules/omarchy-apps.json"

export SW_TEST_DEPLOY_FAIL=1
app_status=0
"$den_apps" add ripgrep >"$test_dir/app-deploy-failure.out" 2>"$test_dir/app-deploy-failure.err" || app_status=$?
[[ $app_status == 1 ]] || fail 'the app wrapper did not preserve a deploy failure status'
! rg -q 'The app list is busy' "$test_dir/app-deploy-failure.err" \
  || fail 'a deploy failure was reported as lock contention'
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a failed ordinary app deployment did not restore the app list'
unset SW_TEST_DEPLOY_FAIL

echo voxtype >"$selection"
echo '[]' >"$app_source/modules/omarchy-apps.json"
: >"$SW_TEST_CALLS"
export SW_TEST_DEPLOY_FAIL=1
if bash "$install_script" --background; then fail 'a failed deploy returned success'; fi
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a failed deploy did not restore the app list'
[[ $(cat "$selection") == voxtype ]] || fail 'failed setup changed the previous backend'
! rg -q '^superwhisper models select ' "$SW_TEST_CALLS" || fail 'failed setup continued configuration'
unset SW_TEST_DEPLOY_FAIL

bash "$service_script" stop
: >"$SW_TEST_CALLS"
export SW_TEST_DAEMON_FAIL=1
if bash "$install_script" --background; then fail 'a daemon startup failure returned success'; fi
[[ $(cat "$selection") == voxtype ]] || fail 'a daemon failure changed the previous backend'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a daemon failure kept the app added by setup'
[[ ! -S $runtime/control.sock ]] || fail 'a daemon failure left its daemon running'
[[ ! -e $runtime/omarchy-daemon.owner ]] || fail 'a daemon failure kept its ownership marker'
! rg -q '^superwhisper models select ' "$SW_TEST_CALLS" || fail 'daemon failure continued configuration'
unset SW_TEST_DAEMON_FAIL

bash "$service_script" stop
: >"$SW_TEST_CALLS"
export SW_TEST_MODEL_FAIL=1
if bash "$install_script" --background; then fail 'a model setup failure returned success'; fi
[[ $(cat "$selection") == voxtype ]] || fail 'a model failure changed the previous backend'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a model failure kept the app added by setup'
[[ ! -S $runtime/control.sock ]] || fail 'a model failure left its daemon running'
[[ ! -e $runtime/omarchy-daemon.owner ]] || fail 'a model failure kept its ownership marker'
jq -e '.keep == "yes" and .errorLoggingEnabled == false' "$preferences" >/dev/null \
  || fail 'a model failure did not preserve preferences and disabled crash reports'
unset SW_TEST_MODEL_FAIL

echo voxtype >"$selection"
export SW_TEST_RESTART_FAIL=1
if bash "$install_script" --background; then fail 'a restart failure returned success'; fi
[[ $(cat "$selection") == voxtype ]] || fail 'a restart failure did not restore the previous backend'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a restart failure kept the app added by setup'
[[ ! -S $runtime/control.sock ]] || fail 'a restart failure left its daemon running'
unset SW_TEST_RESTART_FAIL

echo voxtype >"$selection"
export SW_TEST_RESTART_FAIL=1 SW_TEST_CHANGE_SELECTION_ON_RESTART=1
if bash "$install_script" --background; then fail 'a concurrent selection change made a failed setup return success'; fi
[[ $(cat "$selection") == whisper-cpp ]] \
  || fail 'a restart failure overwrote a newer dictation choice'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a restart failure with a newer selection kept the app added by setup'
[[ ! -S $runtime/control.sock ]] || fail 'a restart failure with a newer selection left its daemon running'
unset SW_TEST_RESTART_FAIL SW_TEST_CHANGE_SELECTION_ON_RESTART

echo voxtype >"$selection"
printf '%s\n' preexisting-owner-token >"$runtime/omarchy-daemon.owner"
lock_ready=$test_dir/lock-held
flock --no-fork "$runtime/omarchy-daemon.lock" "$test_dir/hold-lock" "$lock_ready" &
lock_holder_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -e $lock_ready ]] && break
  "$SW_TEST_REAL_SLEEP" .01
done
[[ -e $lock_ready ]] || fail 'the pre-existing daemon test did not acquire its lock'
: >"$SW_TEST_CALLS"
export SW_TEST_NO_SLEEP=1
if bash "$install_script" --background; then fail 'setup succeeded while an unready pre-existing daemon held the lock'; fi
unset SW_TEST_NO_SLEEP
[[ $(<"$runtime/omarchy-daemon.owner") == preexisting-owner-token ]] \
  || fail 'failed setup changed the owner marker of a pre-existing daemon'
kill -0 "$lock_holder_pid" || fail 'failed setup stopped the unready pre-existing daemon'
[[ $(cat "$selection") == voxtype ]] || fail 'a locked daemon failure changed the previous backend'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a locked daemon failure kept the app added by setup'
kill -TERM "$lock_holder_pid"
wait "$lock_holder_pid" >/dev/null 2>&1 || true
lock_holder_pid=
bash "$service_script" stop

echo '["nixarchy-apps.superwhisper"]' >"$app_source/modules/omarchy-apps.json"
bash "$service_script" start
export SW_TEST_MODEL_FAIL=1
if bash "$install_script" --background; then fail 'a failed retry returned success'; fi
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null \
  || fail 'a failed retry removed a pre-existing app'
[[ -S $runtime/control.sock ]] || fail 'a failed retry stopped a pre-existing daemon'
unset SW_TEST_MODEL_FAIL
bash "$service_script" stop
echo '[]' >"$app_source/modules/omarchy-apps.json"

echo superwhisper >"$selection"
echo '["nixarchy-apps.superwhisper"]' >"$app_source/modules/omarchy-apps.json"
export SW_TEST_DEPLOY_FAIL=1
if bash "$remove_script"; then fail 'failed removal returned success'; fi
[[ $(cat "$selection") == superwhisper ]] || fail 'failed removal cleared the backend'
jq -e '. == ["nixarchy-apps.superwhisper"]' "$app_source/modules/omarchy-apps.json" >/dev/null
unset SW_TEST_DEPLOY_FAIL

bash "$remove_script"
[[ ! -e $selection ]] || fail 'successful removal kept the Superwhisper backend'
[[ -f $preferences ]] || fail 'removal deleted user preferences'
echo voxtype >"$selection"
bash "$remove_script"
[[ $(cat "$selection") == voxtype ]] || fail 'removal cleared another backend'
jq -e '. == []' "$app_source/modules/omarchy-apps.json" >/dev/null

: >"$SW_TEST_CALLS"
bash "$dictation_script" stop
! rg -q '^superwhisper stop$' "$SW_TEST_CALLS" || fail 'stopping an absent daemon called Superwhisper'
bash "$dictation_script" start
rg -qx 'superwhisper start' "$SW_TEST_CALLS"
bash "$dictation_script" toggle
rg -qx 'superwhisper record' "$SW_TEST_CALLS"
bash "$dictation_script" stop
rg -qx 'superwhisper stop' "$SW_TEST_CALLS"
bash "$service_script" start
[[ -S $runtime/control.sock ]] || fail 'the daemon did not start'
bash "$service_script" stop
[[ ! -S $runtime/control.sock ]] || fail 'the daemon did not stop'
bash "$service_script" stop

echo superwhisper >"$selection"
: >"$SW_TEST_CALLS"
bash "$autostart_script"
[[ -S $runtime/control.sock ]] || fail 'the selected Superwhisper backend did not start its daemon'
rg -qx 'superwhisper daemon' "$SW_TEST_CALLS"
bash "$autostart_script"
[[ $(rg -c '^superwhisper daemon$' "$SW_TEST_CALLS") == 1 ]] \
  || fail 'repeated Superwhisper autostart launched another daemon'
! rg -q '^superwhisper (start|record)( |$)' "$SW_TEST_CALLS" \
  || fail 'the Superwhisper autostart helper started or recorded audio'
bash "$service_script" stop

echo voxtype >"$selection"
: >"$SW_TEST_CALLS"
bash "$autostart_script"
[[ ! -S $runtime/control.sock ]] || fail 'a non-Superwhisper backend started the daemon'
! rg -q '^superwhisper daemon$' "$SW_TEST_CALLS" \
  || fail 'a non-Superwhisper backend invoked the daemon'

rm -f "$selection"
: >"$SW_TEST_CALLS"
bash "$autostart_script"
! rg -q '^superwhisper daemon$' "$SW_TEST_CALLS" \
  || fail 'a missing backend selection invoked the daemon'
echo 'superwhisper autostart: selection gate and no-recording checks pass'

mkdir -p "$runtime"
python3 - "$runtime/control.sock" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY
if bash "$service_script" stop; then fail 'removal stopped an external Superwhisper process'; fi
rm "$runtime/control.sock"

printf '%s\n' stop-race-owner-token >"$runtime/omarchy-daemon.owner"
lock_ready=$test_dir/stop-race-lock-held
flock --no-fork "$runtime/omarchy-daemon.lock" "$test_dir/hold-lock" "$lock_ready" &
lock_holder_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -e $lock_ready ]] && break
  "$SW_TEST_REAL_SLEEP" .01
done
[[ -e $lock_ready ]] || fail 'the daemon stop race test did not acquire its lock'
export SW_TEST_LOCK_HOLDER_PID=$lock_holder_pid
if ! SUPERWHISPER_OWNER_TOKEN=stop-race-owner-token bash "$test_dir/service-racing-fuser" stop-owned; then
  fail 'a daemon exit during shutdown made owned cleanup fail'
fi
[[ -e $SW_TEST_FUSER_CALLED ]] || fail 'the daemon stop race test did not invoke its fuser stub'
[[ ! -e $runtime/omarchy-daemon.owner ]] || fail 'a daemon exit race kept a stale ownership marker'
wait "$lock_holder_pid" >/dev/null 2>&1 || true
if kill -0 "$lock_holder_pid" >/dev/null 2>&1; then
  fail 'the daemon stop race test did not terminate its lock holder'
fi
lock_holder_pid=
unset SW_TEST_LOCK_HOLDER_PID
echo 'superwhisper: consent, setup, failure, removal, dictation, and service checks pass'

ln -sfn "$test_dir/missing-source" "$XDG_STATE_HOME/den/app-source"
if "$den_apps" add ripgrep; then fail 'a missing app source silently changed main'; fi
jq -e '. == ["jq"]' "$main_source/modules/omarchy-apps.json" >/dev/null
rm "$XDG_STATE_HOME/den/app-source"
[[ $("$den_apps" list) == jq ]] || fail 'a missing marker did not fall back to the main checkout'
echo 'den-apps: configured source, explicit override, rollback, and missing-source checks pass'
