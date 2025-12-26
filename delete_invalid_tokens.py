# delete_invalid_tokens.py
import sqlite3
db = r"D:\SmartGateway\smart_gateway.db"
con = sqlite3.connect(db)
cur = con.cursor()
# delete by id (3 and 4 from your output)
cur.execute("DELETE FROM device_tokens WHERE id IN (3,4)")
con.commit()
con.close()
print("Deleted tokens 3 and 4")
