# Shell function to automatically label Docker containers with SGE job ID.
# Deploy to /etc/profile.d/sge-docker.sh on all compute nodes.
#
# This function intercepts `docker run` and `docker create` commands,
# injecting an sge_job_id label when running inside an SGE job.
# All other docker commands are passed through unchanged.
#
# Compatibility: POSIX sh, bash, zsh (avoids `local` and bash-only syntax).

# Only define when docker is available
command -v docker >/dev/null 2>&1 || return 0

docker() {
  _sge_docker_real=$(command -v docker)

  # Not in SGE job, or not run/create -> pass through
  if [ -z "$JOB_ID" ] || { [ "$1" != "run" ] && [ "$1" != "create" ]; }; then
    "$_sge_docker_real" "$@"
    _sge_docker_rc=$?
    unset _sge_docker_real
    return "$_sge_docker_rc"
  fi

  # Inject label after subcommand
  _sge_docker_subcmd=$1
  shift
  "$_sge_docker_real" "$_sge_docker_subcmd" --label "sge_job_id=$JOB_ID" "$@"
  _sge_docker_rc=$?
  unset _sge_docker_real _sge_docker_subcmd
  return "$_sge_docker_rc"
}
