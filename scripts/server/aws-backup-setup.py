#!/usr/bin/env python3
"""
Provision AWS resources for the backup flow used by this server template.

This script is intended to run on your local machine, not on the VPS.
It creates or updates:
  - one dedicated S3 bucket for backup repositories
  - one dedicated IAM user for backup access
  - one inline IAM policy scoped to that bucket
  - one access key for the IAM user, if the user has no existing keys

Optionally, it can update backup/config.env locally with the generated AWS
credentials while preserving the rest of the file.
"""

from __future__ import annotations

import argparse
import json
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


def backup_policy(bucket: str) -> dict:
    return {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "BackupBucketObjects",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
                "Resource": f"arn:aws:s3:::{bucket}/backups/*",
            },
            {
                "Sid": "BackupBucketList",
                "Effect": "Allow",
                "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
                "Resource": f"arn:aws:s3:::{bucket}",
                "Condition": {"StringLike": {"s3:prefix": "backups/*"}},
            },
        ],
    }


def create_bucket(s3, bucket: str, region: str) -> None:
    section("S3 bucket")
    try:
        kwargs = {"Bucket": bucket}
        if region != "us-east-1":
            kwargs["CreateBucketConfiguration"] = {"LocationConstraint": region}
        s3.create_bucket(**kwargs)
        ok(f"Created bucket: {bucket}")
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
            skip(f"Bucket already exists: {bucket}")
        else:
            raise

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

    s3.put_bucket_versioning(
        Bucket=bucket,
        VersioningConfiguration={"Status": "Enabled"},
    )
    ok("Enabled bucket versioning")

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

    s3.put_bucket_lifecycle_configuration(
        Bucket=bucket,
        LifecycleConfiguration={
            "Rules": [
                {
                    "ID": "expire-incomplete-multipart",
                    "Status": "Enabled",
                    "Filter": {"Prefix": ""},
                    "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7},
                },
                {
                    "ID": "expire-old-noncurrent-versions",
                    "Status": "Enabled",
                    "Filter": {"Prefix": ""},
                    "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
                },
            ]
        },
    )
    ok("Applied lifecycle rules for multipart uploads and old noncurrent versions")


def create_iam_user(iam, username: str, policy_name: str, policy_doc: dict):
    section("IAM user")
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
    ok(f"Applied inline policy: {policy_name}")

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


def update_env_file(path: Path, updates: dict[str, str], template_path: Path) -> None:
    if path.exists():
        lines = path.read_text().splitlines()
    else:
        lines = template_path.read_text().splitlines()

    remaining = dict(updates)
    result: list[str] = []

    for line in lines:
        replaced = False
        for key, value in list(remaining.items()):
            prefix = f"{key}="
            if line.startswith(prefix):
                result.append(f"{prefix}{value}")
                remaining.pop(key)
                replaced = True
                break
        if not replaced:
            result.append(line)

    if remaining:
        if result and result[-1] != "":
            result.append("")
        for key, value in remaining.items():
            result.append(f"{key}={value}")

    path.write_text("\n".join(result) + "\n")


def print_config_snippet(bucket: str, region: str, creds) -> None:
    section("Copy into backup/config.env")
    if creds is None:
        print("  AWS_ACCESS_KEY_ID=<existing key on IAM user>")
        print("  AWS_SECRET_ACCESS_KEY=<existing secret on IAM user>")
    else:
        access_key_id, secret_access_key = creds
        print(f"  AWS_ACCESS_KEY_ID={access_key_id}")
        print(f"  AWS_SECRET_ACCESS_KEY={secret_access_key}")
    print(f"  AWS_DEFAULT_REGION={region}")

    section("Repository examples for backup/services/*.env")
    print(f"  RESTIC_REPOSITORY=s3:s3.amazonaws.com/{bucket}/backups/myapp-backup")
    print(f"  RESTIC_REPOSITORY=s3:s3.amazonaws.com/{bucket}/backups/planka-backup")
    print("  CONTAINER_NAME=<exact container name or compose service/container stem>")

    section("Important note")
    print("  This helper scopes backup IAM access to the bucket's backups/ prefix only.")
    print("  KEEP_DAILY / KEEP_WEEKLY / KEEP_MONTHLY control snapshot retention only.")
    print("  The backup run schedule is configured separately in Ansible via backup_schedule (default: hourly).")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Provision AWS bucket and IAM user for server backups."
    )
    parser.add_argument("--bucket", required=True, help="S3 bucket for Restic repositories")
    parser.add_argument("--iam-user", required=True, help="Dedicated IAM username for backups")
    parser.add_argument("--region", default="ap-southeast-2", help="AWS region")
    parser.add_argument("--profile", default=None, help="AWS profile from ~/.aws/config")
    parser.add_argument(
        "--policy-name",
        default=None,
        help="Inline IAM policy name (defaults to <iam-user>-policy)",
    )
    parser.add_argument(
        "--write-config",
        action="store_true",
        help="Write AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION into backup/config.env",
    )
    parser.add_argument(
        "--config-path",
        default="backup/config.env",
        help="Path to local backup config file to update",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    policy_name = args.policy_name or f"{args.iam_user}-policy"
    config_path = Path(args.config_path)
    config_example_path = config_path.with_name("config.env.example")

    try:
        global boto3, ClientError
        import boto3
        from botocore.exceptions import ClientError
    except ImportError:
        sys.exit("boto3 is not installed. Run: pip install boto3")

    print(f"\n{BOLD}AWS backup setup{RESET}")
    print(f"  Bucket:    {args.bucket}")
    print(f"  IAM user:  {args.iam_user}")
    print(f"  Region:    {args.region}")
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
        create_bucket(s3, args.bucket, args.region)
        creds = create_iam_user(iam, args.iam_user, policy_name, backup_policy(args.bucket))
    except ClientError as exc:
        sys.exit(f"AWS error: {exc}")

    if args.write_config:
        if creds is None:
            warn("Skipping backup/config.env update because no new secret access key was created.")
        else:
            update_env_file(
                config_path,
                {
                    "AWS_ACCESS_KEY_ID": creds[0],
                    "AWS_SECRET_ACCESS_KEY": creds[1],
                    "AWS_DEFAULT_REGION": args.region,
                },
                config_example_path,
            )
            ok(f"Updated local config file: {config_path}")

    print_config_snippet(args.bucket, args.region, creds)

    section("Manual next steps")
    print("  1. Copy or review values in backup/config.env")
    print("  2. Set RESTIC_REPOSITORY and RESTIC_PASSWORD in backup/services/*.env")
    print("  3. Run: ansible-playbook -i ansible/hosts ansible/backup.yml")

    print(f"\n{GREEN}Done.{RESET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
