import sqlite3
db = r"D:\SmartGateway\smart_gateway.db"
con = sqlite3.connect(db)
cur = con.cursor()
cur.execute("SELECT id, user_id, platform, token FROM device_tokens WHERE platform='web' ORDER BY id DESC LIMIT 1;")
row = cur.fetchone()
con.close()
if not row:
    print("No web token found")
else:
    id, user_id, platform, token = row
    print("id:", id, "user_id:", user_id, "platform:", platform)
    print("len(token) =", len(token))
    # print repr-like so we can see any newline or whitespace
    print("token repr:", repr(token))
