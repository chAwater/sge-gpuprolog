#!/bin/sh
#
# Docker wrapper script for SGE GPU prolog.
#
# Place this at /usr/local/bin/docker (PATH before /usr/bin) on compute
# nodes. When a process running inside an SGE job invokes "docker run"
# or "docker create", the wrapper automatically injects a label so that
# epilog.sh can find and stop the container after the job finishes.
#
# All other invocations are passed through to the real docker binary
# without modification.

REAL_DOCKER=/usr/bin/docker

# Not in SGE job, or not run/create -> pass through
if [ -z "$JOB_ID" ] || { [ "$1" != "run" ] && [ "$1" != "create" ]; }; then
    exec "$REAL_DOCKER" "$@"
fi

# Inject label after run/create subcommand
exec "$REAL_DOCKER" "$1" --label "sge_job_id=$JOB_ID" "${@:2}"
