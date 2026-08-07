"""CICESE monthly tide-calendar PDF -> [(datetime_local, height_cm), ...].

Layout facts established by inspection:
  * 7-column week grid, Sunday first. Each week block prints a row of times (HHMM)
    with matching heights (cm) ~6pt directly beneath.
  * A time label's x position is proportional to its clock time within the day's
    column:  (x - x0)/step  ==  column + time_fraction + 0.043
    The residual on that identity has sd ~0.009 columns, so recovering the column as
    round((x-x0)/step - time_fraction - 0.043) is exact with a wide margin. This is
    what makes end-of-day tides (which spill past the column edge) land correctly.
  * Day-number labels are NOT safe to scrape: axis labels such as "204" sometimes
    split into "2","0","4" tokens that land exactly on a day-number slot. Dates come
    from the calendar instead.
  * Stray label rows can pair into a phantom block, and a sparse final week can fail
    to register, so blocks are mapped onto calendar weeks by vertical pitch rather
    than by naive ordering.

Heights are cm above BMI (Bajamar Media Inferior, equivalent to MLLW).
Times are local standard time on the 120 W meridian (UTC-8, no daylight saving).
"""
import re, calendar, xml.etree.ElementTree as ET
from datetime import datetime

NS = "{http://www.w3.org/1999/xhtml}"
INT = re.compile(r"^-?\d+$")
LABEL_OFFSET = 0.043          # measured constant in the x/time identity above
GRID_Y0, GRID_PITCH = 161.9, 76.4   # fixed-layout week-row grid on the page

def words(path):
    root = ET.parse(path).getroot()
    return [{"x": float(w.get("xMin")), "y": float(w.get("yMin")), "t": (w.text or "").strip()}
            for w in root.iter(NS + "word")]

def rows(ws, tol=3.0):
    ws = sorted(ws, key=lambda w: (w["y"], w["x"])); out = []; cur = []
    for w in ws:
        if cur and abs(w["y"] - cur[0]["y"]) > tol:
            out.append(sorted(cur, key=lambda z: z["x"])); cur = []
        cur.append(w)
    if cur: out.append(sorted(cur, key=lambda z: z["x"]))
    return out

def meridian(ws):
    """Standard-time meridian the calendar is printed on, in degrees west.

    This varies by station AND by month: Ensenada and San Quintin switch between
    120W and 105W because Baja California's border municipalities kept daylight
    saving after Mexico abolished it nationally in 2022. Bahia de los Angeles is
    120W year round; Loreto (Baja California Sur) is 105W year round. Getting this
    wrong puts an unrepresentable one-hour step in the middle of a harmonic fit.
    """
    for i, w in enumerate(ws):
        if w["t"] == "Meridiano:" and i + 1 < len(ws):
            try: return int(ws[i+1]["t"])
            except ValueError: pass
    return None

def parse(path, year, month):
    ws = words(path)
    merid = meridian(ws)
    ticks = sorted(w["x"] for w in ws if w["t"] == "0" and w["y"] < 110)
    step = (ticks[-1] - ticks[0]) / (len(ticks) - 1)
    x0 = ticks[0] - 6.0
    ws = [w for w in ws if w["x"] >= x0 + 5.0]        # drop left-hand cm axis labels
    R = rows(ws)

    weeks = [w for w in calendar.Calendar(firstweekday=6).monthdayscalendar(year, month) if any(w)]

    def grid_slot(y):
        """Week-row index for a page y, or None if it is off the fixed layout grid."""
        k = round((y - GRID_Y0) / GRID_PITCH)
        if 0 <= k < len(weeks) and abs(y - (GRID_Y0 + k*GRID_PITCH)) <= 6.0:
            return k
        return None

    blocks, i = [], 0
    while i < len(R) - 1:
        a, b = R[i], R[i+1]
        if not (4 < b[0]["y"] - a[0]["y"] < 8): i += 1; continue
        # Rejecting off-grid rows here (rather than after) means a legitimate week
        # holding a single tide is still accepted, while stray label rows never are.
        slot = grid_slot(a[0]["y"])
        if slot is None: i += 1; continue
        an = [w for w in a if INT.match(w["t"])]
        bn = [w for w in b if INT.match(w["t"])]
        items = []
        for wt in an:
            t = int(wt["t"])
            if not (0 <= t <= 2359 and t % 100 < 60): continue
            cand = [wb for wb in bn if abs(wb["x"] - wt["x"]) <= 8]
            if not cand: continue
            h = int(min(cand, key=lambda z: abs(z["x"] - wt["x"]))["t"])
            if not (-150 <= h <= 400): continue
            tf = ((t // 100) * 60 + t % 100) / 1440.0
            col = round((wt["x"] - x0) / step - tf - LABEL_OFFSET)
            if not (0 <= col <= 6): continue
            items.append({"col": col, "t": t, "h": h})
        if items:
            blocks.append((slot, items)); i += 2
        else:
            i += 1

    warnings = []
    if not blocks:
        return [], ["no week rows found"]
    seen = {}
    for slot, items in blocks: seen.setdefault(slot, []).extend(items)
    if len(seen) != len(weeks):
        warnings.append(f"{len(seen)}/{len(weeks)} week rows recovered")

    events = []
    for slot, items in sorted(seen.items()):
        colday = {c: d for c, d in enumerate(weeks[slot]) if d}
        for it in items:
            day = colday.get(it["col"])
            if not day: continue
            hh, mm = divmod(it["t"], 100)
            events.append((datetime(year, month, day, hh, mm), it["h"]))
    return sorted(set(events)), warnings, merid
