"""Regenerates test/reference/astropy_reference.json, the independent reference
test/astropy_reference_test.dart holds skotiq_astro to.

Needs astropy (>= 6) and numpy; no network. Run from packages/skotiq_astro:
    python tool/gen_astropy_reference.py
UT1 is taken equal to UTC, as the Dart code does. Positions use astropy's
built-in ephemeris; altitudes are geometric (no refraction)."""
import json, math, random, warnings
import numpy as np
warnings.filterwarnings('ignore')
from astropy.utils import iers
iers.conf.auto_download = False
iers.conf.iers_degraded_accuracy = 'ignore'
from astropy.time import Time, TimeDelta
from astropy.coordinates import EarthLocation, AltAz, SkyCoord, get_body, TETE, GCRS, solar_system_ephemeris
import astropy.units as u
def brentq(f, a, b, xtol=1e-7):
    fa = f(a)
    while b - a > xtol:
        m = 0.5*(a+b); fm = f(m)
        if (fa > 0) == (fm > 0): a, fa = m, fm
        else: b = m
    return 0.5*(a+b)

random.seed(20261110)
sites = [("LosAngeles",34.05,-118.25),("Greenwich",51.48,0.0),("Sydney",-33.87,151.21),("Quito",-0.18,-78.47),
         ("Fairbanks",64.84,-147.72),("Atacama",-23.0,-67.75),("Tokyo",35.68,139.69)]
targets = [("M31",10.6847,41.2687),("M42",83.8221,-5.3911),("Polaris",37.9546,89.2641),("SigOct",317.195,-88.956),
           ("M13",250.4235,36.4613),("LMC",80.8938,-69.7561),("Vega",279.2347,38.7837),("Antares",247.3519,-26.4320),
           ("NGC891",35.6392,42.3491),("M67",132.825,11.8),("Spica",201.2983,-11.1613),("Zero",0.0,0.0)]
def rnd_instant():
    y=random.randint(2024,2032); mo=random.randint(1,12); d=random.randint(1,28)
    return f"{y:04d}-{mo:02d}-{d:02d}T{random.randint(0,23):02d}:{random.randint(0,59):02d}:{random.randint(0,59):02d}.{random.randint(0,999):03d}"
instants = sorted({rnd_instant() for _ in range(60)}) + ["2000-01-01T12:00:00.000","2026-11-10T03:00:00.000","2024-02-29T23:59:59.999","2025-01-01T00:00:00.000"]
out = {"sites":[{"name":n,"lat":la,"lon":lo} for n,la,lo in sites],
       "targets":[{"name":n,"ra":r,"dec":d} for n,r,d in targets], "instants":[], "twilight":[]}
