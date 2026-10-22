# Architecture

The workshop runs on **Google Cloud IPI** Red Hat OpenShift 4.22.18.
`setup/01-install-cluster.sh` creates that cluster on a blank GCP sandbox in
**asia-southeast1** (3 × `n2-standard-4` control plane, 2 × `n2-standard-8`
compute). Setup then clones two GPU MachineSets, installs OpenShift AI 3.5,
and deploys Open WebUI plus an in-cluster lab guide.

`full-setup.sh` is presenter rehearsal: 1 × `g2-standard-48` (4 L4). Class
capacity is `setup/scale-students.sh` (three `g2-standard-24`).

```
GCP IPI cluster  (asia-southeast1)
├─ Control plane  3 × n2-standard-4
├─ General workers  2 × n2-standard-8 (untainted)
│    OpenShift AI operator + dashboard
│    KServe controller
│    NFD / GPU Operator controllers
│    Open WebUI
│    Lab guide (UBI9 httpd)
│    S4 demo object storage (C4 Hugging Face → S3; not enterprise S3)
├─ GPU MachineSet 4-L4   g2-standard-48  replicas 1 (rehearsal)
└─ GPU MachineSet 2-L4   g2-standard-24  replicas 0 until scale-students.sh
     labels: node-role.kubernetes.io/worker-gpu=""
             workshop.opendatahub.io/l4-count=4|2
     taint:  nvidia.com/gpu=True:NoSchedule
          │
          ▼
     NFD → nvidia.com/gpu.present=true
     GPU Operator → allocatable nvidia.com/gpu=4 or 2
     DCGM exporter :9400 → user-workload Prometheus
          │
          ▼
     HardwareProfiles + Kueue ResourceFlavors l4-gpu-4 / l4-gpu-2
     LocalQueue workshop      → ClusterQueue gpu-pool-2l4
     LocalQueue workshop-4gpu → ClusterQueue gpu-pool-4l4 (telco-ops-demo)
     Data Science Projects (telco-ops-demo, telco-ran-ai, telco-core-ai) — Kueue
     telco-ops-notebooks — CPU Jupyter workbench, no LocalQueue
     Model Registry workshop (rhoai-model-registries, evaluation PostgreSQL)
     MCP Catalog / MCP Registry (dashboard flags) + MCP Lifecycle Operator
     MCP server for Red Hat OpenShift in telco-ops-demo (Technology Preview)
     KServe InferenceService + vLLM  (created from the dashboard, not by setup)
          │
          ▼
     Authenticated OpenShift Route (students: curl/Python + workshop-infer token)
     Optional Open WebUI admin (in-cluster :8080, presenter only)
```

## GPU placement

Inference pods must tolerate `nvidia.com/gpu` and land on `worker-gpu` nodes.
Kueue ResourceFlavors `l4-gpu-4` and `l4-gpu-2` carry `l4-count` labels and the
GPU taint, and **also** list a matching `spec.tolerations` entry. OpenShift AI
Queue HardwareProfiles cannot set `spec.scheduling.node` (the CRD rejects it),
so without that flavor toleration Kueue leaves predictors `SchedulingGated`.

HardwareProfiles:

- `gpu-l4-1` and `gpu-l4-2-tp` admit through LocalQueue `workshop`
- `gpu-l4-4-tp` admits through LocalQueue `workshop-4gpu` so a 4-GPU claim
  cannot land on a 2-L4 node

During rehearsal the 2-L4 ClusterQueue quota is 0; `workshop` **borrows** unused
4-L4 quota (same Kueue cohort) so 1-GPU and 2-GPU deploys still schedule on the
presenter node. After `scale-students.sh`, 2-L4 flavor quota is 6 and is listed
first so 1/2-GPU jobs prefer student nodes.

NVIDIA L4 on G2:

- No MIG — isolation unit is a **whole GPU**
- No NVLink — tensor parallelism is NCCL over PCIe
- No RDMA — multi-node / disaggregated prefill-decode is out of scope

`scale-gpu.sh --4l4` / `--2l4` changes **node count**. It does not shard one
replica across nodes. Do not add a second 4-L4 node.

## Packing

**Rehearsal** (1 × 4-L4): C3+C4 share the node; C6 2-GPU tensor parallel uses
half; a 4-GPU stretch consumes the whole node.

**Class** (10 L4): C6 2-GPU tensor parallel uses a **whole 2-L4 node**; the
4-GPU stretch stays on the 4-L4 node. Tenant ResourceQuota remains 2 GPU on
`telco-ran-ai` and `telco-core-ai`.

## Tenancy

| Project | Role | GPU cap |
|---------|------|---------|
| `telco-ops-demo` | Presenter serving | Shared Kueue pools (`workshop` + `workshop-4gpu`) |
| `telco-ops-notebooks` | Presenter Jupyter | CPU workbench, no Kueue LocalQueue |
| `telco-ran-ai` | Playground tenant A | ResourceQuota 2 GPU |
| `telco-core-ai` | Playground tenant B | ResourceQuota 2 GPU |

Kueue-managed projects only list queue-backed HardwareProfiles in the
dashboard, which is why the CPU Jupyter workbench is in `telco-ops-notebooks`
instead of `telco-ops-demo`.

The workbench clones
https://github.com/rh-aiservices-bu/llm-on-openshift onto its PVC. The
LangChain memory notebook talks to an in-cluster vLLM predictor after C3.

This lab’s HTPasswd users are `cluster-admin` so students can `oc login`
without extra RoleBindings. Isolation is still ResourceQuota, Kueue,
NetworkPolicy, and per-project tokens.

## Model Registry

