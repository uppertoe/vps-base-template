"""SES bounce/complaint -> ntfy.

Subscribed to an SNS topic that receives SES BOUNCE and COMPLAINT events (via a
SES configuration set event destination). Posts a concise alert to ntfy.

Env:
  NTFY_URL    full topic URL, e.g. https://ntfy.example.org/alerts
  NTFY_TOKEN  bearer token with write access to that topic

Dependency-free (urllib) so it needs no build step — just zip this file.
"""
import json
import os
import urllib.request


def lambda_handler(event, context):
    url = os.environ["NTFY_URL"]
    token = os.environ["NTFY_TOKEN"]
    for rec in event.get("Records", []):
        try:
            m = json.loads(rec["Sns"]["Message"])
        except Exception:
            continue
        t = m.get("eventType") or m.get("notificationType") or "Event"
        mail = m.get("mail", {})
        src = mail.get("source", "?")
        if t == "Bounce":
            b = m.get("bounce", {})
            rc = ", ".join(r.get("emailAddress", "?") for r in b.get("bouncedRecipients", []))
            title = "SES Bounce: %s/%s" % (b.get("bounceType"), b.get("bounceSubType"))
            body = "From %s\nTo: %s" % (src, rc)
            prio, tags = "high", "warning,email"
        elif t == "Complaint":
            c = m.get("complaint", {})
            rc = ", ".join(r.get("emailAddress", "?") for r in c.get("complainedRecipients", []))
            title = "SES Complaint"
            body = "From %s\nComplaint: %s" % (src, rc)
            prio, tags = "urgent", "rotating_light,email"
        else:
            title = "SES %s" % t
            body = json.dumps(m)[:600]
            prio, tags = "default", "email"
        req = urllib.request.Request(
            url,
            data=body.encode(),
            headers={
                "Authorization": "Bearer %s" % token,
                "Title": title,
                "Priority": prio,
                "Tags": tags,
            },
        )
        try:
            urllib.request.urlopen(req, timeout=8)
        except Exception as e:  # noqa: BLE001 - never fail the SNS delivery
            print("ntfy post failed:", e)
    return {"ok": True}
