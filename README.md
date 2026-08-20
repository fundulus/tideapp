# Fundulus Tides

Tide predictions for US coastal stations and four Baja California sites, with sunrise
and sunset, moon phase, and an inundation calculator for how long a given shore
elevation spends submerged versus exposed, split into daylight and darkness.

The whole application is one self-contained HTML file. Every platform build is a thin
shell around it, so there is exactly one copy of the app and the platforms cannot
drift apart.

## Installing it

The app is published at **https://fundulus.github.io/tideapp/** and installs from
there on every platform, with no app store and nothing to download. Open the link and:

| Platform | How |
|---|---|
| Windows, Edge or Chrome | Click the install icon at the right of the address bar, or ⋯ → Apps → Install this site as an app |
| iPhone, iPad | **Safari only**: Share → Add to Home Screen. Chrome on iOS cannot do this |
| Android, Chrome | ⋮ → Install app |
| macOS, Chrome or Edge | Install icon in the address bar. In Safari: File → Add to Dock |

Open it once while online so the service worker can cache the shell. After that it
launches without a connection, and the four Mexican sites and five San Diego sites
below give real predictions with no network at all.

Install from the address above with its trailing slash. The manifest uses a relative
`start_url` and `scope`, so installing from a deeper path scopes the app oddly.

A signed and notarized macOS build lives in `mac/dist/` if you would rather have a
real application than an installed page. There is no distributable iOS build: Apple
allows installation only through TestFlight or the App Store, and `ios/build.sh`
targets the Simulator.

## Running it

| Target | Command | Notes |
|---|---|---|
| Web / PWA | `cd web && ./build.sh serve` | Assembles `docs/`, serves at `localhost:8888` |
| macOS | `cd mac && ./build.sh run` | 856 KB universal app, no Xcode project |
| iOS Simulator | `cd ios && ./build.sh run` | Boots a simulator, installs, launches |

`docs/` is generated and published by GitHub Pages. Do not edit it by hand; edit
`index.html` and rerun `web/build.sh`.

## Data sources

**United States.** Live predictions from the NOAA CO-OPS API, relative to MLLW.

**Mexico.** Bahía de los Ángeles, Bahía de San Quintín, Ensenada and Loreto are not
served by any free prediction API. Their tides are computed from harmonic constants
derived in-house: two years of CICESE's published tide calendars (2025 and 2026) were
parsed and fitted by least squares. The fit applies Schureman equilibrium arguments
with nodal *f* and *u* corrections, and constrains the derivative to zero at every
published high and low so the model's turning points land on the published ones.

Fitting on 2025 alone and predicting 2026 blind, against CICESE's own published
values:

| Site | Height error | Timing error |
|---|---|---|
| Bahía de los Ángeles | 2.8 cm | 5.6 min |
| Bahía de San Quintín | 2.1 cm | 5.8 min |
| Ensenada | 1.5 cm | 4.3 min |
| Loreto | 1.7 cm | 9.9 min |

Heights are relative to BMI (bajamar media inferior), equivalent to MLLW, so the two
sources are directly comparable. Because the constants are embedded in the page,
these four sites need no network at all.

The derivation tooling lives in `harmonics/`.

## Offline

The service worker caches the application shell, so the app launches without a
connection. The four Mexican sites then work completely offline, and so do five San
Diego sites: Mission Bay (Campland), Quivira Basin, La Jolla, Imperial Beach and San
Diego (Broadway Pier).

Nothing is fitted for the San Diego sites. They carry **NOAA's own published harmonic
constants**, which NOAA states as amplitude and Greenwich epoch, the same convention
the harmonic engine already used. Quivira Basin and Imperial Beach are not harmonic
stations; NOAA predicts them as subordinates of San Diego, and so does this app, from
NOAA's published time shifts and height ratios.

NOAA remains the source whenever it is reachable, so on a connection the numbers are
NOAA's exactly. Against a full year of NOAA's published 2026 predictions:

| Site | Curve | Timing | Height |
|---|---|---|---|
| Mission Bay, Campland | 0.8 cm | 1.2 min | 0.5 cm |
| Quivira Basin, Mission Bay | n/a | 2.0 min | 0.6 cm |
| La Jolla | 0.8 cm | 1.9 min | 0.5 cm |
| Imperial Beach | n/a | 2.0 min | 0.6 cm |
| San Diego, Broadway Pier | 1.0 cm | 2.0 min | 0.7 cm |

NOAA publishes only highs and lows for the two subordinate sites, so there is no
continuous curve of theirs to compare against.

Every other NOAA station still needs the network, though responses already fetched are
kept as a fallback.

## Limitations

Everything here is a **tide prediction**. Real water levels depart from prediction
with weather, notably barometric pressure, wind and river discharge, by amounts that
can exceed the errors quoted above. **Not for navigation.**

CICESE prints each monthly calendar on a single time meridian, standard time for
November through March and daylight time for April through October. Real daylight
saving in Baja California's border municipalities starts mid-March and ends in early
November, so for roughly three weeks each March a printed CICESE table sits an hour
behind civil time. This app shows civil time and flags those dates.