Setup creates a `ModelRegistry` named `workshop` in `rhoai-model-registries`
with `postgres.generateDeployment: true`. That is the **default
(non-production)** database from
[Create a model registry](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_model_registries/creating-a-model-registry_managing-model-registries).
Production registries must use an external PostgreSQL 16.x or MySQL database.

Authenticated users receive RoleBinding `workshop-registry-users` so the
dashboard Registry page is usable without extra clicks.

The lab click path is the product governance path: discover in **AI hub →
Models → Catalog** (or name an OCI URI), **Register model** into `workshop`,
then **AI hub → Registry → version → Deploy**. Presenters do not use the
catalog **Deploy model** shortcut. C4 registers a Hugging Face snapshot from **S3** (demo bucket on
[S4](https://github.com/rh-aiservices-bu/s4); production uses enterprise
object storage). C4b registers a **ModelCar** OCI image built from
`ibm-granite/granite-3.3-2b-instruct` into the in-cluster registry. Dashboard
*Register and store* can also bake a ModelCar; this lab shows the UBI9
Containerfile instead.

Docs: [Working with model registries](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_model_registries/index),
[Register a model from the model catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_model_catalog/index).

## MCP Catalog, MCP Registry, OpenShift MCP server

Technology Preview. Setup:

1. Sets `spec.components.mcplifecycleoperator.managementState: Managed` on the
   DataScienceCluster (required for the catalog Deploy button).
2. Enables `mcpCatalog`, `mcpRegistry`, `genAiStudio`, and
   `aiAssetCustomEndpoints` on `OdhDashboardConfig`.
3. Sets DataScienceCluster `ogx: Managed` so **Gen AI studio → Playground**
   is available (Technology Preview; OGX operator, not LlamaStack).
4. Writes ConfigMap `gen-ai-aa-mcp-servers` so the playground MCP tab lists
   the in-cluster OpenShift MCP server.
5. Installs the `NemoGuardrails` CRD (empty list API only). The playground
   BFF lists that API on every chat; with TrustyAI Removed the missing group
   became HTTP 500. TrustyAI stays Removed — this is not a guardrails deploy.
6. Deploys the catalog MCP server **MCP server for Red Hat OpenShift**
   (`openshift-mcp-server`) in `telco-ops-demo` from
   `registry.redhat.io/openshift-mcp-tech-preview/openshift-mcp-server-rhel9:0.4`,
   read-only `core` + `config` toolsets, ServiceAccount `mcp-viewer` bound to
   ClusterRole `view` plus ClusterRole `workshop-mcp-node-reader` (`get`/`list`/`watch`
   on core `nodes`). Built-in `view` does not include Nodes; C3b needs that for
   allocatable `nvidia.com/gpu`. Playground does not forward a user token, so the
   MCP server uses this ServiceAccount.

This is **not** the Developer Preview `rhoai-mcp` coding-assistant server.
MCP Gateway is **not** installed.

Setup also writes a **custom** MCP catalog source (`workshop-custom-mcp`) into
ConfigMap `mcp-catalog-sources` (`mcp_catalogs`). That is the onboarding path
for a customer-owned MCP: catalog YAML + image URI + Deploy from the dashboard.
The workshop card uses the same certified OpenShift MCP image as a stand-in so
the lab never pulls an uncertified community image. C2b walks the click path;
the custom server is **not** pre-deployed. Do not `oc rollout restart`
`model-catalog`: a rolling restart can leave Postgres table `locks.catalog-leader`
held by a dead pglock owner, and the new pod stays standby so the card never
appears. Setup recovers that lock; `health-check.sh --fix` does the same.

Docs:
[Working with the MCP catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_mcp_catalog/index),
[MCP server for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ai_applications/mcp-server),
[Experimenting with models in the gen AI playground](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/experimenting_with_models_in_the_gen_ai_playground/index),
[Technology Preview support scope](https://access.redhat.com/support/offerings/techpreview).

## Inference access (auth + external tools)

Each Data Science Project has ServiceAccount `workshop-infer` (get on
InferenceServices). The serving wizard **Model access** + **Require token
authentication** creates an OpenShift Route. Unauthenticated calls return
401; `Authorization: Bearer $(oc create token workshop-infer)` succeeds.
Students use curl or Python against that Route. They do **not** use Open
WebUI Direct Connections (`*.svc.cluster.local` is not reachable from a
browser).

Cluster-internal clients (Gen AI Playground, optional Open WebUI admin)
keep using predictor port **8080** and skip the Route.

Open WebUI remains a presenter-only convenience: admin account, Direct
Connections disabled, default `api.openai.com` cleared (no internet egress).

https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploying_models/deploying_models

## Lab guide

Two Antora sites in one UBI9 httpd image, selected by Route hostname:

- Route `lab-guide` (host does **not** start with `playground-`) → presenter
  tree (`content/presenter/`)
- Route `playground` (host `playground-lab-guide.apps…`) → student tree
  (`content/playground/`)

Presenter pages are not in the playground build. ConfigMap `lab-guide-env` is
mounted as `env.json` in both trees.

## What setup does not create

- InferenceServices (the dashboard wizard is the demo)
- A Gen AI Studio playground *instance* (C3b / P9 click **Create playground**)
- Multi-node llm-d topologies
- Models-as-a-Service / Connectivity Link (optional DEEP, not in `full-setup.sh`)
- MCP Gateway Operator
- A second live MCPServer for the custom catalog card (C2b is catalog-only unless the presenter deploys it)
- The Developer Preview `rhoai-mcp` coding-assistant server
- AAP, Lightspeed, GitOps, ServiceNow
- A second 4-L4 node, FreeDNS, CIS, or a new Cloud DNS zone
