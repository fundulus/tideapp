"""Least-squares tidal harmonic analysis with Schureman nodal corrections.

Model:  h(t) = Z0 + SUM_i f_i(t) * A_i * cos( V_i(t) + u_i(t) - g_i )

V_i is the equilibrium argument built from the Doodson numbers over the classical
astronomical arguments (tau, s, h, p, p1); f_i and u_i are the 18.61-year nodal
amplitude factor and phase correction. Fitting with f and u applied means the
recovered A_i and g_i are referenced properly rather than absorbing the node
position of whatever year was fitted, so predictions stay valid in other years.

Solved linearly by substituting a_i = A_i cos g_i, b_i = A_i sin g_i.
"""
import numpy as np
from datetime import datetime, timedelta

D2R = np.pi / 180.0

# Doodson coefficients over (tau, s, h, p, p1), a 90-degree phase term, and which
# nodal-correction family the constituent follows.
CONSTITUENTS = {
    # semidiurnal
    "M2":   (2,  0,  0,  0, 0,    0, "M2"),
    "S2":   (2,  2, -2,  0, 0,    0, None),
    "N2":   (2, -1,  0,  1, 0,    0, "M2"),
    "K2":   (2,  2,  0,  0, 0,    0, "K2"),
    "NU2":  (2, -1,  2, -1, 0,    0, "M2"),
    "MU2":  (2, -2,  2,  0, 0,    0, "M2"),
    "2N2":  (2, -2,  0,  2, 0,    0, "M2"),
    "L2":   (2,  1,  0, -1, 0,  180, "M2"),
    "T2":   (2,  2, -3,  0, 1,    0, None),
    "2SM2": (2,  4, -4,  0, 0,    0, "M2"),
    # diurnal
    "K1":   (1,  1,  0,  0, 0,   90, "K1"),
    "O1":   (1, -1,  0,  0, 0,  -90, "O1"),
    "P1":   (1,  1, -2,  0, 0,  -90, None),
    "Q1":   (1, -2,  0,  1, 0,  -90, "O1"),
    "J1":   (1,  2,  0, -1, 0,   90, "J1"),
    "OO1":  (1,  3,  0,  0, 0,   90, "OO1"),
    "RHO1": (1, -2,  2, -1, 0,  -90, "O1"),
    "2Q1":  (1, -3,  0,  2, 0,  -90, "O1"),
    "S1":   (1,  1, -1,  0, 0,    0, None),
    # long period
    "MF":   (0,  2,  0,  0, 0,    0, "MF"),
    "MM":   (0,  1,  0, -1, 0,    0, "MM"),
    "SSA":  (0,  0,  2,  0, 0,    0, None),
    "SA":   (0,  0,  1,  0, 0,    0, None),
    "MSF":  (0,  2, -2,  0, 0,    0, "M2"),
    # shallow water
    "M4":   (4,  0,  0,  0, 0,    0, "M4"),
    "MS4":  (4,  2, -2,  0, 0,    0, "M2"),
    "MN4":  (4, -1,  0,  1, 0,    0, "M4"),
    "S4":   (4,  4, -4,  0, 0,    0, None),
    "M6":   (6,  0,  0,  0, 0,    0, "M6"),
    "2MS6": (6,  2, -2,  0, 0,    0, "M4"),
    "MK3":  (3,  1,  0,  0, 0,   90, "MK3"),
    "M3":   (3,  0,  0,  0, 0,    0, "M3"),
}

EPOCH = datetime(1899, 12, 31, 12, 0, 0)   # JD 2415020.0, Schureman's 1900 Jan 0.5

def astro(dt_utc):
    """Astronomical arguments in degrees. dt_utc may be an array of datetimes."""
    ts = np.atleast_1d(dt_utc)
    days = np.array([(t - EPOCH).total_seconds() for t in ts]) / 86400.0
    T = days / 36525.0
    s  = 277.0248 + 481267.8906 * T + 0.0020 * T**2
    h  = 280.1895 +  36000.7689 * T + 0.000303 * T**2
    p  = 334.3853 +   4069.0340 * T - 0.010340 * T**2
    N  = 259.1568 -   1934.1420 * T + 0.002078 * T**2
    p1 = 281.2208 +      1.7192 * T + 0.000450 * T**2
    # Hour angle must be the UT hour of day. The epoch is at noon, so (days % 1)
    # would sit half a day out; that is a constant 180 deg in tau which the fitted
    # phases would silently absorb, leaving them incomparable to published constants.
    hours = np.array([t.hour + t.minute/60.0 + t.second/3600.0 for t in ts])
    tau = 15.0 * hours + h - s          # mean lunar time
    return tau, s, h, p, p1, N

