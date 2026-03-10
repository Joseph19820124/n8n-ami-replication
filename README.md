# n8n Workflow: EC2 AMI Creation & Cross-Region/Cross-Account Replication

Automate EC2 AMI backups with n8n — create AMIs on a schedule, replicate across multiple AWS regions, and copy to a secondary AWS account for disaster recovery.

## Scenario

- **Source**: EC2 instance in `us-west-2` (Oregon)
- **Same-account targets**: `us-east-1`, `us-east-2`, `us-west-1`
- **Cross-account target**: A secondary AWS account, `us-west-2`
- **Schedule**: Every 60 minutes (configurable)

## Workflow Diagram

```
┌─────────────┐
│  Schedule    │  Every 60 min
│  Trigger     │
└──────┬──────┘
       │
┌──────▼──────┐
│  Create AMI  │  ec2 create-image (us-west-2)
│              │
└──────┬──────┘
       │
┌──────▼──────┐
│  Poll Loop   │  Wait 30s → describe-images → If available?
│  (Wait + If) │  ↻ loop until AMI state = "available"
└──────┬──────┘
       │
┌──────▼──────────────────────────────────────────────────┐
│  Parallel Branches                                       │
├──────────┬──────────┬──────────┬────────────────────────┤
│          │          │          │                        │
▼          ▼          ▼          ▼                        │
Copy to    Copy to    Copy to    Modify Launch            │
us-east-1  us-east-2  us-west-1  Permission               │
│          │          │          │ (share to account B)   │
│          │          │          ▼                        │
│          │          │          Copy AMI                 │
│          │          │          (account B credentials)  │
│          │          │          us-west-2                │
└──────────┴──────────┴──────────────────────────────────┘
       │
┌──────▼──────┐
│  (Optional)  │  Poll all copies until available
│  Wait All    │
└──────┬──────┘
       │
┌──────▼──────┐
│  (Optional)  │  Deregister old AMIs + delete snapshots
│  Cleanup     │  Keep last N
└─────────────┘
```

## Node Details

| # | Node Type | Purpose | Key Configuration |
|---|-----------|---------|-------------------|
| 1 | **Schedule Trigger** | Periodic trigger | Cron: `0 * * * *` (every hour) |
| 2 | **Execute Command** | Create AMI from source instance | `aws ec2 create-image --instance-id i-xxx --name "backup-{{$now.format('yyyyMMdd-HHmm')}}" --no-reboot --region us-west-2` |
| 3 | **Wait** + **HTTP Request** + **If** | Poll until AMI is available | Loop: wait 30s → `ec2 describe-images` → check `state == available` |
| 4a | **Execute Command** | Copy AMI to us-east-1 | `aws ec2 copy-image --source-region us-west-2 --source-image-id $AMI_ID --region us-east-1` |
| 4b | **Execute Command** | Copy AMI to us-east-2 | Same as above with `--region us-east-2` |
| 4c | **Execute Command** | Copy AMI to us-west-1 | Same as above with `--region us-west-1` |
| 4d-1 | **Execute Command** | Share AMI to account B | `aws ec2 modify-image-attribute --image-id $AMI_ID --launch-permission "Add=[{UserId=ACCOUNT_B_ID}]" --region us-west-2` |
| 4d-2 | **Execute Command** | Cross-account copy (account B creds) | `aws ec2 copy-image --source-region us-west-2 --source-image-id $AMI_ID --region us-west-2` |
| 5 | **Wait** + **If** (optional) | Wait for all copies to complete | Poll `describe-images` in each target region |
| 6 | **Execute Command** (optional) | Cleanup old AMIs | Deregister AMIs older than N, delete associated snapshots |

## Key Design Considerations

### Credential Management
Configure **two sets of AWS credentials** in n8n:
- **Default account** — used for steps 1–4c (create, poll, same-account copy)
- **Account B** — used for step 4d-2 (cross-account copy)

Each credential uses a separate IAM user/role with appropriate EC2 permissions.

### Polling / Wait Loop
n8n has no native "wait until condition" node. Build a polling loop with:
1. **Wait** node (30–60s pause)
2. **HTTP Request** or **Execute Command** (`describe-images`)
3. **If** node — route to next step when `available`, otherwise loop back to Wait

Set a max iteration count to avoid infinite loops.

### Cross-Account Sharing
You cannot directly copy an AMI into another account. The two-step process is:
1. `modify-image-attribute --launch-permission` — grant the target account access
2. Use target account's credentials to `copy-image` from the shared AMI

### Parallel Copy
Same-account copies to multiple regions are independent and can run in parallel using n8n's **Split In Batches** node or parallel branch wiring. The cross-account branch is sequential (share → copy).

## Comparison: n8n Workflow vs. Shell Script (cron)

| Aspect | n8n Workflow | Shell Script + cron |
|--------|-------------|-------------------|
| **Visibility** | Visual workflow editor, execution history UI | Log files, manual inspection |
| **Error handling** | Built-in retry, error branches | Custom `set -e` / trap logic |
| **Credential storage** | Encrypted in n8n DB | Environment variables or AWS profiles |
| **Scheduling** | Built-in Schedule Trigger | System cron |
| **Complexity** | Higher — polling loops are verbose in n8n | Lower — `aws ec2 wait image-available` handles polling natively |
| **Dependencies** | n8n server must be running | Only cron + AWS CLI needed |
| **Best for** | Teams wanting UI visibility & no-code editing | Simple, single-operator setups |

> **TL;DR**: For a straightforward AMI backup pipeline, a shell script with `aws ec2 wait` is simpler. n8n shines when you need a visual audit trail, easy modification by non-developers, or integration with other n8n workflows (notifications, ticketing, etc.).

## License

MIT
