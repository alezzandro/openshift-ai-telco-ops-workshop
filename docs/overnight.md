# Overnight shutdown and morning recovery

S4 (demo object storage) and the C4b ModelCar ImageStream live on general
workers and **survive** GPU overnight stop. Re-run `./setup/12-deploy-s4.sh`
only if the `s4` namespace or ImageStream was deleted.

RHPDS Google Cloud open environments **do not autostop**. GPU MachineSet
replicas 0 **deletes** GPU VMs. Stopped masters and workers keep disks and
PVCs. The GCP Machine API **replaces** stopped instances unless it is paused
first.

Do not stop GPU VMs out-of-band while their MachineSet still has replicas > 0.

## Evening

```bash
./setup/overnight-stop.sh
```

That script:

1. Stops leftover InferenceServices (and LLMInferenceServices) so GPU nodes can drain. Model Registry entries stay. `--reset` also runs `reset-demo.sh` (workshop PVCs).
2. Saves `GPU_4L4_LAST_REPLICAS` / `GPU_2L4_LAST_REPLICAS`, then
   `./setup/scale-gpu.sh --4l4 0 --2l4 0 --no-persist` and waits until GPU Machines are gone.
3. Scales `deployment/machine-api-controllers` in `openshift-machine-api` to 0.
4. `gcloud compute instances stop` on remaining cluster VMs (3 masters + 2 workers).
5. Prints that GPU LAST_REPLICAS were saved.

## Morning

```bash
./setup/overnight-start.sh
./setup/overnight-start.sh --4l4 1
./setup/overnight-start.sh --students
./setup/overnight-start.sh --4l4 1 --2l4 0
./setup/overnight-start.sh --4l4 1 --2l4 3
```

Default GPU counts are the last saved values. The script:

1. Starts masters and waits for API `/healthz`.
2. Starts workers and waits Ready.
3. Restores `machine-api-controllers`.
4. Scales GPU pools with the flags above.
5. Waits for NFD / GPU Operator, then runs `health-check.sh`.

`--students` is `--4l4 1 --2l4 3`.

Then:

```bash
./setup/show-credentials.sh
```

## Notes

- `health-check.sh --fix` restores **per-pool** last replicas. It does **not**
  clone MachineSets and it does **not** start stopped VMs. If the API is down
  or Machine API is paused, use `overnight-start.sh`.
- Do **not** delete the GPU MachineSet objects. Cloning is provisioning
  (`03-prereqs.sh`), not recovery.
- If a GPU Machine event is `ZONE_RESOURCE_POOL_EXHAUSTED`, move the active pools:

  ```bash
  ./setup/switch-gpu-az.sh --list
  ./setup/switch-gpu-az.sh --try asia-southeast1-a,asia-southeast1-b,asia-southeast1-c
  ```
- Open WebUI accounts survive because the PVC is not deleted.
- After adding GPU nodes with `scale-gpu.sh` / `scale-students.sh`, the pre-pull
  DaemonSet lands on the new nodes automatically. Wait until it is Ready before
  students deploy models.
