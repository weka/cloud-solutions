# WEKA Converged on AWS — Runbook

Everything needed to deploy and operate a converged WEKA cluster with this
package, from an empty account to day-2 operations. Follow the sections in
order for a first deployment; each is safe to revisit independently.

**Contents**
1. [Control node setup](#1-control-node-setup)
2. [IAM](#2-iam)
3. [Environment prerequisites](#3-environment-prerequisites)
4. [Configuration: weka_vars.yml + inventory](#4-configuration)
5. [Launch template + instances](#5-launch-template--instances)
6. [Day 0 — deploy the cluster](#6-day-0--deploy-the-cluster)
7. [Day 2 — operate the cluster](#7-day-2--operate-the-cluster)
8. [Troubleshooting](#8-troubleshooting)
9. [Appendix: macOS control nodes](#9-appendix-macos-control-nodes)

---

## 1. Control node setup

A Linux host (laptop, EC2 instance, or CI runner) with:

```bash
python3 -m venv ~/weka-ansible && . ~/weka-ansible/bin/activate
pip install ansible-core boto3 botocore
ansible-galaxy collection install amazon.aws community.aws
```

Plus AWS CLI v2 and the Session Manager plugin:

```bash
# session-manager-plugin (Amazon Linux / RHEL-family)
sudo dnf install -y https://s3.us-east-1.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm
```

AWS credentials come from the standard chain (env vars, instance role, or
a named profile). With SSO named profiles, export static credentials for
the session — the SSM connection plugin resolves credentials itself:

```bash
eval "$(aws configure export-credentials --profile <PROFILE> --format env)"
```

## 2. IAM

Two identities, two policies — fill the placeholders in the `iam/`
templates (`ACCOUNT_ID`, `CLUSTER_NAME`, region, bucket names):

1. **Instance role + profile** — attached to every cluster node. Needs
   `AmazonSSMManagedInstanceCore` (SSM registration) plus the WEKA
   instance policy: S3 read of the tarball bucket, Secrets Manager
   read/write on `weka/<cluster>/*`, SSM parameters under `/weka/<cluster>/*`.
   `scripts/create-infrastructure.sh` creates all of this for you.
2. **Operator** — whoever runs the playbooks. Needs EC2/SSM/IAM read,
   `ssm:StartSession` (the connection transport), launch-template
   management, `RunInstances`, `iam:PassRole` for the instance role, and
   read/write on the S3 transfer bucket.

**The three-way name match**: the cluster name appears in (1) your
`weka_vars.yml`, (2) the inventory tag filter, and (3) the IAM policy tag
conditions. All three must match exactly — a mismatch is the most common
cause of AccessDenied failures.

## 3. Environment prerequisites

What your VPC must provide (verify all of it with one command — step 4
below): a subnet with 1 free private IP per node per `1 + <total cores>`;
self-referencing security groups (all traffic from itself) for mgmt+data
and, on GPU platforms, EFA; **node egress to distro package repos** (NAT
gateway or proxy — an S3 endpoint alone is not enough, and an Internet
Gateway without public IPs provides nothing); a path to SSM (the NAT
covers it, or interface endpoints for `ssm`, `ssmmessages`,
`ec2messages`); and DNS support + hostnames enabled on the VPC.

Missing pieces inside an existing VPC (security groups, SSM endpoints,
the IAM role/profile) can be created for you:

```bash
# fill the CUSTOMER CONFIGURATION block first (VPC id, account id,
# EXISTING_SUBNET_ID to reuse your subnet)
bash scripts/create-infrastructure.sh
```

Verify everything before deploying — read-only, and every failure prints
a copy-paste `fix:` command:

```bash
bash scripts/weka-env-preflight.sh     # reads weka.conf-style values; see script header
```

## 4. Configuration

**`weka_vars.yml`** is the single file you edit — cluster identity, carve,
stripe, install source, credentials behavior. Every playbook consumes it
the same way (`-e @weka_vars.yml`). Values marked CHANGEME are required.

**`inventory/weka_ec2.aws_ec2.yml`** has two values to match: your region
and your cluster tag value. Membership is dynamic — any running instance
tagged `weka-cluster=<name>` is in.

**`group_vars/all.yml`** wires the SSM connection. You should not need to
edit it beyond the transfer bucket if you don't pass
`ssm_transfer_bucket` in `weka_vars.yml`.

### Sizing guidance

- **Stripe**: `stripe_data + stripe_protection <= node count`. The deploy
  refuses violations before any node work — WEKA itself would accept a
  wider stripe and run permanently PARTIALLY_PROTECTED.
- **Carve**: total cores = data ENIs needed per node. Run
  `bash scripts/generate-launch-template.sh describe <instance-type>` for
  a capability report with a suggested starting carve.
- **Scale-in floor**: the cluster can never shrink below its original
  size. Size day-0 to the *minimum* you will ever want.

## 5. Launch template + instances

The generator derives the exact ENI and EBS layout from the instance
type's real capabilities and creates the template:

```bash
# fill the CUSTOMER CONFIGURATION block (or maintain a weka.conf) first
bash scripts/generate-launch-template.sh
```

It handles multi-network-card packing, EFA interfaces on GPU types, the
optional dedicated `/opt/weka` volume, IMDSv2 hop limit, tags, and — on
RHEL-family AMIs — reference `scripts/userdata-el.sh` as `USER_DATA_FILE`
so nodes bootstrap the SSM agent and set SELinux permissive at first boot
(Ubuntu and Amazon Linux need no user data).

Launch your nodes from it:

```bash
aws ec2 run-instances --launch-template LaunchTemplateName=<name> --count <N>
# capacity reservations: add
#   --capacity-reservation-specification 'CapacityReservationTarget={CapacityReservationId=cr-...}'
# capacity blocks additionally need: --instance-market-options MarketType=capacity-block
```

Instances are born tagged; the inventory sees them as soon as they run.
Wait until every node is SSM-managed (`aws ssm describe-instance-information`),
typically 1–4 minutes after launch.

## 6. Day 0 — deploy the cluster

```bash
ansible-playbook -e @weka_vars.yml cluster.yml
```

Phases, in order (each is a play; the run is resumable at any point with
a plain rerun):

1. **Guards** — stripe-vs-node-count refusal before any node work.
2. **Install** — build deps (kernel headers with an EL-vault fallback for
   point-release drift, kernel-matched gcc, jq; AWS CLI from the official
   bundle where repos lack it), optional `/opt/weka` volume, WEKA agent
   from your S3 tarball, agent service started and verified responsive.
3. **Drives** — per-node topology discovery (NUMA-aware cores, NIC role
   split, NVMe selection that skips anything in use: LVM/RAID members,
   partitions, mounts, foreign signatures), then the drives container.
4. **Cluster create** — from the control node, with protection settings
   applied idempotently.
5. **Compute + frontend containers** — join with the cluster's member IPs.
6. **Drive add** — per-drive, tolerant of interrupted prior attempts,
   verified against the cluster's registered count.
7. **Finalize** — start-io, the scale-in baseline parameter, one-time
   admin password rotation into Secrets Manager
   (`weka/<cluster>/admin`), and a next-steps report with the exact
   credential and UI port-forward commands.

Then make it consumable — create a filesystem and mount it on every node:

```bash
ansible-playbook -e @weka_vars.yml fs.yml
```

**Access the UI** (no inbound ports; from your workstation):

```bash
aws secretsmanager get-secret-value --region <region> \
  --secret-id weka/<cluster>/admin --query SecretString --output text
aws ssm start-session --region <region> --target <any-member-instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["14000"],"localPortNumber":["14000"]}'
# browse https://localhost:14000
```

**Running Slurm on these nodes?** The deploy prints the `CpuSpecList`
(WEKA cores + SMT siblings) to reserve in `slurm.conf`; pin or exclude
cores explicitly with `weka_core_ids` / `excluded_core_ids`.

## 7. Day 2 — operate the cluster

All operations resolve membership and health **from the cluster itself**
before acting, and every disruptive operation is gated.

**Status + health:**

```bash
ansible-playbook -e @weka_vars.yml day2-status.yml
ansible-playbook -e @weka_vars.yml healthcheck.yml     # 5 read-only gates
```

**Scale out** — launch new instances from the same launch template (they
are born tagged), wait for SSM, then:

```bash
ansible-playbook -e @weka_vars.yml scale-out.yml
```

Candidates are detected automatically (tagged + in inventory, not yet
members). New nodes install WEKA from the running cluster's own dist
endpoint — always version-matched, even after manual upgrades. Partially
adopted nodes (from an interrupted run) self-heal on the next execution.

**Scale in** — one node at a time, by inventory hostname (instance id):

```bash
ansible-playbook -e @weka_vars.yml -e weka_target=i-0abc... scale-in.yml
```

Refuses below the original cluster size (the floor never moves), refuses
on an unhealthy cluster, drains drives serially with progress output,
verifies the cluster-side removal, wipes the node, and re-tags it so it
is never re-adopted. Optional Slurm integration: add
`-e slurm_controller=<inventory-host>` to drain the Slurm node and wait
for jobs before the WEKA drain (hook mechanics validated against mocks;
review before first use with a production Slurm).

**Maintenance stop/start** — for planned reboots, without removing the
node:

```bash
ansible-playbook -e @weka_vars.yml -e weka_stop_target=i-0abc... node-stop.yml
# ... reboot / maintain the node; the cluster runs degraded ...
ansible-playbook -e @weka_vars.yml -e weka_stop_target=i-0abc... node-start.yml
```

**Replace a dead node** — instance terminated or unreachable:

```bash
# 1. remove the dead id from the running fleet, launch a replacement
#    from the launch template, wait for SSM
# 2. the playbook auto-detects dead members and requires confirmation:
ansible-playbook -e @weka_vars.yml -e confirm_dead_ip=<mgmt-ip> replace.yml
```

Cleans the dead node's containers and drives from the cluster, adopts the
replacement, and waits for the rebuild to full protection.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `stripe X+Y needs N failure domains but only M nodes exist` | Config/fleet mismatch | Fix `stripe_data`/`stripe_protection` in weka_vars.yml, or launch the right node count |
| Env preflight `[FAIL]` lines | Missing VPC prerequisite | Run the printed `fix:` command; egress items belong to your platform team |
| Hosts `UNREACHABLE` mid-task (often during apt/downloads) | SSM command timeout | `ansible_aws_ssm_timeout: 900` is set in `group_vars/all.yml` — keep it; raise for very slow links |
| `Failed to get bucket region ... 404` on every task | Wrong/placeholder transfer bucket | Set `ssm_transfer_bucket` to a real bucket you own |
| A single host `TargetNotConnected`, back online a minute later | Transient SSM agent restart (snap-managed on Ubuntu) | Rerun — everything is idempotent |
| Driver build fails: headers not installable | EL point-release drift or custom kernel | The installer self-installs from the Rocky/Alma vault; custom kernels need matching `kernel-devel` baked into the image |
| Drive count lower than expected, `skipping /dev/...` in discovery | Device in use (LVM/RAID/partition/mount/signature) | Intentional — WEKA builds around it. To reclaim: remove the claim (`vgchange -an`, `wipefs -a`) and scale the node out/in |
| `weka user login` fails on reruns | Password already rotated | Handled automatically (secret-first logins). Manual CLI use: read the secret from Secrets Manager |
| Scale-in `REFUSED ... below the original size floor` | By design | The floor is the day-0 size; scale out before scaling in |
| Cluster `REBUILDING` after node-stop / scale-in / replace | Normal | The playbooks wait for full protection; watch `day2-status.yml` |
| First boot on Rocky/RHEL never reaches SSM | AMI ships no SSM agent | Use `scripts/userdata-el.sh` in the launch template (the generator's `USER_DATA_FILE`) |

## 9. Appendix: macOS control nodes

Linux is the supported control node. macOS works for development with:

- A Python ≤ 3.13 virtualenv (Homebrew's 3.14 ansible kills forked
  workers): `uv venv --python 3.12`, then the same pip/galaxy installs.
- `export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`
- The dynamic inventory and SSM workers cannot share one process on
  macOS. Snapshot first, then run against the snapshot:

  ```bash
  ansible-inventory -i inventory/weka_ec2.aws_ec2.yml --list --yaml > /tmp/weka-hosts.yml
  ansible-playbook -i /tmp/weka-hosts.yml -e @weka_vars.yml cluster.yml
  ```

None of these apply on Linux.