def nodal(kind, N):
    """Schureman nodal amplitude factor f and phase correction u (degrees)."""
    n = N * D2R
    c1, c2, c3 = np.cos(n), np.cos(2*n), np.cos(3*n)
    s1, s2, s3 = np.sin(n), np.sin(2*n), np.sin(3*n)
    one = np.ones_like(N)
    if kind is None:  return one, np.zeros_like(N)
    if kind == "M2":  return 1.0004 - 0.0373*c1 + 0.0002*c2, -2.14*s1
    if kind == "K1":  return 1.0060 + 0.1150*c1 - 0.0088*c2 + 0.0006*c3, -8.86*s1 + 0.68*s2 - 0.07*s3
    if kind == "O1":  return 1.0089 + 0.1871*c1 - 0.0147*c2 + 0.0014*c3, 10.80*s1 - 1.34*s2 + 0.19*s3
    if kind == "K2":  return 1.0241 + 0.2863*c1 + 0.0083*c2 - 0.0015*c3, -17.74*s1 + 0.68*s2 - 0.04*s3
    if kind == "J1":  return 1.0129 + 0.1676*c1 - 0.0170*c2 + 0.0016*c3, -12.94*s1 + 1.34*s2 - 0.19*s3
    if kind == "OO1": return 1.1027 + 0.6504*c1 + 0.0317*c2 - 0.0014*c3, -36.68*s1 + 4.02*s2 - 0.57*s3
    if kind == "MF":  return 1.0429 + 0.4135*c1 - 0.0040*c2, -23.74*s1 + 2.68*s2 - 0.38*s3
    if kind == "MM":  return 1.0000 - 0.1300*c1 + 0.0013*c2, np.zeros_like(N)
    fM2, uM2 = nodal("M2", N)
    if kind == "M4":  return fM2**2, 2*uM2
    if kind == "M6":  return fM2**3, 3*uM2
    if kind == "M3":  return fM2**1.5, 1.5*uM2
    if kind == "MK3":
        fK1, uK1 = nodal("K1", N)
        return fM2*fK1, uM2 + uK1
    return one, np.zeros_like(N)

def design(dt_utc, names):
    """Design matrix [1, f cos(V+u), f sin(V+u), ...] for the given times."""
    tau, s, h, p, p1, N = astro(dt_utc)
    cols = [np.ones_like(tau)]
    for nm in names:
        it, is_, ih, ip, ip1, ph, kind = CONSTITUENTS[nm]
        V = it*tau + is_*s + ih*h + ip*p + ip1*p1 + ph
        f, u = nodal(kind, N)
        ang = (V + u) * D2R
        cols.append(f*np.cos(ang)); cols.append(f*np.sin(ang))
    return np.column_stack(cols)

RATES = (14.4920521, 0.5490165, 0.0410686, 0.0046418, 0.0000020)  # deg/hr

def speed(name):
    it, is_, ih, ip, ip1, _, _ = CONSTITUENTS[name]
    return it*RATES[0] + is_*RATES[1] + ih*RATES[2] + ip*RATES[3] + ip1*RATES[4]

def design_deriv(dt_utc, names):
    """d/dt of the design matrix, in cm/hr. Used to pin the model's turning points
    to the published ones: at a listed high or low the true derivative is zero, so
    those rows carry real information that height-only fitting throws away."""
    tau, s, h, p, p1, N = astro(dt_utc)
    cols = [np.zeros_like(tau)]                     # Z0 contributes nothing
    for nm in names:
        it, is_, ih, ip, ip1, ph, kind = CONSTITUENTS[nm]
        V = it*tau + is_*s + ih*h + ip*p + ip1*p1 + ph
        f, u = nodal(kind, N)
        ang = (V + u) * D2R
        w = speed(nm) * D2R
        cols.append(-f*w*np.sin(ang)); cols.append(f*w*np.cos(ang))
    return np.column_stack(cols)

def fit(times_utc, heights, names=None, deriv_weight=0.0):
    names = list(names or CONSTITUENTS.keys())
    A = design(times_utc, names)
    y = np.asarray(heights, float)
    if deriv_weight > 0:
        A = np.vstack([A, deriv_weight * design_deriv(times_utc, names)])
        y = np.concatenate([y, np.zeros(len(times_utc))])
    coef, *_ = np.linalg.lstsq(A, y, rcond=None)
    Z0 = coef[0]
    out = {}
    for i, nm in enumerate(names):
        a, b = coef[1 + 2*i], coef[2 + 2*i]
        out[nm] = (float(np.hypot(a, b)), float(np.degrees(np.arctan2(b, a)) % 360.0))
    resid = design(times_utc, names) @ coef - np.asarray(heights, float)
    return {"Z0": float(Z0), "const": out, "names": names,
            "rms": float(np.sqrt((resid**2).mean())), "n": len(heights)}

def predict(model, dt_utc):
    names = model["names"]
    tau, s, h, p, p1, N = astro(dt_utc)
    total = np.full_like(tau, model["Z0"], dtype=float)
    for nm in names:
        it, is_, ih, ip, ip1, ph, kind = CONSTITUENTS[nm]
        A_, g = model["const"][nm]
        V = it*tau + is_*s + ih*h + ip*p + ip1*p1 + ph
        f, u = nodal(kind, N)
        total += f * A_ * np.cos((V + u - g) * D2R)
    return total
