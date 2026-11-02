#!/usr/bin/env python3
"""Provision AWS SES for a domain, end to end and idempotently:

  * domain identity + Easy DKIM + custom MAIL FROM (deliverability)
  * a scoped IAM user with SES SMTP credentials (send only as *@<domain>)
  * a bounce/complaint -> SNS -> Lambda -> ntfy pipeline (push alerts)
  * a configuration set wired as the identity default so all sends emit events

It prints the DNS records to add and the SMTP credentials / .env values. Safe to
re-run: existing resources are detected and reused (a new SMTP access key is only
minted with --rotate-smtp-key).

Mirrors scripts/aws-backup-setup.py. Requires boto3 and AWS creds:
    pip install boto3
    python3 scripts/aws-ses-setup.py \
      --profile my-admin --region ap-southeast-2 \
      --domain example.org \
      --ntfy-url https://ntfy.example.org/alerts \
      --ntfy-token tk_xxx

Production access for sending to arbitrary recipients is account+region level and
is requested once in the SES console (or reused from another domain in the same
region). This script does not request it.
"""
import argparse
import base64
import hashlib
import hmac
import io
import json
import os
import sys
import time
import zipfile

try:
    import boto3
    from botocore.exceptions import ClientError
except ImportError:
    sys.exit("boto3 required: pip install boto3")

LAMBDA_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ses-bounce-lambda")


def smtp_password(secret_access_key: str, region: str) -> str:
    """Derive an SES SMTP password from an IAM secret access key (SigV4)."""
    def sign(key, msg):
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    sig = sign(("AWS4" + secret_access_key).encode("utf-8"), "11111111")
    sig = sign(sig, region)
    sig = sign(sig, "ses")
    sig = sign(sig, "aws4_request")
    sig = sign(sig, "SendRawEmail")
    return base64.b64encode(bytes([0x04]) + sig).decode("utf-8")


