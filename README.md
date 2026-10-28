# DevOps Toolkit

Battle-tested automation I keep reaching for across projects: backups, cleanup jobs,
health checks, certificate monitoring, Kubernetes triage and CI pipelines.

Every tool here is:

- **Self-contained** – one file, copy it where you need it
- **Documented** – usage and examples live in the file header (`-h` / `Get-Help`)
- **Automation-friendly** – meaningful exit codes, safe defaults, dry-run modes where it matters

## Tools

| Tool | Area | What it does |
|------|------|--------------|
| [http-healthcheck.sh](bash/http-healthcheck.sh) | Bash | Check HTTP endpoints with retries and timeouts; non-zero exit for CI smoke tests and readiness gates |
| [pg-backup.sh](bash/pg-backup.sh) | Bash / PostgreSQL | Compressed `pg_dump` backups with integrity check, retention and optional S3 upload |
| [docker-cleanup.sh](bash/docker-cleanup.sh) | Bash / Docker | Reclaim disk on Docker hosts and CI runners by age, with dry run; volumes untouched unless asked |
| [log-cleanup.sh](bash/log-cleanup.sh) | Bash | Compress and expire application logs that logrotate doesn't cover; skips files still open |
| [cron-wrap.sh](bash/cron-wrap.sh) | Bash | Wrap any cron job with an overlap lock, timeout, per-job log and webhook alert on failure |
| [pod-triage.sh](kubernetes/pod-triage.sh) | Kubernetes | One-shot view of crashing, pending and flapping pods with last termination reason and previous logs |
| [ssl_expiry_check.py](python/ssl_expiry_check.py) | Python | Parallel TLS certificate expiry check with warn/crit thresholds and JSON output |
| [Get-DiskSpaceReport.ps1](powershell/Get-DiskSpaceReport.ps1) | PowerShell | Free-space report for local or remote Windows servers, pipeline-friendly objects and exit codes |
| [docker-build-push.yml](.github/workflows/docker-build-push.yml) | GitHub Actions | Reusable workflow: multi-arch build, Trivy scan, smart tagging and push to GHCR |
| [remote-state-bootstrap](terraform/remote-state-bootstrap) | Terraform / AWS | Versioned, encrypted, TLS-only S3 state bucket with optional DynamoDB locking; emits a ready-to-paste backend block |

## Quick start

```bash
git clone https://github.com/shivanjalikaname/devops-toolkit.git
cd devops-toolkit

./bash/http-healthcheck.sh https://example.com
python3 python/ssl_expiry_check.py github.com example.com --warn 21
./kubernetes/pod-triage.sh -n production -l
```

```powershell
.\powershell\Get-DiskSpaceReport.ps1 -ComputerName web01, web02 -WarningPercent 15
```

## Exit code convention

Monitoring-style tools follow the Nagios convention so they slot into cron, CI and alerting:

| Code | Meaning |
|------|---------|
| 0 | OK |
| 1 | Warning / at least one check failed |
| 2 | Critical, unreachable, or bad usage |

## Layout

```
bash/                Linux hosts and CI runners
kubernetes/          Cluster operations helpers
python/              Cross-platform automation
powershell/          Windows server automation
terraform/           Small, reusable Terraform modules
.github/workflows/   Reusable GitHub Actions workflows
```

## License

[MIT](LICENSE)
