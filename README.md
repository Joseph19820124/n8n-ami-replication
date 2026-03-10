# n8n + Shell Script: EC2 AMI Creation & Cross-Region/Cross-Account Replication

Automate EC2 AMI backups using **n8n as the scheduler + SSH trigger**, with all AWS logic encapsulated in a single shell script.

## Architecture

```
┌──────────────┐         SSH          ┌──────────────────────────┐
│   n8n        │ ──────────────────── │  Linux Server            │
│              │  "bash ami-replicate │  (with AWS CLI + creds)  │
│  Schedule    │   .sh"              │                          │
│  Trigger     │                      │  ami-replicate.sh:       │
│      │       │                      │   1. Create AMI          │
│      ▼       │                      │   2. Wait until ready    │
│  SSH Node    │ ◄─── stdout/exit ─── │   3. Copy to N regions   │
│      │       │      code            │   4. Share + cross-acct  │
│      ▼       │                      │   5. Wait all copies     │
│  (on error:  │                      │   6. Cleanup old AMIs    │
│   notify)    │                      └──────────────────────────┘
└──────────────┘
```

**Why this approach?**
- n8n only needs **2 nodes** (Schedule Trigger → SSH) — no complex polling loops
- All retry/wait logic lives in the shell script where `aws ec2 wait` works natively
- Easy to test: run the script manually via SSH before wiring up n8n
- Script is version-controlled and portable

## n8n Workflow Setup

### Nodes

| # | Node | Configuration |
|---|------|---------------|
| 1 | **Schedule Trigger** | Cron: `0 */1 * * *` (every hour) |
| 2 | **SSH** | Host: `your-server` / Credential: SSH key / Command: `bash /opt/scripts/ami-replicate.sh` |

### SSH Credential (in n8n)

1. Go to **Credentials** → **New** → **SSH**
2. Fill in:
   - **Host**: your Linux server IP/hostname
   - **Port**: 22
   - **Username**: ec2-user (or your user)
   - **Authentication**: Private Key
   - **Private Key**: paste your SSH private key
3. Save

### Error Handling (optional)

Add an **If** node after SSH to check `{{ $json.exitCode }}`:
- `0` → success (optionally send Slack/email confirmation)
- non-zero → error (send alert)

## Shell Script: `ami-replicate.sh`

### What it does

1. **Create AMI** from the source EC2 instance (`--no-reboot`)
2. **Poll** until the AMI status becomes `available` (30s intervals, 30min timeout)
3. **Copy** to multiple regions in the same account (parallel)
4. **Share** the AMI + snapshots to the target account, then **copy** using target account credentials
5. **Wait** for all copies to finish (parallel wait)
6. **Cleanup** old AMIs — keep the latest N, deregister the rest and delete their snapshots

### Configuration

Edit the config section at the top of `ami-replicate.sh`:

```bash
SOURCE_REGION="us-west-2"
SOURCE_INSTANCE_ID="i-XXXXXXXXXXXXXXXXX"    # ← your instance ID

COPY_REGIONS=("us-east-1" "us-east-2" "us-west-1")

TARGET_ACCOUNT_ID="123456789012"             # ← Account B
TARGET_PROFILE="account-b"                   # ← AWS CLI named profile
TARGET_REGION="us-west-2"

AMI_PREFIX="openclaw"
KEEP_COUNT=3                                 # retention: keep latest 3
```

### Usage

```bash
# Normal run — create AMI + replicate
./ami-replicate.sh

# Skip creation, replicate an existing AMI
./ami-replicate.sh -i ami-0abcdef1234567890
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | AMI creation failed |
| 2 | AMI did not become available (timeout) |
| 3 | Copy or share operation failed |

### Prerequisites

On the Linux server where the script runs:

```bash
# AWS CLI v2
aws --version

# Default profile — Account A (source)
aws configure
# → access key, secret key, region=us-west-2

# Named profile — Account B (target)
aws configure --profile account-b
# → Account B's access key, secret key

# Required IAM permissions (both accounts):
# ec2:CreateImage, ec2:DescribeImages, ec2:CopyImage,
# ec2:ModifyImageAttribute, ec2:DeregisterImage,
# ec2:DescribeSnapshots, ec2:DeleteSnapshot,
# ec2:ModifySnapshotAttribute
```

### Script Flow

```
ami-replicate.sh
  │
  ├─ create-image ─────────────────────────── Source AMI
  │
  ├─ poll describe-images (30s loop) ──────── Wait available
  │
  ├─ copy-image × 3 (parallel start) ─────── us-east-1, us-east-2, us-west-1
  │
  ├─ modify-image-attribute ───────────────── Share AMI to Account B
  │  └─ modify-snapshot-attribute ─────────── Share snapshots too
  │
  ├─ copy-image (account B profile) ───────── Cross-account copy
  │
  ├─ wait all copies (parallel) ───────────── Poll all regions
  │
  └─ cleanup ──────────────────────────────── Deregister old AMIs + snapshots
```

## Comparison: Pure n8n vs. n8n + Script

| Aspect | Pure n8n (many nodes) | n8n + Shell Script |
|--------|----------------------|-------------------|
| **n8n complexity** | ~10+ nodes with polling loops | 2 nodes (trigger + SSH) |
| **Testability** | Must run in n8n | `bash ami-replicate.sh` from terminal |
| **Polling** | Wait+If+Loop (fragile) | Native `sleep` loop in bash |
| **Parallel copies** | Split In Batches node | Background processes + `wait` |
| **Version control** | Export JSON workflow | Standard git for `.sh` file |
| **Visibility** | Full n8n execution UI | Script stdout captured by SSH node |
| **Error handling** | n8n error branches | Exit codes + n8n If node |

## License

MIT
