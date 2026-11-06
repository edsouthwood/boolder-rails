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
9. [Photo Inbox (Upload Many Photos)](#photo-inbox)
    - [Boulder Photos from Visitors](#boulder-photos)
    - [Boulder Names and Importing a Problem List](#boulder-names)
10. [Importing Problems from Photos](#importing-from-photos)
11. [Location Editor (Drag-and-Drop)](#location-editor)
12. [Adding Boulders (Polygon Map Data)](#adding-boulders)
13. [Boulder Editor (In-Browser)](#boulder-editor)
14. [GeoJSON Import Workflow](#geojson-import-workflow)
15. [Individual Problem Editing](#individual-problem-editing)
16. [Problem Description](#problem-description)
17. [Topos and Line Drawing](#topos-and-line-drawing)
18. [Circuits](#circuits)
19. [POIs and Routes](#pois-and-routes)
20. [Contributions](#contributions)
21. [Email Setup](#email-setup)
22. [Language Support](#language-support)
    - [Boolder Credit in the Footer](#boolder-credit)
23. [Open Data Export](#open-data-export)
24. [Offline Use (Map & Photos)](#offline-use)
25. [Problems by Grade and Map Grade Filters](#problems-by-grade)
26. [Printable Topo Sheets](#topo-sheets)
27. [Stats](#stats)
28. [Search engines](#search-engines)
29. [Support Page (Donations)](#support-page)

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

- **Admin passwords** travelled over plain HTTP while the site ran in dev mode, before Caddy's
  HTTPS. They live in the encrypted credentials (`admin_accounts`; see [Admin Accounts](#admin-accounts)),
  not `.env`. Checked 2 Nov 2026: none appears in plain text anywhere in git history. Ed decided
  not to rotate them, because the only exposure was interception of pre-June traffic. Change one
  with `bin/rails credentials:edit` if that account was used on an untrusted network before June,
  or if you have any reason to think it leaked.
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
curl --resolve bowda.edsouthwood.com:443:127.0.0.1 https://bowda.edsouthwood.com/
```

### Uptime monitoring {#uptime-monitoring}

A GitHub Actions workflow, `.github/workflows/uptime.yml`, checks the live site every
15 minutes (at :07, :22, :37 and :52) from GitHub's servers. It still works when this machine
or its internet connection is down. It runs `script/uptime_check.sh`, which checks that:

- `https://bowda.edsouthwood.com/up` returns 200
- `/` returns 200 and contains "Bouldering on Dartmoor", so a Caddy error page or a parked
  domain doesn't count as up
- the HTTPS certificate has at least 14 days left (Caddy normally renews at 30)

Each check is tried 3 times, a minute apart, before it counts as a failure. When a run fails,
GitHub emails the account that last changed the workflow's `cron` line, and keeps doing so
every 15 minutes until the site is back. If the emails don't arrive, check GitHub → Settings →
Notifications → Actions ("Send notifications for failed workflows only" should be on, with
email selected).

- **History and on-demand checks:** the repository's Actions → Uptime page lists every run
  with a summary; **Run workflow** checks straight away.
- **From the server:** `UPTIME_RESOLVE=127.0.0.1 script/uptime_check.sh` (this skips the router
  hairpin described above).
- **Pausing it** (planned downtime): Actions → Uptime → ⋯ → Disable workflow, then enable it again.
- **Caveats:** GitHub can run scheduled jobs a few minutes late when busy, and it pauses
  schedules in a public repository after 60 days without commits, emailing a warning first.
  Re-enable it from the Actions page if that happens.

### Error monitoring (Bugsnag)

Errors are reported to [Bugsnag](https://app.bugsnag.com), production only, tagged
with the deployed git commit so you can see which release introduced a problem.

- **Browser** (JavaScript errors only — no performance monitoring or session tracking, so
  nothing is sent unless an error happens): `app/views/layouts/_bugsnag.html.erb`, rendered in every layout. Its API key is in the partial — browser keys are public by design.
  Offline pages simply skip it.
- **Server** (Rails exceptions, including background jobs): `config/initializers/bugsnag.rb`
  reads `bugsnag: api_key` from the production credentials. Until it's set, the app logs
  "No valid API key has been set, notifications will not be sent" at startup.

Visitor IP addresses are kept out of both (browser: `collectUserIp: false`; server: the
user id is dropped and `clientIp`/forwarding headers redacted), and nothing is stored on
visitors' devices. The privacy policy describes this — update it if the setup changes.

---

### Content-Security-Policy {#content-security-policy}

Every page sends a Content-Security-Policy listing where scripts, styles, images and
connections may come from (`config/initializers/content_security_policy.rb`). It is in
**report-only** mode: browsers block nothing, they just report anything that *would*
have been blocked to `/csp-violations`, which writes a line to the production log:

```bash
journalctl --user -u boolder-rails --since "7 days ago" | grep "\[CSP\]"
```

Each line names the rule, what was blocked and the page, e.g.
`[CSP] img-src blocked https://tiles.example.com/... on https://bowda.edsouthwood.com/map`.
A legitimate new service (a new tile provider, say) means adding its host to the policy;
anything unfamiliar is worth a closer look. Once a stretch of real traffic reports nothing
unexpected, enforce it by setting `content_security_policy_report_only = false`.

Rules for page code, so the policy keeps working:
- Inline `<script>` blocks need `javascript_tag nonce: true` (or `nonce="<%= content_security_policy_nonce %>"`)
- No inline event handlers (`onclick=`, `onchange=`) or `javascript:` links; use Stimulus actions
- MapLibre is loaded with the `shared/maplibre_script` partial, which raises `maplibre-ready`

A **Permissions-Policy** header is enforced too: no camera, microphone, USB or payments;
geolocation (the map's "locate me" button) and fullscreen for the site itself only.

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
2. Restore `.env`, `.env.backup` and `config/master.key` from the webspace (then `chmod 600 .env .env.backup`)
3. Restore the database (the dump recreates PostGIS and every table):
   ```bash
   rsync -az u79222@edsouthwood.com:bowda-backup/db/dartmoor-production-YYYYMMDD.sql.gz .
   createdb dartmoor-production
   gunzip -c dartmoor-production-YYYYMMDD.sql.gz | psql dartmoor-production
   ```
4. Restore storage files: `rsync -az u79222@edsouthwood.com:bowda-backup/storage/ storage/`
5. The cache, queue and cable databases need no restore: `RAILS_ENV=production bin/rails db:prepare` creates them empty

**Last restore test: 1 Nov 2026.** That night's dump, fetched back from the webspace, restored
into a scratch database with no errors. Every table count matched production (12 areas,
1,163 problems, 156 boulders, 79 topos, 390 photo blobs), PostGIS geometry was intact,
and sampled photo files were byte-identical off-site. Worth repeating every few months.

---

## Admin Accounts

Admin logins are managed on the website, under **Accounts** in the admin bar (super admins
only). Passwords are stored as bcrypt hashes, never as readable text.

- **Add an admin**: username, role (super admin or area admin), and for an area admin the areas
  they can work on. Leave the password blank and a strong one is made and shown **once** on the
  Accounts page: send it to them privately and ask them to change it.
- **Edit**: change the role or areas, set a new password (or tick *Make a new random password*),
  or tick **Disabled**. A new password or disabling signs that person out everywhere at once.
- **Delete**: only a disabled account can be deleted; its past edits stay in the audit log.
- Every change asks for **your own password** again, and is recorded in the audit log.
- There's always at least one enabled super admin: the last one can't be demoted or disabled, and
  you can't change your own role or disable yourself.

**My account** (click your username, top right) shows your role and areas and lets you change your
own password: at least 12 characters. You stay signed in on that browser; others are signed out.

### Where logins come from
Logins use these accounts as soon as there's an enabled super admin among them. Until then, and as
an emergency way back in, the old `admin_accounts` list in the encrypted credentials file (or
`ADMIN_USERNAME` / `ADMIN_PASSWORD`) is used instead. On the server:

```bash
bin/rails admin:import_accounts          # copy the credentials accounts across (once; skips existing)
bin/rails admin:set_password ADMIN=ed    # locked out? set (or create) a super admin's password
```

Imported accounts keep their old passwords, even ones shorter than 12 characters (the import
says which); ask those people to change them from My account. Once accounts are in use, the
credentials `admin_accounts` list can be emptied.

### Login lockout
After 10 wrong passwords from one IP address, admin login (including `/jobs`) is refused
with "429 Too Many Requests" for 15 minutes from the first failure. To unlock early, run
this in `RAILS_ENV=production bin/rails console` on the server:

```ruby
Rails.cache.delete("admin_login_failures/<ip address>")
```

### Signing in and out
An admin login lasts 14 days, after which the browser asks for the password again.
**Sign out** (top right of the admin header) ends it straight away. Browsers keep the
password saved and re-send it by themselves, so after signing out the next admin page
asks for it once more on purpose. Admin-only extras on public pages (the cog link on a
problem, unpublished search results) also disappear when the login ends.

---

## Permission Levels

| Role | What they can do |
|---|---|
| `super_admin` | Full access: create/delete areas, manage all data, imports, bulk uploads, audits |
| `area_admin` | Edit assigned areas and their problems, topos, lines; download/upload GeoJSON for their areas; view contributions |

### Area admin restrictions
- Area creation and deletion: super admin only
- Circuits: super admin only
- Bulk uploads, POIs, audit log: super admin only
- GeoJSON import apply step: scoped to assigned areas (every area the file touches is checked)
- Problems can only be moved between areas the admin has access to
- GeoJSON download: accessible per assigned area

---

## Managing Areas

Areas are the top-level geographical groupings. Each area has problems, boulders, circuits, and POI routes.

### The area tool bar
Every admin page for an area has a tool bar under the breadcrumbs:
- **Tabs** for the working views: **Problems** (the problem list), **Boulders** (progress list), **Photos** (topos; click one for the workbench), **Map** (location editor) and **Outlines** (boulder editor). The one you're on is underlined.
- **Counts** on the tabs show what's waiting: boulders that need photos or lines, photos with lines still to draw, and problems to place (no location yet, or only an estimated one).
- **+ Add**: Upload photos, Import problem list, New problem.
- **⋮** for rarer actions: Edit area, Edit circuit (on a circuit's problem list), Map download, Map import.

The **Areas** list has the same shortcuts in its **Tools** column (Boulders, Photos, Map, with the photo and map counts). Photos opens on "Photos to draw" when there are any.

### Creating an area (super admin only)
1. Go to **Admin → Areas → New area**
2. Fill in `name`, `slug` (URL-friendly, e.g. `bonehill-rocks`), `short_name`, priority, and descriptions
3. Leave `published` unchecked until the area is ready to go live
4. Save — then add problems and boulders before publishing

### Editing an area
- **Edit** — update name, descriptions, cover photo, tags, POI routes
- **Delete** — permanently removes the area and all its problems, boulders, topos, and circuits (super admin only)

### Publishing
Toggle the `published` checkbox on the edit screen. Unpublished areas are hidden from the public map and API, and their pages, problem pages, mapping pages and offline download return "not found" to the public, even to someone who guesses the address. Signed-in admins still see them. Photos are only served publicly when the photo is published *and* its area is; admin pages load photos another way, so you can still work on an unpublished area.

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

## Boulder Names and Importing a Problem List {#boulder-names}

Boulders can have names, and every problem can say which boulder it's on, even before it has
a location or a photo. That gives each area a to-do list of boulders still needing photos or
lines.

### Importing a problem list

Area tool bar **+ Add → Import problem list** (`/admin/areas/<slug>/problem-list`). Paste a list or
choose a `.txt` file in this shape: each boulder's name on its own line, then its problems one
per line, each starting with a tab, then the problem's name, a tab and its grade (`f6B`, `6b`,
`f4+` and `5` all work):

```
  Photo Arête
  Little Roof
		Name	Grade
Photo Arête
		Photo Wall	f4
		Photo Arête	f5
Little Roof
		Roof Jug	f5
```

- The list of names at the top is optional. When it's there, any other untabbed line is a note
  (sun, approach…) and is ignored. Without it, a line straight after a boulder's name is a note.
- Only names and grades are read. Other columns are ignored, and grades that aren't bouldering
  grades (e.g. `Summit`) are skipped.
- **Preview** shows every boulder and problem before anything is saved:
  - **matches** is an existing problem with the same name. Accents, case and apostrophes are
    ignored. It goes onto that boulder.
  - **moves from …** means the problem was on another boulder.
  - **Change grade a → b** shows where the list's grade differs. Grades only change if you tick
    the box.
  - **new** creates the problem. It's ticked by default; untick to leave it out.
  - **check** is a near-identical name (one or two letters out). Pick the existing problem,
    "Create as a new problem", or leave it on "Skip this row".
  - **new boulder** is created without an outline, ready to be drawn.
- Importing the same list again is safe: nothing is duplicated.

### Hiding problems

Some problems on a list aren't worth showing yet. **Hide** keeps one in the system but leaves it
off the public site (map, area pages, grade lists, search, offline downloads, other problems'
photos; its own page is a 404 to the public) and out of the Boulders list counts and the workbench.

- **On the import preview**, tick **hide** on a row. Rows for problems that are already hidden
  start ticked; unticking one shows it again.
- **On the Boulders list**, expand a boulder and click **Hide** next to a problem. Hidden ones are
  listed struck through under their boulder (the summary says "(2 hidden)"), each with **Show
  again**. A boulder whose problems are all hidden shows as "No problems", under the **All** tab.
- **On a hidden problem's admin page**, a banner says so, with **Show it again**. The area's admin
  problem list marks hidden problems too.

Admins can still open a hidden problem's public page, with a notice that it's hidden.

### The Boulders list

Area tool bar → **Boulders** tab (`/admin/areas/<slug>/boulders`) lists every boulder, most urgent
first:

| Status | Meaning | Next step |
| --- | --- | --- |
| Not on map | A name with no outline yet | **Draw it** in the boulder editor |
| Needs photos | Drawn, no photos | **Upload photos** (photo inbox) |
| Needs lines | Some of its problems have no line | **Draw lines**: opens the workbench on its next photo |
| Done | Every problem has a line | – |
| No problems | Usually an unnamed outline | – |

**Needs topos** (the default) hides Done and No problems; **All** shows everything. Click a
boulder's name to see its problems (✓ = has a line). Problems on no boulder are listed at the
bottom.

A photo counts for a boulder when it has a line for one of the boulder's problems, or the photo
inbox matched it there by GPS.

How problems get a boulder: from an imported list, or when a located problem sits on an outline.
That happens when the problem gets its location and when the outline is drawn. A boulder set by
a list is never overwritten by location. (When this went live, existing located problems were
linked to the outline they sit on.) To change one problem's boulder, use the **Boulder** menu on
its edit form.

### Naming outlines in the boulder editor

- **Select an outline**. Under **Name** is a list of your listed names that aren't drawn yet,
  with their number of problems; typing narrows it. Click a name to give it to the outline
  straight away, or type a name and press Enter or **Set**. Picking a listed name gives the outline that boulder's
  problems, and the name leaves the "Not on the map yet" list. Typing any other name just renames
  the outline; clearing the box removes the name. A name already used by another outline is
  refused.
- **Picked the wrong listed name?** Picking a second listed name for an outline that already has
  one asks first. **OK** swaps: the outline takes the new name and its problems, and the old name
  goes back on the "Not on the map yet" list with its problems, ready for the right outline.
  **Cancel** then offers to merge both lots of problems onto the outline instead, for a list that
  split one boulder in two; cancel again to change nothing.
- Photos tied to a listed boulder in the workbench (and visitor photos of it) move to the outline
  that takes over its name. Deleting an outline clears photo ties to it.
- **Not on the map yet** (sidebar) lists listed names without an outline, with their number of
  problems. Click one, then draw its outline as usual; it's saved onto that boulder.
- **LiDAR suggestions**: a suggestion's popup also has **Add as a listed boulder…**, to turn it
  straight into one of those names.
- The Boulders list links straight in: **Draw it** opens the editor ready to draw that name, and
  **Show in boulder editor** zooms to an outline and selects it.
- Deleting a named outline takes its problems off it (they're kept, on no boulder).

On the public site, named outlines are labelled on the map when zoomed right in (from zoom 18;
problem grades take priority where they overlap), and a problem page's breadcrumb ends with its
boulder's name (Dartmoor › Bell Tor › Photo Arête). Offline downloads pick up new or changed
names as "Update available".

## Photo Inbox (Upload Many Photos) {#photo-inbox}

The quickest way to get a batch of topo photos onto the site. Any admin for the area can use it.

1. Open the area, then **+ Add → Upload photos** (or **Upload photos** on the area's Topos page)
2. Drop in as many photos as you like, or click to choose them. JPEG, PNG or WebP, up to 25 MB each
3. They upload one at a time, each with a status line: whether it had GPS, and the boulder it was matched to. Keep the tab open until they finish; the browser warns you if you try to leave early

What happens to each photo:

- It becomes a topo in the area, even before any lines are drawn on it, so area admins can see and edit it
- If it has GPS, the nearest boulder within 15 m is noted as **near boulder #N**. This is only a hint for you when drawing; the real link to a boulder is made once lines are drawn
- The GPS position and compass heading are kept with the photo

Each photo on the area's Topos page shows its boulder's name under the topo number (click it to open the boulder editor): **· tied** when you tied it in the workbench, "near" when it was only matched by where the photo was taken.

**Photos to draw** on the area's Topos page lists photos with no lines yet, plus any with a line still to draw (for example from a bulk upload). Click a photo there (or **Photo #N →** straight after uploading) to open it in the [Topo Workbench](#topo-workbench) and draw its lines.

---

## Boulder Photos from Visitors {#boulder-photos}

Visitors can send photos of boulders without picking a problem first, from **Add boulder photos** (`/mapping/photos/new`). It's linked at the top of the Contribute page, the Mapping page and each area's "Problems to map" list.

**What the visitor does**

1. Chooses an area
2. Chooses **which boulder** from a list of the area's boulders with **no photo at all**, most problems first. It uses the same rule as the admin Boulders list: a boulder has a photo once a line is drawn for one of its problems, the topo recompute linked one to it, or an inbox or contributed photo was matched to it. Only named boulders, or ones with problems, are listed; unnamed outlines aren't. Boulders without an outline are marked **Not on the map yet**, and ones with a photo waiting for review are marked so. The last option, **Another boulder, or not sure**, leaves it to GPS. A link can preselect a boulder with `&boulder_id=N`
3. Chooses or drops photos. Each is checked in the browser before anything is sent: JPEG/PNG/WebP under 15 MB, landscape only (portrait photos are refused with a "retake in landscape" message, as topos are cropped to 4:3), and GPS + compass heading read from the photo
4. Optionally gives a name (for the contributors leaderboard), email and comment, then presses **Send photos**. Photos upload one at a time. **Photograph another boulder** goes back to the list for the next one

Where each photo was taken:

- From the photo's own GPS when it has one
- If it has none but was taken in the last 15 minutes, the phone's current position is used instead (only if accurate to 50 m). These show as **(phone position)** in the queue
- Otherwise it has no position, and you place it by hand when drawing

The photo's boulder is the **chosen** one when the visitor picked one, which also sets the area. Otherwise, a photo with a position is matched to the nearest boulder outline within 15 m **in any published area**, and that boulder's area wins over the one the visitor chose. The GPS match is kept either way: if it disagrees with the chosen boulder, the card says **⚠ GPS puts it at …**.

**Reviewing: Photos (N) in the admin menu** (`/admin/photo-contributions`)

- A grid of pending photos, each with its area, boulder (marked **chosen** or **by GPS**, and **not on map** when it has no outline), an OpenStreetMap link to where it was taken, contributor and comment. Area admins see only their areas
- **Accept** turns the photo into an undrawn topo in its area, exactly like a [Photo Inbox](#photo-inbox) upload (same GPS, heading and boulder hint), so it appears in **Photos to draw**. The file moves to the topo, it isn't copied. The accepted list has a **Draw lines →** link to the workbench
- **Decline** keeps the photo in the closed list, with an optional note
- Tick several (or **Select all**) to accept or decline them together

**Emails**: staff get one "New boulder photos" email per upload session, not per photo (`CONTRIBUTION_EMAILS`, as for contributions). A contributor who gave an email gets one acknowledgement per session, and one email per review action saying how many were accepted or declined (with your note when declining).

**Spam and abuse**: the usual invisible captcha checks the first photo of each upload session; the rest of that session goes through on it. Each visitor is limited to 120 photos an hour.

**Privacy**: photos are only ever shown as resized copies with EXIF (exact GPS, camera details) stripped, including on the admin grid. The same now applies to photos on the public contribution pages.

Accepted photos count towards the **Top contributors** leaderboard on the Mapping page, alongside accepted contributions.

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

**Admin → Areas → [area] → Map** tab (or **Map** on the Areas list)

### How to use

1. The left sidebar lists all problems in the area that have **no location** yet, sorted alphabetically
2. The right panel shows a map with boulder polygons for context and green pins for already-located problems
3. **Drag** a problem name from the sidebar and **drop** it onto the map at the correct position — the pin is placed and the location is saved instantly
4. Once placed, the problem disappears from the sidebar and a green marker appears on the map
5. **Reposition** an already-placed problem by dragging its marker to a new position — saves on release
6. **Amber dashed** markers are locations estimated from a photo (see [Topo workbench](#topo-workbench)). Drag each into its real spot and it turns to a normal marker. The legend under the map counts how many are left. Changing a problem's coordinates on its edit page also counts as placing it

Problems already on a photo but with no location can be given estimates in one go (dry run first, lists what it would do):

```bash
bin/rails problems:estimate_locations            # dry run; add AREA=bonehill for one area
bin/rails problems:estimate_locations APPLY=1    # save
```

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

**Admin → Areas → [area] → Outlines** tab

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
5. Click the selected boulder again (or another boulder) to deselect without saving — any unsaved changes are undone

### Deleting a boulder

1. Click the polygon to select it
2. Click **Delete boulder** — confirm the prompt
3. The polygon is removed from the map and the database

### LiDAR hillshade overlay

Under **LiDAR hillshade** in the sidebar, click **LiDAR off** to switch it on. This lays Environment Agency 1 m LiDAR over the satellite image as shaded relief. Boulders show as crisp bumps with no shadows, lichen or grass to confuse things, so outlines are much easier to judge. Use the slider to blend it with the satellite image (around 50–70% works well). Your on/off choice and opacity are remembered in this browser.

- The data is 1 m resolution, so very small boulders look blocky. Use it to find each boulder and judge its edges, then trace with the satellite image visible underneath.
- Satellite imagery can be a few metres out of place; the LiDAR is surveyed to about ±0.4 m. Where the two disagree, trust the LiDAR.
- Trees and gorse also show as bumps; they usually look softer and lumpier than rock.
- The layer is served live by the Environment Agency (England only, Open Government Licence). If it fails to load, their service is down; the rest of the editor still works.

### LiDAR boulder suggestions

Click **Suggest boulders in this view** (under LiDAR in the sidebar). The editor downloads the Environment Agency's LiDAR heights for the current view (under a second for a crag-sized view) and outlines anything that looks like rock:

- **Amber dashed** shapes don't overlap any mapped boulder — possibly unmapped rock.
- **Green dashed** shapes overlap a mapped boulder — compare them with your outline; the LiDAR is often the more accurate of the two.

Click a suggestion (where it isn't covered by a boulder) for its size and height, then:

- **Add as new boulder** saves it straight away and selects it so you can tidy the corners; click **Save changes** when done (or **Delete boulder** if it wasn't rock).
- **Replace outline of #N** puts the LiDAR outline on that boulder. Nothing is saved until you click **Save changes**; click the boulder again to undo.

When a selected boulder has an overlapping suggestion, a **Use LiDAR outline** button also appears above Save changes.

How it decides: two kinds of rock are found.

- **Freestanding rock** is anything more than 1 m above the ground model whose first and last laser returns agree. In gorse and trees the first return comes off the leaves and the last from deeper in, so vegetation is ignored.
- **Outcrops that rise out of the hillside**, like Saddle Tor's, where one face is vertical and the back melts into the slope. The Environment Agency's ground model often keeps that rock as "ground", so it sits 0 m above ground, and its last-return data there just copies the ground model. Instead the editor looks for a **face**: the ground model itself is steeper than 45° *and* the surface drops more than 1.5 m within 2 m. A bush can't pass that test, because bushes are stripped out of the ground model. Each face is widened 1.5 m uphill to stand for the top of the rock.

Shapes under 3 m² are left out. Tested Nov 2026: at Saddle Tor the face rule matched all 14 mapped boulders (the first rule alone matched none); at Bonehill results are unchanged (30 of 32).

Limitations:

- Touching boulders often merge into one shape. When a suggestion covers several mapped boulders, the popup and status line warn you — trim it to one rock before saving, or keep it if your separate outlines were really one boulder.
- Outlines are only good to about ±0.5 m (1 m data), and boulders under 1 m high are missed.
- Walls, banks and parked cars (on the survey day) can show up as rock. Steep earth banks, old field boundaries and track cuttings can pass the face test too.
- A tor whose faces join up comes out as one big shape (the main block at Saddle Tor is about 900 m² covering 7 mapped boulders). It overlaps mapped boulders, so **Add all** leaves it alone; don't use **Replace outline** with it unless you trim it first.
- Outcrop shapes follow the faces, so their uphill edge is only a guess (1.5 m back from the face). Drag it to where the rock really ends.
- **Add all N unmapped as boulders** (appears under the suggest button) saves every amber suggestion in one go, after a confirmation. Look over the amber shapes first, because walls and parked cars can show up as rock. It stops at the first error; any it didn't add stay on the map.
- The view must be under about 750 m across; zoom in if asked. Click **Suggest again for this view** after panning, or after editing boulders so the green/amber colouring is up to date.

Background: a spike at Bonehill (Oct 2026) found LiDAR rock for all 32 mapped boulders, and that mapped outlines sat a median of ~1.9 m south of the rock — probably from tracing the sunlit side and leaving out the shadowed north side.

### Tips

- Zoom in to at least zoom level 19 before tracing — satellite detail is much better at high zoom
- Click a boulder ID in the left sidebar to fly the map to that boulder
- On a phone the sidebar sits above the map; scroll the sidebar to reach Basemap and LiDAR
- The count in the sidebar updates as you add or delete boulders

### Topo order on a boulder (automatic)

Each boulder's photos are linked to it and put in order: anti-clockwise round the boulder, starting after the biggest gap between problems. The app uses this order when it steps through a boulder's photos. It's kept up to date automatically, within a few seconds, whenever you:

- draw or change a boulder outline, or delete a boulder
- place, move or clear a problem's location
- add, redraw or delete a line
- publish or unpublish a photo

Only published photos count, and only problems that sit on (or right at the edge of) an outline. A full rebuild is still available from the command line if ever needed: `bin/rails geo:compute`.

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

The area's problem list is ordered by popularity (or circuit order on a circuit tab) by default. Click the **Id**, **Name**, **Grade** or **Steepness** column header to sort by it; click again to reverse. Problems without a name or grade always go to the bottom. Sorting keeps the circuit tab and the "missing" filter.

From a problem's show page you can:
- Edit name, grade, steepness, sit start, UKC URL
- Set or update location (lat/lon)
- Add a topo photo
- Draw lines on existing topos. Click a line's photo to open the line editor (line, start holds and not-in areas)
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

### Topo workbench (quickest way to draw lines) {#topo-workbench}

One page per photo where you add every problem on it and draw all their lines, with no page reloads. Open it from:
- the area's **Topos** page: click a photo, or **Draw lines**. **Photos to draw** lists the ones still needing work
- the **Photo #N →** link after uploading through the [Photo Inbox](#photo-inbox)
- **Draw lines on this photo** on a topo's edit page, or **Draw all lines on this photo** in the line editor

**Tying the photo to a boulder:** the **Boulder** box at the top of the sidebar shows which boulder the photo is of: one you tied it to, else the boulder its drawn problems are on, else the one nearest where the photo was taken. Pick a different boulder (named ones first, then unnamed ones by number) and click **Tie** to set it, or pick **Not tied to a boulder** to go back to the automatic match. Tying is useful for photos with no GPS and for boulders from a problem list that aren't drawn on the map yet. The tied boulder gets the problems you create on the photo, and the photo counts towards that boulder on the Boulders list.

**Problems on the photo's boulder:** when the photo has a boulder, a yellow box under **Add a problem to this photo** lists that boulder's problems that aren't on the photo yet (listed on it by a problem list or by hand, or located on its outline). Click a name to add just that one, or **Add all N** to add every one in the order they were entered, then draw them one after another with **Enter**. A problem you remove with **✕** goes back into the box.

How to use it:
1. On the right, pick a problem that's already on the photo, or **add one**:
   - type to filter the area's problems. Ones **on boulder** come first: those listed on the photo's boulder (from a problem list or set by hand), then ones located on or near it. Then ones with **no line**. The photo's boulder is named in the panel heading (an unnamed one has a **name it** link to the boulder editor)
   - or type a name and grade and click **Create and draw**. The new problem is put on the photo's boulder. If the photo has GPS and was matched to a boulder, it's also placed on that boulder's edge nearest where you stood. If the photo has GPS but no boulder outline (e.g. a crag whose boulders aren't drawn yet), it's placed where the photo was taken, ready to nudge into place in the [Location Editor](#location-editor). With no GPS, place it there later
   - adding or drawing a line for a problem that has no location yet gives it an **estimated** location from the photo, taken from (in order): where the photo was taken, moved onto its boulder's outline; another problem already placed on the photo (ones placed by hand first, and only within 30 m of where the photo was taken, if it has GPS); or where the photo was taken. Problems estimated from the same photo, or that would land on a spot another problem already has (e.g. two photos taken from the same place), are spread about 2 m apart (along the boulder's outline when it's on the map, so they stay on it) rather than stacked on one spot. Nothing is estimated when a problem list put the problem on a different boulder from the photo's and no problem on that boulder is placed on the photo. A problem that already has a location is never moved
   - estimated locations show as **amber** pins in the [Location Editor](#location-editor) until you drag them into place
2. Click along the line from bottom to top. Other lines on the photo show faintly with their names
3. Press **Enter** (or **Save**). The next problem without a line is picked automatically
4. When every problem has a line, click **Next photo to draw →**

Keys: **Enter** save · **Esc** undo unsaved changes · **Z** undo last point · **N** next problem without a line · **1 / 2 / 3** switch between line, start holds and not-in areas. Picking a problem always switches back to line mode. Zoom to 2× with **+** for detail.

On a line that's already drawn, the first click starts it afresh (the old line shows in blue until then). **✕** removes a problem from the photo (its line here is deleted; the problem stays). **↗** opens the problem in a new tab.

### Drawing lines (one problem at a time)
1. Open a problem's show page
2. Click **New line** (or edit an existing line)
3. In the line editor, click on the photo to place control points for the line
4. Save — the line links the topo to the problem

### Marking start holds (optional)
You can mark up to 4 starting hand holds on a line's photo. They appear as small rings in the grade colour on the public problem page, with a "Start holds" key under the photo. Problems without them look as they did before.
1. Open the line editor (edit an existing line)
2. Above the photo, switch **Clicks add** to **Start holds**
3. Click each starting hold. Green rings mark them, and the points fill the **Start holds** box
4. Save. To remove them, click **Clear start holds** (or empty the box) and save again

Holds belong to the line, so they are positioned on that particular photo. If the line is redrawn on a different topo, mark the holds again. Contributors can also mark start holds on the public contribution form; they're copied onto the line when the contribution is accepted (see [Contributions](#contributions)).

### Marking "not in" areas (optional)
Many Dartmoor problems rule out a feature (an arête, a crack, the neighbouring boulder). You can shade those parts of the photo. On the public problem page they appear as red hatched areas, with a "Not in" key under the photo.
1. In the line editor, switch **Clicks add** to **Not-in areas**
2. Click around the off-limits section; each area needs at least 3 points and is drawn as a red shape
3. To mark a separate section, click **New not-in area** and keep clicking (up to 4 areas per line)
4. Save. **Clear not-in areas** removes them all

Like start holds, not-in areas belong to the line's photo, and contributors can mark them on the contribution form too.

**Zoom:** to place holds or area corners precisely, use the **Zoom − / +** controls (1× or 2×) in the line editor's toolbar, then scroll to pan. The contribution form has the same − / + buttons next to Undo and Clear. Zoom only changes the view. Points are saved the same way at any zoom level.

### Photo to the left / right (public problem pages) {#topo-neighbours}

A problem page's photo has **‹ ›** buttons that step to the nearest photo to the left or right, as if you turned and walked along the rocks. The **← / →** keys do the same on a computer. Each button goes to the most climbed problem on that photo. `TopoNeighbours` (`app/services/topo_neighbours.rb`) works it out on the fly:

- **Where each photo is:** the middle of its located problems, otherwise where the photo was taken (inbox photos).
- **Which way it faces:** the compass heading saved with an inbox photo. Otherwise it's worked out from the boulder: you stand outside the outline looking in, so the facing direction runs from the nearest point on the outline to the boulder's middle.
- **Left and right:** the nearest photo 20°–160° to that side, within 150 m, in the same area. Photos taken from the same spot (under 2 m apart) are skipped. Where possible, right then left comes straight back.
- **No arrows** when a photo's facing direction can't be worked out, i.e. no heading and no boulder outline at its problems. Locating its problems on a drawn boulder makes the arrows appear. Hidden problems, unpublished photos and unpublished areas are never linked.

**Checking them while you work:** the topo workbench sidebar and the admin topo page show **Photo to the left / right** for that photo: the problem each arrow goes to (click to open that photo's workbench), or the reason there's no arrow ("No facing direction…", "No position…", "No other photo to the left within 150 m"). It works in unpublished areas too, as a preview of what visitors will see.

### Deleting a topo
Navigate to the topo's edit page directly via `/admin/topos/<ID>` (find the ID from the problem's show page). Click the red **Delete topo** button and confirm. This permanently deletes the topo and all its associated lines.

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
- **Start holds** — optional; the contributor switches the drawing tool to **Start holds** and clicks up to 4 starting hand holds on the same photo (shown as green rings)
- **Not in** — optional; in **Not in** mode the contributor clicks around off-limits parts of the boulder (3+ points each, **New area** for another, up to 4)
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
- The boulder photo with the drawn route line overlaid in red, any start holds as green rings and any not-in areas as shaded red shapes
- GPS coordinates, name, and any comments

### Partial acceptance

When setting state to **accepted** you can choose which parts to apply using the checkboxes on the edit form. The labels adapt to what the contribution actually contains:

- **Line on Topo #N (no new photo is created)** — shown when the contributor drew on an existing topo; accepting only adds a Line record to that topo
- **Photo & line (new topo)** — shown when the contributor uploaded a photo and drew a line; accepting creates a new topo with the line overlay
- **Photo (new topo, no line drawn)** — shown when the contributor uploaded a photo without drawing a line
- Start holds and not-in areas always go with the photo/line option. The label lists them ("+ 2 start holds and 1 not-in area", or "Line, 2 start holds and 1 not-in area on Topo #N"). Accepting copies them onto the new line. A contributor can also mark only holds or not-in areas on an existing topo; accepting adds a line with just those
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

**Which area?** The form helps you place it:

- If the contributor started from an area's mapping list ("Map a problem that isn't listed"),
  that area comes with the submission and is pre-selected. Area admins can review these for
  their own areas; unlisted submissions with no area stay super-admin only.
- Otherwise the contributor can type a **Crag / area** name (optional). It's shown on the
  edit page and in the contributions list (marked *new?*).
- If the submission has GPS, the area nearest to it (by located problem or boulder outline,
  within 1 km) is pre-selected, with the distance shown. If nothing is within 1 km, the page
  says it may be a new crag.

**New crags.** Super admins see an **…or create a new area** field, pre-filled with the
contributor's crag name when no area is nearby. Filling it in creates the area **unpublished**
(slug from the name, made unique) and puts the new problem in it, all in one step; if
the problem can't be saved, the area isn't created either. Add boulders, check the details
and publish it from **Areas** when it's ready.

**Several submissions from one spot.** The page lists other pending unlisted submissions
within 300 m. Once the first one has created the area, the others suggest it as the nearest
area, so each is one click to link.

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
removed because its translations described Fontainebleau, not Dartmoor. The Fontainebleau
"circuit 7a" feature and the upstream mobile-app page were removed at the same time (`/app`
now redirects to the map).

**Addresses have no language prefix** (November 2026): pages are at `/dartmoor/bonehill`,
`/map`, `/admin` and so on. Old `/en/...` and `/fr/...` addresses (bookmarks, search results,
links in old emails) 301-redirect to the same page without the prefix, keeping any query
string, so search engines move their listings across.

Areas saved for offline before the change are cached under their old `/en/...` addresses.
The service worker looks up the other form when a page or map file isn't cached under the
address asked for. A *page* found only under the other form is redirected to rather than
served: a page saved before the change runs scripts that work out cache addresses from the
page's own URL, so it has to be shown at its old address. Re-saving an area (or "Update")
moves it to the new addresses. `script/offline_check.mjs` checks the new addresses by
default; `PATH_PREFIX=/en` runs it through the old ones.

### Boolder Credit in the Footer {#boolder-credit}

The site footer (`app/views/layouts/_footer.html.erb`) ends with a credit strip below the
main links:

> Built on **Boolder**, the open-source bouldering guide created for Fontainebleau.
> Thank you to the original Boolder team ♥

"Boolder" links to https://www.boolder.com (new tab); the thank-you links to the
"Thank you, Boolder" section of the About page (`/about#thanks`). To change the wording,
edit `views.layout.footer.boolder_credit_html` and `boolder_thanks` in `config/locales/en.yml`.

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
- **The home page** and the area/home page photos (area covers), so the app's start screen
  opens offline and lists the saved areas.

Sizes are small — a single area is on the order of a few MB. A timestamp and a "Remove"
link appear once saved; **Remove** clears that area's tiles and photos again. If any files
fail to download, the saved message says how many — re-save on a better connection.

### My downloads: /downloads

**My downloads** (`/downloads` — footer link "Offline downloads", "Manage downloads" under
the home page's saved list, "All downloads" next to a saved area) lists every published
area with its offline state:

- **Save** / **Remove** any area, or **Save all areas** in one go (one area at a time, with
  progress; one failure doesn't stop the rest).
- Each saved area shows its date and size. When an area has **changed since it was saved**
  (problems, boulders, topo lines or photos, cover), it says **Update available** and offers
  **Update**; "Update all" does every outdated area. The area page and the home page's saved
  list flag the same thing.
- Removing an area keeps any files another saved area still uses (the base map, overlapping
  tiles of neighbouring areas).
- With no connection it lists only the saved areas, read-only. "No connection" is checked by
  actually pinging the server (`/up`): on the moor phones often show signal with nothing
  getting through.

For developers: the download/remove logic is `app/javascript/offline_areas.js` (shared by the
area page's button, My downloads and the home page list). "Changed since saved" compares the
saved copy's version with `Area.offline_versions` — a 12-character hash of the area's
problems/boulders/lines/topos (timestamps and counts), topo photo and cover blob ids, computed
for many areas in a handful of queries. Saves from before versions existed show as needing
an update.

**Map tile snapshots (developers).** OpenFreeMap tile URLs contain a dated snapshot
(`/planet/20261025_080012_pt/…`) and each save re-pins the shared TileJSON to the current one.
After every save, `refreshOtherAreasTiles` (in `offline_areas.js`) re-downloads the tiles of
any other saved area still on an older snapshot (otherwise its map would be blank offline) and
deletes tiles from snapshots no saved area uses. Saves keep their `bounds` for this; older
saves fetch them from `offline-data`. Classic `<script>`/`<link>` assets from CDNs (MapLibre,
es-module-shims) are fetched `no-cors` during a save, matching how the page loads them — the
service worker may hold opaque copies, which a normal fetch can't receive.

### Searching offline

With no connection (or a signal that doesn't answer within 5 seconds), the search box
searches the map data saved on the phone instead of the server. It finds areas and problems
by name, only offers those whose pages are saved (anything else would just open the
"You're offline" page), and says **"Offline — showing results from your saved areas"**.
Matching is simpler than the server's: every word typed must appear in the name, ignoring
case, accents and apostrophes ("tims slab" finds "Tim's Triangular Slab").

Search results now link straight to the problem/area page (online too), instead of going
through `/redirects/new`, which needs the server.

For developers: `searchOffline` in `app/javascript/offline_areas.js` reads the cached
`/map-data.geojson` (problems now include `areaName`) and `/area-labels.geojson` (areas
now include `path`). `Area::OFFLINE_FORMAT` is part of the offline version hash: bump it
whenever what a saved area contains changes shape, so every saved copy shows
"Update available" and picks up the new data (it was bumped to 2 for this).

### Reporting a mistake offline

Every problem page has a **"Report a mistake"** link. It opens the report form already set to
that problem ("About: Flagpole 5 · Bonehill"), so the report arrives in
**Admin → Contributions** linked to the problem (the list shows its name and area instead of
"(empty)").

It works with no signal: the form is saved with each area, and a report that can't be sent is
**kept on the phone** ("your report is saved on this phone and will be sent automatically when
you're back online"). The next time any page of the site opens with a connection, it's sent
and a message confirms it. Sending takes about 5 seconds, because the spam check rejects forms
submitted within 4 seconds of loading.

For developers: `app/javascript/offline_reports.js` (queue in localStorage `queued_reports`,
flushed from `application.js` on every page load and on `online`) and
`report_form_controller.js`. Every send — immediate or queued — first loads a fresh
`/reports/new` (so invisible_captcha's session timestamp and spinner and the CSRF token are
valid), waits 4.5 s, then posts asking for JSON: `ReportsController#create` answers 201, or
422 with `errors` (validation, `rejected` for the honeypot, `too_fast` for the timestamp check)
— the HTML responses redirect in all three cases, so they can't be told apart. Network
failures and 429s keep the report queued. `script/offline_check.mjs` with `REPORT_SEND=1`
also checks the send-on-reconnect (creates a real report: dev only).

### Installing the app

The site is an installable app (a PWA). Installing it is what keeps saved areas safe:
Safari deletes a website's saved data after about 7 days without a visit, but not a
home-screen app's; and saving an area also asks the browser to keep the data permanently
(the offline status page shows whether it agreed).

- **Android / desktop Chrome**: an **"Install the app"** button appears on the home page and
  under the save button on area pages (only when the browser offers installation).
- **iPhone / iPad**: there's no install button on iOS, so the same spots show
  "tap Share, then Add to Home Screen".
- Neither shows once you're using the installed app.

The installed app opens on the **home page**, which has a **"Saved for offline"** list of
the areas saved on that phone. With no signal, any page that wasn't saved shows a
"You're offline" page that also lists the saved areas and links to the map.

For developers: the manifest is `app/views/pwa/manifests/show.json.erb` (icons
`public/icon-192.png`, `public/icon.png`, `public/icon-maskable-512.png`, screenshots in
`public/screenshots/`); the shared head tags, service-worker registration and
`beforeinstallprompt` capture are in `app/views/layouts/_pwa_head.html.erb` (used by both
layouts); the prompt is `install_prompt_controller.js` + `shared/_install_prompt`; the list
is `saved_areas_controller.js`. iOS uses `public/apple-touch-icon.png` (opaque — iOS turns
transparency black).

### Checking what's saved: /offline-status

The **offline status page** (`/offline-status`, linked as "Details" next to a saved
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
  path under `/admin` (or the old `/admin`), so those navigations go straight to the browser.
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
  popup. The bare `/map` page (the header link) is pre-cached too.
- The service worker never resolves a navigation with `null`; uncached pages fall back to a
  small "You're offline" page (and the overlay GeoJSON to an empty FeatureCollection), so
  visiting something you didn't download degrades gracefully instead of erroring.

**Known limitation:** only an area's *own* problem pages are cached. Following a link to a
problem in a different (un-downloaded) area still needs a connection — it shows the offline
fallback page rather than erroring.

---

## Problems by Grade and Map Grade Filters {#problems-by-grade}

**Problems by grade** (`/dartmoor/problems`, linked from a card on the Dartmoor areas page) lists every published problem of one grade across all areas. Problems with a topo photo come first, then by area and name. The menu only offers grades that have problems, with a count for each. Problems need a location on the map to appear.

Grades below 6a are entered in simplified form (`4`, `4+`). Older detailed grades still match: `4` covers 4a to 4b, and `4+` covers 4b+ to 4c+. The same grouping drives the map's grade filters (level buttons and the custom min–max range), so no problems are left out.

---

## Printable Topo Sheets {#topo-sheets}

Every published area has a printable sheet at `/dartmoor/<area>/print`, linked as
**Print topo sheet** under the area's problem list. It shows the area's warning and
description, then every published photo with all its lines drawn and numbered (left to
right, photos in boulder order), each followed by a numbered list of name, grade, sit start
and a short description. Problems with a map location but no photo yet are listed in a table
at the end. Lines are drawn on the server, so they print without any animation; site menus are
left off. Unpublished areas' sheets return "not found" like their other pages.

---

## Stats {#stats}

**Admin → Stats** (super admins only) shows how the site is used and how mapping is going. Pick a period (7, 30, 90 or 365 days) at the top.

- **Visits**: page views in the period (with the change on the previous period once there's enough data), split into home, area, problem and map pages; a daily chart; the most viewed areas (area page, its problems and its map) and problems.
- **Activity, last 12 weeks**: problems added, lines drawn, photos added, contributions and reports, photos from visitors and admin edits, per week.
- **Community**: contributions/reports and visitor photos waiting, accepted and closed, and the typical wait for a decision over the last 90 days.
- **Mapping progress**: per area, problems placed by hand, estimated, with no location and with a line, photos and photos still to draw, and boulders on the map. Click an area for its Boulders list.
- **Admin edits, last 30 days**: who changed what, with a link to the full audit log.

### How visits are counted
Visits are anonymous daily totals in the `page_views` table: one row per day and page (home, an area, a problem, or the map), holding only a count. No IP address, cookie, browser details or visitor ID is stored, so visits can't be linked to anyone; the [privacy policy](/privacy) says so. Counting started on the day this was deployed (4 November 2026), so earlier periods are empty.

Only real visits count: pages opened in a browser (`Sec-Fetch-Mode: navigate`) or by following a link (Turbo). Not counted: Turbo's prefetch when hovering over a link, offline downloads (which fetch every problem page in the background), pages opened while signed in as an admin, bots and scripts (by user agent), error and "not found" pages, and pages served from the offline cache with no connection. Code: `CountsPageViews` (controller concern), `PageView`, `AdminStats`.

---

## Search engines {#search-engines}

- **`/sitemap.xml`** lists every public page for search engines: home, map, the areas page, each published area and its problem list, every shown problem with a location, and circuits. It's built from the database when requested (cached for an hour), so new problems appear straight away and hidden problems and unpublished areas never do. Each entry carries the date the page last changed. Code: `SitemapsController`.
- **`public/robots.txt`** points crawlers at `https://bowda.edsouthwood.com/sitemap.xml`. Change it if the site's address changes.
- **Preferred addresses**: problem, area, area problem-list, areas and map pages tell search engines their canonical address, so the same page reached another way (old `/en/` links, extra query strings) is counted once.
- To see what's indexed, add the site to **Google Search Console** and **Bing Webmaster Tools** (verify by DNS record or an uploaded file) and submit the sitemap address there.

---

## Support Page (Donations) {#support-page}

- **`/support`** ("Support Bowda" in the footer, also linked from the About page FAQ) asks visitors to chip in towards running costs, with a target of **£75 a year**. It explains in plain terms where that goes: server (about £55), the bowda.rocks address (about £11), spare copies and headroom (about £9). It also says the site currently runs on an old computer at home, with the potato photo.
- **The donate button** ("Buy Bowda a coffee") goes to the address in the `SUPPORT_URL` env var, or the `support_url` Rails credential if that isn't set, e.g. `https://ko-fi.com/yourpage`. Only `http(s)` addresses are used. With neither set, the button is hidden and the page says "Donations open soon" with the contact email.
- It's a plain link, not an embedded widget, so no third-party scripts load and the Content-Security-Policy needs no changes.
- **Changing the figures:** edit the `costs` list at the top of `app/views/pages/support.html.erb`. The total is added up automatically, but the "£75 a year" wording in the intro, heading and meta description is written out, so update those too.

