# WEKA Converged Deployment on AWS — Runbook

Deploy a converged WEKA cluster on AWS EC2 instances with local NVMe and
multiple network interfaces. The tooling is instance-type aware: it queries
the selected type's capabilities and generates the correct network layout.
The reference platform is `p6-b300.48xlarge` (NVIDIA B300); any instance type
that meets the minimum requirements (§2) works the same way.

Orchestration uses AWS Systems Manager (SSM) exclusively — no SSH keys, no
inbound network access, no static inventories. Nodes are discovered by EC2
tag and all per-node values (NICs, cores, NVMe, gateway) are discovered at
runtime on each node.

## 1. Package contents

| File | Purpose |
|---|---|
| `RUNBOOK.md` | This document |
| `weka.conf` | **Single source of truth** for all customer values — fill this one file (§4) |
| `deploy.sh` | Workstation driver: runs the installer / day-2 ops on the right node over SSM |
| `scripts/generate-launch-template.sh` | Generates the launch template (or a merge fragment for your existing template) from your environment + instance type |
| `scripts/weka-env-preflight.sh` | Environment conformance check — run FIRST, from your workstation: verifies §3 prerequisites (egress, S3/SSM paths, SGs, IAM, AMI, AZ offering) read-only, before anything launches |
| `scripts/weka-preflight.sh` | Node/AMI conformance check — run before installing (§6.3) |
| `scripts/userdata-el.sh` | Instance user data for RHEL-family AMIs (Rocky/Alma/RHEL): installs the SSM agent + sets SELinux permissive; reference as `USER_DATA_FILE` |
| `scripts/weka-topo-discovery.sh` | Optional deep topology report (NUMA/NIC/NVMe/GPU) |
| `scripts/create-infrastructure.sh` | Optional greenfield helper: creates subnet/SGs/endpoints/IAM inside an existing VPC when §3 items are missing |
| `scripts/attach-data-enis.sh` | Cross-VPC layouts only: attaches the planned data ENIs post-launch (invoked automatically) |
| `install/weka-ssm-install.sh` | Day-0 installer: forms the cluster end to end |
| `install/weka-day2.sh` | Day-2 operations: scale-out / scale-in / replace / status |
| `iam/instance-policy.json` | Instance-profile policy template (what the NODES may do) |
| `iam/operator-policy.json` | Operator policy template (what YOU need to run this package) |
| `ANSIBLE-RUNBOOK.md` | The Ansible-driven path through this package (automation-mandated environments) |
| `ansible/` | Ansible entry point: `site.yml` (day 0) + `day2.yml` — see ANSIBLE-RUNBOOK.md |
| `reference-launch-template-p6b300.json` | Reference: the full p6-b300.48xlarge template layout |

Every script carries a `CUSTOMER CONFIGURATION` block at the top — all
environment-specific values live there, marked `CHANGEME`. No values are
passed as hidden environment variables; the few operational overrides that
exist (e.g. `FORCE_ORCHESTRATOR`) are declared and documented in the same
block. **Do not commit filled-in scripts to shared repositories** — the
install URL is a time-limited bearer token.

## 2. Minimum instance requirements

The generator checks all of these automatically and refuses types that
cannot work:

- **Local instance-store NVMe** (WEKA backend drives). EBS-only types fail.
- **Enough ENI capacity** for: 1 management ENI + one data-plane ENI per
  configured WEKA core (`DRIVE_CORES + COMPUTE_CORES + FRONTEND_CORES`)
  + EFA interfaces on GPU platforms.
- **Kernel ≤ 6.8** on the AMI (WEKA 4.4.x driver build ceiling — see §5).
- Enough physical cores for the carve plus one reserved for the OS.

## 3. Environment prerequisites (bring your own)

The normal flow uses your **existing** VPC infrastructure. You provide, and
the tooling validates, the items below. (If some are missing,
`scripts/create-infrastructure.sh` can create the subnet/SGs/endpoints/IAM
inside your VPC and prints its outputs in the exact form the generator
expects — but bring-your-own is the primary path.)

