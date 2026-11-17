#!/usr/bin/env bash
# Tests of the background command runner of the panel (lib/core/jobs.sh). Run it through tests/run.sh.
set -u
# shellcheck source=tests/lib.sh
source tests/lib.sh
export LANG=C.UTF-8
unset NO_COLOR DELTACTL_COLOR DELTACTL_UI DELTACTL_ASCII COLUMNS

# Each check runs its own small script so a job never leaks into the next one.
run() { ROOT="$PWD" timeout 30 bash -c 'source lib/bootstrap.sh; trap job_cleanup EXIT; '"$1" 2>&1; }
# W defines wait_job: it polls until the job ends (at most ~10 s).
W='wait_job() { local i; for i in $(seq 1 100); do job_poll || true; job_running || return 0; sleep 0.1; done; return 1; }; '

section "1. output and exit status"
check "a finished job keeps its lines and exit code 0" '[ "$(run "$W job_start t bash -c \"echo one; echo two\"; wait_job; echo \${JOB_LINES[*]} rc=\$JOB_RC total=\$JOB_TOTAL")" = "one two rc=0 total=2" ]'
check "the exit code of a failing command is kept" '[ "$(run "$W job_start t bash -c \"echo bad; exit 3\"; wait_job; echo rc=\$JOB_RC")" = "rc=3" ]'
check "stderr goes to the same output" '[ "$(run "$W job_start t bash -c \"echo err >&2\"; wait_job; echo \${JOB_LINES[*]}")" = "err" ]'
check "a last line without a newline is kept" '[ "$(run "$W job_start t printf partial; wait_job; echo \${JOB_LINES[*]}")" = "partial" ]'
check "carriage returns and tabs are cleaned" '[ "$(run "$W job_start t printf \"a\\tb\\r\\n\"; wait_job; echo \"[\${JOB_LINES[0]}]\"")" = "[a    b]" ]'
check "the command has no input: a prompt ends at once" '[ "$(run "$W job_start t bash -c \"read x; echo got=[\\\$x]\"; wait_job; echo \${JOB_LINES[*]} rc=\$JOB_RC")" = "got=[] rc=0" ]'
check "a missing program ends with an error code" '[ "$(run "$W job_start t no-such-program-xyz; wait_job; echo rc=\$JOB_RC")" != "rc=0" ]'

section "2. while it runs"
check "lines arrive before the command ends" '[ "$(run "job_start t bash -c \"echo first; sleep 3\"; for i in \$(seq 1 30); do job_poll; [ \${#JOB_LINES[@]} -gt 0 ] && break; sleep 0.1; done; echo \${JOB_LINES[0]} running=\$(job_running && echo yes || echo no)")" = "first running=yes" ]'
check "a second job is refused while one runs" '[ "$(run "job_start t sleep 3; job_start u echo x && echo started || echo refused")" = "refused" ]'
check "a new job replaces the previous output" '[ "$(run "$W job_start a echo old; wait_job; job_start b echo new; wait_job; echo \${JOB_LINES[*]} \$JOB_TITLE")" = "new b" ]'
check "the elapsed time is counted" '[ "$(run "$W job_start t sleep 1; wait_job; job_elapsed")" -ge 1 ]'

section "3. cancelling"
check "cancel stops the command and its children" '[ "$(run "$W job_start t bash -c \"sleep 31.5 & wait\"; sleep 0.3; job_cancel; wait_job; echo cancelled=\$JOB_CANCELLED; pgrep -f \"^sleep 31.5$\" >/dev/null && echo orphan || echo clean")" = "$(printf "cancelled=1\nclean")" ]'
check "a command that ignores the polite signal is killed after two seconds" '[ "$(run "$W job_start t bash -c \"trap \\\"\\\" TERM; while true; do sleep 0.2; done\"; sleep 0.3; job_cancel; wait_job; echo rc=\$JOB_RC")" = "rc=137" ]'
check "cancel without a job fails" '[ "$(run "job_cancel && echo yes || echo no")" = "no" ]'

section "4. the buffer"
check "the buffer keeps the last lines and counts all of them" '[ "$(run "$W JOB_MAX=10; job_start t bash -c \"seq 1 500\"; wait_job; echo last=\${JOB_LINES[-1]} total=\$JOB_TOTAL under=\$([ \${#JOB_LINES[@]} -le 210 ] && echo yes || echo no)")" = "last=500 total=500 under=yes" ]'
check "cleanup removes the temporary files" '[ "$(run "job_init; d=\$JOB_DIR; job_cleanup; [ -d \$d ] && echo left || echo gone")" = "gone" ]'

finish
