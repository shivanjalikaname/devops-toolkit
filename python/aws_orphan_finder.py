#!/usr/bin/env python3
"""Find AWS resources that are still billing but attached to nothing.

Covers the usual leftovers from deleted instances and abandoned experiments:

  * EBS volumes in the "available" state (not attached to any instance)
  * Elastic IPs with no association (charged hourly since the 2024 IPv4 pricing)
  * Snapshots you own whose source volume is gone and that no AMI you own uses

Read-only: it never deletes anything. With --emit-cleanup it prints the AWS CLI
commands you would run, so the destructive step stays a deliberate human one.

Resources tagged with the keep tag (default "keep", any value except "false")
are reported as skipped instead of orphaned.

Usage:
    aws_orphan_finder.py [--regions R1,R2 | --all-regions] [--profile NAME]
                         [--min-age-days N] [--snapshot-age-days N]
                         [--no-snapshots] [--keep-tag KEY]
                         [--json] [--emit-cleanup]

Examples:
    aws_orphan_finder.py --regions eu-west-1,us-east-1
    aws_orphan_finder.py --all-regions --profile audit --json > orphans.json
    aws_orphan_finder.py --regions us-east-1 --emit-cleanup > cleanup.sh

Required IAM (read-only): ec2:DescribeRegions, ec2:DescribeVolumes,
ec2:DescribeAddresses, ec2:DescribeSnapshots, ec2:DescribeImages.

Exit codes:
    0  nothing orphaned
    1  orphaned resources found
    2  usage error, missing boto3, or an AWS API error
"""

import argparse
import json
import shlex
import sys
from datetime import datetime, timedelta, timezone

# Rough us-east-1 list prices, only for an order-of-magnitude monthly figure.
GB_MONTH = {"gp2": 0.10, "gp3": 0.08, "io1": 0.125, "io2": 0.125,
            "st1": 0.045, "sc1": 0.015, "standard": 0.05}
SNAPSHOT_GB_MONTH = 0.05
EIP_MONTH = 0.005 * 730


def tag_map(tags):
    return {t["Key"]: t["Value"] for t in tags or ()}


def is_kept(tags, keep_tag):
    value = tag_map(tags).get(keep_tag)
    return value is not None and value.strip().lower() != "false"


def paginate(client, op, key, **kwargs):
    for page in client.get_paginator(op).paginate(**kwargs):
        yield from page.get(key, ())


def find_volumes(ec2, region, cutoff, keep_tag):
    for vol in paginate(ec2, "describe_volumes", "Volumes",
                        Filters=[{"Name": "status", "Values": ["available"]}]):
        # CreateTime is the best signal available: EC2 does not expose detach time.
        if vol["CreateTime"] > cutoff:
            continue
        yield {
            "type": "ebs-volume",
            "region": region,
            "id": vol["VolumeId"],
            "name": tag_map(vol.get("Tags")).get("Name", ""),
            "detail": f'{vol["Size"]} GiB {vol["VolumeType"]}',
            "created": vol["CreateTime"].isoformat(),
            "monthly_usd": round(vol["Size"] * GB_MONTH.get(vol["VolumeType"], 0.10), 2),
            "kept": is_kept(vol.get("Tags"), keep_tag),
            "cleanup": ["aws", "ec2", "delete-volume", "--region", region,
                        "--volume-id", vol["VolumeId"]],
        }


def find_addresses(ec2, region, keep_tag):
    # describe_addresses is not paginated.
    for addr in ec2.describe_addresses().get("Addresses", ()):
        if addr.get("AssociationId") or addr.get("NetworkInterfaceId"):
            continue
        alloc = addr.get("AllocationId")
        cleanup = (["aws", "ec2", "release-address", "--region", region, "--allocation-id", alloc]
                   if alloc else
                   ["aws", "ec2", "release-address", "--region", region, "--public-ip", addr["PublicIp"]])
        yield {
            "type": "elastic-ip",
            "region": region,
            "id": alloc or addr["PublicIp"],
            "name": tag_map(addr.get("Tags")).get("Name", ""),
            "detail": addr["PublicIp"],
            "created": "",
            "monthly_usd": round(EIP_MONTH, 2),
            "kept": is_kept(addr.get("Tags"), keep_tag),
            "cleanup": cleanup,
        }


