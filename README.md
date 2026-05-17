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
## Scenario 2 RCA — TBD
## Scenario 3 RCA — TBD
