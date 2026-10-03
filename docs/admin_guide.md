# Boolder Dartmoor — Admin Guide

## Table of Contents
1. [Project Structure](#project-structure)
2. [Development Server](#development-server)
3. [Moving to Production (Runbook)](#moving-to-production-runbook)
4. [Backups](#backups)
5. [Admin Accounts](#admin-accounts)
6. [Permission Levels](#permission-levels)
7. [Managing Areas](#managing-areas)
8. [Bulk Upload (Problems)](#bulk-upload-problems)
9. [Importing Problems from Photos](#importing-from-photos)
10. [Location Editor (Drag-and-Drop)](#location-editor)
11. [Adding Boulders (Polygon Map Data)](#adding-boulders)
12. [Boulder Editor (In-Browser)](#boulder-editor)
13. [GeoJSON Import Workflow](#geojson-import-workflow)
14. [Individual Problem Editing](#individual-problem-editing)
15. [Problem Description](#problem-description)
16. [Topos and Line Drawing](#topos-and-line-drawing)
17. [Circuits](#circuits)
18. [POIs and Routes](#pois-and-routes)
19. [Contributions](#contributions)
20. [Email Setup](#email-setup)
21. [Language Support](#language-support)
22. [Open Data Export](#open-data-export)
23. [Offline Use (Map & Photos)](#offline-use)

---

## Project Structure

```
app/
  controllers/
    admin/                  # All admin controllers (require authentication)
    map_data_controller.rb  # Serves problems + boulders as GeoJSON for the map
    area_labels_controller.rb # Serves area name labels as GeoJSON for the map
  models/
    area.rb                 # Climbing area (has many problems, boulders, circuits)
    problem.rb              # An individual climbing problem
    boulder.rb              # A physical boulder (polygon geometry)
    circuit.rb              # A colour-coded circuit grouping problems
    topo.rb                 # A photo with line drawings on it
    line.rb                 # A drawn line on a topo linking it to a problem
    poi.rb                  # Point of Interest (parking, train station)
    poi_route.rb            # Transport route from a POI to an area
  views/
    admin/                  # Admin HTML views
    map/                    # Public-facing map view
  javascript/
    controllers/
      mapbox_controller.js  # All map behaviour (layers, filters, popups)
db/
  schema.rb                 # Database schema
docs/
  admin_guide.md            # This file
```

---

## Development Server

The development server runs as two systemd user services that start automatically at boot (no login required).

| Service | Purpose |
|---|---|
| `boolder-rails` | Puma web server on port 3000 |
| `boolder-css` | Tailwind CSS watcher (recompiles on file changes) |

### Managing the services

```bash
# Status
systemctl --user status boolder-rails boolder-css

# Stop / start / restart
systemctl --user stop boolder-rails boolder-css
systemctl --user start boolder-rails boolder-css
systemctl --user restart boolder-rails

# Follow logs
journalctl --user -u boolder-rails -f
journalctl --user -u boolder-css -f
```

### Service files

Located at `~/.config/systemd/user/`:
- `boolder-rails.service` — Rails server
- `boolder-css.service` — Tailwind watcher (uses `-w always` so it stays running without a TTY)

Environment variables (`PORT`, `RAILS_ENV`, `MAPBOX_DEV_ACCESS_KEY`, etc.) are loaded from the project's `.env` file via `EnvironmentFile=`.

Boot auto-start is enabled via `loginctl enable-linger ed`, which allows user services to run before login.

---

## Moving to Production (Runbook)

The app was originally served in development mode. Production mode fixes the serious
problems with that: error pages no longer leak stack traces/env vars, emails actually send
(once SMTP credentials are set), background jobs persist in Solid Queue, and the app runs
precompiled assets with no code reloading.

### What is already prepared (one-time, done June 2026)

- `config/environments/production.rb` — host set to `bowda.edsouthwood.com` (asset host and
  mailer URLs), Active Storage on `:local` disk, host authorization enabled. The upstream
  values (`assets.boolder.com`, the upstream S3 bucket) are gone.
- `config/database.yml` — production uses `dartmoor-production` / `-cache` / `-queue` /
  `-cable` over the local socket (peer auth). `DB_HOST` / `POSTGRES_USER` /
  `POSTGRES_PASSWORD` env vars override this for a future external database.
- `deploy/boolder-rails.service` — production systemd unit: `RAILS_ENV=production`,
  `SOLID_QUEUE_IN_PUMA=true` (jobs run inside Puma), binds to `127.0.0.1` so all traffic
  must come through Caddy's TLS.
- Production databases created, data restored, assets precompiled, smoke-tested on port 3001.

### Cutover steps (~10 minutes of downtime)

```bash
# 1. Safety snapshot of the live data
bin/backup

# 2. Stop the dev services (site goes down here)
systemctl --user stop boolder-rails boolder-css

# 3. Re-copy the data so nothing submitted since the last sync is lost
dropdb dartmoor-production && createdb dartmoor-production
pg_dump dartmoor-dev | psql -q dartmoor-production

# 4. Install the production unit and drop the CSS watcher (not needed: assets are precompiled)
cp deploy/boolder-rails.service ~/.config/systemd/user/boolder-rails.service
systemctl --user disable boolder-css
systemctl --user daemon-reload

# 5. Start production (site comes back up)
systemctl --user start boolder-rails

# 6. Point backups at the production database
echo 'BACKUP_DB=dartmoor-production' >> .env.backup
bin/backup   # confirm it dumps dartmoor-production
```

Then verify: site loads at https://bowda.edsouthwood.com, photos display, admin login works,
and a test contribution can be submitted and accepted.

### Post-cutover tasks

- **Rotate `ADMIN_PASSWORD`** in `.env` (the old one travelled over plain HTTP in dev mode),
  then `systemctl --user restart boolder-rails`.
- **Fix the Caddyfile**: `/etc/caddy/Caddyfile` has a stray `EOF` line after the site block —
  remove it and `sudo systemctl reload caddy`.
- **Set up email**: add the `smtp` credentials (see [Email Setup](#email-setup)).
  Until then, contributor emails fail inside background jobs.
- The dev database `dartmoor-dev` is left untouched as a fallback.

### Rollback

Restore the old unit (`RAILS_ENV=development`, `-b 0.0.0.0`, re-enable `boolder-css`),
`systemctl --user daemon-reload && systemctl --user start boolder-rails boolder-css`.
The dev database was never modified, so the site resumes exactly where it left off
(minus anything submitted while production was live — merge that manually if needed).

### Deploying code changes after cutover

Production does not reload code. After pulling changes:

```bash
bundle install
RAILS_ENV=production bin/rails db:migrate
RAILS_ENV=production bin/rails assets:precompile
systemctl --user restart boolder-rails
```

Production runs from this same checkout (`/home/ed/projects/boolder-rails`), so do
risky work, such as framework upgrades, in a separate `git worktree` and only pull it
into the main checkout when deploying. Note the current commit first (`git rev-parse HEAD`)
so you can roll back with `git checkout <commit>` followed by the same four commands.

**Rails version:** 8.1 (upgraded October 2026 from 8.0, which reached end of life on
2026-11-07). PostGIS support comes from the official `activerecord-postgis-adapter`
gem (11.x); the old `boolder-org` `rails-8` fork is no longer used.
`config.load_defaults` is `8.1`. The new defaults were reviewed before switching; the
notable one is that `redirect_to` raises on relative URLs without a leading slash, so
always redirect to path helpers or `/`-prefixed paths.

### If the site is down (502 from Caddy)

A 502 means Caddy is up but the Rails app on `127.0.0.1:3000` is not answering.

```bash
systemctl --user status boolder-rails
journalctl --user -u boolder-rails -n 100 --no-pager
systemctl --user start boolder-rails
```

The usual cause is PostgreSQL going away underneath the app — most often
`unattended-upgrades` restarting it to install a `postgresql-16` security update.
When that happens the Solid Queue supervisor cannot reconnect and the Solid Queue
Puma plugin shuts Puma down *cleanly*. The unit now uses `Restart=always` with
`StartLimitIntervalSec=0` so it retries until the database is back; before that it
used `Restart=on-failure`, which ignores a clean exit and left the site down
silently for 8 days from 2026-08-21.

**Testing from the machine itself:** requests to `https://bowda.edsouthwood.com`
from this box hairpin out through the router and back, which stalls part-way
through larger responses. That is a router NAT artefact, not a site fault. Bypass
it by pointing curl straight at Caddy:

```bash
curl --resolve bowda.edsouthwood.com:443:127.0.0.1 https://bowda.edsouthwood.com/en
```

---

## Backups

Daily automated backups run via a systemd timer and rsync to hosted webspace at `edsouthwood.com`.

### What is backed up

| Item | Location on webspace | Notes |
|---|---|---|
| PostgreSQL database | `bowda-backup/db/` | Compressed pg_dump, timestamped, 7-day rolling retention |
| Uploaded files | `bowda-backup/storage/` | Incremental rsync of `storage/` — current state only |
| `config/master.key` | `bowda-backup/master.key` | Required to decrypt `credentials.yml.enc` |
| `.env` | `bowda-backup/.env` | Mapbox key, admin credentials |

Cache, queue, and cable databases are not backed up — they are ephemeral.

### Size estimate

| | Now (~2% complete) | At 100% |
|---|---|---|
| Database dump (compressed) | ~5 MB | ~250 MB |
| Storage files | ~700 MB | ~37 GB |

### Managing backups

```bash
# Run a backup immediately
bin/backup

# Check backup logs
tail -f log/backup.log

# Check timer status
systemctl --user status boolder-backup.timer

# Follow systemd logs for a backup run
journalctl --user -u boolder-backup -f
```

### Configuration

Remote destination is set in `.env.backup` (not committed to git):

```
BACKUP_REMOTE=u79222@edsouthwood.com:bowda-backup
```

SSH key auth is required — the key is at `~/.ssh/boolder_backup`. The timer fires daily at midnight with up to 30 minutes of random jitter; `Persistent=true` means it catches up if the machine was off at midnight.

### Recovery

To restore after a machine failure:

1. Clone the repo from GitHub
2. Restore `.env` and `config/master.key` from the webspace
3. Restore the database: `gunzip -c dartmoor-dev-YYYYMMDD.sql.gz | psql dartmoor-dev`
4. Restore storage files: `rsync -az u79222@edsouthwood.com:bowda-backup/storage/ storage/`

---

## Admin Accounts

Admin credentials are stored in Rails encrypted credentials. To edit them:

```bash
rails credentials:edit
```

### Legacy format (treated as super admin)
```yaml
admin_accounts:
  yourusername: "yourpassword"
```

### New format with roles
```yaml
admin_accounts:
  # Super admin — full access to everything
  alice:
    password: "somepassword"
    role: super_admin

  # Area admin — restricted to listed area slugs
  bob:
    password: "otherpassword"
    role: area_admin
    areas:
      - bonehill
      - haytor
```

Any existing plain string format continues to work and is treated as `super_admin`.

---

## Permission Levels

| Role | What they can do |
|---|---|
| `super_admin` | Full access: create/delete areas, manage all data, imports, bulk uploads, audits |
| `area_admin` | Edit assigned areas and their problems, topos, lines; download/upload GeoJSON for their areas; view contributions |

### Area admin restrictions
- Area creation and deletion: super admin only
- Circuits: super admin only
- Bulk uploads, GeoJSON imports (apply step), POIs: super admin only
- GeoJSON download: accessible per assigned area

---

## Managing Areas

Areas are the top-level geographical groupings. Each area has problems, boulders, circuits, and POI routes.

### Creating an area (super admin only)
1. Go to **Admin → Areas → New area**
2. Fill in `name`, `slug` (URL-friendly, e.g. `bonehill-rocks`), `short_name`, priority, and descriptions
3. Leave `published` unchecked until the area is ready to go live
4. Save — then add problems and boulders before publishing

### Editing an area
- **Edit** — update name, descriptions, cover photo, tags, POI routes
- **Delete** — permanently removes the area and all its problems, boulders, topos, and circuits (super admin only)

### Publishing
Toggle the `published` checkbox on the edit screen. Unpublished areas are hidden from the public map and API.

### Tags
Available tags: `popular`, `beginner_friendly`, `family_friendly`, `dry_fast`

---

## Bulk Upload (Problems)

The fastest way to add many problems to an area at once.

**Admin → Areas → [select area] → Bulk Upload** (or directly via Admin → Bulk Uploads)

### CSV format

```csv
name,grade,steepness,sit_start,lat,lon,image_filename,ukc_url,description
Overhanging Scoop,5c,overhang,false,50.5712,-3.9341,scoop.jpg,,Classic line up the right side of the overhang.
Low Traverse,4a,wall,false,50.5715,-3.9345,,,
Unnamed Slab,,slab,false,,,,
```

### Column reference

| Column | Required | Notes |
|---|---|---|
| `name` | No | Problem name. Can be blank for unnamed problems. |
| `grade` | No | Font grade: `4`, `5`, `5+`, `6a`, `6b+`, `7a`, etc. |
| `steepness` | **Yes** | See valid values below |
| `sit_start` | No | `true` or leave blank |
| `lat` | No | Decimal latitude (e.g. `50.5712`) |
| `lon` | No | Decimal longitude (e.g. `-3.9341`) |
| `image_filename` | No | Must match an uploaded image filename exactly |
| `ukc_url` | No | Full UKC URL for the problem |
| `description` | No | Free-text description shown on the problem page |

### Valid steepness values
`slab`, `wall`, `vertical`, `overhang`, `roof`, `traverse`, `other`

### Uploading images
If your CSV references images in `image_filename`, upload those image files in the **Images** field on the same form. Filenames must match exactly (case-sensitive). Each image becomes a topo — draw line coordinates on it afterwards in the topo editor.

### What happens after upload
- Each row creates one `Problem` record
- If `image_filename` is provided, a `Topo` is created and attached — but with no line coordinates yet
- Go to each problem's show page to draw lines on topos

---

## Importing Problems from Photos

If you have a folder of photos taken at a climbing area, each named with the problem name and grade, you can import them all in one command using the `import:problems` rake task.

### Filename convention

```
Name_With_Underscores-grade.JPG
```

Examples:
- `American_Squeeze_Job-7b+.JPG` → name: "American Squeeze Job", grade: "7b+"
- `Walla_slab-5.JPG` → name: "Walla slab", grade: "5"
- `The_Blimp-5+.JPG` → name: "The Blimp", grade: "5+"

Rules:
- Use underscores for spaces in the name
- Separate name and grade with a hyphen (the **last** hyphen in the filename)
- Names can contain hyphens — only the last one is treated as the separator
- Photos must be JPEGs with GPS coordinates in the EXIF data (taken on a phone or GPS-enabled camera)

### Running the import

```bash
# Folder inside the project root (name must match the area's slug or name)
rails import:problems FOLDER=bearacleave

# Absolute path
rails import:problems FOLDER=/Users/you/Photos/haytor
```

The folder's basename is matched case-insensitively against area `slug` and `name`, so a folder named `bearacleave` will find an area with slug `Bearacleave`.

### What gets created per photo

| Record | Values |
|---|---|
| `Problem` | Name, grade, steepness: wall, lat/lon from photo GPS EXIF |
| `Topo` | The photo, attached via ActiveStorage |
| `Line` | Links topo to problem — **no coordinates yet** |

After importing, visit each problem in admin to draw the line on the topo photo.

### Notes
- The area must already exist in admin before running the import
- Running the task twice on the same folder will create duplicate problems — only run once
- Photos without GPS EXIF will be skipped with an error message
- Default steepness is set to `wall` — edit individual problems to change it

---

## Location Editor (Drag-and-Drop) {#location-editor}

The location editor lets you set GPS coordinates for unlocated problems directly in the browser, without editing GeoJSON files externally.

**Admin → Areas → [area] → dot menu → Location editor**

### How to use

1. The left sidebar lists all problems in the area that have **no location** yet, sorted alphabetically
2. The right panel shows a map with boulder polygons for context and green pins for already-located problems
3. **Drag** a problem name from the sidebar and **drop** it onto the map at the correct position — the pin is placed and the location is saved instantly
4. Once placed, the problem disappears from the sidebar and a green marker appears on the map
5. **Reposition** an already-placed problem by dragging its green marker to a new position — saves on release

### Bulk-clearing bad locations

If problems were uploaded with incorrect coordinates (e.g. all at the same point), clear them first via the Rails runner:

```bash
bundle exec rails runner "Area.find_by(slug: 'area-slug').problems.update_all(location: nil)"
```

Then use the location editor to place them correctly.

---

## Adding Boulders

Boulders are the physical rock outlines shown as grey polygons on the map (visible at zoom 16+). Each `Boulder` record stores a PostGIS polygon.

### Step 1 — Download the area's GeoJSON
Go to:
```
/[locale]/admin/map/[area_id].geojson
```
Or find the download link on the area edit page. This gives you a GeoJSON file with existing problem locations (Points) and boulder polygons (Polygons).

### Step 2 — Open in geojson.io
1. Go to [geojson.io](https://geojson.io)
2. Drag and drop your `.geojson` file onto the map
3. Switch the base layer to **Satellite** (layers icon, top right)

### Step 3 — Draw boulder polygons
- Use the **polygon tool** (pentagon icon in the right toolbar) to trace around each boulder
- Click to place each vertex, double-click to close the polygon
- No properties are needed on new polygons — just the shape
- Existing boulders will already appear; you can edit their vertices too

### Step 4 — Export and import
1. In geojson.io, click **Save → GeoJSON** to download
2. In the admin: **Admin → Imports → New**
3. Upload the file — you'll see a preview of what will change
4. Click **Apply** to save the changes

The import parser identifies:
- **Point** features → problem location updates
- **Polygon** features → boulder outlines

All features in the file must belong to the same area.

### Tips
- JOSM with the Fastdraw plugin is an alternative to geojson.io for drawing many polygons quickly — see [JOSM docs](https://josm.openstreetmap.de/)
- OpenStreetMap may already have boulder polygons for well-mapped areas — export via [Overpass Turbo](https://overpass-turbo.eu) using `natural=rock` query
- The `ignore_for_area_hull` flag on a boulder excludes it from the area's bounding box calculation (useful for outlying boulders)

---

## Boulder Editor (In-Browser) {#boulder-editor}

The boulder editor lets you trace boulder outlines directly in the browser over a satellite image. No GeoJSON export/import needed.

**Admin → Areas → [area] → dot menu → Boulder editor**

### Drawing a new boulder

1. Click **Draw boulder** — the cursor changes to a crosshair
2. Click on the satellite image to place vertices around the boulder outline
3. **Double-click** to finish and save the polygon — it appears on the map immediately
4. Press **Escape** to cancel without saving

### Editing an existing boulder

1. Click any grey polygon on the map to select it (it turns blue)
2. Its vertices appear as small draggable blue dots
3. Drag any vertex to reshape the outline
4. Click **Save changes** to save
5. Click elsewhere on the map (or the selected boulder again) to deselect without saving

### Deleting a boulder

1. Click the polygon to select it
2. Click **Delete boulder** — confirm the prompt
3. The polygon is removed from the map and the database

### Tips

- Zoom in to at least zoom level 19 before tracing — satellite detail is much better at high zoom
- Click a boulder ID in the left sidebar to fly the map to that boulder
- The count in the sidebar updates as you add or delete boulders

---

## GeoJSON Import Workflow

Used to update problem locations and boulder polygons in bulk.

**Admin → Imports → New**

1. Upload a `.geojson` file (must be a FeatureCollection)
2. The preview page shows exactly what will be added/changed
3. If there are conflicts (someone else edited the same records since the file was exported), the import is blocked
4. Click **Apply** to commit all changes

### File rules
- All features must belong to the same area (inferred from `problemId` / `boulderId` properties)
- Point features with a `problemId` property update problem locations
- Polygon/LineString features update boulder outlines
- New polygon features (no `boulderId`) create new boulder records
- The file is validated before applying — no partial imports

---

## Individual Problem Editing

**Admin → Areas → [area] → [circuit or All] → click problem**

From a problem's show page you can:
- Edit name, grade, steepness, sit start, UKC URL
- Set or update location (lat/lon)
- Add a topo photo
- Draw lines on existing topos
- View contribution requests

### Linking to a circuit
Set `circuit_id` via the problem edit form. Circuit membership determines the coloured dot shown on the map.

---

## Problem Description

Each problem has an optional free-text description field for beta, key moves, starting instructions, or any other notes.

### Adding or editing a description
1. Open a problem in admin and click **Edit**
2. Fill in the **Description** field at the bottom of the form
3. Save — the text appears below the topo photo on the public problem page

Leave the field blank and nothing is shown. Plain text only.

---

## Topos and Line Drawing

Topos are the guidebook-style photos that show where to climb on a boulder face. Lines drawn on them link the photo to specific problems.

### Uploading a topo
**Admin → Topos → New**
- Upload the photo file
- Optionally upload a metadata JSON file (from the iOS app) to auto-link to problems

### Drawing lines
1. Open a problem's show page
2. Click **New line** (or edit an existing line)
3. In the line editor, click on the photo to place control points for the line
4. Save — the line links the topo to the problem

### Deleting a topo
Navigate to the topo's edit page directly via `/en/admin/topos/<ID>` (find the ID from the problem's show page). Click the red **Delete topo** button and confirm. This permanently deletes the topo and all its associated lines.

---

## Circuits

Circuits group problems by colour and difficulty range, following the Fontainebleau circuit tradition.

- Each problem can belong to one circuit
- Circuits are listed on the area page and filterable on the map
- Currently only super admins can edit circuit details (colour, risk rating)
- Circuit membership is set per-problem via the problem edit form

---

## POIs and Routes

Points of Interest (parking areas, train stations, bus stops) help users navigate to climbing areas.

**Admin → POIs** — manage POI records (super admin only)

**Admin → POI Routes** — link POIs to areas with distance and transport type

POI routes appear on the area edit page and are shown in the mobile app.

---

## Contributions

Users can submit photos and route information to improve topos. The contribution form includes:

- **Boulder photo** — uploaded by the contributor; GPS coordinates are automatically extracted from EXIF metadata if available
- **Route line** — drawn directly on the uploaded photo using an in-browser canvas tool; stored as normalised JSON coordinates. Alternatively, the contributor can select an existing topo from the area and draw the line on that instead of uploading a new photo.
- **UKC link** — optional link to the problem on UK Climbing (ukclimbing.com)
- **GPS location** — auto-populated from photo EXIF, or entered manually

**Admin → Contributions** — review pending submissions. The list opens on the **pending**
queue by default, shows a photo thumbnail, submission date and comment preview for quick
triage, and is paginated. A badge at the top shows how many contributions are still pending.
Tick the checkboxes to **bulk-close** several at once (with an optional shared note that goes
into the decline emails) — handy for clearing spam or duplicates. Acceptance stays one-at-a-
time because each import needs its own photo/line/GPS decisions.

The three states are:

- **pending** — awaiting review
- **accepted** — accepted and applied to the data
- **closed** — declined

The edit page records when a contribution was accepted or closed and which admin did it.

When reviewing a contribution, the admin edit page shows:
- The contributor's UKC link (if provided) as a clickable link
- The boulder photo with the drawn route line overlaid in red
- GPS coordinates, name, and any comments

### Partial acceptance

When setting state to **accepted** you can choose which parts to apply using the checkboxes on the edit form. The labels adapt to what the contribution actually contains:

- **Line on Topo #N (no new photo is created)** — shown when the contributor drew on an existing topo; accepting only adds a Line record to that topo
- **Photo & line (new topo)** — shown when the contributor uploaded a photo and drew a line; accepting creates a new topo with the line overlay
- **Photo (new topo, no line drawn)** — shown when the contributor uploaded a photo without drawing a line
- **GPS coordinates** — copies the contributor's GPS location to the problem (only applied if the problem has no existing location; a hint appears if the problem is already located)

If the contribution carries no photo/line or no GPS, the corresponding checkbox is replaced by a "nothing to import" note. Checkboxes are checked by default. Uncheck either to skip that part — useful when the photo is good but the GPS is inaccurate, or vice versa.

Accepting a contribution automatically closes any open contribution request for that problem.

After accepting or closing, you are returned to the contributions list so you can carry on
triaging. The green banner summarises what was applied — e.g. "Contribution #123 accepted ·
line added to Topo #74 · 2 pending remaining" — with the topo linked so you can verify the
import in one click. Updates that don't change the state (e.g. editing the moderator note)
stay on the edit page.

### Existing topo line contributions

If the contributor selected an existing topo photo and drew a line on it (rather than uploading a new photo), the contribution will have an `existing_topo_id` set. When you accept the **Photo & line** part, the system creates a new Line record on that existing topo using the submitted coordinates — no new topo is created.

The whole acceptance import (GPS + line + topo + closing requests) runs in a single database
transaction (`ContributionImporter`). If any step fails, **nothing** is applied and the edit
page shows an error — you never end up with GPS applied but the line missing.

### Unlisted problems (creating a problem from a contribution)

Contributors can submit a problem that isn't on the map yet — these arrive with a
**problem name / URL** but no linked problem. On the edit page for such a contribution,
a **Create & link problem** form lets you pick the area and set the name, grade and
steepness. Creating it makes a real `Problem` (inheriting the contribution's GPS), links the
contribution to it, and then you accept the contribution as normal to import the photo and
line.

### Contributor emails and the moderator note

Contributors who leave an email address are kept in the loop automatically:

- **On submit** — an acknowledgement email ("we received your contribution, pending review").
- **On accept** — a confirmation email.
- **On close (decline)** — a decline email. If you fill in the **Note to contributor** field
  on the edit form, that note is included in the decline email so the contributor knows why.

Contributors with no email address simply don't receive anything; no action is needed.

### Notification recipients

Staff "new contribution" alerts go to the address(es) in the `CONTRIBUTION_EMAILS`
environment variable (comma-separated for multiple), or the `contribution_emails` Rails
credential. If neither is set it falls back to the Dartmoor team address. Set this so the
right people are notified:

```
CONTRIBUTION_EMAILS=you@example.com,teammate@example.com
```

### Spam protection and data integrity

The public form is rate-limited per IP (rack-attack) and carries a honeypot
(invisible_captcha), so automated spam is dropped before it reaches the queue. Contributions
are also validated server-side: a submission must carry at least one piece of real content
(photo, location, line, comment or problem name) and any email address must be well-formed —
empty/garbage rows can no longer be saved.

### Location pin picker (contributor side)

On the public form, contributors set the GPS location by dragging a pin on an interactive map
(MapLibre + OpenFreeMap), centred on the problem's area. The pin and the latitude/longitude
fields stay in sync, and both auto-fill from the photo's EXIF GPS data when present.

---

## Email Setup

### What gets sent and when

All emails come from `ContributeMailer` (`app/mailers/contribute_mailer.rb`):

| Email | Recipient | Trigger |
|---|---|---|
| New contribution | Staff | A contribution is submitted |
| Acknowledgement | Contributor | A contribution is submitted |
| Accepted | Contributor | A contribution is accepted |
| Declined | Contributor | A contribution is closed (includes the moderator note if set) |

Contributor-facing emails are **silently skipped when the contribution has no contributor
email** — the email field on the public form is optional. Staff recipients come from the
`contribution_emails` credential, then the `CONTRIBUTION_EMAILS` env var, then the Dartmoor
team address (see [Contributions](#contributions)).

### Development

Emails are **not sent** in development. They are written as files to `tmp/mails/<recipient>`
— open the file to see exactly what would have gone out. The server log also shows each
mailer job being enqueued and performed.

### Production

Production sends through whatever SMTP server is configured under the `smtp` key in Rails
credentials (`bin/rails credentials:edit`):

```yaml
smtp:
  address: mail.enmail.co        # outgoing/SMTP server (incoming/IMAP is not used)
  port: 587                      # 587 = STARTTLS, 465 = implicit TLS (both handled)
  username: <mailbox username>
  password: <mailbox password>
  from: Bowda <you@yourdomain>   # must be an address this server may send as
```

Notes:

- `from` is used as the sender on all outgoing email (`app/mailers/application_mailer.rb`).
  Most mail servers refuse to send as an address that isn't yours, so use the mailbox's own
  address. Check the recipient's spam folder on the first test — if it lands there, ask your
  mail host about SPF/DKIM records for the sending domain.
- If the credentials are missing or wrong, every send fails — and since emails go out from
  background jobs, the admin UI won't show an error. Failed jobs are visible at `/jobs`
  (admin login) and in `journalctl --user -u boolder-rails`.
- After editing credentials, restart the app: `systemctl --user restart boolder-rails`.

To test on the server: `RAILS_ENV=production bin/rails runner 'ContributeMailer.with(contribution: Contribution.last).acknowledgement_email.deliver_now'`
— `deliver_now` surfaces SMTP errors directly in the terminal instead of hiding them in a job.

---

## Language Support

The site is **English-only** (June 2026). The French locale inherited from upstream was
removed because its translations described Fontainebleau, not Dartmoor. Old `/fr/...` URLs
301-redirect to their `/en/...` equivalents. URLs keep the `/en/` prefix so existing links
stay valid. The Fontainebleau "circuit 7a" feature and the upstream mobile-app page were
removed at the same time (`/en/app` now redirects to the map).

---

## Open Data Export

> **Development-only for now (since June 2026):** the export is disabled in production until
> the other contributors have agreed to releasing the data under CC0. To re-enable it, remove
> the `Rails.env.local?` guards in `config/routes.rb`, `app/views/pages/about.html.erb` and
> `app/views/layouts/_footer.html.erb`.

The full problems dataset is downloadable as CSV, intended for release under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) (public domain):

```
https://bowda.edsouthwood.com/data/problems.csv
```

- **Columns:** `id, name, grade, steepness, latitude, longitude, area, url`
- **What's included:** problems in a *published* area that have a location — the same
  visibility rule as the public site (`Problem#published?`). Unnamed problems export with a
  blank name. Nothing else (contributor details, drafts, unpublished areas) is exposed.
- **Implementation:** `app/controllers/open_data_controller.rb`; generated on the fly with an
  ETag so repeat downloads get 304 responses.
- The download is linked from the About page ("Open data" section) and the site footer.

---

## Offline Use (Map & Photos) {#offline-use}

Mobile signal often drops out on the moor, so each area page has a **"Save map & photos
for offline"** button (under the area description). One tap makes the whole area usable
with no connection — both the topo photos *and* the interactive map.

### What gets downloaded

- **Topo photos** for the area (as before).
- **The problem pages** for the area, so tapping a problem on the map opens its page (with
  the topo and route line) offline.
- **The base map** for the area's bounding box: the OpenFreeMap style, vector map tiles
  (zoom 0–14; the map over-zooms these for the close-up problem view), plus the map's
  glyphs and sprites.
- **The overlay data**: the problem/boulder and area-label GeoJSON.
- **The app itself**: the area page, the map page, and the JS/CSS they need (including the
  MapLibre map library), so the map renders with no network.

Sizes are small — a single area is on the order of a few MB. A timestamp and a "Remove"
link appear once saved; **Remove** clears that area's tiles and photos again. If any files
fail to download, the saved message says how many — re-save on a better connection.

### Checking what's saved: /en/offline-status

The **offline status page** (`/en/offline-status`, linked as "Details" next to a saved
area) is a diagnostic read-out: the service worker version, how many entries each cache
holds, which base-map tile snapshot is pinned, and — per saved area — how many of its topo
photos, problem pages and map files are actually present. Each area is marked
**Complete** or **Incomplete** (incomplete = re-save it from the area page). If offline
mode ever misbehaves in the field, a screenshot of this page is the bug report.

### Returning to the map

Tapping a problem on the map opens its page **in the same tab**, and the page then offers
**"Back to the map"** — in the breadcrumb row at the top, and in place of the usual
"See on the map" link under the photo. Both return you to the *exact* zoom and centre you
left, so you can carry on looking at the boulders around you. The browser's Back button
does the same thing. This works offline as well as on.

Arriving at a problem any other way (a search result, an area list, a shared link) is
unchanged: there is no back control and the link under the photo still reads
"See on the map" and centres on that problem.

### How it works (for developers)


- A **service worker** (`public/service-worker.js`, versioned via `SW_VERSION`) serves the
  cached assets when offline: cache-first for map tiles, map libraries and fingerprinted
  `/assets/`; network-first (with offline fallback) for the GeoJSON and HTML pages;
  cache-first for topo images. HTML matching covers both real navigations *and* Turbo
  Drive visits (plain fetches with an `Accept: text/html` header) — matching only
  `request.mode === 'navigate'` misses every in-page link click. Network-first races the
  network against a **3.5 s timeout**: on a weak signal (one flickering bar, the usual
  case on the moor) fetch can hang for tens of seconds, which would make cached pages look
  broken.
- **`/admin` is never intercepted.** The worker's `fetch` handler returns early for any
  path under `/admin` or `/:locale/admin`, so those navigations go straight to the browser.
  Admin is online-only and behind HTTP basic auth: routing it through network-first meant a
  slow-but-working connection tripped the 3.5 s timeout and served the synthetic "You're
  offline" page, and a 401 challenge mediated by `respondWith` doesn't reliably raise the
  browser's credential dialog. If you *were* offline you'd want a real error there anyway,
  not a cached page.
- The **download controller** (`app/javascript/controllers/offline_download_controller.js`)
  pre-fetches everything when the button is tapped. It reads the area's bounds and map URLs
  from `Areas::OfflineDataController` (`/dartmoor/:slug/offline-data`), enumerates the map
  tiles covering the bounds, and parses the map page for the JS/CSS assets to cache.
  Failed URLs are counted and surfaced instead of being silently dropped.
- **OpenFreeMap tile URLs contain a dated snapshot** (e.g. `/planet/20260621_080001_pt/…`)
  that rotates and is eventually deleted server-side. The download therefore fetches the
  style and TileJSON *fresh* (a `sw-bypass` query param makes the service worker step
  aside) and re-pins them under their canonical URLs, so the pinned TileJSON and the
  downloaded tiles always belong to the same live snapshot.
- OpenFreeMap only serves **Noto Sans** glyphs; overlay layers must use `Noto Sans
  Regular` / `Noto Sans Bold` for `text-font` (the MapLibre default, Open Sans, 404s and
  the labels silently don't render — online or off).
- **End-to-end check**: `script/offline_check.mjs` (Playwright) clicks Save on an area,
  relaunches the browser behind a dead proxy (total offline, including service-worker
  fetches), and asserts the map, tiles, glyphs, problem pages, topos and status page all
  serve from cache. Run with a dev server up: `node script/offline_check.mjs <slug>`.
  Note: stale precompiled assets in `public/assets/` shadow current JS in development —
  test from a checkout without them (or clobber them) when iterating.
- The base map style URL is defined in both `mapbox_controller.js` (the live map) and
  `offline_download_controller.js` (the offline pre-download) — keep the two in sync.
- **"Back to the map" carries the viewport in the URL fragment.** The map stamps its live
  view onto the popup link as `#map=<zoom>/<lat>/<lng>[/<bearing>[/<pitch>]]`
  (`mapbox_controller#viewportHash`, MapLibre's own hash format), and
  `map_return_controller.js` turns that back into a bare `/<locale>/map#<zoom>/<lat>/<lng>`,
  which MapLibre's `hash: true` restores on load. A fragment is deliberate: it is **never
  part of an HTTP request**, so it is invisible to the Cache API and the whole feature needs
  no service-worker or pre-cache change. A query parameter would miss the cache.
  The return target must be the **bare** map — with a `:slug` or `?pid=`, `centerMap()`
  flies over the hash. A `sessionStorage` copy keeps the control working after a hop to a
  variant problem page, which carries no fragment of its own.
- The map popups link straight to the canonical problem page (`problem.path` from the
  map-data GeoJSON), not the `/redirects/new` 302, so the cached page resolves offline.
- "See on the map" links carry `?pid=<problem>`, but only the bare map page is cached
  (the Cache API matches query strings exactly). The worker serves map pages with
  `ignoreSearch` as a fallback, and `mapbox_controller` re-resolves the `pid`
  client-side from the cached map-data GeoJSON to fly to the problem and open its
  popup. The bare `/en/map` page (the header link) is pre-cached too.
- The service worker never resolves a navigation with `null`; uncached pages fall back to a
  small "You're offline" page (and the overlay GeoJSON to an empty FeatureCollection), so
  visiting something you didn't download degrades gracefully instead of erroring.

**Known limitation:** only an area's *own* problem pages are cached. Following a link to a
problem in a different (un-downloaded) area still needs a connection — it shows the offline
fallback page rather than erroring.
