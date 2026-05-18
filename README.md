
# lab-troubleshooting-broken-infra

Day 1 Assignment 3 — three intentionally-broken AWS/Terraform scenarios diagnosed with AWS CLI, fixed in Terraform, and documented with an RCA.

## Scenarios

1. **scenario-01-network** — EC2 unreachable; networking-layer break
2. **scenario-02-iam** — Lambda silently fails to write to S3; IAM break
3. **scenario-03-state** — Terraform state out of sync with AWS

## RCA format (per scenario)

- **Symptom** — what was observed, exact error or behavior
- **Diagnosis path** — the CLI commands run, in order, and what each ruled in/out
- **Root cause** — the actual misconfiguration in one or two sentences
- **Fix** — the Terraform change applied (diff or snippet)
- **Validation** — how the fix was confirmed (command + expected output)
- **Prevention** — what would catch this earlier: a guardrail, a `tflint`/`checkov` rule, a smoke test, a CloudWatch alarm, etc.

---

## Scenario 1 RCA — EC2 unreachable due to NACL ephemeral port gap

**Symptom**

`curl -v --max-time 10 http://<public-ip>` against a freshly applied t3.micro web server timed out at the TCP handshake — `Trying <ip>:80...` followed by `Connection timed out after 10004 milliseconds`. No SYN-ACK ever returned. The instance was `running` with 3/3 status checks passing, so the host and nginx were healthy; the failure was below the application layer.

**Diagnosis path**