1. **Subnet** in the capacity reservation's AZ, with at least
   `(1 + data ENIs) × node count` free IPs. **One subnet for everything is
   the recommended, best-practice layout** — it is the simplest to reason
   about, the most widely deployed, and what every default in this package
   assumes. Two variants exist for environments that require them:
   - **Separate management subnet, same VPC** (`MGMT_SUBNET_ID`): expressed
     directly in the launch template.
   - **Management and data in DIFFERENT VPCs**: supported via EC2 multi-VPC
     ENI attachments (same AWS account and same AZ required). Launch
     templates cannot span VPCs, so the instance launches into the
     management VPC and the generator emits `data-eni-plan.json`; deploy.sh
     and the Ansible playbook execute it automatically post-launch
     (`scripts/attach-data-enis.sh`, idempotent — scale-out/replacement
     nodes get their ENIs the same way). `SG_MGMT` is required (SG_ENA
     belongs to the data VPC). On GPU/EFA platforms the EFA interfaces stay
     in the launch VPC — EFA cannot be hot-attached or cross VPCs.
   Requirements common to both split layouts:
   - One subnet per role cluster-wide (all mgmt ENIs in one subnet, all data
     ENIs in the other).
   - No custom routing between them — the VPC's implicit `local` route covers
     node↔node traffic for both roles automatically.
   - The **management subnet carries the default route** and therefore needs
     ALL the connectivity below (items 4–7). If it uses its own route table,
     the S3 gateway endpoint must be associated with THAT route table.
   - The **data subnet needs nothing external** — no IGW/NAT/endpoints; its
     gateway is the automatic VPC router. Fully isolated is fine.
   - If using a separate `SG_MGMT`, it must pass node↔node WEKA control
     traffic (self-referencing all-traffic is the simple correct rule);
     custom NACLs on either subnet must pass node↔node + ephemeral ports.
   - WEKA clients mount over the DATA network — client instances need
     SG/NACL reachability to the data subnet.
2. **Security groups**: one for mgmt + WEKA data (self-referencing between
   cluster nodes, plus whatever management access you need), and — on GPU/EFA
   platforms — one for EFA that is **self-referencing for ALL traffic, both
   directions** (EFA requirement; the generator verifies this).
3. **Instance profile** with `AmazonSSMManagedInstanceCore` plus the policy in
   `iam/instance-policy.json` — see §4's `iam/instance-policy.json` entry for
   the full placeholder table, what each statement grants, and the exact
   commands to create the role and profile.
4. **SSM connectivity** from the subnet: interface endpoints for `ssm`,
   `ssmmessages`, `ec2messages` (they may live in a parent-region subnet of
   the same VPC), or a NAT path.
5. **S3 access** (gateway endpoint or NAT) for the WEKA distribution
   download, and **package-repository access** (NAT, proxy, or internal
   mirrors) so the tooling can self-install its dependencies (aws CLI, jq,
   make/gcc/kernel headers). The preflight verifies repo reachability per
   node — a node whose default route has no egress fails there, before
   anything installs. An S3 gateway endpoint alone covers the WEKA tarball
   but NOT the distro repositories.
6. **Secrets Manager reachability** (endpoint or NAT): the installer stores
   the rotated admin credential there and day-2 reads it. If unavailable, set
   `ROTATE_ADMIN_PASSWORD=false` and manage credentials manually.
7. **WEKA 4.4.x distribution** reachable from the nodes. Preferred: upload
   the tarball to an S3 bucket, grant the bucket in the instance policy's
   `WekaDistroDownload` statement, and set `WEKA_INSTALL_S3=s3://bucket/key`
   — nodes download it with their instance role (no presigned URL to manage).
   Alternative: `WEKA_INSTALL_URL` with a get.weka.io URL or a presigned URL
   (presigned URLs expire — and expire early if the signing credentials do).
8. **Capacity**: a capacity block or ODCR for the chosen type. Both use
   `InstanceMatchCriteria: targeted`, so launches must reference the
   reservation explicitly (§6.1).

## 4. Configuration model

**Fill one file: `weka.conf`** (package root, tfvars-style). Every script
reads it, and its values override the defaults in each script's
`CUSTOMER CONFIGURATION` block; deploy.sh ships it to the nodes
automatically, so the installers read the same values. Per-operation inputs
(e.g. which node to remove) remain command arguments.

