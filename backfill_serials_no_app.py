# backfill_serials_no_app.py
import os
from datetime import datetime, timedelta
from collections import defaultdict

from sqlalchemy import create_engine, text

# Get DB URL from env or default to sqlite file used in app.py
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./smart_gateway.db")

# If using sqlite, supply connect args
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

engine = create_engine(DATABASE_URL, connect_args=connect_args)

# Defensive datetime parser for different string formats we might have in sqlite
def parse_dt(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    if isinstance(v, (int, float)):
        # Epoch milliseconds or seconds? Try ms then s
        try:
            return datetime.fromtimestamp(float(v) / 1000.0)
        except Exception:
            try:
                return datetime.fromtimestamp(float(v))
            except Exception:
                return None
    s = str(v).strip()
    if not s:
        return None
    # Try several common formats
    fmts = [
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S%z",
        "%Y-%m-%d",
    ]
    # Try fromisoformat first
    try:
        return datetime.fromisoformat(s)
    except Exception:
        pass
    # Replace 'Z' timezone if present
    if s.endswith("Z"):
        s2 = s[:-1]
        try:
            return datetime.fromisoformat(s2)
        except Exception:
            pass
    for f in fmts:
        try:
            return datetime.strptime(s, f)
        except Exception:
            continue
    # fallback: try numeric extraction
    try:
        n = int(s)
        # try ms
        return datetime.fromtimestamp(n / 1000.0)
    except Exception:
        pass
    return None

def backfill():
    conn = engine.connect()
    trans = conn.begin()
    try:
        # Fetch approved appointments that have a start_time (order by doctor + start_time)
        q = text("""
            SELECT id, doctor_id, start_time, end_time
            FROM appointments
            WHERE status = :approved
              AND start_time IS NOT NULL
            ORDER BY doctor_id ASC, start_time ASC, id ASC
        """)
        rows = conn.execute(q, {"approved": "approved"}).fetchall()

        # Group by (doctor_id, date)
        groups = defaultdict(list)
        for r in rows:
            appt_id = r["id"]
            doc_id = r["doctor_id"]
            st_raw = r["start_time"]
            en_raw = r["end_time"]
            st = parse_dt(st_raw)
            en = parse_dt(en_raw)
            if not st:
                continue
            key = (doc_id, st.date())
            groups[key].append({"id": appt_id, "start": st, "end": en})

        total_updates = 0
        for key, lst in groups.items():
            # sort by start (already ordered, but ensure)
            lst.sort(key=lambda x: (x["start"], x["id"]))
            for idx, ap in enumerate(lst, start=1):
                appt_id = ap["id"]
                start = ap["start"]
                end = ap["end"]
                serial = idx
                # compute slot_minutes
                try:
                    if end and start:
                        duration = end - start
                        slot_minutes = int(duration.total_seconds() / 60) if duration.total_seconds() > 0 else 30
                    else:
                        slot_minutes = 30
                except Exception:
                    slot_minutes = 30
                est = start + timedelta(minutes=(serial - 1) * slot_minutes)
                # store estimated_visit_time as ISO string
                est_iso = est.isoformat(sep=" ")
                # Perform update
                upd = text("""
                    UPDATE appointments
                    SET serial_number = :serial,
                        estimated_visit_time = :est
                    WHERE id = :id
                """)
                conn.execute(upd, {"serial": serial, "est": est_iso, "id": appt_id})
                total_updates += 1

        trans.commit()
        print(f"Backfilled {total_updates} appointments.")
    except Exception as ex:
        trans.rollback()
        print("Backfill failed:", ex)
    finally:
        conn.close()

if __name__ == "__main__":
    print("Starting backfill_serials_no_app.py")
    # backup reminder
    print("Make sure you backed up your DB before running this script.")
    backfill()
