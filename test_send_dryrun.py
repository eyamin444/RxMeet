import os, sys
import firebase_admin
from firebase_admin import credentials, messaging

cred_path = os.getenv("FIREBASE_CREDENTIAL_PATH") or r"D:\SmartGateway\firebase-service-account.json"
if not os.path.exists(cred_path):
    print("Set FIREBASE_CREDENTIAL_PATH to your service-account.json path")
    sys.exit(1)

if not firebase_admin._apps:
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)

# Paste the token exactly between the quotes
token = "PASTE_TOKEN_HERE"

message = messaging.Message(
    data={"test": "dryrun"},
    token=token
)

try:
    # dry_run=True validates but does not send a visible notification
    res = messaging.send(message, dry_run=True)
    print("Dry-run succeeded (token valid). response:", res)
except Exception as e:
    print("Dry-run error:", e)
    raise