The per-script `CUSTOMER CONFIGURATION` blocks still exist as documented
defaults — you can run any script standalone without weka.conf by editing
its block directly — but with weka.conf the consistency problem disappears
except for **one value shell cannot reach: the cluster name inside
`iam/instance-policy.json`**. Keep that in sync with `CLUSTER_NAME` in
weka.conf (a mismatch shows up as the AccessDenied in §8).

Per-file reference (defaults and script-specific settings):

**`generate-launch-template.sh`** — region, instance type, AMI, subnet, SGs,
instance profile ARN, cluster name, core carve, node count, root volume, and
the `auto`-derived overrides (`EFA_COUNT`, `EFA_CARD_START`). Optional
`MGMT_SUBNET_ID`/`SG_MGMT` place the management ENI on its own subnet and
security group (validated: same VPC + AZ as the data subnet, split free-IP
capacity).
`WEKA_OPT_VOLUME_GB` adds a **dedicated EBS volume for `/opt/weka`**
(recommended; the default `"auto"` sizes it at 48 GB + 10 GB per WEKA core,
matching official WEKA sizing practice). The installer formats it XFS and
mounts it before the agent installs, so WEKA's software, logs, and traces
are isolated from the root filesystem; scale-out nodes inherit it
automatically. Set `0` to share the root volume instead.

