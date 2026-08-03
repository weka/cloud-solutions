# Axon Ansible Install — converged WEKA on AWS EC2

Deploy and operate **converged WEKA clusters on AWS EC2** — where WEKA backends
share GPU/compute nodes with your workloads — using nothing but the AWS API and
SSM. No SSH keys, no inbound ports, no golden AMIs, no pre-built inventory.

## Design principles

- **SSM-only orchestration.** Every node operation (install, day-2, UI access)
  rides AWS Systems Manager. Nodes need zero inbound connectivity; the UI is
  reached over an SSM port-forward.
- **Tag-driven membership.** Instances tagged `weka-cluster=<name>` *are* the
  cluster. Scale-out adopts tagged non-members; the tag also scopes the IAM
  permissions (send-command, teardown) as a security boundary.
- **Runtime topology discovery.** Cores (NUMA-aware, SMT-excluded), ENA data
  NICs, and instance-store NVMe are discovered on each node at install time —
  the same scripts run unmodified on any instance type that meets the minimums
  (local NVMe + enough ENIs for the core carve).
- **Bring your own everything.** Existing VPCs, subnets, security groups, and
  customer AMIs (Ubuntu, Amazon Linux 2023, Rocky/RHEL-family) are first-class.
  An optional greenfield helper creates only what's missing.
- **Fail before you build.** Two preflight gates run before anything installs:
  an *environment* check (egress paths, S3/SSM reachability, SG self-references,
  IAM, AZ offering, capacity reservation — failures print copy-paste AWS CLI
  remediation commands) and a per-*node* conformance check (kernel ceiling,
  build deps, NVMe, ENI layout, IMDSv2).

## What's in the box

| Piece | Role |
|---|---|
| `scripts/generate-launch-template.sh` | Derives the full ENI/EBS layout from `describe-instance-types` (multi-card packing, EFA, `/opt/weka` volume, user data) and creates/versions the launch template. `describe` mode prints a capability report for any instance type. |
| `scripts/weka-env-preflight.sh` | Read-only account/VPC conformance gate with `fix:` remediation output |
| `scripts/weka-preflight.sh` | Per-node AMI/instance conformance gate |
| `scripts/create-infrastructure.sh` | Optional greenfield helper (SGs, SSM endpoints, IAM role/profile inside an existing VPC) |
| `scripts/userdata-el.sh` | Instance user data for RHEL-family AMIs (SSM agent + SELinux) |
| `scripts/attach-data-enis.sh` | Cross-VPC data-plane ENI attachment (multi-VPC layouts only) |
| `install/weka-ssm-install.sh` | Day-0: phased fan-out install → cluster create → protection → start-io, with automatic admin-password rotation into Secrets Manager |
| `install/weka-day2.sh` | Day-2: `scale-out` / `scale-in` / `replace` / `status`, with a hard scale-in floor at the original cluster size and version-matched installs from the running cluster's own dist endpoint |
| `deploy.sh` | Workstation driver — ships the scripts to the elected orchestrator node inline over SSM |
| `ansible/` | Localhost-only playbooks wrapping the full lifecycle: `envcheck.yml`, `infra.yml` (optional greenfield), `site.yml` (day 0), `day2.yml`, `teardown.yml` — one variables file (`weka_vars.yml`) drives everything |
| `weka.conf` | Single tfvars-style config consumed by every script (rendered from `weka_vars.yml` on the Ansible path) |
| `iam/` | Least-privilege operator and instance policy templates |

## Quick start

```bash
# 1. fill in ansible/weka_vars.yml (or weka.conf for the bash path)
cd ansible
ansible-playbook -e @weka_vars.yml envcheck.yml   # verify the environment
ansible-playbook -e @weka_vars.yml infra.yml      # optional: create SGs/IAM/endpoints
ansible-playbook -e @weka_vars.yml site.yml       # deploy end to end
```

`site.yml` gates on both preflights, generates and creates the launch template,
launches the fleet (on-demand, ODCR, or Capacity Block), waits for SSM, installs,
and finishes with credentials and copy-paste next steps.

## Notable hardening

- NVMe selection enumerates block devices (immune to controller/namespace
  naming skew, e.g. NVMe native multipath) and skips anything the OS already
  claims — LVM members, RAID members, partitions, mounts, foreign signatures.
- RHEL-family support self-heals the usual gaps: AWS CLI v2 bundle fallback
  (no EPEL needed), exact-kernel `kernel-devel` from the distro vault when live
  mirrors have rolled past the AMI's point release, SSM-agent bootstrap via
  user data, SELinux guidance.
- Stripe sizing is validated against the node count before anything builds —
  WEKA silently accepts a wider stripe and runs permanently degraded; this
  package refuses instead.
- Slurm coexistence: pin (`WEKA_CORE_IDS`) or deny (`EXCLUDED_CORE_IDS`) core
  placement; every install prints the `CpuSpecList` (WEKA cores + SMT siblings)
  to reserve in `slurm.conf`.

## Requirements

- WEKA 4.4.x tarball in an S3 bucket in your account (node kernels ≤ 6.8)
- Instances with local NVMe and ENI budget for `1 mgmt + 1 per WEKA core`
- Node egress to distro package repos (NAT/proxy) for build dependencies
- See `RUNBOOK.md` (reference + troubleshooting) and `ANSIBLE-RUNBOOK.md`
  (the guided path) for everything else
