Gridengine GPU prolog
=====================

> **Note:** This is an actively maintained fork of
> [kyamagu/sge-gpuprolog](https://github.com/kyamagu/sge-gpuprolog), which has
> been archived.

---

v1.3 — Docker container cleanup on job termination
---------------------------------------------------

### Problem

When users run Docker containers inside SGE jobs, `qdel` only kills the
`docker run` client process. The container itself keeps running because the
container process is managed by the Docker daemon (`dockerd`), which lives
outside the SGE process group. Orphaned containers accumulate on compute
nodes, consuming GPU memory and other resources.

### Approach

1. **Shell function injection** — A shell function named `docker` is installed
   via `/etc/profile.d/sge-docker.sh`. Because shell functions take priority
   over PATH lookups, every `docker run` and `docker create` invocation is
   transparently intercepted. When `$JOB_ID` is set (i.e. inside an SGE job),
   the function injects `--label sge_job_id=$JOB_ID` before forwarding to the
   real `docker` binary. All other docker subcommands pass through unchanged.
2. **BASH_ENV for non-login shells** — `prolog.sh` writes
   `BASH_ENV=/etc/profile.d/sge-docker.sh` into the job environment file so
   that `#!/bin/bash` scripts (which do not read `/etc/profile.d/`) still load
   the function.
3. **Epilog cleanup** — `epilog.sh` queries `docker ps --filter label=sge_job_id=$JOB_ID`
   and stops any matching containers.

### Installation

Deploy `sge-docker.sh` to every compute node:

    sudo cp sge-docker.sh /etc/profile.d/sge-docker.sh

No changes are needed to `qconf` or queue configuration.

### Coverage

| Shell / method              | Function loaded? | Notes                                      |
|-----------------------------|------------------|--------------------------------------------|
| `#!/bin/bash` (login)       | Yes              | `/etc/profile.d/` sourced by login shells  |
| `#!/bin/bash` (non-login)   | Yes              | Loaded via `BASH_ENV`                      |
| `#!/bin/sh`                 | No               | sh does not read `BASH_ENV` or profile.d   |
| `docker compose`            | No               | Compose calls the Docker API directly      |
| `/usr/bin/docker` (abs path)| No               | Bypasses the shell function                |

---

v1.2 — Remote host support & diagnostic improvements
-----------------------------------------------------

### Problem

1. `reserve-gpu.sh` only operated on the local host — the optional `hostname`
   parameter affected SGE resources (via `qconf`) but not lock files or
   `nvidia-smi` queries, silently producing wrong results for remote nodes.
2. When GPU allocation failed, users had no way to tell *why* a job was
   rescheduled from `qstat` output alone.
3. The `status` command produced false warnings when SGE jobs were running,
   because it counted all lock files equally without distinguishing manual
   locks from SGE job locks.

### Changes

1. **Remote host operations via SSH** — `reserve-gpu.sh` now routes lock file
   and `nvidia-smi` commands through SSH when the target host differs from the
   local machine. Connectivity is verified before any operation.
2. **Job context diagnostic** — on GPU allocation failure, `prolog.sh` writes
   the reschedule reason to the job context (`qalter -ac`), visible in
   `qstat -j` output.
3. **Smart lock classification** — `status` command distinguishes manual locks
   from SGE job locks by cross-referencing the SGE gpu resource value, only
   warning when the counts are genuinely inconsistent.
4. **Bug fixes** — correct shebang (`#!/bin/bash` for `local` keyword),
   fix positional argument parsing for `status` subcommand, sanitize SSH
   output to prevent arithmetic errors.

---

v1.1 — Memory-aware selection & GPU reservation
------------------------------------------------

### Problem

1. The original random device selection ignores GPU load, causing jobs to land
   on heavily loaded devices while idle ones sit unused.
2. When GPUs are manually taken offline (e.g. for maintenance), manually
   creating lock directories without adjusting SGE resource counts causes
   prolog failures.

### Approach

1. **Memory-aware selection** — replace `shuf` with `nvidia-smi` memory query.
   GPUs are sorted by used memory (ascending) so jobs prefer the least loaded
   device. Equal-usage devices are randomized to avoid hotspots.
2. **GPU reservation tool** — `reserve-gpu.sh` atomically creates the lock
   directory AND adjusts the SGE `gpu` resource via `qconf`, keeping both in
   sync. Rollback on failure.

### Usage

    reserve-gpu.sh lock   <gpu_id> [hostname]   # Reserve a GPU
    reserve-gpu.sh unlock <gpu_id> [hostname]   # Release a GPU
    reserve-gpu.sh status [hostname]            # Show lock state and SGE resource

Examples:

    reserve-gpu.sh lock 2              # Reserve GPU 2 on this host
    reserve-gpu.sh lock 0 node01       # Reserve GPU 0 on node01
    reserve-gpu.sh unlock 2            # Release GPU 2 on this host
    reserve-gpu.sh status              # Show status for this host

---

Prerequisites
-------------

SGE prolog exit codes have specific meanings
([sge_conf(5)](http://gridscheduler.sourceforge.net/htmlman/htmlman5/sge_conf.html)):

    Exit 0:    Success
    Exit 99:   Reschedule job (automatic, no manual intervention)
    Exit 100:  Put job in error state (Eqw, requires manual qmod -cj)
    Other:     Put queue in error state

The prolog uses exit 99 when GPU allocation fails, so the job is
automatically rescheduled to retry later. Exit 100 is reserved for
permanent errors (e.g. environment file not writable)

---

v1.0 — Original
----------------

Scripts to manage NVIDIA GPU devices in SGE 6.2u5.

The last Sun Grid Engine that is packaged in Ubuntu 14.04 LTS does not contain
the RSMAP functionality that is implemented in recent Univa Grid Engine. The
ad-hoc scripts in this package implement resource allocation for NVIDIA devices.


Installation
------------

First, set up consumable complex `gpu`.

    qconf -mc

    #name               shortcut   type        relop   requestable consumable default  urgency
    #----------------------------------------------------------------------------------------------
    gpu                 gpu        INT         <=      YES         JOB        0        0

At each exec-host, add `gpu` resource complex. For example,

    qconf -aattr exechost complex_values gpu=1 node01

Set up `prolog` and `epilog` in the queue.

    qconf -mq gpu.q

    prolog                sgeadmin@/path/to/sge-gpuprolog/prolog.sh
    epilog                sgeadmin@/path/to/sge-gpuprolog/epilog.sh

Alternatively, you may set up a parallel environment for GPU and set
`start_proc_args` and `stop_proc_args` to the packaged scripts.

Usage
-----

Request `gpu` resource in the designated queue.

    qsub -q gpu.q -l gpu=1 gpujob.sh

The job script can access `CUDA_VISIBLE_DEVICES` variable.

    #!/bin/sh
    echo $CUDA_VISIBLE_DEVICES

The variable contains a comma-delimited device IDs, such as `0` or `0,1,2`
depending on the number of `gpu` resources to be requested. Use the device ID
for `cudaSetDevice()`.
