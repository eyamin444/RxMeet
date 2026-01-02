# app.py
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")
from datetime import datetime, timedelta, date as dt_date, date
from enum import Enum
import os, secrets
from typing import Optional, List, Iterable, Tuple
from fastapi.responses import PlainTextResponse

from fastapi import FastAPI, Depends, HTTPException, UploadFile, File, Form, Query, Body, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from livekit import api as lk_api
import datetime as dt
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from fastapi.staticfiles import StaticFiles
from jose import jwt
from passlib.context import CryptContext
from pydantic import BaseModel, EmailStr
from sqlalchemy import (
    Column, Integer, String, DateTime, Date, Enum as SAEnum, ForeignKey, Text, Boolean, Float,
    create_engine, or_, and_, text
)
from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session
from firebase_admin import messaging
from sqlalchemy.orm import declarative_base, relationship, sessionmaker, Session
from io import BytesIO
from sqlalchemy import func




# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./smart_gateway.db")
JWT_SECRET = os.getenv("JWT_SECRET", "change_me")
JWT_ALG = os.getenv("JWT_ALG", "HS256")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "240"))
HOSPITAL_HOTLINE = os.getenv("HOSPITAL_HOTLINE", "+88000000000")

LIVEKIT_URL = os.getenv("LIVEKIT_URL", "ws://192.168.0.102:7880")
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "devkey")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "devsecret_1234567890_1234567890_ABCDEFG")

from sqlalchemy.pool import NullPool, StaticPool

import json
import os
import firebase_admin
from firebase_admin import credentials, messaging

import threading
import time


FIREBASE_CREDENTIAL_PATH = os.getenv("FIREBASE_CREDENTIAL_PATH", "D:\\SmartGateway\\firebase-service-account.json")

def ensure_firebase_initialized():
    """
    Idempotent initialize firebase_admin and ensure projectId is supplied
    so Cloud Messaging has a project context in every process/worker.
    """
    try:
        if firebase_admin._apps:
            # already initialized in this process
            try:
                app = firebase_admin.get_app()
                print("Firebase app exists, project_id:", getattr(app, 'project_id', None))
            except Exception:
                pass
            return True

        if FIREBASE_CREDENTIAL_PATH and os.path.exists(FIREBASE_CREDENTIAL_PATH):
            # read service account JSON to extract project_id
            with open(FIREBASE_CREDENTIAL_PATH, "r", encoding="utf-8") as fh:
                sa = json.load(fh)
            project_id = sa.get("project_id")
            # Set GOOGLE_CLOUD_PROJECT env var for libraries that read it
            if project_id:
                os.environ.setdefault("GOOGLE_CLOUD_PROJECT", project_id)

            cred = credentials.Certificate(FIREBASE_CREDENTIAL_PATH)
            init_opts = {}
            if project_id:
                init_opts["projectId"] = project_id

            firebase_admin.initialize_app(cred, options=init_opts)
            print("Firebase admin initialized (project_id={})".format(project_id))
            return True
        else:
            # fallback to ADC (not recommended for production)
            firebase_admin.initialize_app()
            print("Firebase admin initialized (ADC fallback)")
            return True
    except Exception as e:
        print("Failed to initialize firebase_admin:", e)
        return False

def _engine_from_env(url: str):
    if url.startswith("sqlite"):
        is_memory = ":memory:" in url or url.rstrip("/") in ("sqlite://", "sqlite:///:memory:")
        if is_memory:
            return create_engine(
                url,
                connect_args={"check_same_thread": False},
                poolclass=StaticPool,
            )
        else:
            return create_engine(
                url,
                connect_args={"check_same_thread": False},
                poolclass=NullPool,
            )
    else:
        # Production DB (e.g. PostgreSQL or MySQL)
        return create_engine(
            url,
            pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
            max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "10")),
            pool_timeout=int(os.getenv("DB_POOL_TIMEOUT", "30")),
            pool_recycle=int(os.getenv("DB_POOL_RECYCLE", "1800")),
            pool_pre_ping=True,
            pool_use_lifo=True,
        )

engine = _engine_from_env(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, expire_on_commit=False)
Base = declarative_base()


pwd_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")

# -----------------------------------------------------------------------------
# Enums
# -----------------------------------------------------------------------------
class UserRole(str, Enum):
    admin = "admin"
    doctor = "doctor"
    patient = "patient"

class AppointmentStatus(str, Enum):
    requested = "requested"
    approved = "approved"
    rejected = "rejected"
    cancelled = "cancelled"

class AppointmentProgress(str, Enum):
    not_yet = "not_yet"
    in_progress = "in_progress"
    hold = "hold"
    completed = "completed"
    no_show = "no_show"

class PaymentStatus(str, Enum):
    pending = "pending"
    paid = "paid"
    failed = "failed"

class VisitMode(str, Enum):
    online = "online"
    offline = "offline"

# -----------------------------------------------------------------------------
# Models
# -----------------------------------------------------------------------------
class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
    email = Column(String, unique=True, nullable=True)
    phone = Column(String, unique=True, nullable=True)
    role = Column(SAEnum(UserRole), nullable=False)
    password_hash = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    photo_path = Column(String, nullable=True)

    doctor_profile = relationship("Doctor", back_populates="user", uselist=False)
    patient_profile = relationship("Patient", back_populates="user", uselist=False)

class Doctor(Base):
    __tablename__ = "doctors"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    specialty = Column(String, nullable=False)
    category = Column(String, default="General")
    keywords = Column(String, default="")
    bio = Column(Text, default="")
    background = Column(Text, default="")
    rating = Column(Integer, default=5)
    address = Column(String, default="")
    visiting_fee = Column(Float, default=0.0)


    user = relationship("User", back_populates="doctor_profile")
    appointments = relationship("Appointment", back_populates="doctor")
    availabilities = relationship("Availability", backref="doctor")
    documents = relationship("DoctorDocument", back_populates="doctor", cascade="all, delete-orphan")
    education = relationship("DoctorEducation", back_populates="doctor", cascade="all, delete-orphan")
    ratings = relationship("DoctorRating", back_populates="doctor", cascade="all, delete-orphan")
    date_rules = relationship("DateRule", back_populates="doctor", cascade="all, delete-orphan")


class DoctorDocument(Base):
    __tablename__ = "doctor_documents"
    id = Column(Integer, primary_key=True)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    title = Column(String, default="Document")
    doc_type = Column(String, default="certificate")
    file_path = Column(String, nullable=False)
    uploaded_at = Column(DateTime, default=datetime.utcnow)
    doctor = relationship("Doctor", back_populates="documents")

class DoctorEducation(Base):
    __tablename__ = "doctor_education"
    id = Column(Integer, primary_key=True)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    degree = Column(String, nullable=False)
    institute = Column(String, nullable=False)
    year = Column(Integer, nullable=True)
    doctor = relationship("Doctor", back_populates="education")

class Patient(Base):
    __tablename__ = "patients"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    date_of_birth = Column(String, nullable=True)
    age = Column(Integer, nullable=True)
    weight = Column(Integer, nullable=True)
    height = Column(Integer, nullable=True)
    blood_group = Column(String, nullable=True)
    gender = Column(String, nullable=True)
    description = Column(Text, default="")
    current_medicine = Column(Text, default="")
    medical_history = Column(Text, default="")

    user = relationship("User", back_populates="patient_profile")
    appointments = relationship("Appointment", back_populates="patient")
    reports = relationship("MedicalReport", back_populates="patient")

class Appointment(Base):
    __tablename__ = "appointments"
    id = Column(Integer, primary_key=True)
    patient_id = Column(Integer, ForeignKey("patients.id"), nullable=False)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    start_time = Column(DateTime, nullable=False)
    end_time = Column(DateTime, nullable=False)
    status = Column(SAEnum(AppointmentStatus), default=AppointmentStatus.requested)
    payment_status = Column(SAEnum(PaymentStatus), default=PaymentStatus.pending)
    notes = Column(Text, default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    visit_mode = Column(SAEnum(VisitMode), default=VisitMode.offline)
    patient_problem = Column(Text, default="")
    disease_photo_path = Column(String, nullable=True)
    video_room = Column(String, nullable=True)
    completed_at = Column(DateTime, nullable=True)

    progress = Column(SAEnum(AppointmentProgress), default=AppointmentProgress.not_yet)
    cancel_reason = Column(Text, default="")
    last_modified_by_user_id = Column(Integer, nullable=True)
    last_modified_at = Column(DateTime, nullable=True)

    # New columns
    serial_number = Column(Integer, nullable=True)
    estimated_visit_time = Column(DateTime, nullable=True)

    patient = relationship("Patient", back_populates="appointments")
    doctor = relationship("Doctor", back_populates="appointments")
    prescription = relationship("Prescription", back_populates="appointment", uselist=False)
    rating = relationship("DoctorRating", back_populates="appointment", uselist=False)

    # Payments: one-to-many
    payments = relationship("Payment", back_populates="appointment", cascade="all, delete-orphan")

    changes = relationship("AppointmentChangeLog", back_populates="appointment", cascade="all, delete-orphan")
    notes_thread = relationship("AppointmentNote", back_populates="appointment", cascade="all, delete-orphan")

class AppointmentChangeLog(Base):
    __tablename__ = "appointment_change_logs"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False)
    changed_by_user_id = Column(Integer, nullable=False)
    old_start_time = Column(DateTime, nullable=False)
    old_end_time = Column(DateTime, nullable=False)
    new_start_time = Column(DateTime, nullable=False)
    new_end_time = Column(DateTime, nullable=False)
    reason = Column(Text, default="")
    changed_at = Column(DateTime, default=datetime.utcnow)
    appointment = relationship("Appointment", back_populates="changes")

class AppointmentNote(Base):
    __tablename__ = "appointment_notes"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False)
    author_user_id = Column(Integer, nullable=False)
    note = Column(Text, default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    appointment = relationship("Appointment", back_populates="notes_thread")

class Prescription(Base):
    __tablename__ = "prescriptions"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False)
    content = Column(Text, default="")
    file_path = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, nullable=True)  # <— NEW
    appointment = relationship("Appointment", back_populates="prescription")


class MedicalReport(Base):
    __tablename__ = "medical_reports"
    id = Column(Integer, primary_key=True)
    patient_id = Column(Integer, ForeignKey("patients.id"), nullable=False)
    file_path = Column(String, nullable=False)
    original_name = Column(String, nullable=False, default="")
    uploaded_at = Column(DateTime, default=datetime.utcnow)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=True)
    patient = relationship("Patient", back_populates="reports")

class Availability(Base):
    __tablename__ = "availabilities"
    id = Column(Integer, primary_key=True)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    day_of_week = Column(Integer, nullable=False)  # 0..6 Sun..Sat
    start_hour = Column(Integer, nullable=False)   # 0..23
    end_hour = Column(Integer, nullable=False)     # 1..24
    max_patients = Column(Integer, nullable=False, default=4)
    active = Column(Boolean, default=True)
    mode = Column(String, default="offline")       # online/offline
    created_at = Column(DateTime, default=datetime.utcnow)

class DateRule(Base):
    __tablename__ = "date_rules"
    id = Column(Integer, primary_key=True)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    target_date = Column(Date, nullable=False)           # specific day
    start_hour = Column(Integer, nullable=False)
    end_hour = Column(Integer, nullable=False)
    max_patients = Column(Integer, nullable=False, default=4)
    active = Column(Boolean, default=True)
    mode = Column(String, default="offline")             # online/offline
    created_at = Column(DateTime, default=datetime.utcnow)
    doctor = relationship("Doctor", back_populates="date_rules")

class DoctorRating(Base):
    __tablename__ = "doctor_ratings"
    id = Column(Integer, primary_key=True)
    doctor_id = Column(Integer, ForeignKey("doctors.id"), nullable=False)
    patient_id = Column(Integer, ForeignKey("patients.id"), nullable=False)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False, unique=True)
    stars = Column(Integer, nullable=False)
    comment = Column(Text, default="")
    created_at = Column(DateTime, default=datetime.utcnow)
    doctor = relationship("Doctor", back_populates="ratings")
    appointment = relationship("Appointment", back_populates="rating")

class Payment(Base):
    __tablename__ = "payments"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False)  # allow many payments
    transaction_id = Column(String, nullable=False)
    method = Column(String, nullable=False)
    amount = Column(Float, nullable=True)
    status = Column(SAEnum(PaymentStatus), default=PaymentStatus.paid)
    paid_at = Column(DateTime, default=datetime.utcnow)
    raw = Column(Text, default="")
    appointment = relationship("Appointment", back_populates="payments")

class DeviceToken(Base):
    __tablename__ = "device_tokens"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    token = Column(String, nullable=False, index=True)
    platform = Column(String, nullable=True)   # 'android' | 'ios' | 'web'
    created_at = Column(DateTime, default=datetime.utcnow)
    last_seen_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User")

class CallLog(Base):
    __tablename__ = "call_logs"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False, index=True)
    started_by_user_id = Column(Integer, nullable=True)   # user id who started (doctor)
    started_at = Column(DateTime, nullable=True)
    answered_at = Column(DateTime, nullable=True)
    ended_at = Column(DateTime, nullable=True)
    duration = Column(Integer, nullable=True)  # seconds
    status = Column(String, default="ringing")  

class Message(Base):
    __tablename__ = "messages"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False, index=True)
    sender_user_id = Column(Integer, nullable=False, index=True)
    recipient_user_id = Column(Integer, nullable=True, index=True)  # optional, convenience
    body = Column(Text, default="", nullable=False)
    kind = Column(String, default="text")  # text | system | media | etc.
    read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow, index=True)

    # Relationship (optional)
    appointment = relationship("Appointment")

# -----------------------------------------------------------------------------
# SQLite additive auto-migrations (adds columns safely)
# -----------------------------------------------------------------------------
def _has_column(conn, table: str, column: str) -> bool:
    rows = conn.execute(text(f"PRAGMA table_info({table})")).mappings().all()
    return any(row["name"] == column for row in rows)

def _add_column(conn, table: str, ddl: str):
    conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {ddl}"))

def ensure_sqlite_schema(engine):
    if engine.url.get_backend_name() != "sqlite":
        return
    with engine.begin() as conn:
        # users
        if not _has_column(conn, "users", "photo_path"): _add_column(conn, "users", "photo_path TEXT")
        # doctors
        if not _has_column(conn, "doctors", "category"): _add_column(conn, "doctors", "category TEXT DEFAULT 'General'")
        if not _has_column(conn, "doctors", "keywords"): _add_column(conn, "doctors", "keywords TEXT DEFAULT ''")
        if not _has_column(conn, "doctors", "background"): _add_column(conn, "doctors", "background TEXT DEFAULT ''")
        if not _has_column(conn, "doctors", "rating"): _add_column(conn, "doctors", "rating INTEGER DEFAULT 5")
        if not _has_column(conn, "doctors", "address"): _add_column(conn, "doctors", "address TEXT DEFAULT ''")
        if not _has_column(conn, "doctors", "visiting_fee"): _add_column(conn, "doctors", "visiting_fee REAL DEFAULT 0")
        # patients
        for col, ddl in [
            ("age", "age INTEGER"), ("weight", "weight INTEGER"), ("height", "height INTEGER"),
            ("blood_group", "blood_group TEXT"), ("gender", "gender TEXT"),
            ("description", "description TEXT DEFAULT ''"),
            ("current_medicine", "current_medicine TEXT DEFAULT ''"),
            ("medical_history", "medical_history TEXT DEFAULT ''"),
        ]:
            if not _has_column(conn, "patients", col): _add_column(conn, "patients", ddl)
        # appointments (new fields)
        for col, ddl in [
            ("visit_mode", "visit_mode TEXT DEFAULT 'offline'"),
            ("patient_problem", "patient_problem TEXT DEFAULT ''"),
            ("disease_photo_path", "disease_photo_path TEXT"),
            ("video_room", "video_room TEXT"),
            ("progress", "progress TEXT DEFAULT 'not_yet'"),
            ("cancel_reason", "cancel_reason TEXT DEFAULT ''"),
            ("last_modified_by_user_id", "last_modified_by_user_id INTEGER"),
            ("last_modified_at", "last_modified_at TEXT"),
            ("completed_at", "completed_at TEXT"),
            ("serial_number", "serial_number INTEGER"),
            ("estimated_visit_time", "estimated_visit_time TEXT"),
        ]:
            if not _has_column(conn, "appointments", col): _add_column(conn, "appointments", ddl)

        # availabilities
        if not _has_column(conn, "availabilities", "max_patients"):
            _add_column(conn, "availabilities", "max_patients INTEGER DEFAULT 4")
        if not _has_column(conn, "availabilities", "mode"):
            _add_column(conn, "availabilities", "mode TEXT DEFAULT 'offline'")
        if not _has_column(conn, "availabilities", "created_at"):
            _add_column(conn, "availabilities", "created_at TEXT")
        # date_rules
        if not _has_column(conn, "date_rules", "target_date"):
            _add_column(conn, "date_rules", "target_date TEXT")
            if _has_column(conn, "date_rules", "date"):
                conn.execute(text("UPDATE date_rules SET target_date = date"))
        if not _has_column(conn, "date_rules", "created_at"):
            _add_column(conn, "date_rules", "created_at TEXT")
        # prescriptions
        if not _has_column(conn, "prescriptions", "file_path"):
            _add_column(conn, "prescriptions", "file_path TEXT")
        if not _has_column(conn, "prescriptions", "updated_at"):
            _add_column(conn, "prescriptions", "updated_at TEXT")
        # medical_reports
        if not _has_column(conn, "medical_reports", "original_name"):
            _add_column(conn, "medical_reports", "original_name TEXT DEFAULT ''")
        if not _has_column(conn, "medical_reports", "appointment_id"):
            _add_column(conn, "medical_reports", "appointment_id INTEGER")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def create_db():
    Base.metadata.create_all(bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def verify_password(plain, hashed): return pwd_context.verify(plain, hashed)
def hash_password(pw: str) -> str: return pwd_context.hash(pw)

def create_access_token(data: dict, minutes: int = ACCESS_TOKEN_EXPIRE_MINUTES) -> str:
    to_encode = data.copy()
    to_encode["exp"] = datetime.utcnow() + timedelta(minutes=minutes)
    return jwt.encode(to_encode, JWT_SECRET, algorithm=JWT_ALG)

def fcm_send_data_tokens(db: Session, tokens: List[str], data: dict, ttl_seconds: int = 60):
    """
    Send a data-only message to a list of device tokens.
    Removes device tokens which return NotRegistered/Unregistered errors.
    """
    if not tokens:
        return
    webpush_cfg = None
    try:
        webpush_cfg = messaging.WebpushConfig(headers={"Urgency": "high"})
    except Exception:
        webpush_cfg = None
    android_cfg = messaging.AndroidConfig(priority="high", ttl=ttl_seconds)

    for t in list(set(tokens)):
        try:
            msg = messaging.Message(
                data={k: str(v) for k, v in data.items()},
                token=t,
                android=android_cfg,
                webpush=webpush_cfg,
            )
            messaging.send(msg)
        except Exception as e:
            err = str(e)
            # Remove tokens that are no longer valid
            if "Unregistered" in err or "not registered" in err or "registration-token-not-registered" in err:
                try:
                    db.query(DeviceToken).filter(DeviceToken.token == t).delete()
                    db.commit()
                except Exception:
                    db.rollback()
            else:
                # Log and continue; do not raise to avoid failing the whole call
                print("FCM send error:", err)


def get_current_user(db: Session = Depends(get_db), token: str = Depends(oauth2_scheme)) -> User:
    exc = HTTPException(status_code=401, detail="Could not validate credentials",
                        headers={"WWW-Authenticate": "Bearer"})
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
        uid = int(payload.get("sub"))
    except Exception:
        raise exc
    user = db.get(User, uid)
    if not user: raise exc
    return user

def require_role(*roles: UserRole):
    def _dep(curr: User = Depends(get_current_user)):
        if curr.role not in roles:
            raise HTTPException(403, "Insufficient permissions")
        return curr
    return _dep

def hour_range(start: int, end: int) -> Iterable[int]: return range(start, end)

def _active_rule_for(db: Session, doctor_id: int, day_dt: datetime, start_h: int, end_h: int) -> Optional[dict]:
    """
    Returns a dict describing capacity window for this hour slot if active.
    Preference: DateRule for that exact date; otherwise Availability rule.
    """
    dr = (db.query(DateRule)
            .filter(DateRule.doctor_id == doctor_id,
                    DateRule.target_date == dt_date(day_dt.year, day_dt.month, day_dt.day),
                    DateRule.active == True,
                    DateRule.start_hour <= start_h,
                    DateRule.end_hour >= end_h)
            .first())
    if dr:
        return {"max_patients": dr.max_patients, "mode": dr.mode}

    dow = day_dt.weekday()  # 0=Mon..6=Sun
    dow_sun0 = (dow + 1) % 7
    av = (db.query(Availability)
            .filter(Availability.doctor_id == doctor_id,
                    Availability.day_of_week == dow_sun0,
                    Availability.active == True,
                    Availability.start_hour <= start_h,
                    Availability.end_hour >= end_h)
            .first())
    if av:
        return {"max_patients": av.max_patients, "mode": av.mode}
    return None

def slot_capacity_left(db: Session, doctor_id: int, start: datetime, end: datetime) -> int:
    rule = _active_rule_for(db, doctor_id, start, start.hour, end.hour if end.minute == 0 else end.hour + 1)
    if not rule: return 0
    count = (db.query(Appointment)
               .filter(Appointment.doctor_id == doctor_id,
                       Appointment.start_time == start,
                       Appointment.end_time == end,
                       Appointment.status.in_([AppointmentStatus.requested, AppointmentStatus.approved]))
               .count())
    return max(0, int(rule["max_patients"]) - count)

def gen_slots_for_date(db: Session, doctor_id: int, day: dt_date) -> List[datetime]:
    drs = (db.query(DateRule)
             .filter(DateRule.doctor_id == doctor_id,
                     DateRule.target_date == day,
                     DateRule.active == True)
             .all())
    out: List[datetime] = []
    def _append_by_hours(start_h: int, end_h: int):
        for h in hour_range(start_h, end_h):
            st = datetime(day.year, day.month, day.day, h)
            en = st + timedelta(hours=1)
            if slot_capacity_left(db, doctor_id, st, en) > 0:
                out.append(st)

    if drs:
        for r in drs:
            _append_by_hours(r.start_hour, r.end_hour)
        return out

    dow_mon0 = dt_date.weekday(day)  # 0=Mon..6=Sun
    dow_sun0 = (dow_mon0 + 1) % 7
    avails = (db.query(Availability)
                .filter(Availability.doctor_id == doctor_id,
                        Availability.day_of_week == dow_sun0,
                        Availability.active == True)
                .all())
    for a in avails:
        _append_by_hours(a.start_hour, a.end_hour)
    return out

# ---------- <<CALL_TIMEOUT_AND_INTERNAL_END>> ----------
def _notify_end_call_tokens(db: Session, tokens: List[str], appt_id: int, cl: Optional[CallLog], title: str, body: str):
    """Notify tokens with a standardized video_end payload."""
    try:
        if not tokens:
            return
        payload = {"type": "video_end", "appointment_id": str(appt_id)}
        if cl:
            payload["call_log_id"] = str(cl.id)
            payload["message_id"] = f"call_{cl.id}_end"
        multicast = messaging.MulticastMessage(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in payload.items()},
            tokens=list(set(tokens)),
        )
        res = messaging.send_multicast(multicast)
        print(f"_notify_end_call_tokens: sent success={res.success_count} failed={res.failure_count}")
    except Exception as e:
        print("_notify_end_call_tokens: error:", e)