def zip_lambda() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(LAMBDA_SRC, "lambda_function.py"), "lambda_function.py")
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile")
    ap.add_argument("--region", default="ap-southeast-2")
    ap.add_argument("--domain", required=True)
    ap.add_argument("--mail-from-subdomain", default="mail")
    ap.add_argument("--ntfy-url", required=True, help="ntfy topic URL the Lambda posts to")
    ap.add_argument("--ntfy-token", required=True, help="ntfy write token for that topic")
    ap.add_argument("--smtp-user", default=None, help="IAM user name (default <domain>-ses-smtp)")
    ap.add_argument("--sns-topic", default=None, help="SNS topic name (default <slug>-ses-events)")
    ap.add_argument("--lambda-name", default=None, help="Lambda name (default <slug>-ses-ntfy)")
    ap.add_argument("--config-set", default=None, help="config set (default <slug>-events)")
    ap.add_argument("--rotate-smtp-key", action="store_true", help="mint a new SMTP access key")
    args = ap.parse_args()

    slug = args.domain.replace(".", "-")
    smtp_user = args.smtp_user or f"{slug}-ses-smtp"
    topic_name = args.sns_topic or f"{slug}-ses-events"
    fn_name = args.lambda_name or f"{slug}-ses-ntfy"
    cs_name = args.config_set or f"{slug}-events"
    mail_from = f"{args.mail_from_subdomain}.{args.domain}"

    s = boto3.Session(profile_name=args.profile, region_name=args.region)
    acct = s.client("sts").get_caller_identity()["Account"]
    ses, iam, sns, lam, logs = (s.client(x) for x in ("sesv2", "iam", "sns", "lambda", "logs"))
    print(f"account={acct} region={args.region} domain={args.domain}\n")

    # 1) identity + Easy DKIM
    try:
        ses.create_email_identity(EmailIdentity=args.domain)
        print("identity: created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "AlreadyExistsException":
            raise
        print("identity: exists")
    ident = ses.get_email_identity(EmailIdentity=args.domain)
    tokens = ident.get("DkimAttributes", {}).get("Tokens", [])

    # 2) custom MAIL FROM
    ses.put_email_identity_mail_from_attributes(
        EmailIdentity=args.domain, MailFromDomain=mail_from, BehaviorOnMxFailure="USE_DEFAULT_VALUE")

    # 3) scoped SMTP IAM user
    try:
        iam.create_user(UserName=smtp_user, Tags=[{"Key": "purpose", "Value": "ses-smtp"}])
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists":
            raise
    iam.put_user_policy(UserName=smtp_user, PolicyName="ses-send", PolicyDocument=json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": ["ses:SendRawEmail", "ses:SendEmail"],
                       "Resource": "*", "Condition": {"StringLike": {"ses:FromAddress": f"*@{args.domain}"}}}]}))
    smtp_creds = None
    keys = iam.list_access_keys(UserName=smtp_user)["AccessKeyMetadata"]
    if args.rotate_smtp_key or not keys:
        ak = iam.create_access_key(UserName=smtp_user)["AccessKey"]
        smtp_creds = (ak["AccessKeyId"], smtp_password(ak["SecretAccessKey"], args.region))
    # 4) SNS topic + policy allowing SES to publish
    topic = sns.create_topic(Name=topic_name)["TopicArn"]
    sns.set_topic_attributes(TopicArn=topic, AttributeName="Policy", AttributeValue=json.dumps({
        "Version": "2012-10-17", "Statement": [
            {"Sid": "owner", "Effect": "Allow", "Principal": {"AWS": "*"},
             "Action": ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes",
                        "SNS:ListSubscriptionsByTopic"], "Resource": topic,
             "Condition": {"StringEquals": {"AWS:SourceOwner": acct}}},
            {"Sid": "sespub", "Effect": "Allow", "Principal": {"Service": "ses.amazonaws.com"},
             "Action": "sns:Publish", "Resource": topic,
             "Condition": {"StringEquals": {"AWS:SourceAccount": acct}}}]}))

    # 5) Lambda role + function + log retention
    role_name = f"{fn_name}-role"
    try:
        role_arn = iam.create_role(RoleName=role_name, AssumeRolePolicyDocument=json.dumps({
            "Version": "2012-10-17", "Statement": [{"Effect": "Allow",
                "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]}))["Role"]["Arn"]
        iam.attach_role_policy(RoleName=role_name,
                               PolicyArn="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole")
        time.sleep(12)  # role propagation
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists":
            raise
        role_arn = iam.get_role(RoleName=role_name)["Role"]["Arn"]
    env = {"Variables": {"NTFY_URL": args.ntfy_url, "NTFY_TOKEN": args.ntfy_token}}
    code = zip_lambda()
    try:
        fn_arn = lam.create_function(FunctionName=fn_name, Runtime="python3.13", Architectures=["arm64"],
            Handler="lambda_function.lambda_handler", Role=role_arn, Timeout=10, MemorySize=128,
            Code={"ZipFile": code}, Environment=env)["FunctionArn"]
        print("lambda: created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceConflictException":
            raise
        lam.update_function_code(FunctionName=fn_name, ZipFile=code)
        lam.update_function_configuration(FunctionName=fn_name, Environment=env)
        fn_arn = lam.get_function(FunctionName=fn_name)["Configuration"]["FunctionArn"]
        print("lambda: updated")
    try:
        logs.create_log_group(logGroupName=f"/aws/lambda/{fn_name}")
    except ClientError:
        pass
    logs.put_retention_policy(logGroupName=f"/aws/lambda/{fn_name}", retentionInDays=14)

    # 6) SNS -> Lambda
    try:
        lam.add_permission(FunctionName=fn_name, StatementId="sns-invoke",
                           Action="lambda:InvokeFunction", Principal="sns.amazonaws.com", SourceArn=topic)
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceConflictException":
            raise
    subs = sns.list_subscriptions_by_topic(TopicArn=topic)["Subscriptions"]
    if not any(x["Endpoint"] == fn_arn for x in subs):
        sns.subscribe(TopicArn=topic, Protocol="lambda", Endpoint=fn_arn)

    # 7) configuration set -> SNS, default on identity
    try:
        ses.create_configuration_set(ConfigurationSetName=cs_name)
    except ClientError as e:
        if e.response["Error"]["Code"] != "AlreadyExistsException":
            raise
    try:
        ses.create_configuration_set_event_destination(ConfigurationSetName=cs_name, EventDestinationName="to-sns",
            EventDestination={"Enabled": True, "MatchingEventTypes": ["BOUNCE", "COMPLAINT"],
                              "SnsDestination": {"TopicArn": topic}})
    except ClientError as e:
        if e.response["Error"]["Code"] != "AlreadyExistsException":
            raise
    ses.put_email_identity_configuration_set_attributes(EmailIdentity=args.domain, ConfigurationSetName=cs_name)

    # ---- report ----
    print("\n=== DNS records to add ===")
    for t in tokens:
        print(f"  CNAME  {t}._domainkey.{args.domain}  ->  {t}.dkim.amazonses.com")
    print(f"  MX     {mail_from}  ->  10 feedback-smtp.{args.region}.amazonses.com")
    print(f"  TXT    {mail_from}  ->  \"v=spf1 include:amazonses.com ~all\"")
    print(f"  TXT    _dmarc.{args.domain}  ->  \"v=DMARC1; p=none; rua=mailto:dmarc@{args.domain}\"")
    print("\n=== apps/auth/.env (email) ===")
    print("EMAIL_BACKEND=smtp")
    print(f"EMAIL_FROM=Login <auth@{args.domain}>")
    print(f"SMTP_HOST=email-smtp.{args.region}.amazonaws.com")
    print("SMTP_PORT=587")
    if smtp_creds:
        print(f"SMTP_USERNAME={smtp_creds[0]}")
        print(f"SMTP_PASSWORD={smtp_creds[1]}")
    else:
        print("SMTP_USERNAME=<existing key; re-run with --rotate-smtp-key to mint a new one>")
    print(f"\nBounce/complaint pipeline: {cs_name} -> {topic_name} -> {fn_name} -> ntfy")
    print("Test:  send to bounce@simulator.amazonses.com / complaint@simulator.amazonses.com")


if __name__ == "__main__":
    main()
