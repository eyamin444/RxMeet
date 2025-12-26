from firebase_admin import credentials, messaging, initialize_app
import sys, os

cred_path = r"D:\SmartGateway\firebase-service-account.json"
# initialize firebase admin (harmless if already initialized)
try:
    initialize_app(credentials.Certificate(cred_path))
except Exception:
    pass

# paste the token exactly on one line below (replace the contents between the quotes)
token = "fXodC42Rjs18K9a1vogzAw:APA91bFi4SwrV4yR2Ez-MPz3UZbnAWR_yt8upEaGD9aHuU4Mj-6QdxY8BAqiP4DDy023coH6vV6mphM-_NCYqIvCTZYjtwy7vfCHBY3Bb8PPdRx7wiG_MUE"

# show repr and length so we can detect hidden newlines/whitespace
print("token repr:", repr(token))
print("len(token) =", len(token))

# strip accidental whitespace/newlines and show again
token = token.strip()
print("after strip; repr:", repr(token))
print("after strip; len(token) =", len(token))

# dry-run messaging send (validates token without sending a visible notification)
msg = messaging.Message(data={"test":"dryrun"}, token=token)
try:
    res = messaging.send(msg, dry_run=True)
    print("Dry-run succeeded:", res)
except Exception as e:
    print("Dry-run failed:", type(e).__name__, str(e))
