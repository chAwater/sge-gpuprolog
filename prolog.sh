#!/bin/sh
#
# Startup script to allocate GPU devices.
#
# Kota Yamaguchi 2015 <kyamagu@vision.is.tohoku.ac.jp>

source $SGE_ROOT/$SGE_CELL/common/settings.sh

# Check if the environment file is writable.
ENV_FILE=$SGE_JOB_SPOOL_DIR/environment
if [ ! -f $ENV_FILE -o ! -w $ENV_FILE ]
then
  exit 100
fi

# Set BASH_ENV so that non-login bash scripts also load the docker function.
# This ensures the sge-docker.sh function is available regardless of
# whether the job shell is a login shell.
if [ -f /etc/profile.d/sge-docker.sh ]; then
  echo "BASH_ENV=/etc/profile.d/sge-docker.sh" >> $ENV_FILE
fi

# Query how many gpus to allocate.
NGPUS=$(qstat -j $JOB_ID | \
        sed -n "s/hard resource_list:.*gpu=\([[:digit:]]\+\).*/\1/p")
if [ -z $NGPUS ]
then
  exit 0
fi
if [ $NGPUS -le 0 ]
then
  exit 0
fi
NGPUS=$(expr $NGPUS \* ${NSLOTS=1})

# Allocate and lock GPUs.
SGE_GPU=""
i=0
# Sort by memory usage (ascending), randomize order among GPUs with equal usage.
# awk adds a random key per line; sort first by memory (col2), then by random key (col3).
device_ids=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | \
             awk -F', ' 'BEGIN{srand()} {print $1","$2","rand()}' | \
             sort -t',' -k2,2n -k3,3n | cut -d',' -f1)
for device_id in $device_ids
do
  lockfile=/tmp/lock-gpu$device_id
  if mkdir $lockfile 2>/dev/null
  then
    SGE_GPU="$SGE_GPU $device_id"
    i=$(expr $i + 1)
    if [ $i -ge $NGPUS ]
    then
      break
    fi
  fi
done

if [ $i -lt $NGPUS ]
then
  echo "ERROR: Only reserved $i of $NGPUS requested devices."
  # Write diagnostic info to job context (visible via qstat -j, field "context")
  qalter -ac gpu_prolog="[$(date '+%Y-%m-%d %H:%M')] $i/$NGPUS GPUs available, exit 99 (auto reschedule)" $JOB_ID 2>/dev/null
  for device_id in $SGE_GPU; do
    rmdir /tmp/lock-gpu$device_id
  done
  exit 99
fi

# Set the environment.
echo CUDA_VISIBLE_DEVICES="$(echo $SGE_GPU | sed -e 's/^ //' | sed -e 's/ /,/g')" >> $ENV_FILE
exit 0
