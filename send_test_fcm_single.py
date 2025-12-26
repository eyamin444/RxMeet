# send_test_fcm_single.py
import os, firebase_admin
from firebase_admin import credentials, messaging
from pprint import pprint

FIREBASE_CREDENTIAL_PATH = os.getenv("FIREBASE_CREDENTIAL_PATH", "/absolute/path/to/serviceAccount.json")
if not firebase_admin._apps:
    cred = credentials.Certificate(FIREBASE_CREDENTIAL_PATH)
    firebase_admin.initialize_app(cred)
print("firebase_admin._apps:", firebase_admin._apps)

token = "<PASTE_DEVICE_TOKEN_HERE>"
msg = messaging.Message(
    notification=messaging.Notification(title="TEST", body="hello"),
    data={"type":"doctor_call","appointment_id":"debug"},
    token=token
)
try:
    res = messaging.send(msg)
    print("send OK:", res)
except Exception as e:
    print("send ERROR:", type(e), e)
    import traceback; traceback.print_exc()