1. `aws ec2 describe-instance-status` — confirmed instance state `running`, both status checks `ok`. Ruled out host failure and confirmed user-data succeeded (system reachability check exercises outbound packet path, so dnf must have reached the repos).
2. `aws ec2 describe-security-groups` on the instance's SG — ingress TCP/80 from `0.0.0.0/0`, egress all. SG is stateful, so return traffic is automatic. Ruled out SG.
3. `aws ec2 describe-route-tables` on the public subnet — `0.0.0.0/0` route to the IGW present, subnet correctly associated. Ruled out routing.
4. `aws ec2 describe-network-acls` on the public subnet — found the ingress rules allowed TCP/80 and ephemeral 1024–65535, but the **egress** rules only allowed destination TCP/80 and TCP/443. Outbound replies from nginx (going to the client's ephemeral source port, e.g. 55295) were being dropped by the implicit `deny` rule 32767. Confirmed root cause.

**Root cause**

The NACL allowed inbound ephemeral ports (for return traffic from outbound HTTPS to package repos) but did not allow outbound ephemeral ports — so reply packets from nginx back to client ephemeral ports were dropped. NACLs are stateless: every direction must be explicitly allowed, and "return traffic" is a concept that does not exist at the NACL layer.

**Fix**

Added a third egress rule to `aws_network_acl.public` allowing TCP destination ports 1024–65535 to `0.0.0.0/0`. See `scenario-01-network/main.tf` vs `scenario-01-network/main.tf.broken` for the exact diff.

**Validation**

`curl -v --max-time 10 http://<public-ip>` returned `HTTP/1.1 200 OK` with the placeholder body `<h1>scenario-01-network OK</h1>`. The client source port (55295) was within the newly allowed ephemeral range 1024–65535, confirming the fix targeted the exact packet flow being dropped.

**Prevention**

- `checkov` rule for NACLs requiring ephemeral port return traffic would have flagged this at PR time.
- Default to SG-only for subnet ACLs unless there's a compliance reason for a custom NACL. SGs are stateful and forgive this entire class of bug.
- If a custom NACL is required, write it as a matched pair: every inbound `allow` for a service port needs a corresponding outbound `allow` for ephemeral source ports, and vice versa.
- A post-apply smoke test (`curl --max-time 10` from CI or a deploy script) would have caught this within 90 seconds of apply, before the change propagated to anything downstream.
## Scenario 2 RCA — Lambda failed to write to S3 due to two compounded IAM defects

**Symptom**

Bug 1 surfaced loudly: `terraform apply` failed at `aws_lambda_function.heartbeat` creation with `InvalidParameterValueException: The role defined for the function cannot be assumed by Lambda`. Bug 2 surfaced silently: after fixing bug 1, apply succeeded, EventBridge fired the function every 5 minutes, but the S3 bucket remained empty. No alarm, no terminal error. The control plane reported "function active, last invoked N minutes ago," but the data plane failed every invocation.

**Diagnosis path**

1. **Bug 1 — trust policy** — `terraform apply` error message named the resource and the failure mode. Confirmed with `aws iam get-role --role-name lab-heartbeat-lambda-role --query 'Role.AssumeRolePolicyDocument'`. Trust policy listed `Service: ec2.amazonaws.com`; Lambda's STS call to assume the role was rejected because Lambda's signing principal (`lambda.amazonaws.com`) wasn't trusted. Fixed and re-applied.

2. **Bug 2 — identity policy** — after fix #1, `terraform apply` succeeded but `aws s3 ls s3://<bucket>/ --recursive` returned empty. Invoked directly with `aws lambda invoke --invocation-type RequestResponse`. The invoke command's stdout returned `StatusCode: 200, FunctionError: "Unhandled"` — i.e. Lambda *ran* but the handler threw. The response payload contained the actual exception: `AccessDenied... s3:PutObject on resource: "arn:aws:s3:::<bucket>/heartbeat/...json" because no identity-based policy allows the s3:PutObject action`. Confirmed live policy via `aws iam get-role-policy`: the policy's `Resource` field was the bucket ARN (`arn:aws:s3:::<bucket>`) but `s3:PutObject` requires an object-level ARN (`arn:aws:s3:::<bucket>/*`). The IAM evaluator found no statement matching the resource shape and fell through to implicit deny.

**Root cause**

Two compounded defects in the IAM configuration. (a) Trust policy named the wrong service principal — `ec2.amazonaws.com` instead of `lambda.amazonaws.com` — so the Lambda service couldn't assume the execution role. (b) Identity policy granted `s3:PutObject` against the bucket-level ARN, but S3 IAM treats bucket and object actions as distinct resource namespaces; object-level actions require `<bucket-arn>/*`. Bug (a) failed loudly at create time; bug (b) failed silently at every runtime invocation.

**Fix**

Two one-line changes to `main.tf`. See `scenario-02-iam/main.tf` vs `scenario-02-iam/main.tf.broken` for the exact diff.

```hcl
# Trust policy
- identifiers = ["ec2.amazonaws.com"]
+ identifiers = ["lambda.amazonaws.com"]

# Identity policy
- resources = [aws_s3_bucket.heartbeat.arn]
+ resources = ["${aws_s3_bucket.heartbeat.arn}/*"]
```

**Validation**

`aws lambda invoke` returned `StatusCode: 200` with no `FunctionError` field, and a response payload of `{"status": "ok", "key": "heartbeat/...json"}`. `aws s3 ls` showed objects landing in the bucket. After a 60-second wait, a second object appeared with a timestamp not corresponding to any manual invoke — confirming EventBridge was driving the schedule end-to-end and not just my manual invocations.

**Prevention**

- **Lint trust policies against the consuming service.** A `checkov` or custom OPA rule that asserts "if `aws_iam_role` is referenced by `aws_lambda_function.role`, the trust policy must trust `lambda.amazonaws.com`" would have caught bug 1 statically.
- **S3 object-action policies must use `<bucket-arn>/*`.** This is a known IAM gotcha; checkov has `CKV_AWS_*` rules for S3 IAM patterns. Even a `grep` in CI looking for `s3:.*Object` actions paired with bare-bucket ARN resources would catch it.
- **End-to-end smoke test in CI.** A post-apply test that does `aws lambda invoke` and `aws s3 ls` against the bucket would have caught bug 2 within seconds of apply, instead of letting it accumulate as silent CloudWatch errors that nobody is paged on.
- **CloudWatch alarm on Lambda `Errors` metric.** A `Errors > 0` alarm at the function level would surface any silently-failing handler within one evaluation period, even when EventBridge happily keeps firing.
- **Bonus: `Resource: "*"` is sometimes the right answer for write-heavy logs/metrics statements, but for the data path always be specific. The `WriteHeartbeat` policy should be scoped to `<bucket-arn>/heartbeat/*` not the whole bucket, to limit blast radius if the function were ever compromised.**
## Scenario 3 RCA — Terraform state drift, three patterns, three reconciliation strategies

**Symptom**

Following the clean baseline `terraform apply`, three out-of-band changes were made via AWS API (simulating real-world Console activity, compliance automation, and clickops): (1) S3 bucket versioning suspended; (2) two unexpected tags added to a DynamoDB table; (3) a new DynamoDB table created entirely outside Terraform. A subsequent `terraform plan` reported `2 to change, 0 to destroy` and was *silent* about the third drift entirely.

**Diagnosis path**

1. **`terraform plan`** detected drifts 1 and 2 by refreshing state from AWS and comparing against `main.tf`. Versioning showed `Suspended -> Enabled` (state wants Enabled, reality is Suspended). Tags showed `CostCenter` and `ManagedBy` with `-> null` arrows, meaning `apply` would *delete* them.
2. **`terraform plan` did not detect drift 3.** This is the critical lesson: `plan` only refreshes resources already in state. Out-of-band resource creation is invisible to it. Detection required cross-referencing `aws dynamodb list-tables` (filtered by lab tag) against `terraform state list`.

**Root cause**

Three independent drifts, each with a different reconciliation strategy:

| Drift | Description | Source of truth | Strategy |
|-------|-------------|-----------------|----------|
| 1 | Versioning suspended out of band | **Code** (versioning is a recovery control; the code reflects the policy intent) | `terraform apply` — push code's truth onto AWS |
| 2 | Tags added by external system | **AWS** (compliance automation will keep re-adding them; fighting it produces drift loops) | Adopt the tags in `main.tf` + `lifecycle.ignore_changes` to prevent future drift loops |
| 3 | Unmanaged table created | **AWS** (table exists with data; destroying it would be destructive) | `terraform import` to bring the resource under management; write faithful HCL until `plan` reports clean |

The deeper root cause is process, not config: out-of-band changes occurred without going through PR-reviewed Terraform. Without preventive controls (SCPs, drift-detection scheduled jobs, "code-only changes" team policy), this divergence accumulates silently.

**Fix**

- Drift 1: `terraform apply` restored versioning to `Enabled`.
- Drift 2: Added `ManagedBy` and `CostCenter` to `aws_dynamodb_table.sessions.tags`, and added a `lifecycle.ignore_changes` block listing both `tags["KEY"]` and `tags_all["KEY"]` to suppress future drift on the externally-managed values.
- Drift 3: Wrote `aws_dynamodb_table.sessions_audit` block in `main.tf`, then `terraform import aws_dynamodb_table.sessions_audit lab-sessions-audit-<suffix>`, then verified `terraform plan` reported `No changes` — confirming the HCL faithfully represents the live resource.

**Validation**

After all three reconciliations, `terraform plan` reported `No changes. Your infrastructure matches the configuration.` `terraform state list` returned all 6 managed resources including the imported audit table. The out-of-band cross-reference query (list-tables filtered by lab tag vs. state list) now matched exactly — zero unmanaged resources with the lab tag.

**Prevention**

- **Drift detection in CI/CD**: nightly scheduled `terraform plan -detailed-exitcode` against every workspace; exit code 2 means drift; page on it. Catches drifts 1 and 2 within a day.
- **Cross-reference detection**: a custom job that compares tagged AWS resources against state and alerts on any in-AWS-not-in-state. Catches drift 3, which `plan` will never see.
- **SCP "no console writes" for IaC-managed accounts**: deny `*:Create*`, `*:Update*`, `*:Tag*`, `*:Put*` calls from non-CI principals. Stops the drifts from happening in the first place. Common pattern in landing-zone designs (this is exactly what XccelerATOr-style platforms enforce in regulated accounts).
- **`lifecycle.ignore_changes` for cross-system fields**: any attribute touched by another automated system (cost-allocation tags, security-scanner annotations, K8s controller annotations) gets ignored in Terraform from day one. Documents the boundary between systems.
- **`terraform import` discipline**: never `apply` after import until `plan` returns clean. A mismatch between imported state and HCL can cause destructive corrections.
## Scenario 3 RCA — Terraform state drift, three patterns, three reconciliation strategies

**Symptom**

Following the clean baseline `terraform apply`, three out-of-band changes were made via AWS API (simulating real-world Console activity, compliance automation, and clickops): (1) S3 bucket versioning suspended; (2) two unexpected tags added to a DynamoDB table; (3) a new DynamoDB table created entirely outside Terraform. A subsequent `terraform plan` reported `2 to change, 0 to destroy` and was *silent* about the third drift entirely.

**Diagnosis path**

1. **`terraform plan`** detected drifts 1 and 2 by refreshing state from AWS and comparing against `main.tf`. Versioning showed `Suspended -> Enabled` (state wants Enabled, reality is Suspended). Tags showed `CostCenter` and `ManagedBy` with `-> null` arrows, meaning `apply` would *delete* them.
2. **`terraform plan` did not detect drift 3.** This is the critical lesson: `plan` only refreshes resources already in state. Out-of-band resource creation is invisible to it. Detection required cross-referencing `aws dynamodb list-tables` (filtered by lab tag) against `terraform state list`.

**Root cause**

Three independent drifts, each with a different reconciliation strategy:

| Drift | Description | Source of truth | Strategy |
|-------|-------------|-----------------|----------|
| 1 | Versioning suspended out of band | **Code** (versioning is a recovery control; the code reflects the policy intent) | `terraform apply` — push code's truth onto AWS |
| 2 | Tags added by external system | **AWS** (compliance automation will keep re-adding them; fighting it produces drift loops) | Adopt the tags in `main.tf` + `lifecycle.ignore_changes` to prevent future drift loops |
| 3 | Unmanaged table created | **AWS** (table exists with data; destroying it would be destructive) | `terraform import` to bring the resource under management; write faithful HCL until `plan` reports clean |

The deeper root cause is process, not config: out-of-band changes occurred without going through PR-reviewed Terraform. Without preventive controls (SCPs, drift-detection scheduled jobs, "code-only changes" team policy), this divergence accumulates silently.

**Fix**

- Drift 1: `terraform apply` restored versioning to `Enabled`.
- Drift 2: Added `ManagedBy` and `CostCenter` to `aws_dynamodb_table.sessions.tags`, and added a `lifecycle.ignore_changes` block listing both `tags["KEY"]` and `tags_all["KEY"]` to suppress future drift on the externally-managed values.
- Drift 3: Wrote `aws_dynamodb_table.sessions_audit` block in `main.tf`, then `terraform import aws_dynamodb_table.sessions_audit lab-sessions-audit-<suffix>`, then verified `terraform plan` reported `No changes` — confirming the HCL faithfully represents the live resource.

**Validation**

After all three reconciliations, `terraform plan` reported `No changes. Your infrastructure matches the configuration.` `terraform state list` returned all 6 managed resources including the imported audit table. The out-of-band cross-reference query (list-tables filtered by lab tag vs. state list) now matched exactly — zero unmanaged resources with the lab tag.

**Prevention**

- **Drift detection in CI/CD**: nightly scheduled `terraform plan -detailed-exitcode` against every workspace; exit code 2 means drift; page on it. Catches drifts 1 and 2 within a day.
- **Cross-reference detection**: a custom job that compares tagged AWS resources against state and alerts on any in-AWS-not-in-state. Catches drift 3, which `plan` will never see.
- **SCP "no console writes" for IaC-managed accounts**: deny `*:Create*`, `*:Update*`, `*:Tag*`, `*:Put*` calls from non-CI principals. Stops the drifts from happening in the first place. Common pattern in landing-zone designs (this is exactly what XccelerATOr-style platforms enforce in regulated accounts).
- **`lifecycle.ignore_changes` for cross-system fields**: any attribute touched by another automated system (cost-allocation tags, security-scanner annotations, K8s controller annotations) gets ignored in Terraform from day one. Documents the boundary between systems.
- **`terraform import` discipline**: never `apply` after import until `plan` returns clean. A mismatch between imported state and HCL can cause destructive corrections.

See `scenario-03-state/introduce-drift.sh` for a reproducible drift script.
