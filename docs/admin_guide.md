# Boolder Dartmoor — Admin Guide

## Table of Contents
1. [Project Structure](#project-structure)
2. [Development Server](#development-server)
3. [Backups](#backups)
4. [Admin Accounts](#admin-accounts)
5. [Permission Levels](#permission-levels)
6. [Managing Areas](#managing-areas)
7. [Bulk Upload (Problems)](#bulk-upload-problems)
8. [Importing Problems from Photos](#importing-from-photos)
9. [Location Editor (Drag-and-Drop)](#location-editor)
10. [Adding Boulders (Polygon Map Data)](#adding-boulders)
11. [Boulder Editor (In-Browser)](#boulder-editor)
12. [GeoJSON Import Workflow](#geojson-import-workflow)
13. [Individual Problem Editing](#individual-problem-editing)
14. [Problem Description](#problem-description)
15. [Topos and Line Drawing](#topos-and-line-drawing)
16. [Circuits](#circuits)
17. [POIs and Routes](#pois-and-routes)
18. [Contributions](#contributions)

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

**Admin → Contributions** — review pending submissions

- **Pending** — awaiting review
- **Approved** — accepted and visible
- **Rejected** — declined

When reviewing a contribution, the admin edit page shows:
- The contributor's UKC link (if provided) as a clickable link
- The boulder photo with the drawn route line overlaid in red
- GPS coordinates, name, and any comments

### Partial acceptance

When setting state to **accepted** you can choose which parts to apply using the checkboxes on the edit form:

- **Photo & line** — attaches the contributor's photo as a topo and creates the line overlay (or, if the contributor drew on an existing topo, creates the line on that existing topo)
- **GPS coordinates** — copies the contributor's GPS location to the problem (only applied if the problem has no existing location)

Both are checked by default. Uncheck either to skip that part — useful when the photo is good but the GPS is inaccurate, or vice versa.

Accepting a contribution automatically closes any open contribution request for that problem.

### Existing topo line contributions

If the contributor selected an existing topo photo and drew a line on it (rather than uploading a new photo), the contribution will have an `existing_topo_id` set. When you accept the **Photo & line** part, the system creates a new Line record on that existing topo using the submitted coordinates — no new topo is created.
