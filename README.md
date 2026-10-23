# OpenShift AI Telco Operations Workshop

A hands-on workshop that teaches **telco platform engineers** how to operate
inference on **Red Hat OpenShift AI 3.5.2** instead of hand-rolled vLLM on
Kubernetes. OLM Subscriptions are pinned (`startingCSV` + Manual approval) so
operators do not auto-update mid-class; see [docs/architecture.md](docs/architecture.md).

The presenter drives the **OpenShift AI dashboard**, tests models from a
laptop against an authenticated OpenShift Route, then leaves the cluster as
a two-day playground. Presenter and students follow separate in-cluster lab
guides.

## What this workshop shows

- Register catalog models, Hugging Face snapshots from S3, and custom ModelCars in Model Registry, then deploy those versions from the dashboard
- Types of inference services (KServe single-model vs ModelMesh vs distributed inference)
- **GA** single-node tensor parallelism on multiple GPUs of one node
- Horizontal scale (replicas of a model that already fits) vs vertical scale (more GPUs in one replica)
- GPU pool tenancy with HardwareProfiles, Kueue, and Data Science Projects
- A CPU Jupyter workbench (separate non-Kueue project) with Red Hat LangChain + vLLM notebooks
- A Model Registry instance (`workshop`) using the operator-generated PostgreSQL (evaluation only)
- MCP Catalog, MCP Registry, and the MCP server for Red Hat OpenShift (**Technology Preview**)
- How to onboard your own MCP server (custom catalog YAML; C2b)
- **Gen AI studio → Playground** with OpenShift MCP tool calls (C3b / P9; Technology Preview)
- Hugging Face → demo S3 ([S4](https://github.com/rh-aiservices-bu/s4), not production storage) → deploy (C4)
- Custom ModelCar from an arbitrary Hugging Face model (C4b / P10; pre-built into the in-cluster registry)
- Call deployed models from a laptop (authenticated OpenShift Route + `workshop-infer` token)
- Why multi-node / disaggregated serving is Technology Preview and is **not** this lab

Parked ideas (not in this class): [docs/roadmap.md](docs/roadmap.md).

This is **not** a RAN/5G CNF lab, **not** a training/fine-tune class, and **not**
the self-healing / Ansible closed-loop demo.

## Hardware (Google Cloud IPI)

`./setup/full-setup.sh` is sized for **presenter rehearsal** — one 4-L4 node.
Student 2-L4 capacity is a separate script.

| Mode | Shape | GPUs |
|------|--------|------|
| Rehearsal (default) | 1 × `g2-standard-48` | 4 × NVIDIA L4 (96 GB) |
| Class (`scale-students.sh`) | + 3 × `g2-standard-24` | 10 × L4 total (240 GB) |

Both GPU MachineSets are labeled `node-role.kubernetes.io/worker-gpu` and
tainted `nvidia.com/gpu=True:NoSchedule`. NVIDIA L4 has no MIG and no NVLink;
tensor parallelism on this shape uses NCCL over PCIe. Do **not** add a second
4-L4 node.

## Prerequisites

- **Google Cloud IPI** Red Hat OpenShift 4.22 in **asia-southeast1** (this repo installs it)
- Pull access to `registry.redhat.io` / `registry.access.redhat.com` (Red Hat pull secret)
- Public Cloud DNS zone already in the Open Environment project (`<guid>.gcp.redhatworkshops.io`; do not create or re-delegate DNS)
- Regional **NVIDIA_L4_GPUS** quota ≥ 4 for rehearsal, ≥ 10 for class
- Workstation: Google Cloud SDK (`gcloud`); `mise` (`kubectl`, `jq`); `oc` and `openshift-install` 4.22.18 from the OpenShift mirror; `python3`, `openssl`, `curl`, `htpasswd`, `lego`

See [docs/prerequisites.md](docs/prerequisites.md). Credentials live in gitignored `private/credentials/` — never commit them.

## Quick start

Blank Google Cloud sandbox (Open Environment) in **asia-southeast1**:

```bash
# private/credentials/gcp-credentials.txt
# private/credentials/rh-pull-secret.txt
# export GCP_ACME_EMAIL=you@example.com   # or gcp_acme_email in the credentials file
./setup/00-install-tools.sh
./setup/full-setup.sh
./setup/show-credentials.sh
```

`full-setup.sh` installs the cluster if `cluster/auth/kubeconfig` is missing,
issues Let’s Encrypt certificates, creates HTPasswd users `admin` and
`student1`–`student9` (all `cluster-admin`), and brings up **one** 4-L4 node.
It does **not** launch student 2-L4 nodes.

Class day:

```bash
./setup/scale-students.sh   # --4l4 1 --2l4 3
```

Open WebUI and **S4** are **documented demo exceptions** (no certified Operator
equivalent). S4 is only a Hugging Face → S3 lab stand-in; production uses
enterprise object storage (OpenShift Data Foundation, AWS S3, and similar).
The lab pins `quay.io/rh-aiservices-bu/s4:0.3.2-2` (never `:latest`).

`full-setup.sh` always pre-pulls ModelCar and vLLM images onto the GPU node so
the first dashboard deploy does not wait on a 15–20 GB pull. Emergency only:

```bash
SKIP_PREPULL=1 ./setup/full-setup.sh   # live demo will stall on image pull
```

## Operational scripts

| Script | Purpose |
|--------|---------|
| `setup/00-install-tools.sh` | mise (`kubectl`, `jq`) plus `oc` / `openshift-install` 4.22.18, `htpasswd`, `lego`; requires `gcloud` |
| `setup/01-install-cluster.sh` | GCP IPI OpenShift 4.22.18 in `asia-southeast1` (3× `n2-standard-4`, 2× `n2-standard-8`; GPU later) |
| `setup/02-configure-access.sh` | Let’s Encrypt (`lego --dns gcloud`) + HTPasswd `admin` / `student1`–`student9` |
| `setup/destroy-cluster.sh` | `openshift-install destroy cluster` for `./cluster` (keeps the Cloud DNS zone) |
| `setup/full-setup.sh` | Numbered phases 00–12 (presenter rehearsal, including S4 + HF seed) |
| `setup/12-deploy-s4.sh` | Demo S4 object storage, C4 HF seed, C4b ModelCar build |
| `setup/health-check.sh` | Verify cluster, TLS, GPU pools, dashboard, Model Registry, MCP, Open WebUI, lab guide |
| `setup/health-check.sh --fix` | Known recovery: restore per-pool last GPU replicas, re-issue certs under 30 days. Does not start stopped VMs |
| `setup/scale-gpu.sh --4l4 N --2l4 N` | Independent GPU pools (4-L4 0–1, 2-L4 0–3) |
| `setup/scale-students.sh` | Class day: `--4l4 1 --2l4 3` |
| `setup/switch-gpu-az.sh --az <zone>` | Move active GPU MachineSets on `ZONE_RESOURCE_POOL_EXHAUSTED` |
| `setup/overnight-stop.sh` | Stop InferenceServices, GPU replicas 0, pause Machine API, `gcloud compute instances stop` |
| `setup/overnight-start.sh` | Start VMs, restore Machine API, scale GPU pools |
| `setup/show-credentials.sh` | Lab guide URLs, kubeadmin, HTPasswd rows, Open WebUI |
| `setup/reset-demo.sh` | Delete leftover InferenceServices; keep operators and Open WebUI accounts |
| `setup/uninstall-demo.sh` | Tear down workshop namespaces; scale GPU MachineSets to 0 |

Overnight: [docs/overnight.md](docs/overnight.md). This sandbox does **not** autostop.

## Lab guide

After setup, `show-credentials.sh` prints **two** lab guide URLs:

- **Presenter guide** (`lab-guide` Route) — facilitator click-path (C1–C8, C3b, TELCO)
- **Playground** (`playground` Route) — student rules and exercises P1–P10

Do not send students the presenter URL. Console login is `admin` / `studentN`
(passwords are **not** in the lab-guide banner).

Content is authored as Antora AsciiDoc in `content/` and served from a UBI9
httpd Deployment on the cluster. After any `content/` or `lab-guide/` edit,
rebuild with `./setup/11-deploy-lab-guide.sh` so the live Routes pick it up.

Open WebUI is a **documented demo exception**: there is no UBI equivalent, so
the lab pins `ghcr.io/open-webui/open-webui:v0.6.36` (never `:main`) and grants
the `anyuid` SCC. It is presenter-only. Students call the authenticated model
Route with curl or Python (`workshop-infer` token). Direct Connections stay
disabled.

## Product documentation

- [Installing a cluster on GCP with customizations (OpenShift 4.22)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-customizations)
- [Configuring a GCP project](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-account)
- [Configuring certificates (OpenShift 4.22)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/configuring-certificates)
- [HTPasswd identity provider](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/understanding-identity-provider#identity-provider-htpasswd-CR_configuring-identity-providers)
- [Red Hat OpenShift AI Self-Managed 3.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/)
- [Deploying models](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploying_models/deploying_models)
- [Working with the model catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_model_catalog/index)
- [Working with model registries](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_model_registries/index)
- [Use connections](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_on_projects/using-connections_projects)
- [Managing model registries](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_model_registries/index)
- [Working with the MCP catalog](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_the_mcp_catalog/index) (Technology Preview)
- [MCP server for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ai_applications/mcp-server) (Technology Preview)
- [Experimenting with models in the gen AI playground](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/experimenting_with_models_in_the_gen_ai_playground/index) (Technology Preview)
- [Creating a workbench](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/creating_a_workbench/index)
- [Working in JupyterLab](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_in_your_data_science_ide/working_in_jupyterlab)
- [Working with accelerators / hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_accelerators/working-with-hardware-profiles_accelerators)
- [Manage workloads with Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-workloads-with-kueue)
- [Validated model support matrix](https://docs.redhat.com/en/documentation/red_hat_ai/3/html/validated_models/model-support-matrix_validated-models)
- [Distributed Inference with llm-d](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/index) (Technology Preview topologies: talk only on this lab)
- [Technology Preview Features Support Scope](https://access.redhat.com/support/offerings/techpreview)
- [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)
- [GPU machine types (Google Cloud)](https://docs.cloud.google.com/compute/docs/gpus)

## Repository layout

```
setup/       Numbered install scripts (00–12) and Day-2 operations
manifests/   Operators, RHOAI, Kueue, MCP, S4, ModelCar, projects, Open WebUI, lab guide
content/     Antora: content/presenter (facilitator) and content/playground (students)
lab-guide/   Containerfile (UBI9 Node.js build → UBI9 httpd)
docs/        Architecture, prerequisites, overnight runbook, roadmap
```

## Confidentiality

This is a **public** repository. Do not commit customer names, internal mail,
site hardware, kubeconfigs, pull secrets, or generated passwords.