def _notify_chat_message(db: Session, appointment: Appointment, message_row: Message):
    """
    Send a data-only FCM message to the other party for the given message.
    Payload contains message_id, appointment_id, sender_id, body and type=chat_message.
    """
    try:
        # find recipient: if message_row.recipient_user_id provided use it,
        # else compute as the other user on the appointment
        recipient_id = message_row.recipient_user_id
        if not recipient_id:
            # appointment.patient.user_id and appointment.doctor.user_id exist
            if appointment.patient and appointment.patient.user_id == message_row.sender_user_id:
                recipient_id = appointment.doctor.user_id
            elif appointment.doctor and appointment.doctor.user_id == message_row.sender_user_id:
                recipient_id = appointment.patient.user_id
            else:
                # As fallback, send to both
                recipient_id = None

        tokens = []
        if recipient_id:
            tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == recipient_id).all()
            tokens = [t.token for t in tokens_q if t and t.token]
        else:
            # fallback: notify both sides
            dr = db.query(DeviceToken).filter(DeviceToken.user_id == appointment.patient.user_id).all()
            pr = db.query(DeviceToken).filter(DeviceToken.user_id == appointment.doctor.user_id).all()
            tokens = [t.token for t in (dr + pr) if t and t.token]

        if not tokens:
            return

        data_payload = {
            "type": "chat_message",
            "appointment_id": str(appointment.id),
            "message_id": str(message_row.id),
            "sender_id": str(message_row.sender_user_id),
            "body": (message_row.body or "")[:1000],  # keep small
        }
        fcm_send_data_tokens(db, tokens, data_payload, ttl_seconds=3600)
    except Exception as e:
        print("_notify_chat_message error:", e)

def _end_call_internal(db: Session, appointment_id: int, call_log_id: Optional[int] = None, reason: str = "ended", by: Optional[str] = None):
    """
    Internal helper to mark CallLog ended and notify both doctor and patient.
    Idempotent: safe to call multiple times.
    """
    try:
        appt = db.get(Appointment, appointment_id)
        if not appt:
            print(f"_end_call_internal: appointment {appointment_id} not found")
            return False

        cl = None
        if call_log_id:
            cl = db.get(CallLog, call_log_id)
            if not cl or cl.appointment_id != appointment_id:
                cl = None

        # If no call_log provided, try to find the most recent
        if not cl:
            cl = (
                db.query(CallLog)
                .filter(CallLog.appointment_id == appointment_id)
                .order_by(CallLog.started_at.desc())
                .first()
            )

        if cl:
            if not cl.ended_at:
                cl.ended_at = datetime.utcnow()
                cl.status = "missed" if reason == "missed" else "ended"
                # compute duration if answered
                try:
                    if cl.answered_at and cl.started_at:
                        cl.duration = int((cl.ended_at - cl.answered_at).total_seconds())
                except Exception:
                    pass
                db.commit()
        else:
            # no call log found: nothing to update in DB, but we still notify tokens
            pass

        # Notify doctor and patient tokens
        try:
            dr_tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == appt.doctor.user_id).all()
            dr_tokens = [t.token for t in dr_tokens_q if t and t.token]
            _notify_end_call_tokens(db, dr_tokens, appointment_id, cl, "Call ended", f"Call ended for appointment #{appointment_id}")
        except Exception as e:
            print("_end_call_internal: failed to notify doctor tokens:", e)

        try:
            p_tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == appt.patient.user_id).all()
            p_tokens = [t.token for t in p_tokens_q if t and t.token]
            _notify_end_call_tokens(db, p_tokens, appointment_id, cl, "Call ended", f"Call ended for appointment #{appointment_id}")
        except Exception as e:
            print("_end_call_internal: failed to notify patient tokens:", e)

        return True
    except Exception as e:
        print("_end_call_internal error:", e)
        db.rollback()
        return False


def schedule_call_timeout(appointment_id: int, call_log_id: int, timeout_seconds: int = 60):
    """
    Schedule a background Timer to auto-end the call if it remains ringing for timeout_seconds.
    This uses a separate DB session per timer.
    """
    def _worker(appt_id: int, cl_id: int, tsec: int):
        try:
            print(f"SCHEDULE_CALL_TIMEOUT: sleeping {tsec}s for appt={appt_id} cl={cl_id}")
            time.sleep(tsec)
            db = SessionLocal()
            try:
                cl = db.get(CallLog, cl_id)
                if not cl:
                    print(f"SCHEDULE_CALL_TIMEOUT: call_log {cl_id} missing (already ended?)")
                    return
                # Only end if still ringing (no answered_at and no ended_at)
                if cl.ended_at:
                    print(f"SCHEDULE_CALL_TIMEOUT: call_log {cl_id} already ended at {cl.ended_at}")
                    return
                # If already answered, do not mark missed
                if cl.answered_at:
                    print(f"SCHEDULE_CALL_TIMEOUT: call_log {cl_id} already answered at {cl.answered_at}")
                    return
                # Mark as missed through internal end helper
                print(f"SCHEDULE_CALL_TIMEOUT: auto-ending call_log {cl_id} (missed)")
                _end_call_internal(db, appt_id, cl_id, reason="missed", by="system")
            finally:
                db.close()
        except Exception as ex:
            print("SCHEDULE_CALL_TIMEOUT: worker error:", ex)

    t = threading.Thread(target=_worker, args=(appointment_id, call_log_id, timeout_seconds), daemon=True)
    t.start()
    print(f"SCHEDULE_CALL_TIMEOUT: scheduled for appt={appointment_id} cl={call_log_id} in {timeout_seconds}s")
# ---------- <<END CALL_TIMEOUT_AND_INTERNAL>> ----------


# ---- block helpers (new) -----------------------------------------------------
def _overlap(a_start: datetime, a_end: datetime, b_start: datetime, b_end: datetime) -> bool:
    return (a_start < b_end) and (b_start < a_end)

def block_capacity_left(db: Session, doctor_id: int, start: datetime, end: datetime) -> int:
    """Capacity left for the exact [start,end) window, counting ANY overlapping bookings."""
    rule = _active_rule_for(db, doctor_id, start, start.hour, end.hour if end.minute == 0 else end.hour + 1)
    if not rule:
        return 0
    taken = (
        db.query(Appointment)
          .filter(
              Appointment.doctor_id == doctor_id,
              Appointment.status.in_([AppointmentStatus.requested, AppointmentStatus.approved]),
              Appointment.start_time < end,
              Appointment.end_time > start,
          ).count()
    )
    return max(0, int(rule["max_patients"]) - taken)

def gen_blocks_for_date(
    db: Session, doctor_id: int, day: dt_date, mode: Optional[str] = None
) -> List[Tuple[datetime, datetime]]:
    """Return availability windows (not split by hour) for a day, honoring visit mode."""
    out: List[Tuple[datetime, datetime]] = []

    # Prefer date-specific rules
    drs = (
        db.query(DateRule)
          .filter(
              DateRule.doctor_id == doctor_id,
              DateRule.target_date == day,
              DateRule.active == True,
          )
          .order_by(DateRule.start_hour)
          .all()
    )
    if drs:
        for r in drs:
            if mode and r.mode != mode:
                continue
            st = datetime(day.year, day.month, day.day, int(r.start_hour))
            en = datetime(day.year, day.month, day.day, int(r.end_hour))
            if block_capacity_left(db, doctor_id, st, en) > 0:
                out.append((st, en))
        return out

    # Fallback weekly
    dow_mon0 = dt_date.weekday(day)  # Mon=0..Sun=6
    dow_sun0 = (dow_mon0 + 1) % 7
    avs = (
        db.query(Availability)
          .filter(
              Availability.doctor_id == doctor_id,
              Availability.day_of_week == dow_sun0,
              Availability.active == True,
          )
          .order_by(Availability.start_hour)
          .all()
    )
    for a in avs:
        if mode and a.mode != mode:
            continue
        st = datetime(day.year, day.month, day.day, int(a.start_hour))
        en = datetime(day.year, day.month, day.day, int(a.end_hour))
        if block_capacity_left(db, doctor_id, st, en) > 0:
            out.append((st, en))
    return out

# -----------------------------------------------------------------------------
# Schemas (Pydantic)
# -----------------------------------------------------------------------------
class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"

class UserOut(BaseModel):
    id: int
    name: str
    email: Optional[EmailStr] = None
    phone: Optional[str] = None
    role: UserRole
    photo_path: Optional[str] = None
    class Config: from_attributes = True

class RegisterPatientIn(BaseModel):
    name: str
    password: str
    email: Optional[EmailStr] = None
    phone: Optional[str] = None

class CreateDoctorIn(BaseModel):
    name: str
    email: EmailStr
    password: str
    phone: Optional[str] = None
    specialty: str
    category: Optional[str] = "General"
    keywords: Optional[str] = ""
    bio: Optional[str] = ""
    background: Optional[str] = ""
    doctor_phone: Optional[str] = None
    address: Optional[str] = ""

class DoctorOut(BaseModel):
    id: int
    name: str
    email: Optional[EmailStr] = None
    specialty: str
    category: str
    keywords: str
    bio: str
    background: str
    phone: Optional[str] = None
    address: Optional[str] = None
    visiting_fee: Optional[float] = None  
    rating: int
    photo_path: Optional[str] = None
    class Config: from_attributes = True

class AppointmentIn(BaseModel):
    doctor_id: int
    start_time: datetime
    end_time: datetime
    visit_mode: VisitMode = VisitMode.offline
    patient_problem: Optional[str] = ""

class AppointmentOut(BaseModel):
    id: int
    doctor_id: int
    patient_id: int
    start_time: datetime
    end_time: datetime
    status: AppointmentStatus
    payment_status: PaymentStatus
    visit_mode: VisitMode
    patient_problem: str
    notes: str
    video_room: Optional[str] = None
    progress: AppointmentProgress
    completed_at: Optional[datetime] = None
    doctor_name: Optional[str] = None
    patient_name: Optional[str] = None
    serial_number: Optional[int] = None
    estimated_visit_time: Optional[datetime] = None
    class Config: from_attributes = True


class ApproveIn(BaseModel):
    approve: bool
    # optional payment verification fields (admin can pass these while approving)
    transaction_id: Optional[str] = None
    method: Optional[str] = None
    amount: Optional[float] = None
    # optional reason for rejection (admin can provide a note when rejecting)
    reason: Optional[str] = None


class AvailabilityIn(BaseModel):
    day_of_week: int
    start_hour: int
    end_hour: int
    max_patients: int = 4
    active: bool = True
    mode: Optional[str] = "offline"

class PatientProfileIn(BaseModel):
    age: Optional[int] = None
    weight: Optional[int] = None
    height: Optional[int] = None
    blood_group: Optional[str] = None
    gender: Optional[str] = None
    description: Optional[str] = ""
    current_medicine: Optional[str] = ""
    medical_history: Optional[str] = ""

class PatientProfileOut(PatientProfileIn):
    pass

class ReportOut(BaseModel):
    id: int
    original_name: str
    uploaded_at: datetime
    file_path: str
    class Config: from_attributes = True

class DoctorDocOut(BaseModel):
    id: int
    title: str
    doc_type: str
    file_path: str
    uploaded_at: datetime
    class Config: from_attributes = True

class DoctorEduIn(BaseModel):
    degree: str
    institute: str
    year: Optional[int] = None

class DoctorEduOut(DoctorEduIn):
    id: int
    class Config: from_attributes = True

class RateIn(BaseModel):
    stars: int
    comment: Optional[str] = ""

class RateOut(BaseModel):
    id: int
    stars: int
    comment: str
    created_at: datetime
    class Config: from_attributes = True

class PaymentIn(BaseModel):
    transaction_id: str
    method: str
    amount: Optional[float] = None
    raw: Optional[str] = ""

class RescheduleIn(BaseModel):
    new_start_time: datetime
    new_end_time: datetime
    reason: Optional[str] = ""

class ProgressIn(BaseModel):
    progress: AppointmentProgress

class CancelIn(BaseModel):
    reason: Optional[str] = ""

class NoteIn(BaseModel):
    note: str

# schedule inputs
class WeeklyRuleIn(BaseModel):
    id: Optional[int] = None
    dow: int
    start: Optional[str] = None
    end: Optional[str] = None
    start_hour: Optional[int] = None
    end_hour: Optional[int] = None
    mode: Optional[str] = "offline"
    max_patients: Optional[int] = 4
    active: Optional[bool] = True

class WeeklyOffIn(BaseModel):
    id: Optional[int] = None
    dow: int
    active: Optional[bool] = False

class DateRuleIn(BaseModel):
    dates: List[str]  # ["YYYY-MM-DD", ...]
    start: Optional[str] = None
    end: Optional[str] = None
    start_hour: Optional[int] = None
    end_hour: Optional[int] = None
    mode: Optional[str] = "offline"
    max_patients: Optional[int] = 4
    active: Optional[bool] = True

class WeeklySetIn(BaseModel):
    selected_days: List[int]   # Mon=0..Sun=6
    start_hour: int
    end_hour: int
    max_patients: int = 4
    visit_mode: str = "offline"

class DoctorProfileIn(BaseModel):
    name: Optional[str] = None
    specialty: Optional[str] = None
    category: Optional[str] = None
    keywords: Optional[str] = None
    bio: Optional[str] = None
    background: Optional[str] = None
    phone: Optional[str] = None     
    address: Optional[str] = None    
    visiting_fee: Optional[float] = None 