def find_snapshots(ec2, region, cutoff, keep_tag):
    live_volumes = {v["VolumeId"] for v in paginate(ec2, "describe_volumes", "Volumes")}
    ami_snapshots = set()
    for image in ec2.describe_images(Owners=["self"]).get("Images", ()):
        for bdm in image.get("BlockDeviceMappings", ()):
            snap = bdm.get("Ebs", {}).get("SnapshotId")
            if snap:
                ami_snapshots.add(snap)

    for snap in paginate(ec2, "describe_snapshots", "Snapshots", OwnerIds=["self"]):
        if snap["StartTime"] > cutoff:
            continue
        if snap["SnapshotId"] in ami_snapshots or snap.get("VolumeId") in live_volumes:
            continue
        yield {
            "type": "ebs-snapshot",
            "region": region,
            "id": snap["SnapshotId"],
            "name": tag_map(snap.get("Tags")).get("Name", ""),
            "detail": f'{snap["VolumeSize"]} GiB from {snap.get("VolumeId") or "?"}',
            "created": snap["StartTime"].isoformat(),
            # Snapshots are incremental, so this is an upper bound.
            "monthly_usd": round(snap["VolumeSize"] * SNAPSHOT_GB_MONTH, 2),
            "kept": is_kept(snap.get("Tags"), keep_tag),
            "cleanup": ["aws", "ec2", "delete-snapshot", "--region", region,
                        "--snapshot-id", snap["SnapshotId"]],
        }


def scan_region(session, region, args, now):
    ec2 = session.client("ec2", region_name=region)
    findings = list(find_volumes(ec2, region, now - timedelta(days=args.min_age_days), args.keep_tag))
    findings += find_addresses(ec2, region, args.keep_tag)
    if not args.no_snapshots:
        findings += find_snapshots(ec2, region, now - timedelta(days=args.snapshot_age_days),
                                   args.keep_tag)
    return findings


def resolve_regions(session, args):
    if args.all_regions:
        ec2 = session.client("ec2", region_name=session.region_name or "us-east-1")
        return sorted(r["RegionName"] for r in ec2.describe_regions()["Regions"])
    if args.regions:
        return [r.strip() for r in args.regions.split(",") if r.strip()]
    if session.region_name:
        return [session.region_name]
    raise SystemExit("error: no region configured; pass --regions or --all-regions")


def print_table(findings):
    if not findings:
        print("No orphaned resources found.")
        return
    rows = [("TYPE", "REGION", "ID", "NAME", "DETAIL", "USD/MO", "")]
    for f in findings:
        rows.append((f["type"], f["region"], f["id"], f["name"][:30], f["detail"],
                     f'{f["monthly_usd"]:.2f}', "kept" if f["kept"] else ""))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for row in rows:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
    orphaned = [f for f in findings if not f["kept"]]
    total = sum(f["monthly_usd"] for f in orphaned)
    print(f"\n{len(orphaned)} orphaned, {len(findings) - len(orphaned)} kept by tag, "
          f"~${total:.2f}/month (list-price estimate)")


def print_cleanup(findings):
    print("#!/usr/bin/env bash")
    print("# Generated by aws_orphan_finder.py. Review every line before running.")
    print("set -euo pipefail")
    for f in findings:
        if not f["kept"]:
            print(" ".join(shlex.quote(p) for p in f["cleanup"]))


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Report unattached EBS volumes, idle Elastic IPs and orphaned snapshots.")
    where = p.add_mutually_exclusive_group()
    where.add_argument("--regions", help="comma-separated regions (default: profile region)")
    where.add_argument("--all-regions", action="store_true", help="scan every enabled region")
    p.add_argument("--profile", help="AWS named profile")
    p.add_argument("--min-age-days", type=int, default=7,
                   help="ignore volumes created more recently than this (default 7)")
    p.add_argument("--snapshot-age-days", type=int, default=30,
                   help="ignore snapshots newer than this (default 30)")
    p.add_argument("--no-snapshots", action="store_true", help="skip the snapshot scan")
    p.add_argument("--keep-tag", default="keep",
                   help='tag key that marks a resource as intentionally kept (default "keep")')
    out = p.add_mutually_exclusive_group()
    out.add_argument("--json", action="store_true", help="machine-readable output")
    out.add_argument("--emit-cleanup", action="store_true",
                     help="print AWS CLI delete/release commands instead of a report")
    args = p.parse_args(argv)
    if args.min_age_days < 0 or args.snapshot_age_days < 0:
        p.error("age thresholds must be >= 0")
    return args


def main(argv=None):
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code == 0 else 2

    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError
    except ImportError:
        print("error: boto3 is required (pip install boto3)", file=sys.stderr)
        return 2
    aws_errors = (BotoCoreError, ClientError)
    try:
        session = boto3.Session(profile_name=args.profile)
    except aws_errors as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc)
    findings, failed = [], []
    try:
        regions = resolve_regions(session, args)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    except aws_errors as exc:
        print(f"error: listing regions: {exc}", file=sys.stderr)
        return 2

    for region in regions:
        try:
            findings += scan_region(session, region, args, now)
        except aws_errors as exc:
            print(f"error: {region}: {exc}", file=sys.stderr)
            failed.append(region)

    findings.sort(key=lambda f: (f["region"], f["type"], f["id"]))
    if args.json:
        json.dump({"scanned": regions, "failed": failed, "findings": findings},
                  sys.stdout, indent=2, default=str)
        print()
    elif args.emit_cleanup:
        print_cleanup(findings)
    else:
        print_table(findings)

    if failed:
        return 2
    return 1 if any(not f["kept"] for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
