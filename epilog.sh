#!/bin/sh
#
# Finish script to release GPU devices.
#
# Kota Yamaguchi 2015 <kyamagu@vision.is.tohoku.ac.jp>

# Check if the environment file is readable.
ENV_FILE=$SGE_JOB_SPOOL_DIR/environment
if [ ! -f $ENV_FILE -o ! -r $ENV_FILE ]
then
  exit 100
fi

# Remove lock files.
device_ids=$(grep CUDA_VISIBLE_DEVICES $ENV_FILE | \
             sed -e "s/,/ /g" | \
             sed -n "s/CUDA_VISIBLE_DEVICES=\(.*\)/\1/p" | \
             xargs shuf -e)
for device_id in $device_ids
do
  lockfile=/tmp/lock-gpu$device_id
  if [ -d $lockfile ]
  then
    rmdir $lockfile
  fi
done

# Clean up Docker containers started by this job.
# The sge-docker.sh profile script automatically labels containers with
# sge_job_id when run inside an SGE job, enabling reliable cleanup.
containers=$(/usr/bin/docker ps -q --filter "label=sge_job_id=$JOB_ID" 2>/dev/null)
if [ -n "$containers" ]; then
  for cid in $containers; do
    /usr/bin/docker stop "$cid" 2>/dev/null
  done
fi

exit 0
