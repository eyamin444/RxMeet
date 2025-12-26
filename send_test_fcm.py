# send_test_fcm.py
import os
import firebase_admin
from firebase_admin import credentials, messaging

cred_path = os.getenv("FIREBASE_CREDENTIAL_PATH") or r"C:\path\to\service-account.json"
if not os.path.exists(cred_path):
    raise SystemExit("Set FIREBASE_CREDENTIAL_PATH to your service-account.json path")

if not firebase_admin._apps:
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)
    print("Firebase admin initialized")

token = "frBG5auIv1zN6G1zv7NcdR:APA91bGmcwCxLTqjwWgKHIpCQiI1y7yn7XPnZ5vpVpp1ggvNbxzNx60oJXwWD3t5CTb2vofLjNNh_XvQ0F4AVoCH_ypJ1E9gnpeFQ14xeGYKETZGaRRUbnk"

message = messaging.Message(
    data={
        "type": "doctor_call",
        "appointment_id": "41",
        "doctor_name": "Dr Test",
        "room": "room_41"
    },
    token=token,
    android=messaging.AndroidConfig(priority="high"),
)

try:
    res = messaging.send(message)
    print("Sent message id:", res)
except Exception as e:
    print("FCM send error:", e)