# -----------------------------------------------------------------------------
# App
# -----------------------------------------------------------------------------
app = FastAPI(title="Smart Gateway API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

@app.on_event("shutdown")
def on_shutdown():
    try:
        engine.dispose()
    except Exception:
        pass

@app.on_event("startup")
def on_startup():
    os.makedirs("uploads", exist_ok=True)
    create_db()
    ensure_sqlite_schema(engine)

    # Ensure Firebase is initialized in this process
    ok = ensure_firebase_initialized()
    if not ok:
        # if you want to fail fast in dev, raise here. Otherwise just log.
        print("Warning: firebase_admin not initialized at startup")



@app.get("/ping")
def ping(): return {"ok": True}

@app.get("/whoami", response_model=UserOut)
def whoami(current: User = Depends(get_current_user)): return current

# -----------------------------------------------------------------------------
# Auth
# -----------------------------------------------------------------------------
@app.post("/auth/register", response_model=UserOut)
def register_patient(payload: RegisterPatientIn, db: Session = Depends(get_db)):
    if not payload.email and not payload.phone:
        raise HTTPException(400, "Provide email or phone")
    if payload.email and db.query(User).filter(User.email == payload.email).first():
        raise HTTPException(400, "Email already registered")
    if payload.phone and db.query(User).filter(User.phone == payload.phone).first():
        raise HTTPException(400, "Phone already registered")
    u = User(name=payload.name, email=payload.email, phone=payload.phone,
             role=UserRole.patient, password_hash=hash_password(payload.password))
    db.add(u); db.flush()
    db.add(Patient(user_id=u.id))
    db.commit(); db.refresh(u)
    return u

@app.post("/auth/login", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    u = (db.query(User).filter(or_(User.email == form.username, User.phone == form.username)).first())
    if not u or not verify_password(form.password, u.password_hash):
        raise HTTPException(400, "Incorrect email/phone or password")
    token = create_access_token({"sub": str(u.id), "role": u.role.value})
    return Token(access_token=token)

@app.post("/auth/logout", response_model=dict)
def logout():
    return {"ok": True}

@app.post("/auth/change_password", response_model=dict)
def change_password(old: str = Form(...), new: str = Form(...),
                    current: User = Depends(get_current_user),
                    db: Session = Depends(get_db)):
    if not verify_password(old, current.password_hash):
        raise HTTPException(400, "Wrong current password")
    current.password_hash = hash_password(new)
    db.commit()
    return {"ok": True}

@app.post("/me/photo", response_model=dict)
def upload_my_photo(
    file: UploadFile = File(...),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    fname = f"user_{current.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f:
        f.write(file.file.read())
    current.photo_path = path
    db.commit()
    return {"ok": True, "photo_path": path}

@app.patch("/me", response_model=UserOut)
async def update_me(
    request: Request,
    name: Optional[str] = Form(None),
    email: Optional[EmailStr] = Form(None),
    phone: Optional[str] = Form(None),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        raw = await request.body()
        if raw:
            import json
            obj = json.loads(raw)
            if isinstance(obj, dict):
                name = obj.get("name", name)
                email = obj.get("email", email)
                phone = obj.get("phone", phone)
    except Exception:
        pass

    # Apply updates (uniqueness checks for email/phone)
    if name is not None:
        current.name = name

    if email is not None:
        if email and db.query(User).filter(User.email == email, User.id != current.id).first():
            raise HTTPException(400, "Email already in use")
        current.email = email

    if phone is not None:
        if phone and db.query(User).filter(User.phone == phone, User.id != current.id).first():
            raise HTTPException(400, "Phone already in use")
        current.phone = phone

    db.commit()
    db.refresh(current)
    return current

@app.post("/me/device_token", response_model=dict)
async def register_device_token(request: Request, db: Session = Depends(get_db), current: User = Depends(get_current_user)):
    """
    Accepts JSON { "token": "...", "platform": "web" } OR form fields.
    Platform should be 'web', 'android', or 'ios' (optional).
    """
    token = None
    platform = None

    # Try JSON first (async)
    try:
        body = await request.json()
        if isinstance(body, dict):
            token = body.get("token") or body.get("device_token") or body.get("deviceToken")
            platform = body.get("platform") or body.get("platformName")
    except Exception:
        body = None

    # If not JSON, try form
    if not token:
        try:
            form = await request.form()
            token = (form.get("token") or form.get("device_token") or form.get("deviceToken"))
            platform = platform or form.get("platform")
        except Exception:
            pass

    # Last fallback: query param
    if not token:
        token = request.query_params.get("token") if request.query_params else None
        platform = platform or (request.query_params.get("platform") if request.query_params else None)

    if not token:
        raise HTTPException(422, "token is required")

    platform = (platform or "").lower() if platform else None
    if platform not in ("web", "android", "ios", None):
        # normalize common values
        if "web" in platform: platform = "web"
        elif "android" in platform: platform = "android"
        elif "ios" in platform or "iphone" in platform or "ipad" in platform: platform = "ios"
        else:
            platform = None

    existing = db.query(DeviceToken).filter(DeviceToken.token == token).first()
    if existing:
        existing.user_id = current.id
        existing.platform = platform
        existing.last_seen_at = datetime.utcnow()
    else:
        db.add(DeviceToken(user_id=current.id, token=token, platform=platform))
    db.commit()
    return {"ok": True}

# -----------------------------------------------------------------------------
# Admin
# -----------------------------------------------------------------------------
@app.post("/admin/doctors", response_model=DoctorOut)
def admin_create_doctor(payload: CreateDoctorIn, db: Session = Depends(get_db),
                        curr: User = Depends(require_role(UserRole.admin))):
    if db.query(User).filter(User.email == payload.email).first():
        raise HTTPException(400, "Email already registered")
    u = User(name=payload.name, email=payload.email, phone=payload.phone,
             role=UserRole.doctor, password_hash=hash_password(payload.password))
    db.add(u); db.flush()
    d = Doctor(user_id=u.id, specialty=payload.specialty, category=payload.category or "General",
               keywords=payload.keywords or "", bio=payload.bio or "", background=payload.background or "", rating=5)
    db.add(d); db.commit(); db.refresh(d); db.refresh(u)
    return DoctorOut(
        id=d.id, name=u.name, email=u.email, specialty=d.specialty,
        category=d.category, keywords=d.keywords, bio=d.bio, background=d.background,
        phone=u.phone, address=d.address,visiting_fee=d.visiting_fee, rating=d.rating, photo_path=u.photo_path
    )

@app.get("/admin/appointments", response_model=List[AppointmentOut])
def admin_list_appointments(status_filter: Optional[AppointmentStatus] = None,
                            db: Session = Depends(get_db),
                            curr: User = Depends(require_role(UserRole.admin))):
    q = db.query(Appointment)
    if status_filter: q = q.filter(Appointment.status == status_filter)
    return q.order_by(Appointment.start_time.desc()).all()


from datetime import datetime, timedelta

from sqlalchemy import or_, func, text  # ensure func/or_ already imported near top


@app.patch("/admin/appointments/{appointment_id}/approve", response_model=dict)
def approve_appointment(appointment_id: int, body: ApproveIn, db: Session = Depends(get_db),
                        curr: User = Depends(require_role(UserRole.admin))):
    """
    Approve or reject an appointment.

    Important: serial_number is assigned per *schedule window* (DateRule or Availability).
    - Find the best matching DateRule (exact date) or weekly Availability (weekday) whose
      window covers the appointment start_time.
    - Compute serial by counting existing appointments for the same doctor within that
      exact window (schedule_start .. schedule_end) and taking max(serial) + 1 (or 1 if none).
    - Compute estimated_visit_time = schedule_start + (serial - 1) * slot_minutes
      where slot_minutes = max(1, floor(window_minutes / max_patients)).
    """
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(status_code=404, detail="Appointment not found")

    # guard: if appointment already finalized, don't allow re-approve
    status_now = (appt.status.value if appt.status else "").lower()
    # Allow re-approve only if you want; here we continue with normal flow.

    created_payment = False

    if body.approve:
        # ---- handle optional payment creation first ----
        method = (body.method or "").strip() if hasattr(body, "method") else ""
        tx = (body.transaction_id or "").strip() if hasattr(body, "transaction_id") else ""
        amt = getattr(body, "amount", None) if hasattr(body, "amount") else None

        # If any payment info supplied, require method and handle cash specially
        if method:
            if method.lower() != "cash" and not tx:
                raise HTTPException(status_code=422, detail="transaction_id is required for non-cash payments")

            # If cash and tx empty, auto-generate one
            if method.lower() == "cash" and not tx:
                tx = f"CASH-{secrets.token_urlsafe(8)}"

            # Create payment record (mark as paid)
            try:
                pay = Payment(
                    appointment_id=appt.id,
                    transaction_id=tx,
                    method=method,
                    amount=amt,
                    status=PaymentStatus.paid,
                    paid_at=datetime.utcnow(),
                    raw="(entered-by-admin)"
                )
                db.add(pay)
                db.flush()
                created_payment = True
            except Exception as e:
                db.rollback()
                raise HTTPException(status_code=500, detail=f"Failed to record payment: {e}")

        # ---- compute serial_number and estimated_visit_time per schedule window ----
        # Only compute serial if appointment has a start_time (otherwise fallback to day-based)
        if appt.start_time:
            appt_date = appt.start_time.date()
            schedule_row = None
            schedule_start_dt = None
            schedule_end_dt = None
            schedule_max_patients = None

            # 1) Prefer DateRule for that exact date that contains the appointment time
            try:
                drs = (db.query(DateRule)
                         .filter(DateRule.doctor_id == appt.doctor_id,
                                 DateRule.target_date == appt_date,
                                 DateRule.active == True)
                         .all())
            except Exception:
                drs = []

            if drs:
                # find a rule whose time window covers appointment.start_time
                for r in drs:
                    # some DateRule may store start_hour/end_hour; adapt to your schema
                    start_hour = int(getattr(r, "start_hour", 0))
                    start_minute = int(getattr(r, "start_minute", 0) or 0)
                    end_hour = int(getattr(r, "end_hour", start_hour + 1))
                    end_minute = int(getattr(r, "end_minute", 0) or 0)

                    candidate_start = datetime(appt_date.year, appt_date.month, appt_date.day, start_hour, start_minute)
                    candidate_end = datetime(appt_date.year, appt_date.month, appt_date.day, end_hour, end_minute)
                    if candidate_start <= appt.start_time < candidate_end:
                        schedule_row = r
                        schedule_start_dt = candidate_start
                        schedule_end_dt = candidate_end
                        schedule_max_patients = getattr(r, "max_patients", None)
                        break
                if not schedule_row:
                    # fallback to first date rule for that date
                    r = drs[0]
                    start_hour = int(getattr(r, "start_hour", 9))
                    start_minute = int(getattr(r, "start_minute", 0) or 0)
                    end_hour = int(getattr(r, "end_hour", start_hour + 1))
                    end_minute = int(getattr(r, "end_minute", 0) or 0)
                    schedule_row = r
                    schedule_start_dt = datetime(appt_date.year, appt_date.month, appt_date.day, start_hour, start_minute)
                    schedule_end_dt = datetime(appt_date.year, appt_date.month, appt_date.day, end_hour, end_minute)
                    schedule_max_patients = getattr(r, "max_patients", None)

            # 2) If no DateRule matched, fallback to weekly Availability for the weekday
            if not schedule_row:
                try:
                    # Determine weekday index as you store it (this example tries Sun=0..Sat=6 if Availability uses that)
                    # If Availability.day_of_week uses Mon=0..Sun=6 adjust accordingly
                    weekday_mon0 = appt.start_time.weekday()  # Mon=0..Sun=6
                    # Try both conventions: if stored as 0=Sun adjust mapping; adapt to your model.
                    # We'll query both possibilities: day_of_week == weekday_mon0 and day_of_week == (weekday_mon0 + 1)%7
                    dow_candidates = [weekday_mon0, (weekday_mon0 + 1) % 7]
                    avs = (db.query(Availability)
                             .filter(Availability.doctor_id == appt.doctor_id,
                                     Availability.active == True,
                                     Availability.day_of_week.in_(dow_candidates))
                             .all())
                except Exception:
                    avs = []

                if avs:
                    # pick availability that covers appointment start_time
                    for a in avs:
                        start_hour = int(getattr(a, "start_hour", 9))
                        start_minute = int(getattr(a, "start_minute", 0) or 0)
                        end_hour = int(getattr(a, "end_hour", start_hour + 1))
                        end_minute = int(getattr(a, "end_minute", 0) or 0)
                        # build schedule_start for the appointment date (use the appointment date, not rule date)
                        candidate_start = datetime(appt_date.year, appt_date.month, appt_date.day, start_hour, start_minute)
                        candidate_end = datetime(appt_date.year, appt_date.month, appt_date.day, end_hour, end_minute)
                        if candidate_start <= appt.start_time < candidate_end:
                            schedule_row = a
                            schedule_start_dt = candidate_start
                            schedule_end_dt = candidate_end
                            schedule_max_patients = getattr(a, "max_patients", None)
                            break
                    if not schedule_row:
                        a = avs[0]
                        start_hour = int(getattr(a, "start_hour", 9))
                        start_minute = int(getattr(a, "start_minute", 0) or 0)
                        end_hour = int(getattr(a, "end_hour", start_hour + 1))
                        end_minute = int(getattr(a, "end_minute", 0) or 0)
                        schedule_row = a
                        schedule_start_dt = datetime(appt_date.year, appt_date.month, appt_date.day, start_hour, start_minute)
                        schedule_end_dt = datetime(appt_date.year, appt_date.month, appt_date.day, end_hour, end_minute)
                        schedule_max_patients = getattr(a, "max_patients", None)

            # 3) If still not found, fallback to the appointment's own start_time and end_time as a window
            if not schedule_row:
                if appt.end_time:
                    schedule_start_dt = appt.start_time
                    schedule_end_dt = appt.end_time
                else:
                    # default to one-hour window from start
                    schedule_start_dt = appt.start_time
                    schedule_end_dt = appt.start_time + timedelta(hours=1)
                schedule_max_patients = getattr(appt, "max_patients", None) or 1

            # Now compute slot_minutes
            try:
                window_minutes = max(1, int((schedule_end_dt - schedule_start_dt).total_seconds() // 60))
            except Exception:
                window_minutes = 60
            try:
                max_patients = int(schedule_max_patients or 1)
            except Exception:
                max_patients = 1
            if max_patients <= 0:
                max_patients = 1
            slot_minutes = max(1, window_minutes // max_patients)

            # Compute max serial inside this schedule window
            try:
                # Count appointments for same doctor whose start_time falls inside the schedule window
                # We use appointments that already have a serial assigned in that window.
                max_serial = db.query(func.max(Appointment.serial_number)).filter(
                    Appointment.doctor_id == appt.doctor_id,
                    Appointment.start_time >= schedule_start_dt,
                    Appointment.start_time < schedule_end_dt
                ).scalar()
            except Exception:
                max_serial = None

            max_serial = int(max_serial or 0)
            appt.serial_number = max_serial + 1

            # Compute estimated_visit_time from schedule_start_dt
            try:
                offset_min = (appt.serial_number - 1) * slot_minutes
                appt.estimated_visit_time = schedule_start_dt + timedelta(minutes=offset_min)
            except Exception:
                appt.estimated_visit_time = appt.start_time
        else:
            # No start_time, fallback: increment day-wide serial as before
            try:
                date_only = datetime.utcnow().date()
                day_start = datetime(date_only.year, date_only.month, date_only.day)
                day_end = day_start + timedelta(days=1)
                max_serial = db.query(func.max(Appointment.serial_number)).filter(
                    Appointment.doctor_id == appt.doctor_id,
                    Appointment.start_time >= day_start,
                    Appointment.start_time < day_end
                ).scalar() or 0
                appt.serial_number = int(max_serial) + 1
                appt.estimated_visit_time = appt.start_time
            except Exception:
                appt.serial_number = (appt.serial_number or 0) + 1
                appt.estimated_visit_time = appt.start_time

        # Finally mark appointment approved and payment_status if payments exist
        appt.status = AppointmentStatus.approved
        try:
            existing_cnt = db.query(Payment).filter(Payment.appointment_id == appt.id).count()
            if existing_cnt > 0:
                appt.payment_status = PaymentStatus.paid
        except Exception:
            pass

        appt.last_modified_by_user_id = curr.id
        appt.last_modified_at = datetime.utcnow()

        # persist
        try:
            db.commit()
            db.refresh(appt)
        except Exception as e:
            db.rollback()
            raise HTTPException(status_code=500, detail=f"Failed to save appointment: {e}")

        # Optionally notify patient (best-effort)
        try:
            patient_user_id = appt.patient.user_id if appt.patient else None
            if patient_user_id:
                tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == patient_user_id).all()
                tokens = [t.token for t in tokens_q if t and t.token]
                if tokens:
                    title = "Appointment Approved"
                    serial_disp = appt.serial_number or ""
                    when_disp = (appt.estimated_visit_time.strftime("%Y-%m-%d %I:%M %p") if appt.estimated_visit_time else "")
                    body_text = f"Your appointment #{appt.id} has been approved. Serial: {serial_disp}. Est: {when_disp}"
                    data_payload = {
                        "type": "appointment_approved",
                        "appointment_id": str(appt.id),
                        "serial_number": str(serial_disp),
                        "estimated_visit_time": appt.estimated_visit_time.isoformat() if appt.estimated_visit_time else "",
                        "message": body_text,
                    }
                    try:
                        multicast = messaging.MulticastMessage(
                            notification=messaging.Notification(title=title, body=body_text),
                            data={k: str(v) for k, v in data_payload.items()},
                            tokens=list(set(tokens)),
                        )
                        messaging.send_multicast(multicast)
                    except Exception:
                        try:
                            fcm_send_data_tokens(db, tokens, data_payload, ttl_seconds=3600)
                        except Exception:
                            pass
        except Exception:
            pass

    else:
        # Reject flow
        reason = getattr(body, 'reason', None) if hasattr(body, 'reason') else None
        appt.status = AppointmentStatus.rejected
        if reason:
            appt.notes = (appt.notes or "") + ("\n\nREJECTED: " + reason)
        appt.last_modified_by_user_id = curr.id
        appt.last_modified_at = datetime.utcnow()
        try:
            db.commit()
            db.refresh(appt)
        except Exception as e:
            db.rollback()
            raise HTTPException(status_code=500, detail=f"Failed to reject appointment: {e}")

    # Build response similar to earlier behaviour (payments summary, doctor/patient info)
    payments_rows = db.query(Payment).filter(Payment.appointment_id == appt.id).order_by(Payment.paid_at.desc()).all()
    payments_items = []
    payments_total = 0.0
    for p in payments_rows:
        amt = float(p.amount) if (p.amount is not None) else 0.0
        payments_total += amt
        payments_items.append({
            "id": p.id,
            "transaction_id": p.transaction_id,
            "method": p.method,
            "amount": p.amount,
            "status": p.status.value if p.status else None,
            "paid_at": p.paid_at,
            "raw": p.raw,
        })

    doctor_name = None
    doctor_phone = None
    if appt.doctor:
        try:
            doctor_name = appt.doctor.user.name if appt.doctor.user else None
            doctor_phone = appt.doctor.user.phone if appt.doctor.user else None
        except Exception:
            doctor_name = None
            doctor_phone = None

    patient_name = None
    if appt.patient:
        try:
            patient_name = appt.patient.user.name if appt.patient.user else None
        except Exception:
            patient_name = None

    resp = {
        "id": appt.id,
        "doctor_id": appt.doctor_id,
        "patient_id": appt.patient_id,
        "patient_name": patient_name,
        "doctor_name": doctor_name,
        "start_time": appt.start_time,
        "end_time": appt.end_time,
        "status": appt.status.value,
        "payment_status": appt.payment_status.value,
        "visit_mode": appt.visit_mode.value if appt.visit_mode else None,
        "patient_problem": appt.patient_problem,
        "notes": appt.notes,
        "progress": appt.progress.value if appt.progress else None,
        "serial_number": appt.serial_number,
        "estimated_visit_time": appt.estimated_visit_time,
        "payments": {
            "total": payments_total,
            "count": len(payments_items),
            "items": payments_items,
        },
    }

    return resp

# ------------------ New admin payments listing endpoint ------------------
@app.get("/admin/payments", response_model=dict)
def admin_list_payments(
    q: Optional[str] = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(25, ge=1, le=200),
    db: Session = Depends(get_db),
    curr: User = Depends(require_role(UserRole.admin))
):
    """
    Admin listing of payments with simple search (transaction_id, method, patient name/email, appointment id).
    Returns paginated result:
      { ok: true, page, page_size, total, items: [ { id, transaction_id, method, amount, status, paid_at, appointment_id, patient_name, patient_id } ] }
    """
    base = db.query(Payment).join(Appointment, Payment.appointment_id == Appointment.id).join(Patient, Appointment.patient_id == Patient.id).join(User, Patient.user_id == User.id)

    if q:
        q_str = f"%{q.strip().lower()}%"
        # search transaction_id, method, patient name/email, appointment id
        try:
            appt_id_int = int(q.strip())
        except Exception:
            appt_id_int = None

        base = base.filter(
            or_(
                func.lower(Payment.transaction_id).ilike(q_str),
                func.lower(Payment.method).ilike(q_str),
                func.lower(User.name).ilike(q_str),
                func.lower(User.email).ilike(q_str),
                (Payment.appointment_id == appt_id_int) if appt_id_int is not None else text("0=1")
            )
        )

    total = base.count()
    rows = base.order_by(Payment.paid_at.desc()).offset((page - 1) * page_size).limit(page_size).all()

    items = []
    for p in rows:
        appt = p.appointment
        patient_name = ""
        patient_id = None
        if appt and appt.patient:
            patient_id = appt.patient.id
            try:
                patient_name = appt.patient.user.name if appt.patient.user else ""
            except Exception:
                patient_name = ""
        items.append({
            "id": p.id,
            "transaction_id": p.transaction_id,
            "method": p.method,
            "amount": p.amount,
            "status": p.status.value if p.status else None,
            "paid_at": p.paid_at,
            "appointment_id": p.appointment_id,
            "patient_id": patient_id,
            "patient_name": patient_name,
        })

    return {"ok": True, "page": page, "page_size": page_size, "total": total, "items": items}

# -----------------------------------------------------------------------------
# Doctor — Schedules (flexible JSON/Form)
# -----------------------------------------------------------------------------
@app.get("/doctor/schedule", response_model=dict)
def doctor_get_schedule(current: User = Depends(require_role(UserRole.doctor)), db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")

    av = (db.query(Availability)
            .filter(Availability.doctor_id == d.id)
            .order_by(Availability.created_at.desc(), Availability.id.desc())
            .all())

    weekly_rules = [{
        "id": a.id, "dow": a.day_of_week,
        "start": f"{a.start_hour:02d}:00", "end": f"{a.end_hour:02d}:00",
        "start_hour": a.start_hour, "end_hour": a.end_hour, "active": a.active,
        "mode": a.mode, "max_patients": a.max_patients,
        "created_at": a.created_at.isoformat() if a.created_at else None
    } for a in av]

    start = datetime.utcnow().date() - timedelta(days=90)
    end = datetime.utcnow().date() + timedelta(days=90)

    dr = (db.query(DateRule)
            .filter(DateRule.doctor_id == d.id,
                    DateRule.target_date >= start,
                    DateRule.target_date <= end)
            .order_by(DateRule.created_at.desc(), DateRule.id.desc())
            .all())

    date_rules = [{
        "id": r.id, "date": r.target_date.isoformat(),
        "start_hour": r.start_hour, "end_hour": r.end_hour,
        "active": r.active, "mode": r.mode, "max_patients": r.max_patients,
        "created_at": r.created_at.isoformat() if r.created_at else None
    } for r in dr]

    return {"weekly_rules": weekly_rules, "date_rules": date_rules}

@app.post("/doctor/schedule/weekly_set", response_model=dict)
def doctor_weekly_set(
    payload: Optional[WeeklySetIn] = Body(default=None),
    # form fallbacks:
    body: Optional[str] = Form(default=None),                 # JSON string in a form field
    selected_days: Optional[List[int]] = Form(default=None),
    start_hour: Optional[int] = Form(default=None),
    end_hour: Optional[int] = Form(default=None),
    max_patients: Optional[int] = Form(default=None),
    visit_mode: Optional[str] = Form(default=None),
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")

    # 1) Proper JSON body
    if payload is None:
        # 2) 'body' form field contains a JSON string
        if body:
            import json
            try:
                obj = json.loads(body)
                payload = WeeklySetIn(**obj)
            except Exception as e:
                raise HTTPException(422, f"Invalid JSON in form field 'body': {e}")

    # 3) Build from individual form fields
    if payload is None:
        if selected_days is None or start_hour is None or end_hour is None:
            raise HTTPException(422, "selected_days, start_hour, end_hour are required")
        payload = WeeklySetIn(
            selected_days=[int(x) for x in selected_days],  # Mon=0..Sun=6
            start_hour=int(start_hour),
            end_hour=int(end_hour),
            max_patients=int(max_patients or 4),
            visit_mode=(visit_mode or "offline"),
        )

    # Disable existing rules for those DOWs, then upsert the window
    db.query(Availability).filter(
        Availability.doctor_id == d.id,
        Availability.day_of_week.in_([(x + 1) % 7 for x in payload.selected_days])  # convert Mon0→Sun0
    ).update({"active": False}, synchronize_session=False)

    for dow_mon0 in payload.selected_days:
        dow_sun0 = (dow_mon0 + 1) % 7
        a = (db.query(Availability)
               .filter(Availability.doctor_id == d.id,
                       Availability.day_of_week == dow_sun0,
                       Availability.start_hour == payload.start_hour,
                       Availability.end_hour == payload.end_hour)
               .first())
        if not a:
            a = Availability(
                doctor_id=d.id, day_of_week=dow_sun0,
                start_hour=payload.start_hour, end_hour=payload.end_hour,
                max_patients=payload.max_patients, mode=payload.visit_mode, active=True
            )
            db.add(a)
        else:
            a.active = True
            a.max_patients = payload.max_patients
            a.mode = payload.visit_mode

    db.commit()
    return {"ok": True}

@app.post("/doctor/schedule/date_rule", response_model=dict)
async def doctor_add_date_rule_flexible(
    request: Request,
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")

    # Try JSON first (regardless of Content-Type)
    payload: Optional[DateRuleIn] = None
    raw_bytes = await request.body()
    if raw_bytes:
        import json
        try:
            raw_json = json.loads(raw_bytes)
            if isinstance(raw_json, dict):
                payload = DateRuleIn(**raw_json)
        except Exception:
            pass

    # Fall back to form
    if payload is None:
        form = await request.form()
        dates_list: List[str] = []
        if "dates" in form:
            vals = form.getlist("dates")
            if len(vals) == 1 and "," in vals[0]:
                dates_list = [s.strip() for s in vals[0].split(",") if s.strip()]
            else:
                dates_list = [str(v) for v in vals]
        elif "dates_json" in form:
            import json
            dj = form.get("dates_json")
            try:
                v = json.loads(dj)
                dates_list = [str(x) for x in (v if isinstance(v, list) else [v])]
            except Exception:
                dates_list = [s.strip() for s in str(dj).split(",") if s.strip()]

        def to_int(val, alt=None):
            try:
                return int(val)
            except Exception:
                return alt

        start_hour = to_int(form.get("start_hour"))
        end_hour = to_int(form.get("end_hour"))
        if start_hour is None and form.get("start"):
            try:
                start_hour = int(str(form.get("start")).split(":")[0])
            except Exception:
                pass
        if end_hour is None and form.get("end"):
            try:
                end_hour = int(str(form.get("end")).split(":")[0])
            except Exception:
                pass

        if not dates_list or start_hour is None or end_hour is None:
            raise HTTPException(422, "dates, start_hour, end_hour are required")

        payload = DateRuleIn(
            dates=dates_list,
            start_hour=start_hour,
            end_hour=end_hour,
            mode=str(form.get("mode") or "offline"),
            max_patients=to_int(form.get("max_patients"), 4),
            active=str(form.get("active", "true")).lower() in ("true", "1", "yes", "on"),
        )

    # Create rows safely
    try:
        rows = db.execute(text("PRAGMA table_info(date_rules)")).mappings().all()
        cols = {r["name"] for r in rows}
        legacy_has_day = "day" in cols

        created = []
        for s in payload.dates:
            try:
                day = datetime.fromisoformat(str(s)).date()
            except Exception:
                raise HTTPException(400, f"Bad date format (expected YYYY-MM-DD): {s}")

            sh = int(payload.start_hour if payload.start_hour is not None else 9)
            eh = int(payload.end_hour if payload.end_hour is not None else 17)

            if legacy_has_day:
                from sqlalchemy import text as sql_text
                db.execute(
                    sql_text("""
                        INSERT INTO date_rules
                        (doctor_id, target_date, start_hour, end_hour, max_patients, active, mode, created_at, day)
                        VALUES (:doctor_id, :target_date, :start_hour, :end_hour, :max_patients, :active, :mode, :created_at, :day)
                    """),
                    {
                        "doctor_id": d.id,
                        "target_date": day.isoformat(),
                        "start_hour": sh,
                        "end_hour": eh,
                        "max_patients": int(payload.max_patients or 4),
                        "active": 1 if payload.active else 0,
                        "mode": (payload.mode or "offline"),
                        "created_at": datetime.utcnow().isoformat(sep=" "),
                        "day": day.isoformat(),
                    }
                )
            else:
                row = DateRule(
                    doctor_id=d.id,
                    target_date=day,
                    start_hour=sh,
                    end_hour=eh,
                    max_patients=int(payload.max_patients or 4),
                    active=bool(payload.active),
                    mode=(payload.mode or "offline"),
                )
                db.add(row)

            created.append({"date": day.isoformat(), "start_hour": sh, "end_hour": eh})

        db.commit()
        return {"ok": True, "created": created}
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Could not create date rules: {e}")


@app.patch("/doctor/schedule/date_rule/{rule_id}", response_model=dict)
async def doctor_update_date_rule(
    rule_id: int,
    request: Request,
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")
    r = db.get(DateRule, rule_id)
    if not r or r.doctor_id != d.id:
        raise HTTPException(404, "Rule not found")

    # Parse JSON first (regardless of content-type)
    data = {}
    raw = await request.body()
    if raw:
        import json
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                data = obj
        except Exception:
            data = {}

    # If no JSON, fall back to form
    if not data:
        form = await request.form()
        data = dict(form)

    def _to_int(x):
        try:
            return int(x)
        except Exception:
            return None

    def _hh_to_int(s):
        if s is None:
            return None
        try:
            return int(str(s).split(":")[0])
        except Exception:
            return None

    sh = data.get("start_hour")
    eh = data.get("end_hour")
    st = data.get("start")
    en = data.get("end")

    new_sh = _to_int(sh)
    new_eh = _to_int(eh)
    if new_sh is None and st is not None:
        new_sh = _hh_to_int(st)
    if new_eh is None and en is not None:
        new_eh = _hh_to_int(en)

    if new_sh is not None:
        r.start_hour = new_sh
    if new_eh is not None:
        r.end_hour = new_eh

    if "max_patients" in data:
        v = _to_int(data.get("max_patients"))
        if v is not None:
            r.max_patients = v

    if "mode" in data and data.get("mode") is not None:
        r.mode = str(data.get("mode"))

    if "active" in data and data.get("active") is not None:
        val = str(data.get("active")).lower()
        r.active = val in ("true", "1", "yes", "on")

    db.commit()
    return {"ok": True}

@app.post("/doctor/schedule/toggle", response_model=dict)
def doctor_toggle_rule(
    item_id: int = Form(...),
    kind: str = Form(...),        # 'weekly' | 'dated'
    active: bool = Form(...),
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    if kind == "weekly":
        row = db.get(Availability, item_id)
    else:
        row = db.get(DateRule, item_id)
    if not row or getattr(row, "doctor_id", None) != d.id:
        raise HTTPException(404, "Rule not found")
    row.active = bool(active)
    db.commit()
    return {"ok": True}

@app.delete("/doctor/schedule/weekly/{availability_id}", response_model=dict)
def doctor_delete_weekly_rule(
    availability_id: int,
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")
    row = db.get(Availability, availability_id)
    if not row or row.doctor_id != d.id:
        raise HTTPException(404, "Weekly rule not found")
    db.delete(row)
    db.commit()
    return {"ok": True, "deleted": availability_id}

@app.delete("/doctor/schedule/date_rule/{rule_id}", response_model=dict)
def doctor_delete_date_rule(
    rule_id: int,
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")
    row = db.get(DateRule, rule_id)
    if not row or row.doctor_id != d.id:
        raise HTTPException(404, "Date rule not found")
    db.delete(row)
    db.commit()
    return {"ok": True, "deleted": rule_id}

# -----------------------------------------------------------------------------
# Doctor — other endpoints
# -----------------------------------------------------------------------------
@app.get("/doctor/availability", response_model=List[dict])
def doctor_get_availability(current: User = Depends(require_role(UserRole.doctor)),
                            db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    items = (db.query(Availability).filter(Availability.doctor_id == d.id).order_by(Availability.day_of_week).all())
    out = []
    for a in items:
        out.append({
            "id": a.id, "day_of_week": a.day_of_week,
            "start_hour": a.start_hour, "end_hour": a.end_hour,
            "max_patients": a.max_patients, "active": a.active, "mode": a.mode,
        })
    return out

@app.post("/doctor/availability", response_model=dict)
def doctor_set_availability(body: AvailabilityIn, current: User = Depends(require_role(UserRole.doctor)),
                            db: Session = Depends(get_db)):
    doc = current.doctor_profile
    if not doc: raise HTTPException(400, "Doctor profile missing")
    a = Availability(doctor_id=doc.id, day_of_week=body.day_of_week,
                     start_hour=body.start_hour, end_hour=body.end_hour,
                     max_patients=body.max_patients, active=body.active, mode=body.mode or "offline")
    db.add(a); db.commit(); db.refresh(a)
    return {"ok": True, "id": a.id}

@app.get("/doctor/appointments", response_model=List[AppointmentOut])
def doctor_appointments(
    day: Optional[dt_date] = None,
    view: Optional[str] = None,
    final_only: Optional[int] = None,
    status: Optional[AppointmentStatus] = None,
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db)
):
    doc = current.doctor_profile
    if not doc: raise HTTPException(400, "Doctor profile missing")
    q = db.query(Appointment).filter(Appointment.doctor_id == doc.id)
    if status: q = q.filter(Appointment.status == status)
    items = q.order_by(Appointment.start_time.desc()).all()

    if day:
        items = [a for a in items if a.start_time.date() == day]
    if view:
        now = datetime.utcnow()
        def include(a: Appointment) -> bool:
            if view == "today":
                return a.start_time.date() == (day or datetime.utcnow().date())
            if view == "upcoming":
                return a.end_time >= now and a.status != AppointmentStatus.cancelled
            if view == "pending":
                done = (a.progress in (AppointmentProgress.completed, AppointmentProgress.no_show)) or a.status == AppointmentStatus.cancelled
                return (not done) and a.end_time >= now
            if view == "completed":
                return a.progress == AppointmentProgress.completed
            return True
        items = [a for a in items if include(a)]
    if final_only:
        pass

    return [
        AppointmentOut(
            id=a.id,
            doctor_id=a.doctor_id,
            patient_id=a.patient_id,
            start_time=a.start_time,
            end_time=a.end_time,
            status=a.status,
            payment_status=a.payment_status,
            visit_mode=a.visit_mode,
            patient_problem=a.patient_problem,
            notes=a.notes,
            video_room=a.video_room,
            progress=a.progress,
            completed_at=a.completed_at,
            doctor_name=(a.doctor.user.name if a.doctor and a.doctor.user else ""),
            patient_name=(a.patient.user.name if a.patient and a.patient.user else "")
        )
        for a in items
    ]


@app.get("/doctor/patients", response_model=List[dict])
def doctor_patients(q: Optional[str] = None,
                    current: User = Depends(require_role(UserRole.doctor)),
                    db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    appts = (db.query(Appointment).filter(Appointment.doctor_id == d.id).all())
    seen = {}
    for a in appts:
        p = a.patient
        u = p.user if p else None
        if not p or not u: continue
        key = p.id
        if key not in seen:
            seen[key] = {
                "patient_id": p.id,
                "name": u.name,
                "email": u.email,
                "phone": u.phone,
                "last_appointment_id": a.id,
            }
        else:
            if a.start_time > db.get(Appointment, seen[key]["last_appointment_id"]).start_time:
                seen[key]["last_appointment_id"] = a.id
    items = list(seen.values())
    if q:
        qs = q.lower()
        items = [i for i in items if
                 (i["name"] or "").lower().find(qs) >= 0 or
                 (i["email"] or "").lower().find(qs) >= 0 or
                 (i["phone"] or "").lower().find(qs) >= 0]
    return items

@app.get("/doctor/patient_history/{appointment_id}", response_model=dict)
def doctor_patient_history(appointment_id: int,
                           current: User = Depends(require_role(UserRole.doctor)),
                           db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if appt.doctor.user_id != current.id: raise HTTPException(403, "Not your appointment")
    p = appt.patient
    reports = [{"id": r.id, "name": r.original_name, "uploaded_at": r.uploaded_at.isoformat(), "file_path": r.file_path}
               for r in (p.reports if p else [])]
    presc = None
    if appt.prescription:
        presc = {"id": appt.prescription.id, "content": appt.prescription.content, "file_path": appt.prescription.file_path}
    return {
        "appointment_id": appt.id,
        "patient_id": p.id if p else None,
        "patient_name": p.user.name if (p and p.user) else "",
        "profile": {
            "age": p.age if p else None, "weight": p.weight if p else None, "height": p.height if p else None,
            "blood_group": p.blood_group if p else None, "gender": p.gender if p else None,
            "description": p.description if p else "", "current_medicine": p.current_medicine if p else "",

            "medical_history": p.medical_history if p else ""
        },
        "medical_reports": reports,
        "current_appointment_prescription": presc,
    }

# -----------------------------------------------------------------------------
# Public / Patient
# -----------------------------------------------------------------------------
@app.get("/doctors", response_model=List[DoctorOut])
def list_doctors(q: Optional[str] = None, category: Optional[str] = None, db: Session = Depends(get_db)):
    qry = db.query(Doctor).join(User)
    if q:
        like = f"%{q.lower()}%"
        qry = qry.filter(or_(Doctor.specialty.ilike(like),
                             Doctor.keywords.ilike(like),
                             User.name.ilike(like),
                             Doctor.bio.ilike(like)))
    if category:
        qry = qry.filter(Doctor.category.ilike(f"%{category}%"))
    docs = qry.all()
    out: List[DoctorOut] = []
    for d in docs:
        u = d.user
        out.append(DoctorOut(
            id=d.id, name=(u.name if u else ""), email=(u.email if u else None),
            specialty=d.specialty, category=d.category, keywords=d.keywords,
            bio=d.bio, background=d.background, phone=(u.phone if u else None),
            address=d.address, visiting_fee=d.visiting_fee, rating=d.rating,
            photo_path=(u.photo_path if u else None)
        ))
    return out

# Rich browse for Flutter list (fast + precise)
@app.get("/doctors/browse", response_model=List[dict])
def browse_doctors(
    q: Optional[str] = None,
    specialty: Optional[str] = None,
    visit_mode: Optional[str] = Query(None, pattern="^(online|offline|any)$"),
    day: Optional[dt_date] = None,
    available_from: Optional[dt_date] = None,
    available_to: Optional[dt_date] = None,
    available_only: int = 0,
    db: Session = Depends(get_db),
):

    # Build base query (push text search to SQL)
    qry = db.query(Doctor).join(User)
    if q:
        like = f"%{q.lower()}%"
        qry = qry.filter(or_(
            User.name.ilike(like),
            Doctor.specialty.ilike(like),
            Doctor.keywords.ilike(like),
            Doctor.bio.ilike(like),
        ))
    if specialty:
        qry = qry.filter(Doctor.specialty.ilike(f"%{specialty}%"))

    docs: List[Doctor] = qry.all()

    #  Window
    if day:
        start_d = end_d = day
    else:
        start_d = available_from or datetime.utcnow().date()
        end_d = available_to or (start_d + timedelta(days=30))
        if end_d < start_d:
            start_d, end_d = end_d, start_d

    # Build payload with earliest dates per mode 
    out: List[dict] = []
    for d in docs:
        # earliest per mode
        next_online = _first_available_date(db, d.id, start_d, end_d, "online")
        next_offline = _first_available_date(db, d.id, start_d, end_d, "offline")

        # honor visit_mode + available_only
        if visit_mode == "online":
            if available_only and not next_online:
                continue
        elif visit_mode == "offline":
            if available_only and not next_offline:
                continue
        else:  # any
            if available_only and not (next_online or next_offline):
                continue

        out.append({
            "id": d.id,
            "name": d.user.name if d.user else "",
            "email": d.user.email if d.user else None,
            "specialty": d.specialty,
            "category": d.category,
            "keywords": d.keywords,
            "bio": d.bio,
            "background": d.background,
            "rating": d.rating,
            "photo_path": d.user.photo_path if d.user else None,
            # availability summary (most recent dates)
            "next_online": next_online.isoformat() if next_online else None,
            "next_offline": next_offline.isoformat() if next_offline else None,
            # quick flags for client
            "has_online": bool(next_online),
            "has_offline": bool(next_offline),
        })

    # Sort: earliest presence first (any mode), then by name
    def _sort_key(m):
        def dparse(x):
            return datetime.fromisoformat(x).date() if x else date.max
        return (min(dparse(m["next_online"]), dparse(m["next_offline"])), m["name"].lower())
    out.sort(key=_sort_key)
    return out

# Add near your public routes in FastAPI
@app.get("/doctors/{doctor_id}/education", response_model=List[DoctorEduOut])
def list_doctor_education(doctor_id: int, db: Session = Depends(get_db)):
    d = db.get(Doctor, doctor_id)
    if not d: raise HTTPException(404, "Doctor not found")
    rows = (
        db.query(DoctorEducation)
          .filter(DoctorEducation.doctor_id == doctor_id)
          .order_by(DoctorEducation.year.desc().nullslast(), DoctorEducation.id.desc())
          .all()
    )
    return [DoctorEduOut(id=r.id, degree=r.degree, institute=r.institute, year=r.year) for r in rows]

# -----------------------------------------------------------------------------
# Search helpers for public browse
# -----------------------------------------------------------------------------
def _first_available_date(db: Session, doctor_id: int, start_d: dt_date, end_d: dt_date, mode: Optional[str]) -> Optional[dt_date]:

    d = start_d
    # safety
    scans = 0
    while d <= end_d and scans < 120:
        scans += 1
        blocks = gen_blocks_for_date(db, doctor_id, d, mode)
        if blocks:
            return d
        d += timedelta(days=1)
    return None

@app.get("/doctors/{doctor_id}", response_model=DoctorOut)
def doctor_profile(doctor_id: int, db: Session = Depends(get_db)):
    d = db.get(Doctor, doctor_id)
    if not d: raise HTTPException(404, "Doctor not found")
    u = d.user
    return DoctorOut(
        id=d.id, name=(u.name if u else ""), email=(u.email if u else None),
        specialty=d.specialty, category=d.category, keywords=d.keywords,
        bio=d.bio, background=d.background, phone=(u.phone if u else None),
        address=d.address, visiting_fee=d.visiting_fee, rating=d.rating,
        photo_path=(u.photo_path if u else None)
    )

# hourly slots (kept for compatibility), filtered by visit_mode if provided
@app.get("/doctors/{doctor_id}/slots", response_model=List[str])
def doctor_slots_for_date(
    doctor_id: int,
    day: dt_date = Query(..., description="YYYY-MM-DD"),
    visit_mode: Optional[str] = Query(None),
    db: Session = Depends(get_db),
):
    if not db.get(Doctor, doctor_id): raise HTTPException(404, "Doctor not found")
    if visit_mode not in (None, "online", "offline"):
        raise HTTPException(400, "visit_mode must be 'online' or 'offline'")
    out: List[str] = []
    for (st, en) in gen_blocks_for_date(db, doctor_id, day, visit_mode):
        h = st.hour
        while True:
            h_st = datetime(day.year, day.month, day.day, h)
            h_en = h_st + timedelta(hours=1)
            if h_en > en:
                break
            if slot_capacity_left(db, doctor_id, h_st, h_en) > 0:
                out.append(h_st.isoformat())
            h += 1
    return out

# raw blocks for the day (new)
@app.get("/doctors/{doctor_id}/blocks", response_model=List[dict])
def doctor_blocks_for_date(
    doctor_id: int,
    day: dt_date = Query(..., description="YYYY-MM-DD"),
    visit_mode: Optional[str] = Query(None),
    db: Session = Depends(get_db),
):
    if not db.get(Doctor, doctor_id): raise HTTPException(404, "Doctor not found")
    if visit_mode not in (None, "online", "offline"):
        raise HTTPException(400, "visit_mode must be 'online' or 'offline'")
    blocks = gen_blocks_for_date(db, doctor_id, day, visit_mode)
    return [{"start": st.isoformat(), "end": en.isoformat()} for (st, en) in blocks]

# book appointment (JSON)
@app.post("/appointments", response_model=AppointmentOut)
def request_appointment(payload: AppointmentIn, db: Session = Depends(get_db),
                        current: User = Depends(require_role(UserRole.patient))):
    p = current.patient_profile
    if not p: raise HTTPException(400, "Patient profile missing")
    if slot_capacity_left(db, payload.doctor_id, payload.start_time, payload.end_time) <= 0:
        raise HTTPException(400, "Selected slot is not available")
    appt = Appointment(patient_id=p.id, doctor_id=payload.doctor_id,
                       start_time=payload.start_time, end_time=payload.end_time,
                       status=AppointmentStatus.requested, payment_status=PaymentStatus.pending,
                       visit_mode=payload.visit_mode, patient_problem=payload.patient_problem or "",
                       last_modified_by_user_id=current.id, last_modified_at=datetime.utcnow())
    db.add(appt); db.commit(); db.refresh(appt)
    return appt

@app.post("/appointments/request_multipart", response_model=AppointmentOut)
def request_appointment_multipart(
    doctor_id: int = Form(...),
    start_time: str = Form(...),
    end_time: str = Form(...),
    visit_mode: VisitMode = Form(VisitMode.offline),
    patient_problem: str = Form(""),
    disease_photo: UploadFile = File(None),
    current: User = Depends(require_role(UserRole.patient)),
    db: Session = Depends(get_db),
):
    st, et = datetime.fromisoformat(start_time), datetime.fromisoformat(end_time)
    p = current.patient_profile
    if not p: raise HTTPException(400, "Patient profile missing")
    if slot_capacity_left(db, doctor_id, st, et) <= 0:
        raise HTTPException(400, "Selected slot is not available")
    path = None
    if disease_photo is not None:
        fname = f"dis_{current.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{disease_photo.filename}"
        path = os.path.join("uploads", fname)
        with open(path, "wb") as f: f.write(disease_photo.file.read())
    appt = Appointment(patient_id=p.id, doctor_id=doctor_id, start_time=st, end_time=et,
                       status=AppointmentStatus.requested, payment_status=PaymentStatus.pending,
                       visit_mode=visit_mode, patient_problem=patient_problem or "", disease_photo_path=path,
                       last_modified_by_user_id=current.id, last_modified_at=datetime.utcnow())
    db.add(appt); db.commit(); db.refresh(appt)
    return appt

# appointment detail
@app.get("/appointments/{appointment_id}", response_model=dict)
def get_appointment(appointment_id: int, current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    a = db.get(Appointment, appointment_id)
    if not a:
        raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.doctor and a.doctor and a.doctor.user_id == current.id)
        or (current.role == UserRole.patient and a.patient and a.patient.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    # Build payments list and total
    rows = db.query(Payment).filter(Payment.appointment_id == appointment_id).order_by(Payment.paid_at.desc()).all()
    payments = []
    payments_total = 0.0
    for p in rows:
        amt = float(p.amount) if (p.amount is not None) else 0.0
        payments_total += amt
        payments.append({
            "id": p.id,
            "transaction_id": p.transaction_id,
            "method": p.method,
            "amount": p.amount,
            "status": p.status.value if p.status else None,
            "paid_at": p.paid_at,
            "raw": p.raw,
        })

    return {
        "id": a.id,
        "doctor_id": a.doctor_id,
        "patient_id": a.patient_id,
        "patient_name": a.patient.user.name if a.patient and a.patient.user else "",
        "doctor_name": a.doctor.user.name if a.doctor and a.doctor.user else "",
        "start_time": a.start_time,
        "end_time": a.end_time,
        "status": a.status.value,
        "payment_status": a.payment_status.value,
        "visit_mode": a.visit_mode.value,
        "patient_problem": a.patient_problem,
        "notes": a.notes,
        "video_room": a.video_room,
        "progress": a.progress.value,
        "completed_at": a.completed_at,
        # NEW: serial and estimated visiting time
        "serial_number": a.serial_number,
        "estimated_visit_time": a.estimated_visit_time,
        # payments summary
        "payments": {"total": payments_total, "count": len(payments), "items": payments},
        "doctor": {
            "name": a.doctor.user.name if a.doctor and a.doctor.user else "",
            "phone": (a.doctor.user.phone if a.doctor and a.doctor.user else None),
            "address": (a.doctor.address if a.doctor else None),
            "visiting_fee": (a.doctor.visiting_fee if a.doctor else None),
            "photo_path": a.doctor.user.photo_path if a.doctor and a.doctor.user else None,
        },
        "contact": {
            "doctor_phone": (a.doctor.user.phone if a.doctor and a.doctor.user else None),
            "doctor_address": (a.doctor.address or "") if a.doctor else "",
            "hospital_hotline": HOSPITAL_HOTLINE,
        },
    }

# payments - mark paid
@app.post("/appointments/{appointment_id}/pay", response_model=dict)
async def pay_for_appointment(
    appointment_id: int,
    request: Request,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    if not ((current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id) or current.role == UserRole.admin):
        raise HTTPException(403, "Forbidden")

    # Parse JSON first
    body: Optional[PaymentIn] = None
    raw = await request.body()
    if raw:
        import json
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                body = PaymentIn(**obj)
        except Exception:
            body = None

    # Fallback to form
    if body is None:
        form = await request.form()
        tx = (form.get("transaction_id") or "").strip()
        method = (form.get("method") or "").strip()
        amount_raw = form.get("amount")
        raw_field = form.get("raw") or ""
        amount_val: Optional[float] = None
        if amount_raw is not None and amount_raw != "":
            try:
                amount_val = float(amount_raw)
            except Exception:
                amount_val = None

        # If cash, transaction_id may be empty; else require tx+method.
        if not method:
            raise HTTPException(422, "method is required")
        method_lower = method.lower()
        if method_lower != "cash" and not tx:
            raise HTTPException(422, "transaction_id is required for non-cash payments")

        # For cash with missing tx, generate one so DB not-null constraint satisfied
        if method_lower == "cash" and not tx:
            tx = f"CASH-{secrets.token_urlsafe(6)}"

        body = PaymentIn(
            transaction_id=str(tx),
            method=str(method),
            amount=amount_val,
            raw=str(raw_field or ""),
        )

    # At this point body.method must be present
    method_lower = (body.method or "").strip().lower()
    tx_val = (body.transaction_id or "").strip()

    # For non-cash methods, transaction_id is mandatory
    if method_lower != "cash" and not tx_val:
        raise HTTPException(422, "transaction_id is required for non-cash payments")

    # For cash, generate if not provided
    if method_lower == "cash" and not tx_val:
        tx_val = f"CASH-{secrets.token_urlsafe(6)}"

    # Append a new Payment row (do not overwrite existing)
    try:
        pay = Payment(
            appointment_id=appointment_id,
            transaction_id=tx_val,
            method=body.method,
            amount=body.amount,
            status=PaymentStatus.paid,
            paid_at=datetime.utcnow(),
            raw=body.raw or "",
        )
        db.add(pay)

        # mark appointment paid (business rule)
        appt.payment_status = PaymentStatus.paid
        appt.last_modified_by_user_id = current.id
        appt.last_modified_at = datetime.utcnow()

        db.commit()
        db.refresh(pay)
        db.refresh(appt)
        return {"ok": True, "payment_id": pay.id}
    except Exception as e:
        db.rollback()
        raise HTTPException(500, f"Failed to record payment: {e}")

# near other endpoints in app.py
import traceback
from fastapi import Body

@app.post("/me/device_token")
def me_device_token(payload: dict = Body(...),
                    db: Session = Depends(get_db),
                    current_user: User = Depends(get_current_user)):
    """
    Register or refresh a device token for the logged-in user.
    Caller must be authenticated (current_user).
    """
    token = (payload.get("token") or "").strip()
    platform = payload.get("platform") or ("web" if kIsWeb else "android")

    if not token:
        raise HTTPException(status_code=400, detail="token is required")

    try:
        # upsert token for this user
        existing = db.query(DeviceToken).filter(
            DeviceToken.user_id == current_user.id,
            DeviceToken.token == token
        ).first()

        now = datetime.utcnow()
        if existing:
            existing.last_seen_at = now
            existing.platform = platform
        else:
            dt = DeviceToken(
                user_id=current_user.id,
                token=token,
                platform=platform,
                created_at=now,
                last_seen_at=now
            )
            db.add(dt)

        db.commit()
        return {"ok": True}
    except Exception as e:
        db.rollback()
        # print stacktrace to server logs (very helpful when debugging 500)
        print("me/device_token error:", e)
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="failed to save device token")


@app.get("/appointments/{appointment_id}/payment", response_model=dict)
def get_payment_for_appointment(
    appointment_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    rows = db.query(Payment).filter(Payment.appointment_id == appointment_id).order_by(Payment.paid_at.desc()).all()
    items = []
    total = 0.0
    for p in rows:
        amt = float(p.amount) if (p.amount is not None) else 0.0
        total += amt
        items.append({
            "id": p.id,
            "transaction_id": p.transaction_id,
            "method": p.method,
            "amount": p.amount,
            "status": p.status.value if p.status else "paid",
            "paid_at": p.paid_at,
            "raw": p.raw,
        })

    return {"ok": True, "payment_status": appt.payment_status.value, "total": total, "count": len(items), "items": items}

# ---- Payments listing (patient) + PDF receipt --------------------------------
from fastapi import Query as _Query  # avoid name clash

try:
    # Pretty PDF if installed 
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    _HAS_RL = True
except Exception:
    _HAS_RL = False

def _ensure_can_view_payment(current: User, pay: Payment) -> None:
    appt = pay.appointment
    if not appt:
        raise HTTPException(404, "Appointment not found for this payment")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

def _human(dt: Optional[datetime]) -> str:
    if not dt:
        return ""
    try:
        return dt.strftime("%Y %b %d • %-I:%M %p")
    except Exception:
        return dt.strftime("%Y %b %d • %I:%M %p").lstrip("0")

import os
from io import BytesIO
from typing import Any, Iterable, Optional

from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.graphics.barcode.code128 import Code128
from reportlab.lib.utils import simpleSplit


# ---------- Fonts ----------
_FONT_READY = False

def _register_fonts():
    global _FONT_READY
    if _FONT_READY:
        return

    base = os.path.join(os.getcwd(), "assets", "fonts")
    regular = os.path.join(base, "DejaVuSans.ttf")
    bold = os.path.join(base, "DejaVuSans-Bold.ttf")
    mono = os.path.join(base, "DejaVuSansMono.ttf")
    emoji = os.path.join(base, "NotoEmoji-Regular.ttf")

    try:
        if os.path.exists(regular):
            pdfmetrics.registerFont(TTFont("DV", regular))
        if os.path.exists(bold):
            pdfmetrics.registerFont(TTFont("DVB", bold))
        if os.path.exists(mono):
            pdfmetrics.registerFont(TTFont("DVM", mono))
        if os.path.exists(emoji):
            pdfmetrics.registerFont(TTFont("EMJ", emoji))
    except Exception:
        pass

    _FONT_READY = True

def _font(name: str) -> str:
    regs = set(pdfmetrics.getRegisteredFontNames())
    if name in regs:
        return name
    return {"DV": "Helvetica", "DVB": "Helvetica-Bold", "DVM": "Courier"}.get(name, "Helvetica")


# ---------- Helpers ----------
def _safe_enum_value(x: Any) -> str:
    if x is None:
        return ""
    try:
        return x.value if hasattr(x, "value") else str(x)
    except Exception:
        return ""

def _get_name(obj: Any) -> str:
    """SQLAlchemy-friendly: obj.name -> obj.user.name -> obj.profile.name"""
    if obj is None:
        return ""
    for getter in (
        lambda o: getattr(o, "name", None),
        lambda o: getattr(getattr(o, "user", None), "name", None),
        lambda o: getattr(getattr(o, "profile", None), "name", None),
    ):
        try:
            v = getter(obj)
            if isinstance(v, str) and v.strip():
                return v.strip()
        except Exception:
            pass
    return ""

def _titleize(s: str) -> str:
    s = (s or "").strip()
    if not s:
        return ""
    if any(ch.isupper() for ch in s[1:]):
        return s
    return " ".join(w.capitalize() for w in s.replace("_", " ").split())

def _get_original_app_name(default: str = "RxMeet") -> str:
    """
    Priority:
      1) Django settings
      2) Env vars
      3) Project folder name
      4) Default
    """
    # Django settings (if available)
    try:
        from django.conf import settings  # type: ignore
        for key in (
            "APP_DISPLAY_NAME",
            "APP_NAME",
            "SITE_NAME",
            "PROJECT_NAME",
            "BRAND_NAME",
            "APPLICATION_NAME",
        ):
            v = getattr(settings, key, None)
            if isinstance(v, str) and v.strip():
                return _titleize(v)
    except Exception:
        pass

    # Env vars
    for key in (
        "APP_DISPLAY_NAME",
        "APP_NAME",
        "SITE_NAME",
        "PROJECT_NAME",
        "BRAND_NAME",
        "APPLICATION_NAME",
    ):
        v = os.getenv(key)
        if v and v.strip():
            return _titleize(v)

    # Folder name (often the real app name)
    try:
        folder = os.path.basename(os.getcwd())
        if folder and folder.strip():
            return _titleize(folder)
    except Exception:
        pass

    return _titleize(default) if default else "RxMeet"

def _date_only(dt: Any) -> str:
    try:
        if dt is None:
            return "—"
        if hasattr(dt, "date"):
            d = dt.date()
        else:
            d = dt
        return d.strftime("%d %b %Y")
    except Exception:
        return "—"

def _time_only(dt: Any) -> str:
    try:
        if dt is None:
            return ""
        s = dt.strftime("%I:%M %p").lstrip("0")
        return s
    except Exception:
        return ""

def _time_range_only(start: Any, end: Any) -> str:
    s = _time_only(start)
    e = _time_only(end)
    if s and e:
        return f"{s} – {e}"
    if s:
        return s
    return "—"

def _draw_wrapped(
    c: canvas.Canvas,
    text: str,
    x: float,
    y: float,
    max_w: float,
    font: str,
    size: int,
    leading: float,
) -> float:
    c.setFont(font, size)
    lines = simpleSplit(text or "", font, size, max_w)
    for ln in lines:
        c.drawString(x, y, ln)
        y -= leading
    return y

def _kv_block(
    c: canvas.Canvas,
    x: float,
    y: float,
    w: float,
    title: str,
    rows: list[tuple[str, str]],
    *,
    bold_value_keys: Optional[Iterable[str]] = None,
) -> float:
    pad = 10
    header_h = 22
    row_gap = 10
    label_w = 150
    value_w = w - pad * 2 - label_w - 10

    font_label = _font("DVB")
    font_value = _font("DV")
    font_value_bold = _font("DVB")
    size_label = 9
    size_value = 10
    leading = 13

    bold_set = set(bold_value_keys or [])

    # estimate height
    h = header_h + pad
    for _, v in rows:
        vv = v or "—"
        v_lines = simpleSplit(vv, font_value, size_value, value_w)
        h += max(leading * len(v_lines), leading) + 2
    h += pad

    c.setStrokeColor(colors.HexColor("#E6E8EC"))
    c.setFillColor(colors.white)
    c.roundRect(x, y - h, w, h, 10, stroke=1, fill=1)

    c.setFillColor(colors.HexColor("#F6F7F9"))
    c.roundRect(x, y - header_h, w, header_h, 10, stroke=0, fill=1)

    c.setFillColor(colors.HexColor("#111827"))
    c.setFont(_font("DVB"), 11)
    c.drawString(x + pad, y - 15, title)

    yy = y - header_h - 14
    for k, v in rows:
        c.setFillColor(colors.HexColor("#6B7280"))
        c.setFont(font_label, size_label)
        c.drawString(x + pad, yy, k)

        vv = (v.strip() if isinstance(v, str) and v.strip() else "—")
        use_font = font_value_bold if k in bold_set else font_value

        c.setFillColor(colors.HexColor("#111827"))
        yy2 = _draw_wrapped(
            c, vv, x + pad + label_w, yy, value_w, use_font, size_value, leading
        )
        yy = yy2 - 2

    return y - h - row_gap


def _render_receipt_pdf(pay: "Payment") -> bytes:
    _register_fonts()

    appt = getattr(pay, "appointment", None)
    doctor = getattr(appt, "doctor", None) if appt else None
    patient = getattr(appt, "patient", None) if appt else None

    doctor_name = _get_name(doctor) or "—"
    patient_name = _get_name(patient) or "—"

    appt_id = getattr(appt, "id", None) if appt else None
    serial_no = getattr(appt, "serial_number", None) if appt else None
    approx_time = getattr(appt, "estimated_visit_time", None) if appt else None

    mode = ""
    try:
        mode = _safe_enum_value(getattr(appt, "visit_mode", "")) if appt else ""
    except Exception:
        mode = ""

    txn = getattr(pay, "transaction_id", "") or ""
    method = _safe_enum_value(getattr(pay, "method", "")) or ""
    status = _safe_enum_value(getattr(pay, "status", None)) or "paid"
    paid_at = _human(getattr(pay, "paid_at", None))

    amount = getattr(pay, "amount", None)
    amount_str = "—" if amount is None else f"{amount:.2f}"

    start_time = getattr(appt, "start_time", None) if appt else None
    end_time = getattr(appt, "end_time", None) if appt else None

    # Appointment date shown once (top)
    appt_date_str = _date_only(start_time)

    # Appointment time: time-only range
    appt_time_str = _time_range_only(start_time, end_time)

    serial_str = str(serial_no) if serial_no else "—"
    approx_str = _time_only(approx_time) or "—"

    app_name = _get_original_app_name(default="RxMeet")

    # Barcode: appointment number only
    barcode_data = str(appt_id or "").strip() or "0"

    note_text = "Note: Visiting time is approximate. Actual visit may be before or after this time."

    buf = BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    W, H = A4

    margin_x = 18 * mm
    top = H - 18 * mm
    content_w = W - 2 * margin_x

    # Header row
    c.setFillColor(colors.HexColor("#111827"))
    c.setFont(_font("DVB"), 18)
    c.drawString(margin_x, top, "Payment Receipt")

    # App name (center, professional, no "App:")
    c.setFont(_font("DVB"), 12)
    c.setFillColor(colors.HexColor("#111827"))
    c.drawCentredString(W / 2, top + 2, app_name)

    # Appointment date (right)
    c.setFont(_font("DV"), 10)
    c.setFillColor(colors.HexColor("#6B7280"))
    c.drawRightString(W - margin_x, top + 2, f"Appointment Date: {appt_date_str}")

    # Divider
    c.setStrokeColor(colors.HexColor("#E6E8EC"))
    c.setLineWidth(1)
    c.line(margin_x, top - 10, W - margin_x, top - 10)

    y = top - 26

    # Summary left + Barcode right
    gap = 10
    left_w = (content_w - gap) * 0.54
    right_w = (content_w - gap) - left_w

    y = _kv_block(
        c,
        margin_x,
        y,
        left_w,
        "Summary",
        [
            ("Doctor", doctor_name),
            ("Patient", patient_name),
            ("Receipt ID", txn or "—"),
            ("Issued", paid_at or "—"),
            ("Appointment", f"#{appt_id}" if appt_id else "—"),
        ],
        bold_value_keys=("Doctor", "Patient"),
    )

    card_x = margin_x + left_w + gap
    card_w = right_w
    card_h = 86
    card_y_top = (top - 26)

    c.setStrokeColor(colors.HexColor("#E6E8EC"))
    c.setFillColor(colors.white)
    c.roundRect(card_x, card_y_top - card_h, card_w, card_h, 10, stroke=1, fill=1)

    c.setFillColor(colors.HexColor("#F6F7F9"))
    c.roundRect(card_x, card_y_top - 22, card_w, 22, 10, stroke=0, fill=1)

    c.setFillColor(colors.HexColor("#111827"))
    c.setFont(_font("DVB"), 11)
    c.drawString(card_x + 10, card_y_top - 15, "Appointment Barcode")

    bc = Code128(barcode_data, barHeight=32, barWidth=0.9)
    bc.drawOn(c, card_x + 12, card_y_top - card_h + 18)

    c.setFont(_font("DVM"), 9)
    c.setFillColor(colors.HexColor("#374151"))
    c.drawString(card_x + 12, card_y_top - card_h + 10, f"#{barcode_data}")

    y = min(y, card_y_top - card_h - 10)

    # Payment block
    y = _kv_block(
        c,
        margin_x,
        y,
        content_w,
        "Payment",
        [
            ("Transaction ID", txn or "—"),
            ("Amount", amount_str),
            ("Method", method or "—"),
            ("Status", status or "—"),
            ("Paid at", paid_at or "—"),
        ],
    )

    # Appointment block
    y = _kv_block(
        c,
        margin_x,
        y,
        content_w,
        "Appointment",
        [
            ("Number", f"#{appt_id}" if appt_id else "—"),
            ("Doctor", doctor_name),
            ("Patient", patient_name),
            ("Mode", mode or "—"),
            ("Appointment time", appt_time_str),
            ("Serial number", serial_str),
            ("Approx. visiting time", approx_str),
        ],
        bold_value_keys=("Doctor", "Patient"),
    )

    # Note (always visible; if too low, put it on a new page)
    note_y = y
    if note_y < 28 * mm:
        c.showPage()
        # simple header on note-only page
        c.setFillColor(colors.HexColor("#111827"))
        c.setFont(_font("DVB"), 14)
        c.drawString(margin_x, H - 22 * mm, "Payment Receipt")
        c.setFont(_font("DV"), 11)
        c.drawCentredString(W / 2, H - 22 * mm + 2, app_name)
        note_y = H - 40 * mm

    c.setFillColor(colors.HexColor("#6B7280"))
    _draw_wrapped(
        c,
        note_text,
        margin_x,
        note_y,
        content_w,
        _font("DV"),
        9,
        12,
    )

    c.showPage()
    c.save()

    pdf = buf.getvalue()
    buf.close()
    return pdf

def _list_payments_for_patient(db: Session, current: User, page: int, page_size: int):
    if current.role != UserRole.patient:
        raise HTTPException(403, "Only patients can list their payments")

    p = current.patient_profile
    if not p:
        raise HTTPException(400, "Patient profile missing")

    base = (
        db.query(Payment)
          .join(Appointment, Payment.appointment_id == Appointment.id)
          .filter(Appointment.patient_id == p.id)
    )
    total = base.count()
    items = (
        base.order_by(Payment.paid_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
            .all()
    )

    out = []
    for pay in items:
        appt = pay.appointment
        doc_name = appt.doctor.user.name if (appt and appt.doctor and appt.doctor.user) else ""
        out.append({
            "payment_id": pay.id,
            "appointment_id": pay.appointment_id,
            "transaction_id": pay.transaction_id,
            "method": pay.method,
            "amount": pay.amount,
            "status": pay.status.value if pay.status else "paid",
            "paid_at": pay.paid_at,
            "doctor": {"id": appt.doctor_id if appt else None, "name": doc_name},
            "appointment": {
                "start_time": appt.start_time if appt else None,
                "end_time": appt.end_time if appt else None,
                "status": appt.status.value if appt and appt.status else None,
                "visit_mode": (appt.visit_mode.value if hasattr(appt.visit_mode, "value") else appt.visit_mode) if appt else None,
            },
        })

    return {"ok": True, "page": page, "page_size": page_size, "total": total, "items": out}

@app.get("/me/payments", response_model=dict)
def list_my_payments(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/payments/me", response_model=dict)
def list_my_payments_alias1(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/payments", response_model=dict)
def list_my_payments_alias2(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/patient/payments", response_model=dict)
def list_my_payments_alias3(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/billing/payments", response_model=dict)
def list_my_payments_alias4(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/billing/history", response_model=dict)
def list_my_payments_alias5(
    page: int = _Query(1, ge=1),
    page_size: int = _Query(10, ge=1, le=100),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return _list_payments_for_patient(db, current, page, page_size)

@app.get("/payments/{payment_id}/receipt")
def payment_receipt(
    payment_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    """
    Return PDF receipt for a payment.

    Authentication:
      - Normal mode: client sends Authorization: Bearer <token> (preferred)
      - Browser/dev mode: client may append ?token=<access_token> (convenience for dev)
        NOTE: Passing tokens in URLs is less secure — use only for short-lived dev/testing.
    """
    # Try Authorization header first
    auth_header = request.headers.get("Authorization") or ""
    token = None
    if auth_header and auth_header.lower().startswith("bearer "):
        token = auth_header.split(" ", 1)[1].strip()
    else:
        # Fallback to query param for convenience: ?token=... or ?access_token=...
        token = (request.query_params.get("token") or request.query_params.get("access_token") or "").strip()

    current_user = None
    if token:
        try:
            payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
            uid = int(payload.get("sub"))
            current_user = db.get(User, uid)
        except Exception:
            # decode failed; we'll treat as unauthenticated below
            current_user = None

    if not current_user:
        raise HTTPException(401, detail="Not authenticated")

    pay = db.get(Payment, payment_id)
    if not pay:
        raise HTTPException(404, "Payment not found")

    # permission check
    _ensure_can_view_payment(current_user, pay)

    # Render PDF and return
    pdf = _render_receipt_pdf(pay)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="receipt-{payment_id}.pdf"'},
    )

# ---- / Payments listing + PDF -----------------------------------------------

@app.post("/appointments/{appointment_id}/video/start", response_model=dict)
def create_video_room(appointment_id: int, current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if not (current.role == UserRole.doctor and appt.doctor.user_id == current.id):
        raise HTTPException(403, "Only the doctor can start the video call")
    if not appt.video_room:
        appt.video_room = "room_" + secrets.token_urlsafe(8)
        appt.last_modified_by_user_id = current.id
        appt.last_modified_at = datetime.utcnow()
        db.commit()
    return {"ok": True, "room": appt.video_room}

# ---------- <<START_CALL_PATCH>> ----------
@app.post("/appointments/{appointment_id}/call/start")
def start_call(appointment_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    """
    Doctor starts a call. Create a CallLog and send a doctor_call push to the patient.
    The push carries:
      - appointment_id
      - call_log_id
      - message_id (unique for this call instance)
      - doctor_name, room
    """
    # Ensure firebase is initialized in this worker/process
    if not ensure_firebase_initialized():
        raise HTTPException(status_code=500, detail="Server firebase not initialized")

    import traceback
    print(f"START_CALL: appointment_id={appointment_id} by user={getattr(current_user,'id',None)}")

    appt = db.query(Appointment).filter(Appointment.id == appointment_id).first()
    if not appt:
        raise HTTPException(status_code=404, detail="Appointment not found")

    if current_user.role != UserRole.doctor or appt.doctor.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only doctor can start the call")

    if not getattr(appt, "patient", None) or not getattr(appt.patient, "user_id", None):
        raise HTTPException(status_code=400, detail="Appointment patient information missing")

    # Create call log record so we can trace/answer/end this call (idempotent per start)
    cl = CallLog(appointment_id=appointment_id,
                 started_by_user_id=current_user.id,
                 started_at=datetime.utcnow(),
                 status="ringing")
    db.add(cl)
    db.commit()
    db.refresh(cl)

    # message_id used for client dedupe
    message_id = f"call_{cl.id}_{secrets.token_urlsafe(6)}"

    # Get patient tokens
    tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == appt.patient.user_id).all()
    tokens = list({t.token for t in tokens_q if t and t.token})
    print(f"START_CALL: found {len(tokens)} tokens for patient_user_id={appt.patient.user_id}")
    if not tokens:
        return {"ok": True, "sent": 0, "failed": 0, "errors": [], "call_log_id": cl.id, "message_id": message_id}

    title = f"{(appt.doctor.user.name if appt.doctor and appt.doctor.user else 'Doctor')} is calling"
    body = "Tap to answer the call"
    data_payload = {
        "type": "doctor_call",
        "appointment_id": str(appt.id),
        "doctor_name": (appt.doctor.user.name if appt.doctor and appt.doctor.user else "Doctor"),
        "room": (appt.video_room or f"room_{appt.id}"),
        "call_log_id": str(cl.id),
        "message_id": message_id,   # for client dedupe
    }

    # Platform configs
    android_cfg = None
    try:
        if hasattr(messaging, "AndroidConfig") and hasattr(messaging, "AndroidNotification"):
            android_cfg = messaging.AndroidConfig(
                priority="high",
                ttl=60,
                notification=messaging.AndroidNotification(
                    channel_id="calls_channel",
                    sound="default",
                    click_action="FLUTTER_NOTIFICATION_CLICK",
                ),
            )
    except Exception as e:
        print("START_CALL: AndroidConfig skipped:", e)

    apns_cfg = None
    try:
        if hasattr(messaging, "ApnsConfig") and hasattr(messaging, "ApnsPayload") and hasattr(messaging, "Aps"):
            apns_cfg = messaging.ApnsConfig(
                headers={"apns-priority": "10"},
                payload=messaging.ApnsPayload(
                    aps=messaging.Aps(alert={"title": title, "body": body}, sound="telehealth_incoming_ringtone.caf")
                ),
            )
    except Exception as e:
        print("START_CALL: ApnsConfig skipped:", e)

    webpush_cfg = None
    try:
        if hasattr(messaging, "WebpushConfig") and hasattr(messaging, "WebpushNotification"):
            webpush_cfg = messaging.WebpushConfig(
                headers={"TTL": "60", "Urgency": "high"},
                notification=messaging.WebpushNotification(title=title, body=body),
            )
    except Exception as e:
        print("START_CALL: WebpushConfig skipped:", e)

    notification_obj = None
    if hasattr(messaging, "Notification"):
        try:
            notification_obj = messaging.Notification(title=title, body=body)
        except Exception:
            notification_obj = None

    success = 0
    failed = 0
    errors = []

    # Try multicast
    if hasattr(messaging, "send_multicast") and hasattr(messaging, "MulticastMessage"):
        try:
            multicast = messaging.MulticastMessage(
                notification=(notification_obj if notification_obj else None),
                data={k: str(v) for k, v in data_payload.items()},
                android=android_cfg,
                apns=apns_cfg,
                webpush=webpush_cfg,
                tokens=tokens,
            )
            res = messaging.send_multicast(multicast)
            success = int(res.success_count or 0)
            failed = int(res.failure_count or 0)
            print(f"START_CALL: send_multicast result: success={success}, failed={failed}")
            for i, resp in enumerate(res.responses):
                if not resp.success:
                    err = str(resp.exception) if resp.exception else "unknown"
                    errors.append({"token": multicast.tokens[i], "error": err})
                    if "Unregistered" in err or "not registered" in err or "registration-token-not-registered" in err:
                        try:
                            db.query(DeviceToken).filter(DeviceToken.token == multicast.tokens[i]).delete()
                            db.commit()
                        except Exception:
                            db.rollback()
            return {"ok": True, "sent": success, "failed": failed, "errors": errors, "call_log_id": cl.id, "message_id": message_id}
        except Exception as e:
            print("START_CALL: send_multicast failed, falling back:", e)
            traceback.print_exc()

    # Fallback: per-token send
    for t in tokens:
        try:
            msg_kwargs = {"data": {k: str(v) for k, v in data_payload.items()}, "token": t}
            if notification_obj: msg_kwargs["notification"] = notification_obj
            if android_cfg: msg_kwargs["android"] = android_cfg
            if apns_cfg: msg_kwargs["apns"] = apns_cfg
            if webpush_cfg: msg_kwargs["webpush"] = webpush_cfg

            msg = messaging.Message(**msg_kwargs)
            messaging.send(msg)
            success += 1
        except Exception as e:
            failed += 1
            err = str(e)
            print(f"START_CALL: send to token failed token={t} error={err}")
            errors.append({"token": t, "error": err})
            if "Unregistered" in err or "not registered" in err or "registration-token-not-registered" in err:
                try:
                    db.query(DeviceToken).filter(DeviceToken.token == t).delete()
                    db.commit()
                except Exception:
                    db.rollback()
            continue

    print(f"START_CALL: per-token send result: success={success}, failed={failed}")
    return {"ok": True, "sent": success, "failed": failed, "errors": errors, "call_log_id": cl.id, "message_id": message_id}
    # schedule server-side timeout to mark missed if nobody answers in 60s
    try:
        schedule_call_timeout(appt.id, cl.id, timeout_seconds=60)
    except Exception as e:
        print("START_CALL: schedule_call_timeout failed:", e)

# ---------- <<END START_CALL_PATCH>> ----------


# ---------- <<ANSWER_CALL_PATCH>> ----------
@app.post("/appointments/{appointment_id}/call/answer", response_model=dict)
def answer_call(
    appointment_id: int, call_log_id: Optional[int] = Form(None), current: User = Depends(require_role(UserRole.patient)), db: Session = Depends(get_db)
):
    """
    Patient answers: mark the CallLog answered and notify doctor(s) that patient joined.
    """
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    if appt.patient.user_id != current.id:
        raise HTTPException(403, "Not your appointment")

    cl = db.get(CallLog, call_log_id) if call_log_id else None
    if cl and cl.appointment_id != appointment_id:
        raise HTTPException(400, "call log mismatch")

    if not cl:
        # fallback: create a call log if the doctor didn't create one (defensive)
        cl = CallLog(appointment_id=appointment_id, started_at=datetime.utcnow(), started_by_user_id=None, status="answered")
        db.add(cl)
        db.commit()
        db.refresh(cl)

    # Mark answered
    cl.answered_at = datetime.utcnow()
    cl.status = "answered"
    db.commit()

    # Notify doctor's device tokens that patient has joined
    try:
        tokens_q = db.query(DeviceToken).filter(DeviceToken.user_id == appt.doctor.user_id).all()
        tokens = [t.token for t in tokens_q if t and t.token]
        if tokens:
            title = f"Patient joined"
            body = f"Patient has answered appointment #{appt.id}"
            data_payload = {"type": "participant_joined", "appointment_id": str(appt.id), "call_log_id": str(cl.id), "message_id": f"call_{cl.id}_joined"}
            multicast = messaging.MulticastMessage(
                notification=messaging.Notification(title=title, body=body),
                data={k: str(v) for k, v in data_payload.items()},
                tokens=list(set(tokens)),
            )
            res = messaging.send_multicast(multicast)
            print(f"ANSWER_CALL: notified doctor tokens success={res.success_count} failed={res.failure_count}")
    except Exception as e:
        print("ANSWER_CALL: failed to notify doctor:", e)

    return {"ok": True, "call_log_id": cl.id}
# ---------- <<END ANSWER_CALL_PATCH>> ----------


# ---------- <<END_CALL_PATCH>> ----------
@app.post("/appointments/{appointment_id}/call/end", response_model=dict)
def end_call(appointment_id: int, db: Session = Depends(get_db), current_user: User = Depends(get_current_user), call_log_id: Optional[int] = Body(None)):
    """
    Called by any party (patient, doctor, admin) to end a call. Marks CallLog ended and notifies BOTH
    doctor and patient with type=video_end. Idempotent.
    """
    # Security check unchanged (your existing guard)
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(status_code=404, detail="Appointment not found")

    if not (current_user.role == UserRole.patient and appt.patient.user_id == current_user.id) and current_user.role != UserRole.admin and not (current_user.role == UserRole.doctor and appt.doctor.user_id == current_user.id):
        raise HTTPException(status_code=403, detail="Forbidden")

    # Call the internal routine (idempotent). This will mark CallLog ended and notify both sides.
    ok = _end_call_internal(db, appointment_id, call_log_id=call_log_id, reason="ended", by=getattr(current_user, "id", None))
    if not ok:
        # internal helper already printed/logged; respond success for idempotency
        return {"ok": True}
    return {"ok": True}

# ---------- <<END END_CALL_PATCH>> ----------

@app.post("/appointments/{appointment_id}/video/token", response_model=dict)
def mint_video_token(
    appointment_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # Load appointment
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    # Only doctor or patient on this appointment (or admin) can join
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    # Room name (create if missing)
    room_name = appt.video_room
    if not room_name:
        room_name = f"appt_{appt.id}"
        appt.video_room = room_name
        appt.last_modified_by_user_id = current.id
        appt.last_modified_at = datetime.utcnow()
        db.commit()

    # Identity + display name
    if current.role == UserRole.doctor:
        identity = f"doc-{current.id}"
    elif current.role == UserRole.patient:
        identity = f"pat-{current.id}"
    else:
        identity = f"user-{current.id}"

    display_name = current.name or identity

    # Build LiveKit access token (new SDK style)
    at = lk_api.AccessToken(
        api_key=LIVEKIT_API_KEY,
        api_secret=LIVEKIT_API_SECRET,
    )

    at = (
        at
        .with_identity(identity)
        .with_name(display_name)
        .with_grants(
            lk_api.VideoGrants(
                room_join=True,
                room=room_name,
            )
        )
        .with_ttl(dt.timedelta(hours=1))
    )

    jwt = at.to_jwt()

    # Convert LIVEKIT_URL to WebSocket URL for the client
    url = LIVEKIT_URL
    if url.startswith("http://"):
        url = "ws://" + url[len("http://"):]
    elif url.startswith("https://"):
        url = "wss://" + url[len("https://"):]

    return {
        "ok": True,
        "url": url,
        "room": room_name,
        "token": jwt,
        "identity": identity,
        "display_name": display_name,
    }

# prescriptions
@app.post("/appointments/{appointment_id}/prescription", response_model=dict)
def upsert_prescription(appointment_id: int, content: str = Form(""), file: UploadFile = File(None),
                        current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if not ((current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
            (current.role == UserRole.patient and appt.patient.user_id == current.id)):
        raise HTTPException(403, "Forbidden")

    file_path = None
    if file is not None:
        fname = f"rx_{appointment_id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
        file_path = os.path.join("uploads", fname)
        with open(file_path, "wb") as f: f.write(file.file.read())

    if appt.prescription:
        if content:
            appt.prescription.content = content
        if file_path:
            appt.prescription.file_path = file_path
        appt.prescription.updated_at = datetime.utcnow()              # <-- NEW
    else:
        db.add(Prescription(
            appointment_id=appointment_id,
            content=content or "",
            file_path=file_path,
            updated_at=datetime.utcnow()                               # <-- NEW
        ))
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit()
    return {"ok": True}

@app.get("/appointments/{appointment_id}/prescription", response_model=dict)
def get_prescription(appointment_id: int, current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    allowed = ((current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
               (current.role == UserRole.patient and appt.patient.user_id == current.id) or
               current.role == UserRole.admin)
    if not allowed: raise HTTPException(403, "Forbidden")
    if not appt.prescription: return {"ok": True, "content": "", "file_path": None}
    return {"ok": True, "content": appt.prescription.content, "file_path": appt.prescription.file_path}

@app.get("/appointments/{appointment_id}/prescription/download")
def download_prescription(appointment_id: int,
                          current: User = Depends(get_current_user),
                          db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt or not appt.prescription or not appt.prescription.file_path:
        raise HTTPException(404, "Not found")
    allowed = (
        (current.role == UserRole.patient and appt.patient.user_id == current.id) or
        (current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
        (current.role == UserRole.admin)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    fname = os.path.basename(appt.prescription.file_path)
    return FileResponse(path=appt.prescription.file_path, filename=fname, media_type="application/octet-stream")

@app.delete("/appointments/{appointment_id}/prescription", response_model=dict)
def delete_prescription(appointment_id: int,
                        current: User = Depends(get_current_user),
                        db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Not found")
    allowed = (
        (current.role == UserRole.patient and appt.patient.user_id == current.id) or
        (current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
        (current.role == UserRole.admin)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    if appt.prescription:
        try:
            if appt.prescription.file_path and os.path.exists(appt.prescription.file_path):
                os.remove(appt.prescription.file_path)
        except Exception:
            pass
        db.delete(appt.prescription); db.commit()
    return {"ok": True}

# ---- Back-compat aliases for text/file-only prescription ops ----------------

@app.get("/appointments/{appointment_id}/prescription/text", response_class=PlainTextResponse)
@app.get("/appointments/{appointment_id}/prescriptions/text", response_class=PlainTextResponse)
def get_prescription_text(appointment_id: int,
                          current: User = Depends(get_current_user),
                          db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    if not appt.prescription or not (appt.prescription.content or "").strip():
        raise HTTPException(404, "Prescription text not found")
    return appt.prescription.content

# Download only the file (alias; canonical is /prescription/download)
@app.get("/appointments/{appointment_id}/prescription/file")
@app.get("/appointments/{appointment_id}/prescriptions/file")
def get_prescription_file(appointment_id: int,
                          current: User = Depends(get_current_user),
                          db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    if not appt.prescription or not appt.prescription.file_path or not os.path.exists(appt.prescription.file_path):
        raise HTTPException(404, "Prescription file not found")
    fname = os.path.basename(appt.prescription.file_path)
    return FileResponse(path=appt.prescription.file_path, filename=fname, media_type="application/octet-stream")

# Delete only the file, keep the text
@app.delete("/appointments/{appointment_id}/prescription/file", response_model=dict)
@app.delete("/appointments/{appointment_id}/prescriptions/file", response_model=dict)
def delete_prescription_file(appointment_id: int,
                             current: User = Depends(get_current_user),
                             db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    if not appt.prescription or not appt.prescription.file_path:
        raise HTTPException(404, "No prescription file to delete")
    try:
        if os.path.exists(appt.prescription.file_path):
            os.remove(appt.prescription.file_path)
    except Exception:
        pass
    appt.prescription.file_path = None
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit()
    return {"ok": True}

# Delete only the text, keep the file
@app.delete("/appointments/{appointment_id}/prescription/text", response_model=dict)
@app.delete("/appointments/{appointment_id}/prescriptions/text", response_model=dict)
def delete_prescription_text(appointment_id: int,
                             current: User = Depends(get_current_user),
                             db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed: raise HTTPException(403, "Forbidden")
    if not appt.prescription:
        raise HTTPException(404, "No prescription to clear")
    appt.prescription.content = ""
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit()
    return {"ok": True}
# -----------------------------------------------------------------------------


# appointment-scoped reports (new)
@app.post("/appointments/{appointment_id}/reports", response_model=dict)
def upload_report_for_appointment(
    appointment_id: int,
    file: UploadFile = File(...),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    fname = f"rep_appt_{appointment_id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f:
        f.write(file.file.read())

    r = MedicalReport(
        patient_id=appt.patient_id,
        file_path=path,
        original_name=file.filename,
        appointment_id=appointment_id,
    )
    db.add(r)
    db.commit()
    db.refresh(r)
    return {"ok": True, "id": r.id, "file_path": r.file_path, "original_name": r.original_name}

@app.get("/appointments/{appointment_id}/reports", response_model=List[ReportOut])
def list_reports_for_appointment(
    appointment_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")
    items = (
        db.query(MedicalReport)
          .filter(MedicalReport.appointment_id == appointment_id)
          .order_by(MedicalReport.uploaded_at.desc())
          .all()
    )
    return [ReportOut(id=i.id, original_name=i.original_name, uploaded_at=i.uploaded_at, file_path=i.file_path) for i in items]

@app.delete("/appointments/{appointment_id}/reports/{report_id}", response_model=dict)
def delete_report_for_appointment(
    appointment_id: int, report_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    row = db.get(MedicalReport, report_id)
    if not row or row.appointment_id != appointment_id:
        raise HTTPException(404, "Report not found")

    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    try:
        if row.file_path and os.path.exists(row.file_path):
            os.remove(row.file_path)
    except Exception:
        pass
    db.delete(row)
    db.commit()
    return {"ok": True}

# Delete a patient's own report (and allow admin)
@app.delete("/patients/reports/{report_id}", response_model=dict)
def patient_delete_report(
    report_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    row = db.get(MedicalReport, report_id)
    if not row:
        raise HTTPException(404, "Report not found")

    # Only the owning patient or an admin can delete
    if current.role == UserRole.patient:
        p = current.patient_profile
        if not p:
            raise HTTPException(400, "Patient profile missing")
        if row.patient_id != p.id:
            raise HTTPException(403, "Forbidden")
    elif current.role != UserRole.admin:
        raise HTTPException(403, "Forbidden")

    # Remove file from disk if present
    try:
        if row.file_path and os.path.exists(row.file_path):
            os.remove(row.file_path)
    except Exception:
        pass

    db.delete(row)
    db.commit()
    return {"ok": True, "deleted": report_id}

# Optional alias for clients that POST deletes
@app.post("/patients/reports/{report_id}/delete", response_model=dict)
def patient_delete_report_alias(
    report_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return patient_delete_report(report_id, current, db)

# Doctor documents (upload/list/delete)
@app.post("/doctor/documents", response_model=DoctorDocOut)
def upload_doctor_document(
    title: str = Form("Document"),
    doc_type: str = Form("certificate"),
    file: UploadFile = File(...),
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    fname = f"doc_{d.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f: f.write(file.file.read())
    row = DoctorDocument(doctor_id=d.id, title=title, doc_type=doc_type, file_path=path)
    db.add(row); db.commit(); db.refresh(row)
    return DoctorDocOut(id=row.id, title=row.title, doc_type=row.doc_type, file_path=row.file_path, uploaded_at=row.uploaded_at)

@app.get("/doctor/documents", response_model=List[DoctorDocOut])
def list_doctor_documents(current: User = Depends(require_role(UserRole.doctor)), db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    items = db.query(DoctorDocument).filter(DoctorDocument.doctor_id == d.id).order_by(DoctorDocument.uploaded_at.desc()).all()
    return [DoctorDocOut(id=i.id, title=i.title, doc_type=i.doc_type, file_path=i.file_path, uploaded_at=i.uploaded_at) for i in items]

@app.delete("/doctor/documents/{doc_id}", response_model=dict)
def delete_doctor_document(doc_id: int, current: User = Depends(require_role(UserRole.doctor)), db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    row = db.get(DoctorDocument, doc_id)
    if not row or row.doctor_id != d.id: raise HTTPException(404, "Not found")
    try:
        if row.file_path and os.path.exists(row.file_path):
            os.remove(row.file_path)
    except Exception:
        pass
    db.delete(row); db.commit()
    return {"ok": True}

# -----------------------------------------------------------------------------
# Patient reports + admin on behalf
# -----------------------------------------------------------------------------
@app.post("/patients/reports", response_model=dict)
def patient_upload_report(file: UploadFile = File(...),
                          current: User = Depends(require_role(UserRole.patient)),
                          db: Session = Depends(get_db)):
    p = current.patient_profile
    if not p: raise HTTPException(400, "Patient profile missing")
    fname = f"rep_{p.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f: f.write(file.file.read())
    r = MedicalReport(patient_id=p.id, file_path=path, original_name=file.filename)
    db.add(r); db.commit(); db.refresh(r)
    return {"ok": True, "id": r.id, "name": r.original_name, "file_path": r.file_path}

@app.post("/admin/patients/{patient_id}/reports", response_model=dict)
def admin_upload_report_for_patient(patient_id: int, file: UploadFile = File(...),
                                    curr: User = Depends(require_role(UserRole.admin)),
                                    db: Session = Depends(get_db)):
    p = db.get(Patient, patient_id)
    if not p: raise HTTPException(404, "Patient not found")
    fname = f"rep_{p.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f: f.write(file.file.read())
    r = MedicalReport(patient_id=p.id, file_path=path, original_name=file.filename)
    db.add(r); db.commit(); db.refresh(r)
    return {"ok": True, "id": r.id, "name": r.original_name, "file_path": r.file_path}

@app.get("/patients/reports", response_model=List[ReportOut])
def list_my_reports(current: User = Depends(require_role(UserRole.patient)), db: Session = Depends(get_db)):
    p = current.patient_profile
    items = (db.query(MedicalReport).filter(MedicalReport.patient_id == p.id)
             .order_by(MedicalReport.uploaded_at.desc()).all())
    return [ReportOut(id=i.id, original_name=i.original_name, uploaded_at=i.uploaded_at, file_path=i.file_path) for i in items]

@app.get("/patients/{patient_id}", response_model=dict)
def get_patient_by_id(patient_id: int, current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    p = db.get(Patient, patient_id)
    if not p: raise HTTPException(404, "Not found")
    if current.role == UserRole.doctor:
        has_rel = (db.query(Appointment).filter(Appointment.patient_id == p.id,
                                                Appointment.doctor.has(user_id=current.id)).first())
        if not has_rel:
            raise HTTPException(403, "Forbidden")
    elif current.role == UserRole.patient and p.user_id != current.id:
        raise HTTPException(403, "Forbidden")
    return {
        "id": p.id, "name": p.user.name if p.user else "",
        "age": p.age, "weight": p.weight, "height": p.height,
        "blood_group": p.blood_group, "gender": p.gender,
        "description": p.description, "current_medicine": p.current_medicine,
        "medical_history": p.medical_history
    }

@app.get("/patients/{patient_id}/reports", response_model=List[ReportOut])
def list_reports_for_patient(patient_id: int, current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    p = db.get(Patient, patient_id)
    if not p: raise HTTPException(404, "Not found")
    if current.role == UserRole.patient and p.user_id != current.id:
        raise HTTPException(403, "Forbidden")
    if current.role == UserRole.doctor:
        has_rel = (db.query(Appointment).filter(Appointment.patient_id == p.id,
                                                Appointment.doctor.has(user_id=current.id)).first())
        if not has_rel:
            raise HTTPException(403, "Forbidden")
    items = (db.query(MedicalReport).filter(MedicalReport.patient_id == p.id)
             .order_by(MedicalReport.uploaded_at.desc()).all())
    return [ReportOut(id=i.id, original_name=i.original_name, uploaded_at=i.uploaded_at, file_path=i.file_path) for i in items]

@app.get("/patients/{patient_id}/prescriptions", response_model=List[dict])
def list_patient_prescriptions(patient_id: int,
                               current: User = Depends(get_current_user),
                               db: Session = Depends(get_db)):
    p = db.get(Patient, patient_id)
    if not p: raise HTTPException(404, "Not found")
    if current.role == UserRole.patient and p.user_id != current.id:
        raise HTTPException(403, "Forbidden")
    if current.role == UserRole.doctor:
        has_rel = db.query(Appointment).filter(
            Appointment.patient_id == p.id,
            Appointment.doctor.has(user_id=current.id)
        ).first()
        if not has_rel: raise HTTPException(403, "Forbidden")

    rows = (db.query(Prescription)
              .join(Appointment, Prescription.appointment_id == Appointment.id)
              .filter(Appointment.patient_id == p.id)
              .order_by(Prescription.created_at.desc()).all())
    out = []
    for r in rows:
        out.append({
            "id": r.id,
            "appointment_id": r.appointment_id,
            "title": "Prescription",
            "created_at": r.created_at.isoformat(),
            "file_url": ("/" + r.file_path) if r.file_path and not r.file_path.startswith("/") else r.file_path,
            "content": r.content,
        })
    return out

@app.get("/patient/profile", response_model=dict)
def get_patient_profile(current: User = Depends(require_role(UserRole.patient)), db: Session = Depends(get_db)):
    p = current.patient_profile
    if not p: raise HTTPException(400, "Patient profile missing")
    appts = (db.query(Appointment).filter(Appointment.patient_id == p.id)
             .order_by(Appointment.start_time.desc()).all())
    reports = (db.query(MedicalReport).filter(MedicalReport.patient_id == p.id)
               .order_by(MedicalReport.uploaded_at.desc()).all())
    prescs = []
    for ap in appts:
        if ap.prescription:
            prescs.append({"appointment_id": ap.id, "content": ap.prescription.content, "file_path": ap.prescription.file_path})
    return {
        "profile": {
            "age": p.age, "weight": p.weight, "height": p.height, "blood_group": p.blood_group,
            "gender": p.gender, "description": p.description, "current_medicine": p.current_medicine,
            "medical_history": p.medical_history
        },
        "appointments": [{"id": a.id, "start_time": a.start_time, "end_time": a.end_time,
                          "status": a.status.value, "progress": a.progress.value} for a in appts],
        "reports": [{"id": r.id, "name": r.original_name, "at": r.uploaded_at, "file_path": r.file_path} for r in reports],
        "prescriptions": prescs,
    }

@app.patch("/patient/profile", response_model=PatientProfileOut)
def update_patient_profile(body: PatientProfileIn, current: User = Depends(require_role(UserRole.patient)),
                           db: Session = Depends(get_db)):
    p = current.patient_profile
    if not p: raise HTTPException(400, "Patient profile missing")
    for k, v in body.dict(exclude_unset=True).items():
        setattr(p, k, v)
    db.commit(); db.refresh(p)
    return PatientProfileOut(**{k: getattr(p, k) for k in PatientProfileOut.model_fields})

# ratings
def _recompute_doctor_avg_rating(db: Session, doctor_id: int):
    rows = db.query(DoctorRating).filter(DoctorRating.doctor_id == doctor_id).all()
    avg = round(sum(r.stars for r in rows) / len(rows)) if rows else 5
    d = db.get(Doctor, doctor_id)
    if d:
        d.rating = int(avg)
        db.commit()

@app.post("/appointments/{appointment_id}/rate", response_model=RateOut)
def rate_doctor(appointment_id: int, body: RateIn, current: User = Depends(require_role(UserRole.patient)),
                db: Session = Depends(get_db)):
    if body.stars < 1 or body.stars > 5: raise HTTPException(400, "stars must be 1..5")
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if appt.patient.user_id != current.id: raise HTTPException(403, "Not your appointment")
    if appt.status != AppointmentStatus.approved: raise HTTPException(400, "Appointment not approved")
    ex = db.query(DoctorRating).filter(DoctorRating.appointment_id == appointment_id).first()
    if ex:
        ex.stars = body.stars; ex.comment = body.comment or ""
        db.commit(); db.refresh(ex); _recompute_doctor_avg_rating(db, appt.doctor_id); return ex
    row = DoctorRating(doctor_id=appt.doctor_id, patient_id=appt.patient_id,
                       appointment_id=appt.id, stars=body.stars, comment=body.comment or "")
    db.add(row); db.commit(); db.refresh(row); _recompute_doctor_avg_rating(db, appt.doctor_id)
    return row

@app.get("/me/appointments", response_model=List[AppointmentOut])
def my_appointments(current: User = Depends(require_role(UserRole.patient)), db: Session = Depends(get_db)):
    p = current.patient_profile
    rows = (db.query(Appointment)
            .filter(Appointment.patient_id == p.id)
            .order_by(Appointment.start_time.desc())
            .all())
    return [
        AppointmentOut(
            id=a.id,
            doctor_id=a.doctor_id,
            patient_id=a.patient_id,
            start_time=a.start_time,
            end_time=a.end_time,
            status=a.status,
            payment_status=a.payment_status,
            visit_mode=a.visit_mode,
            patient_problem=a.patient_problem,
            notes=a.notes,
            video_room=a.video_room,
            progress=a.progress,
            completed_at=a.completed_at,
            doctor_name=(a.doctor.user.name if a.doctor and a.doctor.user else ""),
            patient_name=(a.patient.user.name if a.patient and a.patient.user else "")
        )
        for a in rows
    ]


# -----------------------------------------------------------------------------
# Scheduling audit & controls
# -----------------------------------------------------------------------------
def _can_touch_appt(current: User, appt: Appointment) -> bool:
    return (
        (current.role == UserRole.admin) or
        (current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
        (current.role == UserRole.patient and appt.patient.user_id == current.id)
    )

@app.patch("/appointments/{appointment_id}/reschedule", response_model=AppointmentOut)
def reschedule_appointment(appointment_id: int, body: RescheduleIn,
                           current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if not _can_touch_appt(current, appt): raise HTTPException(403, "Forbidden")

    if slot_capacity_left(db, appt.doctor_id, body.new_start_time, body.new_end_time) <= 0:
        raise HTTPException(400, "New time not available")

    db.add(AppointmentChangeLog(
        appointment_id=appt.id, changed_by_user_id=current.id,
        old_start_time=appt.start_time, old_end_time=appt.end_time,
        new_start_time=body.new_start_time, new_end_time=body.new_end_time,
        reason=body.reason or ""
    ))
    appt.start_time = body.new_start_time
    appt.end_time = body.new_end_time
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit(); db.refresh(appt)
    return appt
# ===== Prescription rendering (PDF + JPG) =====================================

from io import BytesIO
from typing import Optional, Tuple, List
from fastapi import HTTPException, Depends, Request, Query
from fastapi.responses import Response
from sqlalchemy.orm import Session
import os, hashlib
from datetime import datetime

# reportlab imports for PDF layout + QR
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.graphics.barcode import qr as _qr
from reportlab.graphics.shapes import Drawing as _QRDrawing
from reportlab.graphics import renderPDF as _renderQR

DAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

def _rx_decode(content: str) -> dict:
    """Decode JSON-ish prescription content into a dict. Tolerant of plain text."""
    try:
        import json
        return (json.loads(content) if content else {}) or {}
    except Exception:
        return {"diagnosis": content or "", "advice": "", "follow_up": None, "medicines": []}

def _visiting_summary(db: Session, doctor_id: int) -> str:
    """
    Builds a compact summary like: "Mon to Fri (09:00 – 11:00)"
    from active weekly Availability rows.
    """
    avs = (
        db.query(Availability)
          .filter(Availability.doctor_id == doctor_id, Availability.active == True)
          .order_by(Availability.day_of_week, Availability.start_hour)
          .all()
    )
    if not avs:
        return ""

    groups = {}
    for a in avs:
        key = (int(a.start_hour), int(a.end_hour))
        groups.setdefault(key, []).append(int(a.day_of_week))

    (st_hr, en_hr), days = max(groups.items(), key=lambda kv: len(kv[1]))
    days = sorted(days)

    def _compress(ds: List[int]) -> str:
        runs: List[Tuple[int, int]] = []
        start = prev = None
        for d in ds:
            if start is None:
                start = prev = d
            elif d == prev + 1:
                prev = d
            else:
                runs.append((start, prev)); start = prev = d
        runs.append((start, prev))
        labels = []
        for a, b in runs:
            if a == b:
                labels.append(DAY_SHORT[a % 7])
            else:
                labels.append(f"{DAY_SHORT[a % 7]} to {DAY_SHORT[b % 7]}")
        return ", ".join(labels)

    return f"{_compress(days)} ({st_hr:02d}:00 – {en_hr:02d}:00)"

# --- drawing helpers (match the new UI) --------------------------------------

def _fit(text: str, font="Helvetica", size=10, max_w=120):
    text = (text or "").strip()
    if not text:
        return ""
    w = pdfmetrics.stringWidth(text, font, size)
    if w <= max_w:
        return text
    ell = "…"
    for i in range(len(text) - 1, 0, -1):
        cut = text[:i] + ell
        if pdfmetrics.stringWidth(cut, font, size) <= max_w:
            return cut
    return ell

def _label_line_value(c, x, y, label, value, total_w, label_w=36*mm, gap=4*mm, line_h=0.6):
    c.setFont("Helvetica", 9.5)
    c.setFillColor(colors.black)
    c.drawString(x, y, f"{label}")
    lx1 = x + label_w
    lx2 = x + total_w
    c.setStrokeColorRGB(0.8, 0.86, 0.84)  # faint line
    c.setLineWidth(line_h)
    c.line(lx1, y - 2, lx2, y - 2)
    if value:
        c.setFont("Helvetica", 10)
        c.setFillColor(colors.black)
        val = _fit(value, size=10, max_w=(lx2 - lx1 - 4))
        c.drawRightString(lx2 - 2, y, val)

def _draw_plus_badge(c, cx, cy, r=7*mm):
    c.saveState()
    c.setFillColorRGB(0.84, 0.96, 0.92)   # mint circle
    c.setStrokeColorRGB(0.75, 0.9, 0.85)
    c.setLineWidth(1)
    c.circle(cx, cy, r, stroke=1, fill=1)
    c.setStrokeColor(colors.black)
    c.setLineWidth(1.4)
    c.line(cx - r*0.45, cy, cx + r*0.45, cy)
    c.line(cx, cy - r*0.45, cx, cy + r*0.45)
    c.restoreState()

# --- QR & verification helpers -----------------------------------------------

def _rx_sig(prescription_id: int, created_at: datetime) -> str:
    """Short signature for offline verification."""
    ts = int((created_at or datetime.utcnow()).timestamp())
    raw = f"rx|{prescription_id}|{ts}|{JWT_SECRET}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16].upper()

def _build_verify_url(request: Request, prescription_id: int, sig: str) -> str:
    base = os.getenv("PUBLIC_BASE_URL") or str(request.base_url)
    if not base.endswith("/"):
        base += "/"
    return f"{base}verify/prescription/{prescription_id}?sig={sig}"

def _draw_qr(c, x: float, y: float, size: float, data: str):
    widget = _qr.QrCodeWidget(data)
    b = widget.getBounds()
    w, h = (b[2] - b[0]), (b[3] - b[1])
    d = _QRDrawing(size, size, transform=[size / w, 0, 0, size / h, 0, 0])
    d.add(widget)
    _renderQR.draw(d, c, x, y)

# --- PDF endpoint -------------------------------------------------------------

# Card-style prescription PDF with QR verification
@app.get("/appointments/{appointment_id}/prescription.pdf")
@app.get("/appointments/{appointment_id}/prescription/pdf")
def prescription_pdf(
    appointment_id: int,
    request: Request,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # --- local imports so you don't have to edit import section
    from io import BytesIO
    from reportlab.pdfgen import canvas
    from reportlab.lib.pagesizes import A4
    from reportlab.lib import colors
    from reportlab.lib.units import mm
    from reportlab.pdfbase import pdfmetrics
    from reportlab.graphics.barcode import qr as _qr
    from reportlab.graphics.shapes import Drawing as _QRDrawing
    from reportlab.graphics import renderPDF as _renderQR
    import hashlib, os
    from datetime import datetime

    appt = db.get(Appointment, appointment_id)
    if not appt or not appt.prescription:
        raise HTTPException(404, "Prescription not found")

    # authorization
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id)
        or (current.role == UserRole.doctor and appt.doctor and appt.doctor.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    # -------- helpers (scoped) ----------
    def _rx_decode(content: str) -> dict:
        try:
            import json
            return (json.loads(content) if content else {}) or {}
        except Exception:
            return {"diagnosis": content or "", "advice": "", "follow_up": None, "medicines": []}

    def _fit(text: str, font="Helvetica", size=10, max_w=120):
        text = (text or "").strip()
        if not text:
            return ""
        w = pdfmetrics.stringWidth(text, font, size)
        if w <= max_w:
            return text
        ell = "…"
        for i in range(len(text)-1, 0, -1):
            cut = text[:i] + ell
            if pdfmetrics.stringWidth(cut, font, size) <= max_w:
                return cut
        return ell

    def _label_line_value(c, x, y, label, value, total_w, label_w=36*mm, line_h=0.6):
        c.setFont("Helvetica", 9.5)
        c.setFillColor(colors.black)
        c.drawString(x, y, f"{label}")
        lx1 = x + label_w
        lx2 = x + total_w
        c.setStrokeColorRGB(0.8, 0.86, 0.84)
        c.setLineWidth(line_h)
        c.line(lx1, y - 2, lx2, y - 2)
        if value:
            c.setFont("Helvetica", 10)
            c.setFillColor(colors.black)
            c.drawRightString(lx2 - 2, y, _fit(value, size=10, max_w=(lx2 - lx1 - 4)))

    def _draw_plus_badge(c, cx, cy, r=7*mm):
        c.saveState()
        c.setFillColorRGB(0.84, 0.96, 0.92)
        c.setStrokeColorRGB(0.75, 0.9, 0.85)
        c.setLineWidth(1)
        c.circle(cx, cy, r, stroke=1, fill=1)
        c.setStrokeColor(colors.black)
        c.setLineWidth(1.4)
        c.line(cx - r*0.45, cy, cx + r*0.45, cy)
        c.line(cx, cy - r*0.45, cx, cy + r*0.45)
        c.restoreState()

    def _rx_sig(prescription_id: int, created_at: datetime) -> str:
        ts = int((created_at or datetime.utcnow()).timestamp())
        raw = f"rx|{prescription_id}|{ts}|{JWT_SECRET}"
        return hashlib.sha256(raw.encode()).hexdigest()[:16].upper()

    def _build_verify_url(presc_id: int, sig: str) -> str:
        base = os.getenv("PUBLIC_BASE_URL") or str(request.base_url)
        if not base.endswith("/"):
            base += "/"
        return f"{base}verify/prescription/{presc_id}?sig={sig}"

    def _draw_qr(c, x: float, y: float, size: float, data: str):
        widget = _qr.QrCodeWidget(data)
        b = widget.getBounds()
        w0, h0 = (b[2] - b[0]), (b[3] - b[1])
        d = _QRDrawing(size, size, transform=[size / w0, 0, 0, size / h0, 0, 0])
        d.add(widget)
        _renderQR.draw(d, c, x, y)

    def _visiting_summary(doctor_id: int) -> str:
        avs = (
            db.query(Availability)
              .filter(Availability.doctor_id == doctor_id, Availability.active == True)
              .order_by(Availability.day_of_week, Availability.start_hour)
              .all()
        )
        if not avs:
            return ""
        groups = {}
        for a in avs:
            key = (int(a.start_hour), int(a.end_hour))
            groups.setdefault(key, []).append(int(a.day_of_week))
        (st_hr, en_hr), days = max(groups.items(), key=lambda kv: len(kv[1]))
        days = sorted(days)
        names = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
        runs, start = [], None
        prev = None
        for d in days:
            if start is None:
                start = prev = d
            elif d == prev + 1:
                prev = d
            else:
                runs.append((start, prev)); start = prev = d
        runs.append((start, prev))
        lbls = [names[a] if a==b else f"{names[a]} to {names[b]}" for a,b in runs]
        return f"{', '.join(lbls)} ({st_hr:02d}:00 – {en_hr:02d}:00)"

    # -------- data ----------
    data = _rx_decode(appt.prescription.content)
    pat = appt.patient
    patient_name = (pat.user.name if pat and pat.user else "") or "—"
    age = "" if not pat or pat.age is None else str(pat.age)
    gender = (pat.gender or "") if pat else ""
    doctor_name = appt.doctor.user.name if (appt and appt.doctor and appt.doctor.user) else "Dr."
    doctor_meta = appt.doctor.specialty if (appt and appt.doctor) else ""
    doc_addr = appt.doctor.address if (appt and appt.doctor) else ""
    appt_dt = appt.start_time or appt.prescription.created_at
    follow_up = data.get("follow_up") or "No date"
    advice = (data.get("advice") or "").replace("\n", " ")
    diagnosis = (data.get("diagnosis") or "").replace("\n", " ")
    vitals = data.get("vitals") or {}
    bp, pulse, temp, spo2 = (vitals.get("bp",""), vitals.get("pulse",""), vitals.get("temp",""), vitals.get("spo2",""))
    doc_phone = appt.doctor.user.phone if (appt and appt.doctor and appt.doctor.user) else None
    visit_str = _visiting_summary(appt.doctor_id)

    presc = appt.prescription
    sig = _rx_sig(presc.id, presc.created_at or appt_dt or datetime.utcnow())
    verify_url = _build_verify_url(presc.id, sig)
    show_qr = str(request.query_params.get("qr", "1")).lower() in ("1","true","yes","on")

    # -------- draw ----------
    buf = BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    W, H = A4

    Mx, My = 14*mm, 16*mm
    card_x, card_y = Mx, My
    card_w, card_h = W - 2*Mx, H - 2*My
    r = 6*mm

    c.setFillColorRGB(0.94, 0.98, 0.96)
    c.setStrokeColorRGB(0.75, 0.83, 0.80)
    c.setLineWidth(1)
    c.roundRect(card_x, card_y, card_w, card_h, r, stroke=1, fill=1)

    pad = 10*mm
    x0 = card_x + pad
    y0 = card_y + card_h - pad

    _draw_plus_badge(c, x0 + 6*mm, y0 - 5*mm, r=6*mm)
    c.setFillColor(colors.black)
    c.setFont("Helvetica-Bold", 14)
    c.drawString(x0 + 16*mm, y0 - 2*mm, doctor_name)
    if doctor_meta:
        c.setFont("Helvetica", 10.5)
        c.setFillColorRGB(0.18, 0.32, 0.30)
        c.drawString(x0 + 16*mm, y0 - 6*mm - 10, doctor_meta)
    if appt_dt:
        c.setFont("Helvetica", 10.5)
        c.setFillColor(colors.black)
        c.drawRightString(card_x + card_w - pad, y0 - 2*mm, f"Date: {appt_dt.strftime('%Y-%m-%d')}")

    c.setStrokeColorRGB(0.75, 0.83, 0.80)
    c.setLineWidth(1)
    c.line(card_x + 6*mm, y0 - 16*mm, card_x + card_w - 6*mm, y0 - 16*mm)

    left_w = card_w * 0.36
    left_x = x0
    right_x = left_x + left_w + 6*mm

    cur_y = y0 - 16*mm - 10
    _label_line_value(c, left_x, cur_y, "Date:", appt_dt.strftime("%Y-%m-%d") if appt_dt else "", total_w=left_w - 12); cur_y -= 14
    _label_line_value(c, left_x, cur_y, "Name:", patient_name, total_w=left_w - 12); cur_y -= 14
    _label_line_value(c, left_x, cur_y, "Age:", age, total_w=left_w - 12); cur_y -= 14
    _label_line_value(c, left_x, cur_y, "Sex:", gender, total_w=left_w - 12); cur_y -= 14
    _label_line_value(c, left_x, cur_y, "Adv:", advice, total_w=left_w - 12); cur_y -= 18

    c.setFont("Helvetica-Bold", 10.5)
    c.setFillColorRGB(0.18, 0.32, 0.30)
    c.drawString(left_x, cur_y, "Vitals"); cur_y -= 12
    _label_line_value(c, left_x, cur_y, "BP:", bp, total_w=left_w - 12); cur_y -= 12
    _label_line_value(c, left_x, cur_y, "Pulse:", pulse, total_w=left_w - 12); cur_y -= 12
    _label_line_value(c, left_x, cur_y, "Temp:", temp, total_w=left_w - 12); cur_y -= 12
    _label_line_value(c, left_x, cur_y, "SpO₂:", spo2, total_w=left_w - 12); cur_y -= 6

    div_top = y0 - 16*mm - 6
    div_bottom = card_y + 28*mm
    c.setStrokeColorRGB(0.75, 0.83, 0.80)
    c.setLineWidth(1)
    c.line(left_x + left_w, div_bottom, left_x + left_w, div_top)

    rx_y = y0 - 16*mm - 8
    c.setFont("Helvetica-Bold", 28)
    c.setFillColor(colors.black)
    c.drawString(right_x, rx_y, "℞")
    c.setFont("Helvetica", 11)
    c.drawString(right_x, rx_y - 22, f"Follow-up: {follow_up}")
    if diagnosis:
        c.setFont("Helvetica", 10)
        c.setFillColorRGB(0.25, 0.35, 0.33)
        c.drawString(right_x, rx_y - 40, _fit(diagnosis, size=10, max_w=card_w - left_w - 30*mm))

    if show_qr:
        qr_size = 26*mm
        qr_x = card_x + card_w - (10*mm) - qr_size
        qr_y = card_y + 22*mm
        _draw_qr(c, qr_x, qr_y, qr_size, verify_url)
        c.setFont("Helvetica", 8.5); c.setFillColor(colors.black)
        c.drawRightString(qr_x + qr_size, qr_y - 8, "Scan to verify")
        c.drawRightString(qr_x + qr_size, qr_y - 18, f"Code: {sig}")
    else:
        c.setFont("Helvetica", 9)
        c.drawRightString(card_x + card_w - 10*mm, card_y + 8*mm, f"Verify code: {sig}")

    c.setStrokeColorRGB(0.75, 0.83, 0.80)
    c.setLineWidth(1)
    c.line(card_x + 6*mm, card_y + 20*mm, card_x + card_w - 6*mm, card_y + 20*mm)

    c.setFont("Helvetica", 10); c.setFillColor(colors.black)
    if doc_addr:
        c.setFont("Helvetica", 9)
        c.drawString(card_x + 10*mm, card_y + 8*mm, _fit(doc_addr, size=9, max_w=card_w - 30*mm))

    if visit_str:
        c.drawRightString(card_x + card_w - 10*mm, card_y + 13*mm, visit_str)

    c.showPage(); c.save()
    pdf = buf.getvalue(); buf.close()
    return Response(
        pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="prescription-{appointment_id}.pdf"'},
    )

# Public verification endpoint used by the QR
@app.get("/verify/prescription/{prescription_id}", response_model=dict)
def verify_prescription(prescription_id: int, sig: str, db: Session = Depends(get_db)):
    from datetime import datetime
    import hashlib
    p = db.get(Prescription, prescription_id)
    if not p:
        raise HTTPException(404, "Not found")
    ts = int((p.created_at or datetime.utcnow()).timestamp())
    expected = hashlib.sha256(f"rx|{p.id}|{ts}|{JWT_SECRET}".encode()).hexdigest()[:16].upper()
    valid = (sig == expected)
    details = {}
    if valid and p.appointment:
        ap = p.appointment
        details = {
            "doctor": ap.doctor.user.name if (ap.doctor and ap.doctor.user) else "",
            "patient": ap.patient.user.name if (ap.patient and ap.patient.user) else "",
            "date": (ap.start_time or p.created_at).strftime("%Y-%m-%d"),
        }
    return {"ok": True, "valid": valid, "details": details}

@app.patch("/appointments/{appointment_id}/progress", response_model=AppointmentOut)
def update_progress(
    appointment_id: int,
    body: Optional[ProgressIn] = Body(default=None),
    progress: Optional[AppointmentProgress] = Form(default=None),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if current.role not in (UserRole.doctor, UserRole.admin):
        raise HTTPException(403, "Only doctor/admin can set progress")
    if current.role == UserRole.doctor and appt.doctor.user_id != current.id:
        raise HTTPException(403, "Not your appointment")

    new_val = (body.progress if body and body.progress else progress)
    if new_val is None:
        raise HTTPException(400, "progress is required")

    # Lock if previously completed for > 7 days (prefer completed_at when available)
    if appt.progress == AppointmentProgress.completed:
        since = appt.completed_at or appt.last_modified_at or appt.created_at
        if since and datetime.utcnow() - since > timedelta(days=7):
            raise HTTPException(403, "Edits allowed only within 7 days of completion")

    previous = appt.progress
    appt.progress = new_val
    if new_val == AppointmentProgress.completed and previous != AppointmentProgress.completed:
        appt.completed_at = datetime.utcnow()   
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit(); db.refresh(appt)
    return appt


@app.patch("/appointments/{appointment_id}/cancel", response_model=AppointmentOut)
def cancel_appointment(appointment_id: int, body: CancelIn,
                       current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if not _can_touch_appt(current, appt): raise HTTPException(403, "Forbidden")
    db.add(AppointmentChangeLog(
        appointment_id=appt.id, changed_by_user_id=current.id,
        old_start_time=appt.start_time, old_end_time=appt.end_time,
        new_start_time=appt.start_time, new_end_time=appt.end_time,
        reason=f"CANCEL: {body.reason or ''}"
    ))
    appt.status = AppointmentStatus.cancelled
    appt.cancel_reason = body.reason or ""
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.commit(); db.refresh(appt)
    return appt

@app.post("/appointments/{appointment_id}/cancel", response_model=AppointmentOut)
def cancel_appointment_post(
    appointment_id: int,
    body: CancelIn = Body(default=CancelIn()),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return cancel_appointment(appointment_id, body, current, db)

@app.delete("/appointments/{appointment_id}", response_model=dict)
def delete_appointment(
    appointment_id: int,
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Not found")

    if current.role == UserRole.patient:
        if appt.patient.user_id != current.id:
            raise HTTPException(403, "Forbidden")
    elif current.role != UserRole.admin:
        raise HTTPException(403, "Forbidden")

    pending = (
        appt.status in (AppointmentStatus.requested, AppointmentStatus.approved)
        and appt.progress in (AppointmentProgress.not_yet, AppointmentProgress.in_progress, AppointmentProgress.hold)
    )
    if pending:
        raise HTTPException(400, "Cannot delete a pending appointment. Cancel it first.")

    if appt.prescription:
        try:
            if appt.prescription.file_path and os.path.exists(appt.prescription.file_path):
                os.remove(appt.prescription.file_path)
        except Exception:
            pass
        db.delete(appt.prescription)

    db.delete(appt)
    db.commit()
    return {"ok": True}

@app.post("/appointments/{appointment_id}/notes", response_model=dict)
def add_appt_note(appointment_id: int, body: NoteIn,
                  current: User = Depends(get_current_user), db: Session = Depends(get_db)):
    appt = db.get(Appointment, appointment_id)
    if not appt: raise HTTPException(404, "Appointment not found")
    if not _can_touch_appt(current, appt): raise HTTPException(403, "Forbidden")
    row = AppointmentNote(appointment_id=appointment_id, author_user_id=current.id, note=body.note)
    appt.last_modified_by_user_id = current.id
    appt.last_modified_at = datetime.utcnow()
    db.add(row); db.commit()
    return {"ok": True, "id": row.id, "created_at": row.created_at}

from pydantic import BaseModel

class MessageIn(BaseModel):
    body: str
    kind: Optional[str] = "text"
# ------------------------- Chat: model, helpers, endpoints -------------------------
# Place this block in app.py (replace your existing chat block). It depends on:
# - sqlalchemy.orm Session, text, engine, Base
# - models: User, Appointment, DeviceToken, Message
# - firebase_admin.messaging as messaging
# - get_current_user, get_db, datetime, os
from typing import List, Optional, Set, Dict
from fastapi import Request, UploadFile, File, Form, Query, HTTPException
from sqlalchemy import text
from datetime import datetime
import os
import time

# firebase_admin.messaging should already be imported as `messaging`
# If not, add:
# from firebase_admin import messaging

# Appointment-scoped chat (file-capable)
class AppointmentMessage(Base):
    __tablename__ = "appointment_messages"
    id = Column(Integer, primary_key=True)
    appointment_id = Column(Integer, ForeignKey("appointments.id"), nullable=False, index=True)
    sender_user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    body = Column(Text, default="")
    file_path = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    # optional relationships
    appointment = relationship("Appointment")
    sender = relationship("User")


# SQLite auto-create helper for appointment_messages (idempotent)
def _ensure_messages_table(conn):
    rows = conn.execute(text("SELECT name FROM sqlite_master WHERE type='table' AND name='appointment_messages'")).all()
    if not rows:
        conn.execute(text("""
            CREATE TABLE appointment_messages (
                id INTEGER PRIMARY KEY,
                appointment_id INTEGER NOT NULL,
                sender_user_id INTEGER NOT NULL,
                body TEXT DEFAULT '',
                file_path TEXT,
                created_at TEXT DEFAULT (datetime('now'))
            )
        """))


# Ensure table exists at startup (idempotent)
try:
    if engine.url.get_backend_name() == "sqlite":
        with engine.begin() as conn:
            _ensure_messages_table(conn)
except Exception:
    pass


# --- small in-process dedupe cache to avoid rapid duplicate notifications ----
_recent_notifications: Dict[str, float] = {}

def _should_send_notification(key: str, window_seconds: float = 2.0) -> bool:
    """
    Returns True if we should send (and records now). If the same key
    was sent within the last `window_seconds`, returns False.
    """
    try:
        now = time.time()
        last = _recent_notifications.get(key)
        if last is None or (now - last) > window_seconds:
            _recent_notifications[key] = now
            # prune occasional old entries to keep memory small
            if len(_recent_notifications) > 5000:
                cutoff = now - 60.0
                for k in list(_recent_notifications.keys()):
                    if _recent_notifications.get(k, 0) < cutoff:
                        _recent_notifications.pop(k, None)
            return True
        else:
            return False
    except Exception:
        return True


def _get_user_device_tokens(db: Session, user_id: int) -> List[str]:
    """Return list of tokens for user (deduped)."""
    try:
        rows = db.query(DeviceToken).filter(DeviceToken.user_id == user_id).all()
        tokens = [r.token for r in rows if r and r.token]
        # dedupe while preserving order
        out: List[str] = []
        seen = set()
        for t in tokens:
            if t and t not in seen:
                seen.add(t)
                out.append(t)
        return out
    except Exception:
        return []


def _prune_bad_tokens(db: Session, bad_tokens: List[str]):
    """Remove tokens that are invalid/unregistered from DB."""
    if not bad_tokens:
        return
    try:
        for t in bad_tokens:
            try:
                db.query(DeviceToken).filter(DeviceToken.token == t).delete()
                db.commit()
            except Exception:
                db.rollback()
    except Exception:
        pass


def _notify_chat_message(db: Session, appt: Appointment, msg: AppointmentMessage):
    """
    Send a visible notification + data to other participants (doctor/patient) for a chat message.
    Aggregates tokens for all recipients and sends a single multicast so a token is notified once.
    """
    try:
        # Build dedupe key to avoid rapid double-sends (same user action)
        text_body = (msg.body or "").strip()
        snippet = (text_body[:120] if text_body else "") or ("img" if msg.file_path else "")
        dedupe_key = f"chat:{msg.appointment_id}:{msg.sender_user_id}:{snippet}"
        if not _should_send_notification(dedupe_key, window_seconds=2.0):
            print(f"_notify_chat_message: suppressed duplicate key={dedupe_key}")
            return

        sender = db.get(User, msg.sender_user_id)
        sender_name = ""
        if sender:
            sender_name = getattr(sender, "name", None) or getattr(sender, "full_name", None) or getattr(sender, "display_name", "") or f"User #{sender.id}"

        title = sender_name or "New message"
        body_text = text_body or ("Image" if msg.file_path else "")

        # Collect recipient user IDs (exclude sender)
        recipients: Set[int] = set()
        try:
            if appt.doctor and getattr(appt.doctor, "user_id", None) and appt.doctor.user_id != msg.sender_user_id:
                recipients.add(appt.doctor.user_id)
            if appt.patient and getattr(appt.patient, "user_id", None) and appt.patient.user_id != msg.sender_user_id:
                recipients.add(appt.patient.user_id)
        except Exception:
            pass

        if not recipients:
            return

        # Aggregate tokens for all recipients and dedupe globally
        tokens_set: Set[str] = set()
        for rid in recipients:
            toks = _get_user_device_tokens(db, rid)
            for t in toks:
                if t:
                    tokens_set.add(t)

        # Remove sender's own tokens (don't notify sender)
        try:
            sender_tokens = set(_get_user_device_tokens(db, msg.sender_user_id))
            tokens_set.difference_update(sender_tokens)
        except Exception:
            pass

        tokens = list(tokens_set)
        if not tokens:
            return

        data_payload = {
            "type": "chat_message",
            "appointment_id": str(msg.appointment_id),
            "message_id": str(msg.id),
            "sender_id": str(msg.sender_user_id),
            "sender_name": sender_name,
            "body": body_text,
            "file_path": msg.file_path or "",
            "created_at": str(msg.created_at),
        }

        # Visible notification object (ensures OS shows a visible notification)
        notification_obj = None
        try:
            notification_obj = messaging.Notification(title=title, body=body_text)
        except Exception:
            notification_obj = None

        # Android config
        android_cfg = None
        try:
            android_cfg = messaging.AndroidConfig(
                priority="high",
                ttl=60,
                notification=messaging.AndroidNotification(
                    channel_id="chat_channel",
                    click_action="FLUTTER_NOTIFICATION_CLICK",
                    sound="default",
                ),
            )
        except Exception:
            android_cfg = None

        # APNs config (iOS)
        apns_cfg = None
        try:
            apns_cfg = messaging.ApnsConfig(
                headers={"apns-priority": "10"},
                payload=messaging.ApnsPayload(
                    aps=messaging.Aps(alert={"title": title, "body": body_text}, sound="default")
                ),
            )
        except Exception:
            apns_cfg = None

        # Webpush config
        webpush_cfg = None
        try:
            webpush_cfg = messaging.WebpushConfig(
                headers={"TTL": "60", "Urgency": "high"},
                notification=messaging.WebpushNotification(title=title, body=body_text),
            )
        except Exception:
            webpush_cfg = None

        # Send single multicast to all recipient tokens
        multi = messaging.MulticastMessage(
            notification=notification_obj,
            data={k: (v or "") for k, v in data_payload.items()},
            android=android_cfg,
            apns=apns_cfg,
            webpush=webpush_cfg,
            tokens=tokens,
        )

        try:
            resp = messaging.send_multicast(multi)
            # If there are failures, prune NotRegistered tokens
            bad = []
            if hasattr(resp, "responses"):
                for i, r in enumerate(resp.responses):
                    if not getattr(r, "success", False):
                        ex = getattr(r, "exception", None)
                        errstr = str(ex) if ex else ""
                        tok = tokens[i]
                        if "NotRegistered" in errstr or "Unregistered" in errstr or "registration-token-not-registered" in errstr:
                            bad.append(tok)
                if bad:
                    _prune_bad_tokens(db, bad)
        except Exception as e:
            # Fallback: try per-token send and prune invalid ones
            bad_tokens = []
            for t in tokens:
                try:
                    kwargs = {"data": {k: (v or "") for k, v in data_payload.items()}, "token": t}
                    if notification_obj:
                        kwargs["notification"] = notification_obj
                    if android_cfg:
                        kwargs["android"] = android_cfg
                    if apns_cfg:
                        kwargs["apns"] = apns_cfg
                    if webpush_cfg:
                        kwargs["webpush"] = webpush_cfg
                    messaging.send(messaging.Message(**kwargs))
                except Exception as ex2:
                    err2 = str(ex2)
                    if "NotRegistered" in err2 or "Unregistered" in err2 or "registration-token-not-registered" in err2:
                        bad_tokens.append(t)
            if bad_tokens:
                _prune_bad_tokens(db, bad_tokens)

    except Exception as e:
        print("_notify_chat_message error:", e)


# ---------- Text chat endpoints (legacy Message table) ----------
@app.get("/appointments/{appointment_id}/messages", response_model=List[dict])
def list_messages(appointment_id: int, page: int = 1, page_size: int = 50, db: Session = Depends(get_db), current: User = Depends(get_current_user)):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    # Authorization: only patient/doctor/admin
    if not ((current.role == UserRole.admin) or
            (current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
            (current.role == UserRole.patient and appt.patient.user_id == current.id)):
        raise HTTPException(403, "Forbidden")
    q = db.query(Message).filter(Message.appointment_id == appointment_id).order_by(Message.created_at.asc())
    items = q.offset((page - 1) * page_size).limit(page_size).all()
    out = []
    for m in items:
        out.append({
            "id": m.id,
            "appointment_id": m.appointment_id,
            "sender_user_id": m.sender_user_id,
            "recipient_user_id": m.recipient_user_id,
            "body": m.body,
            "kind": m.kind,
            "read": m.read,
            "created_at": m.created_at,
        })
    return out


@app.post("/appointments/{appointment_id}/messages", response_model=dict)
def post_message(appointment_id: int, payload: MessageIn, db: Session = Depends(get_db), current: User = Depends(get_current_user)):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    # Authorization: only patient/doctor/admin
    if not ((current.role == UserRole.admin) or
            (current.role == UserRole.doctor and appt.doctor.user_id == current.id) or
            (current.role == UserRole.patient and appt.patient.user_id == current.id)):
        raise HTTPException(403, "Forbidden")

    recipient_id = None
    if current.role == UserRole.doctor:
        recipient_id = appt.patient.user_id
    elif current.role == UserRole.patient:
        recipient_id = appt.doctor.user_id

    msg = Message(
        appointment_id=appointment_id,
        sender_user_id=current.id,
        recipient_user_id=recipient_id,
        body=payload.body or "",
        kind=payload.kind or "text",
        created_at=datetime.utcnow(),
        read=False,
    )
    db.add(msg)
    db.commit()
    db.refresh(msg)

    # Notify other party via FCM (convert to AppointmentMessage-like payload)
    try:
        fake_am = AppointmentMessage(
            appointment_id=msg.appointment_id,
            sender_user_id=msg.sender_user_id,
            body=msg.body,
            file_path=None,
            created_at=msg.created_at
        )
        _notify_chat_message(db, appt, fake_am)
    except Exception as e:
        print('Failed to notify chat recipient:', e)

    return {"ok": True, "message": {
        "id": msg.id,
        "appointment_id": msg.appointment_id,
        "sender_user_id": msg.sender_user_id,
        "recipient_user_id": msg.recipient_user_id,
        "body": msg.body,
        "kind": msg.kind,
        "read": msg.read,
        "created_at": msg.created_at
    }}


@app.post("/appointments/{appointment_id}/messages/mark_read", response_model=dict)
def mark_messages_read(appointment_id: int, db: Session = Depends(get_db), current: User = Depends(get_current_user)):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")
    q = db.query(Message).filter(Message.appointment_id == appointment_id, Message.recipient_user_id == current.id, Message.read == False)
    updated = q.update({"read": True}, synchronize_session=False)
    db.commit()
    return {"ok": True, "updated": int(updated)}


# ---------- Appointment-scoped chat endpoints (with files) ----------
@app.get("/appointments/{appointment_id}/chat", response_model=dict)
def list_chat_messages(
    appointment_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=500),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    # permission: admin or doctor/patient on appt
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.doctor and appt.doctor and appt.doctor.user_id == current.id)
        or (current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    base = db.query(AppointmentMessage).filter(AppointmentMessage.appointment_id == appointment_id)
    total = base.count()
    items = base.order_by(AppointmentMessage.created_at.asc()).offset((page - 1) * page_size).limit(page_size).all()

    out = []
    for m in items:
        out.append({
            "id": m.id,
            "appointment_id": m.appointment_id,
            "sender_user_id": m.sender_user_id,
            "body": m.body,
            "file_path": m.file_path,
            "created_at": m.created_at,
        })
    return {"ok": True, "page": page, "page_size": page_size, "total": total, "items": out}


@app.post("/appointments/{appointment_id}/chat/send", response_model=dict)
async def send_chat_message(
    appointment_id: int,
    request: Request,
    file: UploadFile = File(None),
    body: Optional[str] = Form(None),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Send a chat message in the appointment thread.
    Accepts either:
      - JSON body { "body": "..." } (Content-Type: application/json)
      - multipart/form-data with 'body' and optional 'file'
    """
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    # permission: only doctor/patient/admin (doctor/patient must belong to appt)
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.doctor and appt.doctor and appt.doctor.user_id == current.id)
        or (current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    # Parse JSON body if any
    text_body = None
    try:
        raw = await request.body()
        if raw:
            import json
            try:
                j = json.loads(raw)
                if isinstance(j, dict):
                    text_body = j.get("body", text_body)
            except Exception:
                pass
    except Exception:
        pass

    # Prefer form/body param
    if body is not None:
        text_body = body

    # For multipart file, save file
    file_path = None
    if file is not None:
        try:
            fname = f"chat_{appointment_id}_{current.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
            path = os.path.join("uploads", fname)
            with open(path, "wb") as fh:
                fh.write(file.file.read())
            file_path = path
        except Exception as e:
            print("chat upload error:", e)
            raise HTTPException(500, "Failed to save uploaded file")

    if (not text_body or not str(text_body).strip()) and not file_path:
        raise HTTPException(422, "body or file is required")

    msg = AppointmentMessage(
        appointment_id=appointment_id,
        sender_user_id=current.id,
        body=(text_body or "").strip(),
        file_path=file_path,
        created_at=datetime.utcnow(),
    )
    db.add(msg)
    db.commit()
    db.refresh(msg)

    # Notify the other participant(s)
    try:
        _notify_chat_message(db, appt, msg)
    except Exception as e:
        print("notify_chat_message error:", e)

    return {
        "ok": True,
        "message": {
            "id": msg.id,
            "appointment_id": msg.appointment_id,
            "sender_user_id": msg.sender_user_id,
            "body": msg.body,
            "file_path": msg.file_path,
            "created_at": msg.created_at,
        },
    }


@app.post("/appointments/{appointment_id}/chat/upload", response_model=dict)
async def upload_chat_file_only(
    appointment_id: int,
    file: UploadFile = File(...),
    note: Optional[str] = Form(None),
    current: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    appt = db.get(Appointment, appointment_id)
    if not appt:
        raise HTTPException(404, "Appointment not found")

    # permission check, same as send_chat_message
    allowed = (
        current.role == UserRole.admin
        or (current.role == UserRole.doctor and appt.doctor and appt.doctor.user_id == current.id)
        or (current.role == UserRole.patient and appt.patient and appt.patient.user_id == current.id)
    )
    if not allowed:
        raise HTTPException(403, "Forbidden")

    try:
        fname = f"chat_{appointment_id}_{current.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
        path = os.path.join("uploads", fname)
        with open(path, "wb") as fh:
            fh.write(file.file.read())
        file_path = path
    except Exception as e:
        print("chat upload error:", e)
        raise HTTPException(500, "Failed to save uploaded file")

    # create message row
    msg = AppointmentMessage(
        appointment_id=appointment_id,
        sender_user_id=current.id,
        body=(note or "").strip(),
        file_path=file_path,
        created_at=datetime.utcnow(),
    )
    db.add(msg)
    db.commit()
    db.refresh(msg)

    # notify other participants
    try:
        _notify_chat_message(db, appt, msg)
    except Exception as e:
        print("notify_chat_message error:", e)

    return {
        "ok": True,
        "message": {
            "id": msg.id,
            "appointment_id": msg.appointment_id,
            "sender_user_id": msg.sender_user_id,
            "body": msg.body,
            "file_path": msg.file_path,
            "created_at": msg.created_at,
        },
    }

# ----------------------------------------------------------------------------- end chat

# -----------------------------------------------------------------------------
# Bootstrap admin
# -----------------------------------------------------------------------------
@app.post("/dev/bootstrap_admin", response_model=UserOut)
def bootstrap_admin(email: EmailStr, name: str = "Admin", password: str = "admin",
                    db: Session = Depends(get_db)):
    if db.query(User).filter(User.email == email).first():
        raise HTTPException(400, "Email exists")
    u = User(name=name, email=email, role=UserRole.admin, password_hash=hash_password(password))
    db.add(u); db.commit(); db.refresh(u)
    return u

# -----------------------------------------------------------------------------
# Compat endpoints for Flutter
# -----------------------------------------------------------------------------
@app.get("/doctor/me", response_model=DoctorOut)
def doctor_me(current: User = Depends(require_role(UserRole.doctor))):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    return DoctorOut(
        id=d.id, name=current.name, email=current.email, specialty=d.specialty,
        category=d.category, keywords=d.keywords, bio=d.bio, background=d.background,
        phone=current.phone, address=d.address, visiting_fee=d.visiting_fee, rating=d.rating,
        photo_path=current.photo_path
    )

@app.patch("/doctor/profile", response_model=DoctorOut)
async def doctor_update_profile(
    request: Request,
    body: Optional[DoctorProfileIn] = Body(default=None),
    name: Optional[str] = Form(default=None),
    specialty: Optional[str] = Form(default=None),
    category: Optional[str] = Form(default=None),
    keywords: Optional[str] = Form(default=None),
    bio: Optional[str] = Form(default=None),
    background: Optional[str] = Form(default=None),
    phone: Optional[str] = Form(default=None),
    address: Optional[str] = Form(default=None),
    visiting_fee: Optional[float] = Form(default=None),  # <— NEW
    current: User = Depends(require_role(UserRole.doctor)),
    db: Session = Depends(get_db),
):
    d = current.doctor_profile
    if not d:
        raise HTTPException(400, "Doctor profile missing")

    if body is None:
        raw = await request.body()
        if raw:
            try:
                import json
                obj = json.loads(raw)
                if isinstance(obj, dict):
                    body = DoctorProfileIn(**obj)
            except Exception:
                body = None

    if body:
        if body.name is not None: current.name = body.name
        for k in ["specialty","category","keywords","bio","background"]:
            v = getattr(body, k)
            if v is not None: setattr(d, k, v)
        if body.phone is not None: current.phone = body.phone
        if body.address is not None: d.address = body.address
        if body.visiting_fee is not None: d.visiting_fee = float(body.visiting_fee)
    else:
        if name is not None: current.name = name
        if specialty is not None: d.specialty = specialty
        if category is not None: d.category = category
        if keywords is not None: d.keywords = keywords
        if bio is not None: d.bio = bio
        if background is not None: d.background = background
        if phone is not None: current.phone = phone
        if address is not None: d.address = address
        if visiting_fee is not None: d.visiting_fee = float(visiting_fee)

    db.commit()
    db.refresh(current)
    db.refresh(d)
    return DoctorOut(
        id=d.id, name=current.name, email=current.email, specialty=d.specialty,
        category=d.category, keywords=d.keywords, bio=d.bio, background=d.background,
        phone=current.phone, address=d.address, visiting_fee=d.visiting_fee, rating=d.rating,
        photo_path=current.photo_path
    )

@app.post("/doctor/profile/photo", response_model=dict)
def doctor_upload_photo(file: UploadFile = File(...),
                        current: User = Depends(require_role(UserRole.doctor)),
                        db: Session = Depends(get_db)):
    fname = f"user_{current.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f: f.write(file.file.read())
    current.photo_path = path
    db.commit()
    return {"ok": True, "photo_path": path}

@app.post("/doctor/profile/document", response_model=dict)
def doctor_upload_profile_document(file: UploadFile = File(...),
                                   current: User = Depends(require_role(UserRole.doctor)),
                                   db: Session = Depends(get_db)):
    d = current.doctor_profile
    if not d: raise HTTPException(400, "Doctor profile missing")
    fname = f"doc_{d.id}_{datetime.utcnow().strftime('%Y%m%d%H%M%S')}_{file.filename}"
    path = os.path.join("uploads", fname)
    with open(path, "wb") as f: f.write(file.file.read())
    row = DoctorDocument(doctor_id=d.id, title="Document", doc_type="certificate", file_path=path)
    db.add(row); db.commit(); db.refresh(row)
    return {"ok": True, "id": row.id, "file_path": row.file_path}
