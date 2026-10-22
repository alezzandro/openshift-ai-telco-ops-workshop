#!/usr/bin/env python3
"""Build and retarget GCP IPI GPU MachineSets across zones.

MachineSets are zone-bound: copy networkInterfaces from a worker MachineSet
already in the target zone, then set machineType / zone / onHostMaintenance.
Two pools share a zone: worker-gpu-4l4 (g2-standard-48) and worker-gpu-2l4
(g2-standard-24).
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import sys

GPU_ROLE = "worker-gpu"
L4_LABEL = "workshop.opendatahub.io/l4-count"
STRIP_META = (
    "uid",
    "resourceVersion",
    "creationTimestamp",
    "generation",
    "managedFields",
    "selfLink",
)


class GpuMachineSetError(ValueError):
    pass


def _labels(ms):
    return (
        ms.get("spec", {})
        .get("template", {})
        .get("metadata", {})
        .get("labels", {})
        or {}
    )


def _provider(ms):
    return (
        ms.get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("providerSpec", {})
        .get("value", {})
        or {}
    )


def machineset_az(ms):
    prov = _provider(ms)
    return prov.get("zone") or (prov.get("placement") or {}).get("availabilityZone") or ""


def gpu_pool(ms):
    name = (ms.get("metadata") or {}).get("name", "")
    node_labels = (
        ms.get("spec", {})
        .get("template", {})
        .get("spec", {})
        .get("metadata", {})
        .get("labels", {})
        or {}
    )
    count = str(node_labels.get(L4_LABEL) or "")
    if "4l4" in name or count == "4":
        return "4l4"
    if "2l4" in name or count == "2":
        return "2l4"
    return ""


def is_gpu_machineset(ms):
    name = (ms.get("metadata") or {}).get("name", "")
    role = _labels(ms).get("machine.openshift.io/cluster-api-machine-role", "")
    return "gpu" in name.lower() or "gpu" in role.lower()


def list_azs(items):
    azs = []
    for ms in items:
        az = machineset_az(ms)
        if az and az not in azs:
            azs.append(az)
    return azs


def _pool_items(items, pool=None):
    gpus = [ms for ms in items if is_gpu_machineset(ms)]
    if pool:
        gpus = [ms for ms in gpus if gpu_pool(ms) == pool]
    return gpus


def pick_gpu_machineset(items, pool=None):
    gpus = _pool_items(items, pool)
    active = [ms for ms in gpus if (ms.get("spec") or {}).get("replicas") or 0]
    pool_list = active or gpus
    return pool_list[0] if pool_list else None


def other_gpu_machineset_names(items, keep_name, pool=None):
    return [
        ms.get("metadata", {}).get("name")
        for ms in _pool_items(items, pool)
        if is_gpu_machineset(ms) and ms.get("metadata", {}).get("name") != keep_name
    ]


ZONE_RE = re.compile(r"[a-z]+-[a-z]+\d+-[a-z]")
CAPACITY_MARKERS = (
    "ZONE_RESOURCE_POOL_EXHAUSTED",
    "resource_availability",
    "STOCKOUT",
    "does not have enough resources",
    "InsufficientInstanceCapacity",
)


def parse_suggested_azs(message):
    """Parse spare zones from a GCP STOCKOUT / ZONE_RESOURCE_POOL_EXHAUSTED event."""
    if not message:
        return []
    azs = []
    for token in ZONE_RE.findall(message):
        if token not in azs:
            azs.append(token)
    return azs


def _is_gpu_machine(machine):
    name = (machine.get("metadata") or {}).get("name", "")
    labels = (machine.get("metadata") or {}).get("labels") or {}
    role = labels.get("machine.openshift.io/cluster-api-machine-type", "")
    return "gpu" in name.lower() or "gpu" in role.lower()


def capacity_failure(machines, events=None):
    """Detect GPU launch failures. GCP STOCKOUT text lives on Machine events."""
    lines = []
    failed = False
    suggested = []
    seen = 0
    gpu_names = set()
    for machine in machines or []:
        if not _is_gpu_machine(machine):
            continue
        name = (machine.get("metadata") or {}).get("name", "")
        if (machine.get("metadata") or {}).get("deletionTimestamp"):
            lines.append(f"  machine {name}: deleting (ignored)")
            continue
        seen += 1
        gpu_names.add(name)
        status = machine.get("status") or {}
        phase = status.get("phase") or ""
        err = status.get("errorMessage") or status.get("errorReason") or ""
        if err in ("None", "none"):
            err = ""
        lines.append(f"  machine {name}: phase={phase or 'unknown'} {err}".rstrip())
        blob = f"{phase} {err}"
        if phase == "Failed" or any(marker in blob for marker in CAPACITY_MARKERS):
            failed = True
            suggested.extend(parse_suggested_azs(err))
    reported_event_machines = set()
    for event in events or []:
        obj = event.get("involvedObject") or {}
        if obj.get("kind") != "Machine":
            continue
        name = obj.get("name") or ""
        if name not in gpu_names:
            continue
        message = event.get("message") or ""
        if not any(marker in message for marker in CAPACITY_MARKERS):
            continue
        failed = True
        extra = parse_suggested_azs(message)
        for az in extra:
            if az not in suggested:
                suggested.append(az)
        if name in reported_event_machines:
            continue
        reported_event_machines.add(name)
        if extra:
            lines.append(
                f"  event {name}: ZONE_RESOURCE_POOL_EXHAUSTED; zones in message: {', '.join(extra)}"
            )
        else:
            lines.append(f"  event {name}: {message[:160]}")
    return {
        "failed": failed,
        "seen": seen,
        "suggested_azs": suggested,
        "lines": lines,
    }


def _peer_in_az(items, az):
    peers = []
    for ms in items:
        if is_gpu_machineset(ms):
            continue
        if machineset_az(ms) != az:
            continue
        role = _labels(ms).get("machine.openshift.io/cluster-api-machine-role", "")
        if role and role not in ("worker", "compute"):
            continue
        peers.append(ms)
    if not peers:
        return None
    peers.sort(key=lambda m: 0 if (m.get("spec") or {}).get("replicas") else 1)
    return peers[0]


def _cluster_id(ms):
    labels = (ms.get("metadata") or {}).get("labels") or {}
    return labels.get("machine.openshift.io/cluster-api-cluster") or ""


def _strip_identity(ms):
    meta = ms.setdefault("metadata", {})
    for key in STRIP_META:
        meta.pop(key, None)
    annotations = meta.get("annotations") or {}
    annotations.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    ms.pop("status", None)


def _apply_gpu_role(ms, cluster_id, gpu_name, gpu_annotation, l4_count):
    meta = ms.setdefault("metadata", {})
    meta["name"] = gpu_name
    meta.setdefault("labels", {})["machine.openshift.io/cluster-api-cluster"] = cluster_id
    annotations = meta.setdefault("annotations", {})
    if gpu_annotation:
        annotations["machine.openshift.io/GPU"] = str(gpu_annotation)
    annotations.pop("machine.openshift.io/memoryMb", None)
    annotations.pop("machine.openshift.io/vCPU", None)

    sel = ms.setdefault("spec", {}).setdefault("selector", {}).setdefault("matchLabels", {})
    sel["machine.openshift.io/cluster-api-cluster"] = cluster_id
    sel["machine.openshift.io/cluster-api-machine-role"] = GPU_ROLE
    sel["machine.openshift.io/cluster-api-machine-type"] = GPU_ROLE
    sel["machine.openshift.io/cluster-api-machineset"] = gpu_name

    tpl = ms["spec"].setdefault("template", {})
    tl = tpl.setdefault("metadata", {}).setdefault("labels", {})
    tl["machine.openshift.io/cluster-api-cluster"] = cluster_id
    tl["machine.openshift.io/cluster-api-machine-role"] = GPU_ROLE
    tl["machine.openshift.io/cluster-api-machine-type"] = GPU_ROLE
    tl["machine.openshift.io/cluster-api-machineset"] = gpu_name

    node_meta = tpl.setdefault("spec", {}).setdefault("metadata", {})
    node_labels = node_meta.setdefault("labels", {})
    node_labels[f"node-role.kubernetes.io/{GPU_ROLE}"] = ""
    if l4_count:
        node_labels[L4_LABEL] = str(l4_count)
    taints = tpl["spec"].setdefault("taints", [])
    if not any(t.get("key") == "nvidia.com/gpu" for t in taints):
        taints.append({"key": "nvidia.com/gpu", "value": "True", "effect": "NoSchedule"})


def _set_boot_disk(prov, volume_size, disk_type="pd-ssd"):
    disks = prov.get("disks")
    if disks:
        for disk in disks:
            if disk.get("boot"):
                if volume_size is not None:
                    disk["sizeGb"] = int(volume_size)
                disk["type"] = disk_type
        return
    if volume_size is None:
        return
    for bd in prov.get("blockDevices") or []:
        ebs = bd.get("ebs") or {}
        if ebs:
            ebs["volumeSize"] = int(volume_size)


def build_gpu_machineset(
    items,
    target_az,
    replicas=1,
    machine_type=None,
    instance_type=None,
    volume_size=None,
    gpu_annotation=None,
    l4_count=4,
    pool=None,
    disk_type="pd-ssd",
):
    target_az = (target_az or "").strip()
    if not target_az:
        raise GpuMachineSetError("target zone is required")

    machine_type = machine_type or instance_type
    l4_count = int(l4_count)
    if pool is None:
        pool = "4l4" if l4_count >= 4 else "2l4"
    if gpu_annotation is None:
        gpu_annotation = str(l4_count)

    peer = _peer_in_az(items, target_az)
    if peer is None:
        known = ", ".join(list_azs(items)) or "(none)"
        raise GpuMachineSetError(
            f"No worker MachineSet in {target_az} (need its subnet). Known zones: {known}"
        )

    source = pick_gpu_machineset(items, pool=pool)
    from_worker = False
    if source is None:
        source = pick_gpu_machineset(items)
    if source is None:
        for ms in items:
            if is_gpu_machineset(ms):
                continue
            if (
                _labels(ms).get("machine.openshift.io/cluster-api-machine-role") == "worker"
                and ((ms.get("spec") or {}).get("replicas") or 0) >= 1
            ):
                source = ms
                from_worker = True
                break
        if source is None:
            raise GpuMachineSetError("No GPU or worker MachineSet found to clone")

    cluster_id = _cluster_id(source) or _cluster_id(peer)
    gpu_name = f"{cluster_id}-{GPU_ROLE}-{pool}-{target_az}"
    gpu = copy.deepcopy(source)
    _strip_identity(gpu)
    _apply_gpu_role(gpu, cluster_id, gpu_name, gpu_annotation, l4_count)
    gpu["spec"]["replicas"] = int(replicas)

    prov = gpu["spec"]["template"]["spec"]["providerSpec"]["value"]
    peer_prov = _provider(peer)
    if peer_prov.get("networkInterfaces"):
        prov["networkInterfaces"] = copy.deepcopy(peer_prov["networkInterfaces"])
    if peer_prov.get("region"):
        prov["region"] = peer_prov["region"]
    if peer_prov.get("projectID"):
        prov["projectID"] = peer_prov["projectID"]
    if peer_prov.get("serviceAccounts"):
        prov["serviceAccounts"] = copy.deepcopy(peer_prov["serviceAccounts"])
    if peer_prov.get("tags"):
        prov["tags"] = copy.deepcopy(peer_prov["tags"])
    if peer_prov.get("credentialsSecret"):
        prov["credentialsSecret"] = copy.deepcopy(peer_prov["credentialsSecret"])
    if peer_prov.get("userDataSecret"):
        prov["userDataSecret"] = copy.deepcopy(peer_prov["userDataSecret"])
    prov["zone"] = target_az
    prov.pop("placement", None)
    prov.pop("subnet", None)
    prov["onHostMaintenance"] = "Terminate"
    if machine_type:
        prov["machineType"] = machine_type
        prov.pop("instanceType", None)
    elif from_worker:
        raise GpuMachineSetError("machine_type is required when cloning from a worker MachineSet")
    _set_boot_disk(prov, volume_size, disk_type=disk_type)
    return gpu


def _load_items(raw):
    data = json.loads(raw)
    if isinstance(data, dict) and "items" in data:
        return data["items"]
    if isinstance(data, list):
        return data
    return [data]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list-azs", help="Print zones that already have a worker MachineSet")

    p_pick = sub.add_parser("pick-active", help="Print active GPU MachineSet name|replicas|az")
    p_pick.add_argument("--json", action="store_true")
    p_pick.add_argument("--pool", default="", help="4l4 or 2l4")

    p_others = sub.add_parser("others", help="Print GPU MachineSet names except --keep")
    p_others.add_argument("--keep", required=True)
    p_others.add_argument("--pool", default="")

    p_report = sub.add_parser("report", help="Human-readable GPU / worker zone report")

    p_build = sub.add_parser("build", help="Emit a GPU MachineSet JSON for --az")
    p_build.add_argument("--az", required=True)
    p_build.add_argument("--replicas", type=int, default=1)
    p_build.add_argument("--machine-type", default="")
    p_build.add_argument("--instance-type", default="", help="alias of --machine-type")
    p_build.add_argument("--volume-size", type=int, default=0)
    p_build.add_argument("--gpu-annotation", default="")
    p_build.add_argument("--pool", default="4l4")
    p_build.add_argument("--l4-count", type=int, default=0)
    p_build.add_argument("--disk-type", default="pd-ssd")

    p_cap = sub.add_parser(
        "capacity-check",
        help="Exit 1 if GPU Machines are Failed or events show STOCKOUT",
    )
    p_cap.add_argument("--events-json", default="")

    args = parser.parse_args(argv)
    items = _load_items(sys.stdin.read())

    if args.cmd == "list-azs":
        for az in list_azs(items):
            print(az)
        return 0

    if args.cmd == "pick-active":
        pool = args.pool or None
        ms = pick_gpu_machineset(items, pool=pool)
        if ms is None:
            return 0
        name = ms.get("metadata", {}).get("name", "")
        replicas = (ms.get("spec") or {}).get("replicas") or 0
        az = machineset_az(ms)
        if args.json:
            json.dump({"name": name, "replicas": replicas, "az": az, "pool": gpu_pool(ms)}, sys.stdout)
            sys.stdout.write("\n")
        else:
            print(f"{name}|{replicas}|{az}")
        return 0

    if args.cmd == "others":
        pool = args.pool or None
        for name in other_gpu_machineset_names(items, args.keep, pool=pool):
            if name:
                print(name)
        return 0

    if args.cmd == "report":
        print("GPU MachineSets:")
        gpus = [ms for ms in items if is_gpu_machineset(ms)]
        if not gpus:
            print("  (none)")
        for ms in gpus:
            name = ms.get("metadata", {}).get("name", "")
            replicas = (ms.get("spec") or {}).get("replicas") or 0
            az = machineset_az(ms)
            print(f"  {name}  pool={gpu_pool(ms) or '?'}  zone={az}  replicas={replicas}")
        print("Worker zones (subnet present):")
        for az in list_azs(items):
            peer = _peer_in_az(items, az)
            if peer is None:
                continue
            replicas = (peer.get("spec") or {}).get("replicas") or 0
            print(f"  {az}  (example {peer.get('metadata', {}).get('name')} replicas={replicas})")
        return 0

    if args.cmd == "capacity-check":
        events = []
        if args.events_json:
            with open(args.events_json, encoding="utf-8") as fh:
                events = _load_items(fh.read())
        result = capacity_failure(items, events)
        for line in result["lines"]:
            print(line)
        if result["suggested_azs"]:
            print("  Suggested zones: " + ", ".join(result["suggested_azs"]))
        if result["seen"] == 0:
            return 2
        return 1 if result["failed"] else 0

    l4_count = args.l4_count or (4 if args.pool == "4l4" else 2)
    kwargs = {
        "replicas": args.replicas,
        "pool": args.pool,
        "l4_count": l4_count,
        "disk_type": args.disk_type,
    }
    mtype = args.machine_type or args.instance_type
    if mtype:
        kwargs["machine_type"] = mtype
    if args.volume_size:
        kwargs["volume_size"] = args.volume_size
    if args.gpu_annotation:
        kwargs["gpu_annotation"] = args.gpu_annotation
    try:
        built = build_gpu_machineset(items, args.az, **kwargs)
    except GpuMachineSetError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    json.dump(built, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
