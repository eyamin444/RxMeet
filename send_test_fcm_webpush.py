# D:\SmartGateway\send_test_fcm_webpush.py
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
    print("Firebase admin initialized")

# <<< PASTE THE FULL TOKEN HERE (ONE LINE) >>>
token = "fXodC42Rjs18K9a1vogzAw:APA91bFi4SwrV4yR2Ez-MPz3UZbnAWR_yt8upEaGD9aHuU4Mj-6QdxY8BAqiP4DDy023coH6vV6mphM-_NCYqIvCTZYjtwy7vfCHBY3Bb8PPdRx7wiG_MUE"

message = messaging.Message(
    data={
        "type": "doctor_call",
        "appointment_id": "41",
        "doctor_name": "Dr Test",
        "room": "room_41",
    },
    webpush=messaging.WebpushConfig(
        headers={"TTL": "60"},
        notification=messaging.WebpushNotification(
            title="TEST Incoming Call",
            body="Doctor is calling — test webpush",
            icon="https://www.google.com/favicon.ico"
        )
    ),
    token=token,
)

try:
    res = messaging.send(message)
    print("Sent webpush message id:", res)
except Exception as e:
    print("FCM send error:", e)
    raise