**`weka-ssm-install.sh`** (day-0) — cluster name, `EXPECTED_NODES`,
stripe (`DATA`+`PROTECTION` ≤ node count; ≥5 hosts minimum for any cluster),
`HOT_SPARES`, `JOIN_COUNT`, core carve, RAM per core, mgmt ENI position, base
ports, install source (`WEKA_INSTALL_S3` preferred / `WEKA_INSTALL_URL`),
rotation settings, SSM timeout, and `DRIVES_PER_NODE` (0 = give WEKA all
instance-store NVMe; N = only N per node, selected NUMA-balanced — e.g. 5 of
the p6-b300's 8, leaving 3 for other workloads). On platforms that expose
device NUMA affinity (e.g. p6-b300), cores and data NICs are automatically
allocated as same-NUMA pairs for NUMA-local DPDK polling (the drives-phase
log prints the pairing table); where affinity is hidden, assignment falls
back to balanced round-robin. **Core placement / Slurm coexistence**:
`WEKA_CORE_IDS` pins WEKA to exactly the cores you list (cpulist syntax,
count = carve total); `EXCLUDED_CORE_IDS` keeps auto-selection away from
cores you list (a core is avoided if any of its hyperthreads appears — paste
your Slurm partition's CPU list directly). Either way, discovery prints the
ready-to-paste `CpuSpecList=` line (WEKA cores **plus their SMT siblings**)
for slurm.conf, repeated in the installer's final "Next steps" output; also
size `MemSpecLimit` for the WEKA container memory you configured. Override
knob: `FORCE_ORCHESTRATOR=1` to run from a non-elected node.

**`weka-day2.sh`** — same identity values as day-0 (credentials come
from Secrets Manager automatically). Override knobs: `ORIGINAL_SIZE` (only if
the baseline parameter is missing), `NODE_IP` (only for terminated nodes the
API can no longer resolve).

**`weka-preflight.sh`** — thresholds: `WEKA_MAX_KERNEL` (default 6.8),
`MIN_DATA_NICS` (set to your core-carve total), `MIN_PHYS_CORES`,
`MIN_FREE_GB`, mgmt ENI position. Also verifies **memory arithmetic**: the
configured carve's requirement (cores × RAM-per-core + agent overhead)
against actually-available memory, and warns on **pre-reserved hugepages**
(boot-time `hugepages=N` reservations reduce what WEKA and the OS can use).
Note: WEKA's agent allocates and manages its *own* hugepages from the
container memory sizing — no hugepage configuration is needed or performed
by this package; on converged hosts, make sure Slurm's `MemSpecLimit` and
any other reservations leave room for the carve.

**`iam/instance-policy.json`** — edit these values before creating the role:

| Placeholder | Replace with | Appears in |
|---|---|---|
| `ACCOUNT_ID` | Your AWS account id | Every resource ARN (tagging, SSM, secrets, parameters) |
| `us-east-1` | Your deployment region | Region pins on the same ARNs and conditions |
| `CLUSTER_NAME` | Your cluster name — **exactly** the `CLUSTER_NAME` in weka.conf | The `SsmOrchestrationInstances` tag condition. A mismatch is the most common install failure (§8: AccessDenied on `…:instance/…`) |
| `YOUR-INSTALL-BUCKET` | The bucket holding your WEKA tarball (`WEKA_INSTALL_S3`) | `WekaDistroDownload` statement. Delete the statement if you use `WEKA_INSTALL_URL` instead |
| `YOUR-WEKA-OBS-BUCKET` | Your tiering / snap-to-object bucket | `WekaSnapToObjAndTiering` statement. Delete if not using object storage |

What each statement grants (for your security review):

- `ClusterDiscovery` — read-only EC2 describes; how nodes find each other by tag.
- `EniManagement` — create/attach/delete ENIs and IP assignment, region-pinned;
  used by WEKA's network provisioning on the data plane.
- `WekaResourceTagging` — `ec2:CreateTags` restricted to instances/ENIs and to
  the `weka-*`/`Name` tag keys (day-2 uses it to mark removed nodes).
- `SsmOrchestrationInstances` / `SsmOrchestrationDocument` — lets the
  orchestrator node run the phase scripts on cluster members via SSM,
  restricted to instances carrying your cluster tag + the stock
  `AWS-RunShellScript` document. **Keep these two statements separate** —
  a tag condition applied to the document ARN denies everything.
- `WekaAdminSecret` — create/read/update only `secret:weka/*` (the rotated
  admin credential).
- `WekaBaselineParams` — get/put only `parameter/weka/*` (the scale-in floor).
- `SsmOrchestrationRead` — read-only SSM status polling.

Create the role and instance profile from the filled file (skip if you used
`create-infrastructure.sh`, which does this for you):

```bash
ROLE=weka-cluster1-instance-role          # your names
PROFILE=weka-cluster1-instance-profile
aws iam create-role --role-name $ROLE --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name $ROLE --policy-name weka-instance \
  --policy-document file://iam/instance-policy.json
aws iam create-instance-profile --instance-profile-name $PROFILE
aws iam add-role-to-instance-profile --instance-profile-name $PROFILE --role-name $ROLE
aws iam get-instance-profile --instance-profile-name $PROFILE \
  --query 'InstanceProfile.Arn' --output text   # -> INSTANCE_PROFILE_ARN for the generator
```

`AmazonSSMManagedInstanceCore` is attached separately (above) — it is not in
the policy file, and nothing works over SSM without it.

**`iam/operator-policy.json`** — the permissions for the IAM user/role that
RUNS this package from a workstation (generator, launches, deploy.sh, SSM
port-forward, credential retrieval). Placeholders: `ACCOUNT_ID`, `us-east-1`,
`CLUSTER_NAME` (the SSM/terminate statements are tag-scoped to your cluster,
same as the instance policy), `WEKA-INSTANCE-ROLE-NAME` (the role from the
section above — `iam:PassRole` on it is required by `RunInstances`, scoped to
EC2 only), and `YOUR-INSTALL-BUCKET` (tarball upload). Statements prefixed
`Optional*` can be deleted if not wanted: teardown rights (terminate
tag-matched instances, delete the weka secret/parameter) and the greenfield
rights used only by `create-infrastructure.sh` (network creation plus IAM
role/profile creation scoped to `CLUSTER_NAME-*` names). The two
`SsmCommand*`/`SsmPortForward*` statement pairs must stay separate for the
same reason as in the instance policy.

## 5. AMI and kernel requirements

WEKA 4.4.x kernel drivers do not build on kernels newer than 6.8. Symptom if
ignored: the install phase fails with `Driver command './prepare.sh' failed`.
The preflight catches this before anything is installed.

Any AMI works if: kernel ≤ 6.8 (or pinnable to it), kernel headers and a
compiler matching the kernel's build compiler are present or installable, and
the SSM agent is present. The installer self-installs its other dependencies
(aws CLI, jq, make/gcc/headers) via the distro package manager — which
requires repository access from the node (§3.5); AMIs with everything baked
in need no repo access.

Example kernel pin for Ubuntu 24.04 (which boots 6.17 by default — run on
every node via SSM, then reboot):

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -yq linux-image-aws-lts-24.04 linux-headers-aws-lts-24.04
K=$(ls /boot/vmlinuz-6.8.0-*-aws | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux $K" && update-grub && reboot
```

## 6. Deployment — step-by-step walkthrough

You will edit **one file** (`weka.conf`) and run **four commands**. Every
command block below is paste-runnable as-is. Work from the package root.

### 6.0 Fill weka.conf

Open `weka.conf` and set every CHANGEME: region, cluster name, instance
type, AMI, subnet, security group(s), instance profile ARN, node count,
stripe, core carve, and the WEKA install source. This is the only editing
step — all scripts read this file.

### 6.1 Generate and create the launch template

Not sure what a given instance type supports, or what core carve fits? Ask
the generator first — no configuration needed:

```bash
bash scripts/generate-launch-template.sh describe g6.12xlarge
```

It prints the type's NVMe/GPU/ENI/EFA capabilities, the ENI budget math, the
**maximum core carve**, a suggested starting split, and the auto-sized
`/opt/weka` volume — or tells you the type is unsuitable and why.

**Run** (first pass validates without creating anything):

```bash
bash scripts/generate-launch-template.sh
```

**You should see:** `[ok]` lines for instance storage, EFA plan, and subnet
capacity; a layout summary (mgmt / efa / data ENI counts); two files written;
and the installer values echoed back. Any `[FAIL]` line tells you exactly
what to fix before continuing.

Now run it with `CREATE_IN_AWS=true` (either uncomment/add it in weka.conf
or edit the script default), and it prints the template id
**and the exact `aws ec2 run-instances` command for your next step** (one
variant for on-demand/ODCR, one for capacity blocks).

If you maintain your own launch template instead, take the
`*-merge-fragment.json` file and add its three blocks (`NetworkInterfaces`,
`MetadataOptions`, `TagSpecifications`) to your template as a new version.

### 6.2 Launch the nodes and wait for SSM

Paste the `run-instances` command the generator printed (add your capacity
reservation id if using a capacity block). Then watch the fleet register:

```bash
REGION=us-east-1            # your region
CLUSTER=weka-cluster1       # your cluster name
aws ssm describe-instance-information --region $REGION \
  --filters Key=tag:weka-cluster,Values=$CLUSTER \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
```

**You should see:** one row per node, all `Online` (allow 1–2 minutes after
launch). If your AMI needs the kernel pin (§5), do it now on every node and
wait for `Online` again after the reboot.

### 6.3 Preflight — every node, zero failures

```bash
REGION=us-east-1
CLUSTER=weka-cluster1
B64=$(base64 < scripts/weka-preflight.sh | tr -d '\n')
CID=$(aws ssm send-command --region $REGION --document-name AWS-RunShellScript \
  --targets Key=tag:weka-cluster,Values=$CLUSTER \
  --parameters "commands=[\"echo $B64 | base64 -d > /tmp/preflight.sh && sudo bash /tmp/preflight.sh\"]" \
  --query 'Command.CommandId' --output text)
sleep 45
for IID in $(aws ssm list-command-invocations --region $REGION --command-id $CID \
    --query 'CommandInvocations[].InstanceId' --output text); do
  echo "===== $IID ====="
  aws ssm get-command-invocation --region $REGION --command-id $CID --instance-id $IID \
    --query '[Status,StandardOutputContent]' --output text | tail -6
done
```

**You should see:** `##### RESULT: N pass / N warn / 0 fail #####` on every
node. Do not continue past a FAIL — each one is a mid-install failure caught
early (§8 maps them to fixes).

### 6.4 Install

```bash
./deploy.sh install
```

deploy.sh finds the elected orchestrator by tag, ships the installer to it
over SSM (no S3 staging, no SSH), runs it, and prints status lines until it
completes (typically 8–15 minutes, dominated by the WEKA download on each
node).

**You should see** the phases march by in the final output — install →
cleanup → drives → cluster create → protection → compute → frontend →
adddrives → start-io — ending with `weka status` showing `status: OK` and
`Fully protected`, followed by a **"Next steps"** section containing three
ready-to-paste commands with your real values filled in: retrieving the
admin credentials from Secrets Manager, and the SSM port-forward (with a
live backend instance id) for the WEKA UI at `https://localhost:14000`.

**Do not log into the WEKA UI while the installer is running** — a first
login with default credentials forces a password rotation mid-install. After
completion this cannot happen: the password is already rotated.

If a phase fails, deploy.sh prints the failing node's output and the log
location (`/tmp/weka-run.log` on the orchestrator). §8 maps the common
failures to fixes; after fixing, teardown (§8 bottom) and re-run.

### 6.5 Verify

Use the two commands from the installer's "Next steps" output (credentials +
UI tunnel), and/or:

```bash
./deploy.sh day2 status
```

**You should see:** every instance listed as `MEMBER`, the baseline
recorded, and `status: OK`. Filesystem/group creation, tiering, and client
mounts follow standard WEKA documentation from here.

## 7. Day-2 operations

Edit `install/weka-day2.sh`'s CUSTOMER CONFIGURATION once (same identity
values as day-0), then drive everything through deploy.sh — it ships the
script to a healthy member and runs it there. Credentials come from the
Secrets Manager secret automatically.

```bash
weka-day2.sh status                  # membership vs tags, baseline, candidates
weka-day2.sh scale-out               # adopt ALL tagged non-member running nodes
weka-day2.sh scale-in  <iid> [...]   # graceful serialized removal
weka-day2.sh replace   <iid> [--remove-first]   # failed-node swap
```

**Scale-out:** launch additional instances from the same launch template
(they are born tagged), wait until running, run `scale-out`. Idempotent —
membership is computed, so interrupted runs can simply be re-run. Refuses to
start unless the cluster is healthy and fully protected. New nodes install
WEKA **from the running cluster's own distribution endpoint**, so they always
join at the cluster's current version — including versions applied by manual
upgrades after the original deployment (`WEKA_INSTALL_URL` in the day-2
script is only a fallback and normally stays empty).

> **Fleet-wide opt-in pattern.** Because scale-out is purely tag-driven, a
> converged fleet can launch *every* instance from a variant of the WEKA
> launch template with the `weka-cluster` tag removed (keeping the full ENI
> layout, instance profile, and /opt/weka volume), then opt individual nodes
> into WEKA later by simply **adding the tag and running `scale-out`** — no
> relaunch needed. On non-WEKA nodes the data ENIs sit unconfigured (they
> still consume subnet IPs) and EFA works normally. Two rules: opting a node
> **out** is `scale-in <instance-id>`, never tag removal (drives must drain);
> and remember tagged nodes give up the WEKA core/memory carve, so scheduler
> reservations (e.g. Slurm `CpuSpecList`) differ between tagged and untagged
> nodes.

**Scale-in:** hard refusals, checked before any action: (1) **never below the
original cluster size** — WEKA does not support it; the floor comes from the
deployment baseline and never moves; (2) never below stripe viability
(`nodes_after ≥ DATA+PROTECTION+hot-spares`). Removal is serialized per node:
drive deactivate → wait for data redistribution → drive remove → container
removal → local wipe → re-tag. The script never terminates EC2 instances —
it reports "safe to terminate" and leaves that to you. Interrupted drains
resume cleanly on re-run.

**Replace:** default add-first — launch the replacement, run
`replace <failed-iid>`; it adopts the new node while degraded, removes the
dead node's drives/containers, and waits for full protection. On a full
capacity block (no free slot for N+1), use `--remove-first`, then launch the
replacement and run `scale-out`. For already-terminated instances pass
`NODE_IP=<mgmt-ip>` if the API can no longer resolve the node.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Install phase: `prepare.sh failed with error code 101`, compile errors | Kernel newer than 6.8 | §5 kernel pin, or an AMI with kernel ≤ 6.8 (preflight catches this) |
| Driver build: `gcc-N: not found` | AMI lacks the compiler its kernel was built with | Installer self-installs it; if repos are unreachable, bake make/gcc/headers into the AMI |
| `aws: command not found` / `jq` missing | Minimal AMI | Self-installed via distro packages; needs S3-backed mirror access (§3.5) |
| Nodes never reach SSM `Online` | No path to SSM endpoints | §3.4 |
| `AccessDeniedException` on `ssm:SendCommand` **on resource …:instance/…** | The instance policy's `weka-cluster` tag condition doesn't include your cluster name (the `CLUSTER_NAME` placeholder wasn't filled, or you renamed the cluster without updating the policy) | Put your cluster name in the policy's `SsmOrchestrationInstances` condition — the three-way-match rule (§4). Safe to re-run after fixing |
| `AccessDeniedException` on `ssm:SendCommand` **mentioning the document** | The two `SsmOrchestration*` IAM statements were merged | Keep them separate (§3.3) |
| Install phase `TimedOut` on several nodes at once, with **no error output** | Slow package-repo egress — every node downloads distro indexes and build deps simultaneously through the same NAT gateway/instance or proxy, and the slowest nodes blow the per-phase timeout (1200 s default). Small NAT *instances* are the usual culprit | Just re-run — everything is idempotent, and the nodes that finished are skipped while the stragglers resume with warm package caches. For constrained egress, raise the timeout in weka.conf (`SSM_TIMEOUT=2400`), or bake make/gcc/headers/awscli/jq into the AMI so nodes skip the downloads entirely |
| `FATAL: expected N nodes, found M` | Tag/count mismatch | Verify `weka-cluster=<name>` tags and running state |
| `FATAL: I am i-…; elected orchestrator is i-…` | Ran installer on a non-elected node | Run there, or set `FORCE_ORCHESTRATOR=1` |
| `Clustering operation failed: at least 5 hosts needed` | WEKA minimum cluster size | Deploy ≥ 5 nodes |
| `FATAL: no IPv4 on <nic>` | Subnet out of IPs, or network manager conflict | Check subnet free IPs first |
| Download 403 mid-workflow | Presigned URL expired (or its issuing credentials did) | Regenerate the URL right before the run |
| `InsufficientInstanceCapacity` at launch | The AZ (pinned by your subnet) can't fill the request right now — common for multi-node GPU asks; the "available AZ" hints in the error churn minute to minute | Switch `SUBNET_ID` to a subnet in another AZ and re-run (the template re-versions automatically). If several AZs bounce, the atomic ask is too large for current pools: reduce node count, pivot to a comparable type from a deeper pool (the generator re-validates), or use a capacity reservation |
| Day-2 "secret not readable" then login failure | Secret missing or IAM/endpoint gap | Verify secret exists, IAM `WekaAdminSecret` statement, Secrets Manager reachability |
| SSM output truncated at 24,000 chars | SSM API limit | Retrieve big artifacts gzip+base64, or enable the CloudWatch output option |
| `bash -n` on macOS reports a syntax error in the installers | macOS ships bash 3.2 (parser bug with case patterns in `$()`) | Syntax-check with bash ≥ 4 / on Linux; the scripts run on Linux |
| Preflight FAILs NIC/NVMe checks on a node already running WEKA | DPDK-bound devices are invisible to sysfs | Expected — those checks apply to pre-install nodes (reported as WARN) |

**Teardown / reinstall:** the installer refuses to run over an existing
cluster. To rebuild from scratch, run on all nodes via SSM:
`sudo weka local stop -f && sudo weka local rm --all -f`, then re-run day-0.

## 9. Support notes

- Validated end to end on `p6-b300.48xlarge` (reference platform) and
  `i3en.2xlarge` (functional validation); the generator refuses instance
  types that do not meet WEKA minimums.
- The generator validates *feasibility* of a layout, not performance sizing.
  Engage WEKA for core-carve and stripe sizing guidance for your workload.
- On new/exotic multi-card platforms, review the generated ENI layout before
  first use; per-card capabilities not expressed by the EC2 API are handled
  by convention (`EFA_CARD_START` override available).
