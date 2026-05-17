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

## Scenario 1 RCA — TBD
## Scenario 2 RCA — TBD
## Scenario 3 RCA — TBD
