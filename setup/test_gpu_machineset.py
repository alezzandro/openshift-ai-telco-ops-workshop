#!/usr/bin/env python3
"""Unit tests for GCP GPU MachineSet zone retargeting (no cluster required)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gpu_machineset as gm  # noqa: E402


def machineset(name, zone, role="worker", replicas=1, gpu=False, pool="", l4_count=None):
    cluster = "ocp-test"
    labels = {
        "machine.openshift.io/cluster-api-cluster": cluster,
        "machine.openshift.io/cluster-api-machine-role": role,
        "machine.openshift.io/cluster-api-machine-type": role,
        "machine.openshift.io/cluster-api-machineset": name,
    }
    machine_type = "n2-standard-8"
    if gpu:
        machine_type = "g2-standard-48" if (pool or "4l4") == "4l4" else "g2-standard-24"
    node_labels = {}
    if gpu:
        node_labels["node-role.kubernetes.io/worker-gpu"] = ""
        count = l4_count if l4_count is not None else (4 if (pool or "4l4") == "4l4" else 2)
        node_labels[gm.L4_LABEL] = str(count)
    ms = {
        "apiVersion": "machine.openshift.io/v1beta1",
        "kind": "MachineSet",
        "metadata": {
            "name": name,
            "namespace": "openshift-machine-api",
            "uid": "old-uid",
            "resourceVersion": "123",
            "generation": 7,
            "creationTimestamp": "2026-01-01T00:00:00Z",
            "labels": {"machine.openshift.io/cluster-api-cluster": cluster},
            "annotations": {
                "machine.openshift.io/GPU": "4" if gpu and (pool or "4l4") == "4l4" else ("2" if gpu else "0"),
                "kubectl.kubernetes.io/last-applied-configuration": "{}",
            },
        },
        "spec": {
            "replicas": replicas,
            "selector": {"matchLabels": dict(labels)},
            "template": {
                "metadata": {"labels": dict(labels)},
                "spec": {
                    "metadata": {"labels": node_labels},
                    "providerSpec": {
                        "value": {
                            "machineType": machine_type,
                            "region": "asia-southeast1",
                            "zone": zone,
                            "projectID": "openenv-example",
                            "networkInterfaces": [
                                {
                                    "network": f"{cluster}-network",
                                    "subnetwork": f"{cluster}-worker-{zone}",
                                }
                            ],
                            "disks": [
                                {
                                    "autoDelete": True,
                                    "boot": True,
                                    "sizeGb": 120,
                                    "type": "pd-ssd",
                                }
                            ],
                            "serviceAccounts": [
                                {"email": f"{cluster}-w@openenv-example.iam.gserviceaccount.com"}
                            ],
                            "tags": [f"{cluster}-worker"],
                            "credentialsSecret": {"name": "gcp-cloud-credentials"},
                            "userDataSecret": {"name": "worker-user-data"},
                        }
                    },
                },
            },
        },
        "status": {"replicas": replicas},
    }
    if gpu:
        ms["spec"]["template"]["spec"]["taints"] = [
            {"key": "nvidia.com/gpu", "value": "True", "effect": "NoSchedule"}
        ]
        ms["spec"]["template"]["spec"]["providerSpec"]["value"]["onHostMaintenance"] = "Terminate"
    return ms


class GpuMachineSetTests(unittest.TestCase):
    def setUp(self):
        self.items = [
            machineset("ocp-test-worker-asia-southeast1-a", "asia-southeast1-a", replicas=1),
            machineset("ocp-test-worker-asia-southeast1-b", "asia-southeast1-b", replicas=1),
            machineset("ocp-test-worker-asia-southeast1-c", "asia-southeast1-c", replicas=0),
            machineset(
                "ocp-test-worker-gpu-4l4-asia-southeast1-a",
                "asia-southeast1-a",
                role="worker-gpu",
                replicas=1,
                gpu=True,
                pool="4l4",
            ),
        ]

    def test_list_azs_from_worker_machinesets(self):
        azs = gm.list_azs(self.items)
        self.assertEqual(
            azs, ["asia-southeast1-a", "asia-southeast1-b", "asia-southeast1-c"]
        )

    def test_pick_active_prefers_replicas(self):
        self.items[3]["spec"]["replicas"] = 0
        extra = machineset(
            "ocp-test-worker-gpu-4l4-asia-southeast1-b",
            "asia-southeast1-b",
            role="worker-gpu",
            replicas=1,
            gpu=True,
            pool="4l4",
        )
        picked = gm.pick_gpu_machineset(self.items + [extra], pool="4l4")
        self.assertEqual(
            picked["metadata"]["name"], "ocp-test-worker-gpu-4l4-asia-southeast1-b"
        )

    def test_pick_active_falls_back_to_scaled_to_zero(self):
        self.items[3]["spec"]["replicas"] = 0
        picked = gm.pick_gpu_machineset(self.items, pool="4l4")
        self.assertEqual(
            picked["metadata"]["name"], "ocp-test-worker-gpu-4l4-asia-southeast1-a"
        )

    def test_build_rewrites_zone_and_subnet(self):
        built = gm.build_gpu_machineset(
            self.items, "asia-southeast1-b", replicas=1, pool="4l4", l4_count=4
        )
        self.assertEqual(
            built["metadata"]["name"], "ocp-test-worker-gpu-4l4-asia-southeast1-b"
        )
        prov = built["spec"]["template"]["spec"]["providerSpec"]["value"]
        self.assertEqual(prov["zone"], "asia-southeast1-b")
        self.assertEqual(
            prov["networkInterfaces"][0]["subnetwork"],
            "ocp-test-worker-asia-southeast1-b",
        )
        self.assertEqual(prov["machineType"], "g2-standard-48")
        self.assertEqual(prov["onHostMaintenance"], "Terminate")
        self.assertEqual(built["spec"]["replicas"], 1)
        self.assertEqual(
            built["spec"]["template"]["spec"]["metadata"]["labels"][gm.L4_LABEL],
            "4",
        )

    def test_build_strips_cluster_identity(self):
        built = gm.build_gpu_machineset(
            self.items, "asia-southeast1-b", replicas=1, pool="4l4"
        )
        meta = built["metadata"]
        for key in ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields"):
            self.assertNotIn(key, meta)
        self.assertNotIn("status", built)
        self.assertNotIn(
            "kubectl.kubernetes.io/last-applied-configuration",
            meta.get("annotations", {}),
        )

    def test_build_keeps_gpu_taint_and_node_role(self):
        built = gm.build_gpu_machineset(
            self.items, "asia-southeast1-c", replicas=1, pool="4l4"
        )
        spec = built["spec"]["template"]["spec"]
        self.assertEqual(
            spec["metadata"]["labels"]["node-role.kubernetes.io/worker-gpu"], ""
        )
        self.assertTrue(
            any(t.get("key") == "nvidia.com/gpu" for t in spec.get("taints", []))
        )

    def test_build_2l4_same_zone_as_4l4(self):
        built = gm.build_gpu_machineset(
            self.items,
            "asia-southeast1-a",
            replicas=0,
            pool="2l4",
            l4_count=2,
            machine_type="g2-standard-24",
            volume_size=250,
            gpu_annotation="2",
        )
        self.assertEqual(
            built["metadata"]["name"], "ocp-test-worker-gpu-2l4-asia-southeast1-a"
        )
        self.assertEqual(built["spec"]["replicas"], 0)
        prov = built["spec"]["template"]["spec"]["providerSpec"]["value"]
        self.assertEqual(prov["machineType"], "g2-standard-24")
        self.assertEqual(prov["disks"][0]["sizeGb"], 250)
        self.assertEqual(prov["disks"][0]["type"], "pd-ssd")
        self.assertEqual(
            built["spec"]["template"]["spec"]["metadata"]["labels"][gm.L4_LABEL], "2"
        )

    def test_build_unknown_az_is_error(self):
        with self.assertRaises(gm.GpuMachineSetError) as ctx:
            gm.build_gpu_machineset(self.items, "asia-southeast1-d", replicas=1)
        self.assertIn("asia-southeast1-d", str(ctx.exception))

    def test_build_from_worker_when_no_gpu_ms(self):
        workers_only = [m for m in self.items if "gpu" not in m["metadata"]["name"]]
        built = gm.build_gpu_machineset(
            workers_only,
            "asia-southeast1-b",
            replicas=1,
            machine_type="g2-standard-48",
            volume_size=250,
            gpu_annotation="4",
            pool="4l4",
            l4_count=4,
        )
        self.assertEqual(
            built["metadata"]["name"], "ocp-test-worker-gpu-4l4-asia-southeast1-b"
        )
        prov = built["spec"]["template"]["spec"]["providerSpec"]["value"]
        self.assertEqual(prov["machineType"], "g2-standard-48")
        self.assertEqual(prov["disks"][0]["sizeGb"], 250)
        self.assertEqual(built["metadata"]["annotations"]["machine.openshift.io/GPU"], "4")

    def test_other_gpu_names_pool(self):
        extra = machineset(
            "ocp-test-worker-gpu-2l4-asia-southeast1-a",
            "asia-southeast1-a",
            role="worker-gpu",
            replicas=0,
            gpu=True,
            pool="2l4",
        )
        names = gm.other_gpu_machineset_names(
            self.items + [extra],
            "ocp-test-worker-gpu-4l4-asia-southeast1-b",
            pool="4l4",
        )
        self.assertEqual(names, ["ocp-test-worker-gpu-4l4-asia-southeast1-a"])

    def test_parse_suggested_azs_from_gcp_event(self):
        msg = (
            "The zone 'projects/openenv-example/zones/asia-southeast1-a' does not have enough "
            "resources available to fulfill the request. ZONE_RESOURCE_POOL_EXHAUSTED "
            "g2-standard-48 nvidia-l4. Try asia-southeast1-b later."
        )
        self.assertEqual(
            gm.parse_suggested_azs(msg),
            ["asia-southeast1-a", "asia-southeast1-b"],
        )

    def test_capacity_failure_reads_events_not_status(self):
        machines = [
            {
                "metadata": {
                    "name": "ocp-test-worker-gpu-4l4-asia-southeast1-a-x",
                    "labels": {
                        "machine.openshift.io/cluster-api-machine-type": "worker-gpu",
                    },
                },
                "status": {"phase": "Provisioning"},
            }
        ]
        events = [
            {
                "involvedObject": {
                    "kind": "Machine",
                    "name": "ocp-test-worker-gpu-4l4-asia-southeast1-a-x",
                },
                "message": (
                    "ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS: A g2-standard-48 VM "
                    "instance with 4 nvidia-l4 accelerator(s) is currently unavailable "
                    "in the asia-southeast1-a zone."
                ),
            }
        ]
        result = gm.capacity_failure(machines, events)
        self.assertTrue(result["failed"])
        self.assertEqual(result["suggested_azs"], ["asia-southeast1-a"])
        self.assertEqual(result["seen"], 1)

    def test_capacity_failure_provisioning_without_event_is_not_failed(self):
        machines = [
            {
                "metadata": {
                    "name": "ocp-test-worker-gpu-4l4-asia-southeast1-c-x",
                    "labels": {
                        "machine.openshift.io/cluster-api-machine-type": "worker-gpu",
                    },
                },
                "status": {"phase": "Provisioning"},
            }
        ]
        result = gm.capacity_failure(machines, [])
        self.assertFalse(result["failed"])
        self.assertEqual(result["seen"], 1)

    def test_capacity_failure_ignores_stale_events_for_deleted_machines(self):
        machines = [
            {
                "metadata": {
                    "name": "ocp-test-worker-gpu-4l4-asia-southeast1-c-x",
                    "labels": {
                        "machine.openshift.io/cluster-api-machine-type": "worker-gpu",
                    },
                },
                "status": {"phase": "Provisioning"},
            }
        ]
        events = [
            {
                "involvedObject": {
                    "kind": "Machine",
                    "name": "ocp-test-worker-gpu-4l4-asia-southeast1-a-old",
                },
                "message": "ZONE_RESOURCE_POOL_EXHAUSTED in asia-southeast1-a",
            }
        ]
        result = gm.capacity_failure(machines, events)
        self.assertFalse(result["failed"])


if __name__ == "__main__":
    unittest.main()
