#!/usr/bin/env python3
"""
Provision the AWS destination for off-host log export (scaffold log-export role).

This script is intended to run on your local machine, not on the VPS.
It creates or updates:
  - one dedicated S3 bucket with Object Lock (WORM) and versioning enabled
  - a default Object Lock retention period (12 months by default) so uploaded
    log archives cannot be modified or deleted until they age out — even by
    the uploading credentials, and (in governance mode) only by admins with
    s3:BypassGovernanceRetention before then
  - lifecycle rules that expire objects shortly AFTER their lock expires, so
    evidence is kept exactly as long as required without unbounded cost
  - one dedicated IAM user whose inline policy allows s3:PutObject on the
    logs/ prefix and NOTHING else — no read, no delete, no list, no lifecycle
  - one access key for that user, if it has none

The write-only user + Object Lock is what turns "off-host" into
"tamper-evident, delete-resistant" (ISM-1988/1815): a compromised VPS can stop
future exports (visible, because exports are daily) but cannot rewrite history.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"
YELLOW = "\033[33m"


def ok(message: str) -> None:
    print(f"  {GREEN}✓{RESET} {message}")


def skip(message: str) -> None:
    print(f"  {YELLOW}-{RESET} {message}")


def warn(message: str) -> None:
    print(f"  {YELLOW}!{RESET} {message}")


def section(title: str) -> None:
    print(f"\n{BOLD}{title}{RESET}")
    print("-" * len(title))


def logs_policy(bucket: str) -> dict:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "LogArchiveWriteOnly",
                "Effect": "Allow",
                "Action": ["s3:PutObject"],
                "Resource": f"arn:aws:s3:::{bucket}/logs/*",
            }
        ],
    }


def create_bucket(s3, bucket: str, region: str, retention_days: int, mode: str) -> None:
    section("S3 bucket (Object Lock)")
    try:
        kwargs = {"Bucket": bucket, "ObjectLockEnabledForBucket": True}
        if region != "us-east-1":
            kwargs["CreateBucketConfiguration"] = {"LocationConstraint": region}
        s3.create_bucket(**kwargs)
        ok(f"Created bucket with Object Lock: {bucket}")
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
            skip(f"Bucket already exists: {bucket} (will apply/verify Object Lock config)")
            # Object Lock on an existing bucket requires versioning first.
            s3.put_bucket_versioning(
                Bucket=bucket, VersioningConfiguration={"Status": "Enabled"}
            )
            # Object Lock can ONLY be enabled at bucket creation. If this
            # pre-existing bucket was made without it, the put_object_lock_
            # configuration below fails with a cryptic InvalidBucketState —
            # detect it here and fail with an actionable message instead.
            try:
                s3.get_object_lock_configuration(Bucket=bucket)
            except ClientError as lock_exc:
                if lock_exc.response["Error"]["Code"] == "ObjectLockConfigurationNotFoundError":
                    sys.exit(
                        f"Bucket {bucket} already exists WITHOUT Object Lock. Object Lock "
                        "cannot be added to an existing bucket — choose a new --bucket name "
                        "(a dedicated *-logs bucket is recommended) or delete and recreate it."
                    )
                raise
        else:
            raise

    s3.put_object_lock_configuration(
        Bucket=bucket,
        ObjectLockConfiguration={
            "ObjectLockEnabled": "Enabled",
            "Rule": {"DefaultRetention": {"Mode": mode, "Days": retention_days}},
        },
    )
    ok(f"Default Object Lock retention: {mode} {retention_days} days")

    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    ok("Enabled block public access")

    s3.put_bucket_encryption(
        Bucket=bucket,
        ServerSideEncryptionConfiguration={
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
                    "BucketKeyEnabled": True,
                }
            ]
        },
    )
    ok("Enabled default SSE-S3 encryption")

    # Expire objects a month after their lock lapses: retention is exact,
    # storage cost is bounded. Noncurrent versions (e.g. the re-uploaded
    # hash-chain.log) age out on the same clock.
    expire_days = retention_days + 30
    s3.put_bucket_lifecycle_configuration(
        Bucket=bucket,
        LifecycleConfiguration={
            "Rules": [
                {
                    "ID": "expire-after-lock",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "logs/"},
                    "Expiration": {"Days": expire_days},
                    "NoncurrentVersionExpiration": {"NoncurrentDays": expire_days},
                },
                {
                    "ID": "expire-incomplete-multipart",
                    "Status": "Enabled",
                    "Filter": {"Prefix": ""},
                    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7},
                },
            ]
        },
    )
    ok(f"Lifecycle: expire archives {expire_days} days after upload (lock + 30)")


def create_iam_user(iam, username: str, policy_name: str, policy_doc: dict):
    section("IAM user (write-only)")
    created = False

    try:
        iam.create_user(UserName=username)
        ok(f"Created IAM user: {username}")
        created = True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "EntityAlreadyExists":
            skip(f"IAM user already exists: {username}")
        else:
            raise

    iam.put_user_policy(
        UserName=username,
        PolicyName=policy_name,
        PolicyDocument=json.dumps(policy_doc),
    )
    ok(f"Applied inline policy: {policy_name} (s3:PutObject on logs/ only)")

    if not created:
        keys = iam.list_access_keys(UserName=username)["AccessKeyMetadata"]
        if keys:
            warn(
                f"User already has {len(keys)} access key(s); skipping key creation. "
                "Delete old keys in AWS first if you want a replacement."
            )
            return None

    access_key = iam.create_access_key(UserName=username)["AccessKey"]
    ok(f"Created access key: {access_key['AccessKeyId']}")
    return access_key["AccessKeyId"], access_key["SecretAccessKey"]


def update_hosts_file(path: Path, updates: dict) -> None:
    """Replace/uncomment matching key= lines in an INI inventory, else insert the
    keys under [servers:vars] (they are group vars). Modelled on
    aws-backup-setup.py:update_env_file but INI-section aware."""
    lines = path.read_text().splitlines() if path.exists() else []
    remaining = dict(updates)
    result: list[str] = []

    for line in lines:
        replaced = False
        for key, value in list(remaining.items()):
            # Match an active "key=" or a commented "# key=" example line.
            if re.match(rf"^\s*#?\s*{re.escape(key)}=", line):
                result.append(f"{key}={value}")
                remaining.pop(key)
                replaced = True
                break
        if not replaced:
            result.append(line)

    if remaining:
        out: list[str] = []
        inserted = False
        for line in result:
            out.append(line)
            if not inserted and line.strip() == "[servers:vars]":
                for key, value in remaining.items():
                    out.append(f"{key}={value}")
                inserted = True
        if not inserted:
            if out and out[-1] != "":
                out.append("")
            out.append("[servers:vars]")
            for key, value in remaining.items():
                out.append(f"{key}={value}")
        result = out

    path.write_text("\n".join(result) + "\n")


def write_hosts(hosts_path: str, bucket: str, region: str, creds) -> None:
    section(f"Write host vars into {hosts_path}")
    if creds is None:
        warn(
            "IAM user already has an access key; its secret is unrecoverable from AWS, "
            f"so {hosts_path} was NOT written. Delete the old key in AWS and re-run to "
            "mint + write a fresh one, or paste the saved secret by hand."
        )
        return
    access_key_id, secret_access_key = creds
    update_hosts_file(
        Path(hosts_path),
        {
            "log_export_s3_uri": f"s3://{bucket}/logs",
            "log_export_aws_access_key_id": access_key_id,
            "log_export_aws_secret_access_key": secret_access_key,
            "log_export_aws_region": region,
        },
    )
    ok(f"Wrote log_export_* into {hosts_path}")


def print_inventory_snippet(bucket: str, region: str, creds) -> None:
    section("Copy into ansible/hosts (host vars — the inventory is gitignored)")
    print(f"  log_export_s3_uri=s3://{bucket}/logs")
    if creds is None:
        print("  log_export_aws_access_key_id=<existing key on IAM user>")
        print("  log_export_aws_secret_access_key=<existing secret on IAM user>")
    else:
        access_key_id, secret_access_key = creds
        print(f"  log_export_aws_access_key_id={access_key_id}")
        print(f"  log_export_aws_secret_access_key={secret_access_key}")
    print(f"  log_export_aws_region={region}")

    section("Then")
    print("  1. Re-run the site play: ansible-playbook -i ansible/hosts scaffold/ansible/site-quick.yml")
    print("  2. First export: ssh <host> 'sudo systemctl start log-export.service'")
    print("  3. Verify: ssh <host> 'sudo tail /var/lib/log-export/hash-chain.log'")

    section("Important notes")
    print("  - The uploader CANNOT read, list or delete — verify uploads from your")
    print("    admin credentials (aws s3 ls), not from the VPS.")
    print("  - Governance mode: admins with s3:BypassGovernanceRetention can undo a")
    print("    mistake; use --compliance for a lock even account admins cannot lift")
    print("    (test costs/sizing first — compliance-mode objects are immovable).")
    print("  - Keep this bucket separate from the backup bucket: different threat")
    print("    model, different credentials, different retention.")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Provision the Object-Locked S3 bucket + write-only IAM user for off-host log export."
    )
    parser.add_argument("--bucket", required=True, help="S3 bucket for log archives")
    parser.add_argument("--iam-user", required=True, help="Dedicated write-only IAM username")
    parser.add_argument("--region", default="ap-southeast-2", help="AWS region")
    parser.add_argument("--profile", default=None, help="AWS profile from ~/.aws/config")
    parser.add_argument(
        "--retention-days",
        type=int,
        default=366,
        help="Default Object Lock retention in days (ISM-1988 needs >= 12 months searchable)",
    )
    parser.add_argument(
        "--compliance",
        action="store_true",
        help="Use COMPLIANCE mode (immutable for everyone, incl. account admins) instead of GOVERNANCE",
    )
    parser.add_argument(
        "--policy-name",
        default=None,
        help="Inline IAM policy name (defaults to <iam-user>-policy)",
    )
    parser.add_argument(
        "--write-hosts",
        action="store_true",
        help="Write log_export_* directly into the inventory (default: print for manual paste)",
    )
    parser.add_argument(
        "--hosts-path",
        default="ansible/hosts",
        help="Inventory file to update with --write-hosts (default: ansible/hosts)",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    policy_name = args.policy_name or f"{args.iam_user}-policy"
    mode = "COMPLIANCE" if args.compliance else "GOVERNANCE"

    try:
        global boto3, ClientError
        import boto3
        from botocore.exceptions import ClientError
    except ImportError:
        sys.exit("boto3 is not installed. Run: pip install boto3")

    print(f"\n{BOLD}AWS log-export setup{RESET}")
    print(f"  Bucket:    {args.bucket}")
    print(f"  IAM user:  {args.iam_user}")
    print(f"  Region:    {args.region}")
    print(f"  Retention: {mode} {args.retention_days} days")
    if args.profile:
        print(f"  Profile:   {args.profile}")

    try:
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        sts = session.client("sts")
        account_id = sts.get_caller_identity()["Account"]
        print(f"  Account:   {account_id}")
        s3 = session.client("s3")
        iam = session.client("iam")
    except ClientError as exc:
        sys.exit(f"AWS authentication failed: {exc}")

    try:
        create_bucket(s3, args.bucket, args.region, args.retention_days, mode)
        creds = create_iam_user(iam, args.iam_user, policy_name, logs_policy(args.bucket))
    except ClientError as exc:
        sys.exit(f"AWS error: {exc}")

    if args.write_hosts:
        write_hosts(args.hosts_path, args.bucket, args.region, creds)
    else:
        print_inventory_snippet(args.bucket, args.region, creds)

    print(f"\n{GREEN}Done.{RESET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
