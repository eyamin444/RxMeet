# check_and_prune_tokens.py
import os, argparse, sqlite3, traceback
import firebase_admin
from firebase_admin import credentials, messaging

# CONFIG: adjust if needed
DB_DEFAULT = os.getenv("DATABASE_URL", "sqlite:///./smart_gateway.db")
# parse sqlite path if DATABASE_URL like 'sqlite:///./smart_gateway.db'
if DB_DEFAULT.startswith("sqlite:///"):
    sqlite_path = DB_DEFAULT.replace("sqlite:///", "")
else:
    # fallback to local file
    sqlite_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "smart_gateway.db"))

cred_path = os.getenv("FIREBASE_CREDENTIAL_PATH", os.path.join(os.path.dirname(__file__), "firebase-service-account.json"))

def ensure_firebase():
    if not firebase_admin._apps:
        cred = credentials.Certificate(cred_path)
        firebase_admin.initialize_app(cred)
        print("Firebase admin initialized")

def open_db(path):
    if not os.path.exists(path):
        raise SystemExit(f"DB file not found: {path}")
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    return con

def is_prunable_err(msg: str) -> bool:
    if not msg: return False
    L = msg.lower()
    return any(x in L for x in ("unregistered","not registered","registration-token-not-registered","not a valid fcm","invalid registration token"))

def main(prune=False, limit=None):
    print("Using sqlite DB:", sqlite_path)
    print("Using firebase cred:", cred_path)
    ensure_firebase()
    con = open_db(sqlite_path)
    cur = con.cursor()
    q = "SELECT id, user_id, platform, token FROM device_tokens ORDER BY id DESC"
    if limit:
        q += f" LIMIT {int(limit)}"
    cur.execute(q)
    rows = cur.fetchall()
    print("Found tokens:", len(rows))
    results = []
    for r in rows:
        tid, uid, platform, token = r["id"], r["user_id"], r["platform"], r["token"]
        s = token or ""
        print("\nChecking id=%s user=%s platform=%s len=%s" % (tid, uid, platform, len(s)))
        print("repr:", repr(s[:200]))
        if not s.strip():
            print(" -> empty token, will prune")
            if prune:
                cur.execute("DELETE FROM device_tokens WHERE id=?", (tid,))
                con.commit()
            results.append((tid, uid, platform, "empty_token_deleted" if prune else "empty_token"))
            continue
        # dry-run send
        try:
            msg = messaging.Message(data={"test":"dryrun"}, token=s)
            messaging.send(msg, dry_run=True)
            print(" -> VALID (dry-run OK)")
            results.append((tid, uid, platform, "valid"))
        except Exception as e:
            emsg = str(e)
            print(" -> ERROR:", type(e).__name__, emsg)
            # detailed traceback if debug
            traceback.print_exc()
            if is_prunable_err(emsg):
                print(" -> Marked prunable (will be deleted)" if prune else " -> Marked prunable (not deleted, run with --prune to delete)")
                if prune:
                    try:
                        cur.execute("DELETE FROM device_tokens WHERE id=?", (tid,))
                        con.commit()
                        results.append((tid, uid, platform, f"pruned:{emsg}"))
                    except Exception as ex:
                        print("Failed to delete:", ex)
                        results.append((tid, uid, platform, f"prune_failed:{ex}"))
                else:
                    results.append((tid, uid, platform, f"prunable:{emsg}"))
            else:
                results.append((tid, uid, platform, f"error:{emsg}"))
    print("\nSummary:")
    for r in results:
        print(r)
    con.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--prune", action="store_true", help="Delete clearly invalid tokens (Unregistered/Invalid).")
    parser.add_argument("--limit", type=int, default=None, help="Limit number of tokens to check (for quick runs).")
    args = parser.parse_args()
    main(prune=args.prune, limit=args.limit)
