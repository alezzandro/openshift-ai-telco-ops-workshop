# Prerequisites

## Cluster

This repo installs **Red Hat OpenShift 4.22.18** with Google Cloud IPI in
**asia-southeast1**. GPU workers are not in the IPI compute pool —
`03-prereqs.sh` clones `g2-standard-48` (replicas 1) and `g2-standard-24`
(replicas 0) after the cluster is up.

```bash
./setup/00-install-tools.sh
./setup/full-setup.sh
```

Put the Open Environment dump in `private/credentials/gcp-credentials.txt`
and the Red Hat pull secret in `private/credentials/rh-pull-secret.txt`
(gitignored). Set `GCP_ACME_EMAIL` in the environment or add a
`gcp_acme_email` labeled line in that dump. The installer needs the
**existing** public Cloud DNS zone from that dump
(`<guid>.gcp.redhatworkshops.io` in project `openenv-<guid>`). Do not create a
new zone or change NS.

https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-customizations[Installing a cluster on GCP with customizations (OpenShift 4.22)]

https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_google_cloud/installing-gcp-account[Configuring a GCP project]

Also required:

- Default StorageClass (`pd-ssd` / the IPI default is enough)
- At least two Ready general (non-GPU) workers for operators, dashboard, Open WebUI, and the lab guide
- Cluster pull secret that can pull `registry.redhat.io` and `registry.access.redhat.com`

## Google Cloud capacity

- Region for new installs: **asia-southeast1**. G2 was STOCKOUT in EU zones on
  the 2026-10-21 probe. Override `GCP_REGION` only with `GCP_REGION_OVERRIDE=1`
  after you re-prove stock.
- Presenter GPU: `g2-standard-48` (4 × NVIDIA L4). Student GPU: `g2-standard-24` (2 × L4).
- Disk type **pd-ssd** (G2 rejects `pd-standard`). G2 cannot live-migrate
  (`onHostMaintenance: Terminate`).
- Regional quota **NVIDIA_L4_GPUS** ≥ 4 for rehearsal, ≥ 10 for class. G2 does
  not consume CPU quota. This sandbox has no quota-increase path.
- Failures are usually `ZONE_RESOURCE_POOL_EXHAUSTED`, not quota.

If the current GPU zone is out of G2 stock, move whichever pools have replicas > 0:

```bash
./setup/switch-gpu-az.sh --list
./setup/switch-gpu-az.sh --az asia-southeast1-c
./setup/switch-gpu-az.sh --try asia-southeast1-a,asia-southeast1-b,asia-southeast1-c
```

`01-install-cluster.sh` writes a G2-capable worker zone to `cluster/.gpu-az`.
`03-prereqs.sh` uses that when `GPU_AZ` is unset.

To destroy an IPI cluster created by this repo (not workshop namespaces on a kept cluster):

```bash
./setup/destroy-cluster.sh
```

That keeps the pre-existing Cloud DNS zone.

## Workstation tools

`./setup/00-install-tools.sh` installs:

| Tool | Why |
|------|-----|
| `mise` | User-session package manager |
| `gcloud` | Must already be installed (Google Cloud SDK) |
| `oc` / `openshift-install` | Cluster API and GCP IPI (OpenShift 4.22.18 from [mirror.openshift.com](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/)) |
| `kubectl` | Kubernetes client (same API) |
| `jq` | JSON in setup scripts |
| `python3` | MachineSet JSON transform |
| `openssl` | Random HTPasswd / Open WebUI secrets |
| `htpasswd` | bcrypt HTPasswd identity provider |
| `lego` | Let’s Encrypt DNS-01 against Cloud DNS |
| `curl` | Health checks and Open WebUI admin signup |

## OpenShift AI 3.5

The setup installs the Red Hat OpenShift AI operator from `redhat-operators` on channel `stable-3.x`, plus:

- Node Feature Discovery (`redhat-operators`)
- NVIDIA GPU Operator (`certified-operators`, package `gpu-operator-certified`)
- cert-manager Operator for Red Hat OpenShift (Kueue prerequisite only; cluster certs are Let’s Encrypt via `lego`)
- Red Hat build of Kueue (`kueue-operator`)

Ray, Training, and pipelines stay **Removed** so GPUs stay on serving.
Model Registry stays **Managed**. The MCP Lifecycle Operator is set to
**Managed** so the Technology Preview MCP Catalog deploy action works.

## Access

`02-configure-access.sh` issues Let’s Encrypt certificates for
`api.<cluster>.<baseDomain>` and `*.apps.<cluster>.<baseDomain>` with
`lego --dns gcloud`, then creates HTPasswd users `admin` and `student1`–`student9`
(all `cluster-admin`). kubeadmin remains break-glass.
`show-credentials.sh` prints both. The lab-guide banner has **no passwords**.

https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/configuring-certificates[Configuring certificates (OpenShift 4.22)]

https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/authentication_and_authorization/understanding-identity-provider#identity-provider-htpasswd-CR_configuring-identity-providers[HTPasswd identity provider]

## Model Registry and MCP (Technology Preview)

`10-deploy-registry-mcp.sh` (called from `full-setup.sh`) creates:

- Model Registry `workshop` with operator-generated PostgreSQL (evaluation only)
- MCP Catalog + MCP Registry dashboard flags
- MCP server for Red Hat OpenShift in `telco-ops-demo` (read-only)

MCP Catalog, MCP Lifecycle Operator, and MCP server for Red Hat OpenShift are
Technology Preview — not supported with Red Hat production SLAs and not
recommended for production.
See https://access.redhat.com/support/offerings/techpreview.

## What students need

- Browser access to the Playground Route, OpenShift console, and OpenShift AI dashboard
- HTPasswd user `student1`–`student9` (this lab binds them as `cluster-admin`; tenant ResourceQuota still caps GPU in `telco-ran-ai` / `telco-core-ai`)
- Laptop `oc` or curl against the authenticated model Route (`workshop-infer` token)
