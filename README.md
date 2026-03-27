Gridengine GPU prolog
=====================

> **Note:** This is an actively maintained fork of
> [kyamagu/sge-gpuprolog](https://github.com/kyamagu/sge-gpuprolog), which has
> been archived.

Changes from upstream
---------------------

### Memory-aware device selection

GPUs are now sorted by memory usage (ascending) instead of random selection,
so jobs prefer the least loaded device. GPUs with equal memory usage are
randomized to avoid hotspots.

### GPU reservation tool

`reserve-gpu.sh` allows manual reservation/release of GPU devices while keeping
SGE resource counts in sync. This avoids prolog failures when GPUs are
temporarily taken offline for maintenance or debugging.

    reserve-gpu.sh lock   <gpu_id> [hostname]   # Reserve a GPU
    reserve-gpu.sh unlock <gpu_id> [hostname]   # Release a GPU
    reserve-gpu.sh status [hostname]            # Show lock state and SGE resource

Examples:

    reserve-gpu.sh lock 2              # Reserve GPU 2 on this host
    reserve-gpu.sh lock 0 node01       # Reserve GPU 0 on node01
    reserve-gpu.sh unlock 2            # Release GPU 2 on this host
    reserve-gpu.sh status              # Show status for this host

---

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