solar_system_ephemeris.set('builtin')
for iso in instants:
    t = Time(iso, scale='utc'); t.delta_ut1_utc = 0.0
    rec = {"utc": iso+"Z", "jd": float(t.jd1)+float(t.jd2),
           "gmst_h": float(t.sidereal_time('mean','greenwich').hour),
           "gast_h": float(t.sidereal_time('apparent','greenwich').hour)}
    sun = get_body('sun', t); moon = get_body('moon', t)
    st = sun.transform_to(TETE(obstime=t)); mt = moon.transform_to(TETE(obstime=t))
    rec["sun"] = {"ra": float(st.ra.deg), "dec": float(st.dec.deg)}
    rec["moon"] = {"ra": float(mt.ra.deg), "dec": float(mt.dec.deg), "dist_km": float(mt.distance.to(u.km).value)}
    sj = sun.transform_to(GCRS(obstime=t)); mj = moon.transform_to(GCRS(obstime=t))
    elong = sj.separation(mj).rad
    rs = sj.distance.to(u.km).value; rm = mj.distance.to(u.km).value
    i = math.atan2(rs*math.sin(elong), rm - rs*math.cos(elong))
    rec["moon"]["illum_pct"] = 100.0*(1+math.cos(i))/2
    rec["moon"]["elong_deg"] = math.degrees(elong)
    rec["per_site"] = []
    for n,la,lo in sites:
        loc = EarthLocation(lat=la*u.deg, lon=lo*u.deg, height=0*u.m)
        fr = AltAz(obstime=t, location=loc, pressure=0*u.hPa)
        sa = sun.transform_to(fr)
        # geocentric moon alt (no parallax): from TETE ra/dec + GAST
        lst = (rec["gast_h"]*15 + lo) % 360
        def altaz(ra,dec):
            ha = math.radians(lst-ra); d=math.radians(dec); p=math.radians(la)
            alt = math.asin(math.sin(d)*math.sin(p)+math.cos(d)*math.cos(p)*math.cos(ha))
            az = math.atan2(-math.sin(ha)*math.cos(d), math.sin(d)*math.cos(p)-math.cos(d)*math.sin(p)*math.cos(ha))
            return math.degrees(alt), math.degrees(az)%360
        ma = altaz(rec["moon"]["ra"], rec["moon"]["dec"])
        tg = SkyCoord(ra=[x[1] for x in targets]*u.deg, dec=[x[2] for x in targets]*u.deg, frame='icrs').transform_to(fr)
        rec["per_site"].append({"sun_alt": float(sa.alt.deg), "sun_az": float(sa.az.deg),
                                "moon_alt_geocentric": ma[0], "moon_az_geocentric": ma[1],
                                "lmst_h": (rec["gmst_h"] + lo/15) % 24,
                                "targets": [[float(a),float(z)] for a,z in zip(tg.alt.deg, tg.az.deg)]})
    out["instants"].append(rec)

# twilight: per (date, site) events after the site's mean solar noon of that UTC calendar date
dates = ["2024-03-20","2024-06-21","2025-09-22","2025-12-21","2026-11-10","2027-02-03","2028-05-15","2029-08-08","2030-10-31","2031-01-15","2026-07-04","2032-04-01"]
def sun_alt(tjd, loc):
    t = Time(tjd, format='jd', scale='utc'); t.delta_ut1_utc = 0.0
    return float(get_body('sun', t).transform_to(AltAz(obstime=t, location=loc, pressure=0*u.hPa)).alt.deg)
for ds in dates:
    for n,la,lo in sites:
        loc = EarthLocation(lat=la*u.deg, lon=lo*u.deg, height=0*u.m)
        noon = Time(ds+"T12:00:00", scale='utc') - TimeDelta(lo/15*3600, format='sec')
        grid = noon.jd + np.arange(0, 24*6+1)/144.0
        tt = Time(grid, format='jd', scale='utc'); tt.delta_ut1_utc = 0.0
        alts = get_body('sun', tt).transform_to(AltAz(obstime=tt, location=loc, pressure=0*u.hPa)).alt.deg
        ev = {"date": ds, "site": n, "solar_noon_utc": noon.isot+"Z"}
        for name, thr in [("sun",-0.8333),("civil",-6.0),("nautical",-12.0),("astronomical",-18.0)]:
            dusk = dawn = None
            for k in range(len(grid)-1):
                a0, a1 = alts[k]-thr, alts[k+1]-thr
                if a0 > 0 and a1 <= 0 and dusk is None:
                    dusk = brentq(lambda x: sun_alt(x, loc)-thr, grid[k], grid[k+1], xtol=1e-7)
                if a0 < 0 and a1 >= 0 and dawn is None and dusk is not None:
                    dawn = brentq(lambda x: sun_alt(x, loc)-thr, grid[k], grid[k+1], xtol=1e-7)
            f = lambda x: None if x is None else Time(x, format='jd', scale='utc').isot+"Z"
            ev[name+"_dusk"] = f(dusk); ev[name+"_dawn"] = f(dawn)
        out["twilight"].append(ev)
json.dump(out, open("test/reference/astropy_reference.json","w"), separators=(",",":"))
print("instants", len(out["instants"]), "twilight", len(out["twilight"]))
