# Axon Bash Install — converged WEKA on AWS EC2

Deploy and operate **converged WEKA clusters on AWS EC2** — WEKA backends
sharing GPU/compute nodes with your workloads — as **plain bash over the
AWS CLI and SSM**. No SSH keys, no inbound ports, no golden AMIs, and no
configuration-management dependencies: if a host can run `aws` and `bash`,
it can drive this package.

```bash
# after filling weka.conf (see RUNBOOK.md):
./deploy.sh install
./deploy.sh day2 status
```

## Which package should I use?

| | **This package (bash)** | [Axon Ansible Native](../Axon_Ansible_Native/README.md) |
|---|---|---|
| Dependencies | AWS CLI + bash | Ansible + AWS collections + Session Manager plugin |
| Configuration | `weka.conf` (one file) | `weka_vars.yml` (one file) |
| Day 0 | ✅ full deploy | ✅ full deploy |
| Day 2 core | ✅ status, scale-out, scale-in (floor-enforced), replace | ✅ same |
| Filesystem + POSIX mounts | manual (`weka fs` + `mount -t wekafs`) | ✅ `fs.yml` |
| Health gates, maintenance stop/start | manual | ✅ playbooks |
| Rerun/resume semantics | guarded, with documented recovery steps | natively idempotent — plain rerun resumes anything |
| Best for | minimal workstations, script-first teams, quick POCs, air-gapped ops | Ansible shops, AWX/CI integration, full-lifecycle automation |

Both packages share the same workstation tooling (`scripts/`), IAM model,
tag-driven design, and launch templates — you can start here and adopt the
Ansible package later without redeploying (the variable model carries over).

## What's in the box

| Piece | Role |
|---|---|
| `deploy.sh` | Workstation driver: ships the installers to the elected orchestrator node over SSM and streams status |
| `install/weka-ssm-install.sh` | Day-0: phased fan-out install → cluster create → protection → start-io, with automatic admin-password rotation into Secrets Manager |
| `install/weka-day2.sh` | Day-2: `scale-out` / `scale-in` / `replace` / `status`, with the original-cluster-size floor and version-matched installs from the running cluster's dist endpoint |
| `scripts/generate-launch-template.sh` | Derives the ENI/EBS layout from `describe-instance-types` and creates the launch template; `describe <type>` prints a capability report |
| `scripts/weka-env-preflight.sh` | Read-only account/VPC conformance check; failures print copy-paste `fix:` commands |
| `scripts/weka-preflight.sh` | Per-node AMI/instance conformance check |
| `scripts/create-infrastructure.sh` | Optional greenfield helper (SGs, SSM endpoints, IAM role/profile inside an existing VPC) |
| `scripts/userdata-el.sh` | Launch-template user data for RHEL-family AMIs (SSM agent + SELinux) |
| `scripts/attach-data-enis.sh` | Cross-VPC data-plane ENI attachment (multi-VPC layouts only) |
| `weka.conf` | Single tfvars-style config consumed by every script |
| `iam/` | Least-privilege operator and instance policy templates |

## Requirements

- WEKA 4.4.x tarball in an S3 bucket in your account (node kernels ≤ 6.8)
- Instances with local NVMe and ENI budget for `1 mgmt + 1 per WEKA core`
- Node egress to distro package repos (NAT/proxy) for build dependencies
- See **[RUNBOOK.md](RUNBOOK.md)** for prerequisites, IAM, the step-by-step
  walkthrough, and troubleshooting
