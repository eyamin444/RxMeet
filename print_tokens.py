# print_tokens.py
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from app import DATABASE_URL, DeviceToken  # or import your app DB helpers

engine = create_engine(DATABASE_URL)
Session = sessionmaker(bind=engine)
s = Session()
rows = s.query(DeviceToken).filter(DeviceToken.user_id == <PATIENT_USER_ID>).all()
for r in rows:
    print("id", r.id, "platform", r.platform, "token_repr", repr(r.token))
s.close()
