# check_tokens.py
import os
import firebase_admin
from firebase_admin import credentials, messaging
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from app import DATABASE_URL, DeviceToken  # adapt to your import

# init firebase if needed
FIREBASE_CREDENTIAL_PATH = os.getenv("FIREBASE_CREDENTIAL_PATH", "/absolute/path/serviceAccount.json")
if not firebase_admin._apps:
    cred = credentials.Certificate(FIREBASE_CREDENTIAL_PATH)
    firebase_admin.initialize_app(cred)

engine = create_engine(DATABASE_URL)
Session = sessionmaker(bind=engine)
s = Session()

rows = s.query(DeviceToken).limit(50).all()
for r in rows:
    token = (r.token or "").strip()
    print("Testing id:", r.id, "platform:", r.platform, "token:", repr(token)[:120])
    try:
        msg = messaging.Message(notification=messaging.Notification(title="Debug", body="Test"), token=token)
        res = messaging.send(msg, dry_run=True)  # dry_run to validate
        print("OK:", res)
    except Exception as e:
        print("ERROR:", type(e), str(e)[:300])
s.close()
