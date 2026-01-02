#!/usr/bin/env python3
"""
Backfill serial_number and estimated_visit_time for approved appointments.

Usage:
  python backfill_serials.py                 # uses DATABASE_URL env or ./smart_gateway.db
  python backfill_serials.py --dry-run
  python backfill_serials.py --reassign
  python backfill_serials.py --db path/to/db.sqlite3 --reassign
"""

import argparse
import os
import sqlite3
from datetime import datetime, timedelta
from collections import defaultdict
from typing import Optional

# ---- helper: parse datetimes robustly ----
def parse_dt(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    if isinstance(s, datetime):
        return s
    s = str(s).strip()
    if not s:
        return None
    # common ISO forms
    try:
        # handle trailing Z
        if s.endswith("Z"):
            s2 = s[:-1] + "+00:00"
            return datetime.fromisoformat(s2)
        return datetime.fromisoformat(s)
    except Exception:
        pass
    # common fallback formats (no timezone)
    fmts = [
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
    ]
    for f in fmts:
        try:
            return datetime.strptime(s, f)
        except Exception:
            continue
    # maybe numeric epoch
    try:
        i = int(s)
        # heuristic: if > 1e12 treat as ms, else seconds
        if i > 1_000_000_000_000:
            return datetime.fromtimestamp(i / 1000.0)
        if i > 1_000_000_000:
            return datetime.fromtimestamp(i)
    except Exception:
        pass
    return None

def iso(dt: Optional[datetime]) -> Optional[str]:
    if not dt:
        return None
    return dt.isoformat(sep=" ")

# ---- main backfill logic ----
def backfill_sqlite(db_path: str, dry_run: bool = False, reassign: bool = False):
    if not os.path.exists(db_path):
        raise SystemExit(f"DB file not found: {db_path}")

    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    # fetch approved appointments with start_time ordered by doctor and start_time
    cur.execute("""
      SELECT id, doctor_id, start_time, end_time, serial_number, estimated_visit_time
      FROM appointments
      WHERE status = 'approved' AND start_time IS NOT NULL
      ORDER BY doctor_id, start_time, id
    """)
    rows = cur.fetchall()
    if not rows:
        print("No approved appointments with start_time found.")
        return

    # group by (doctor_id, date(start_time))
    groups = defaultdict(list)
    for r in rows:
        start = parse_dt(r["start_time"])
        if not start:
            continue
        key = (r["doctor_id"], start.date())
        groups[key].append(r)

    total_updates = 0
    planned_updates = []

    for (doctor_id, day), items in sorted(groups.items()):
        # sort by start_time
        items_sorted = sorted(items, key=lambda r: parse_dt(r["start_time"]) or datetime.min)

        # If not reassign, start serial at existing max(serial) for that day and doctor
        if reassign:
            start_serial = 1
        else:
            # find the current max serial among this day's appointments
            cur.execute("""
              SELECT MAX(serial_number) as mx FROM appointments
              WHERE doctor_id = ? AND start_time >= ? AND start_time < ?
            """, (doctor_id, f"{day} 00:00:00", f"{day + timedelta(days=1)} 00:00:00"))
            mx = cur.fetchone()["mx"]
            if mx is None:
                start_serial = 1
            else:
                start_serial = int(mx) + 1

        # If reassign we want to give 1..N for the whole day. So set serial = 1..len(items)
        if reassign:
            next_serial_base = 1
        else:
            next_serial_base = start_serial

        # If reassign: recompute for entire day's approved appts (1..N)
        if reassign:
            # compute fresh serials 1..n ordered by start_time
            for idx, r in enumerate(items_sorted, start=1):
                appt_id = r["id"]
                start_dt = parse_dt(r["start_time"])
                end_dt = parse_dt(r["end_time"])
                # compute slot_minutes
                if start_dt and end_dt and end_dt > start_dt:
                    slot_minutes = int((end_dt - start_dt).total_seconds() / 60)
                    if slot_minutes <= 0:
                        slot_minutes = 30
                else:
                    slot_minutes = 30
                serial = idx
                est = start_dt + timedelta(minutes=(serial - 1) * slot_minutes) if start_dt else None
                planned_updates.append((appt_id, serial, iso(est)))
        else:
            # Fill only missing serials: if appointment already has serial_number and not reassign, skip it
            current_serial = next_serial_base
            for r in items_sorted:
                appt_id = r["id"]
                existing_serial = r["serial_number"]
                start_dt = parse_dt(r["start_time"])
                end_dt = parse_dt(r["end_time"])
                if existing_serial is not None and existing_serial != "":
                    # skip existing serial, but advance the current_serial to ensure we don't clash
                    try:
                        existing_serial_int = int(existing_serial)
                        if existing_serial_int >= current_serial:
                            current_serial = existing_serial_int + 1
                        continue
                    except Exception:
                        # if non-int, treat as not present
                        pass

                # compute slot_minutes
                if start_dt and end_dt and end_dt > start_dt:
                    slot_minutes = int((end_dt - start_dt).total_seconds() / 60)
                    if slot_minutes <= 0:
                        slot_minutes = 30
                else:
                    slot_minutes = 30

                serial = current_serial
                est = start_dt + timedelta(minutes=(serial - 1) * slot_minutes) if start_dt else None
                planned_updates.append((appt_id, serial, iso(est)))
                current_serial += 1

    if not planned_updates:
        print("Nothing to update (no missing serials or dry-run with no changes).")
        return

    # summary
    print(f"Planned updates: {len(planned_updates)} appointments will be updated.")
    if dry_run:
        print("Dry run mode: no changes will be applied. Sample of planned updates:")
        for i, (aid, serial, est) in enumerate(planned_updates[:50], start=1):
            print(f"{i}. appt_id={aid} -> serial={serial}, estimated_visit_time={est}")
        return

    # apply updates in a transaction
    try:
        for appt_id, serial, est in planned_updates:
            cur.execute("""
                UPDATE appointments
                SET serial_number = ?, estimated_visit_time = ?
                WHERE id = ?
            """, (serial, est, appt_id))
            total_updates += 1
        con.commit()
        print(f"Committed: updated {total_updates} appointment rows.")
    except Exception as ex:
        con.rollback()
        print("Error applying updates:", ex)
    finally:
        con.close()

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--db", "-d", help="SQLite DB path or sqlite:///<path>", default=None)
    p.add_argument("--reassign", action="store_true", help="Reassign serials for every day to 1..N")
    p.add_argument("--dry-run", action="store_true", help="Do not apply changes, just show planned updates")
    args = p.parse_args()

    # determine DB path
    db_path = None
    if args.db:
        if args.db.startswith("sqlite:///"):
            db_path = args.db.replace("sqlite:///", "")
        else:
            db_path = args.db
    else:
        env = os.environ.get("DATABASE_URL") or os.environ.get("DB") or None
        if env and env.startswith("sqlite:///"):
            db_path = env.replace("sqlite:///", "")
        elif env and os.path.exists(env):
            db_path = env
        else:
            # fallback default file used by your app
            db_path = os.path.join(os.getcwd(), "smart_gateway.db")
    print(f"Using DB: {db_path}")
    backfill_sqlite(db_path, dry_run=args.dry_run, reassign=args.reassign)
