# Boolder Dartmoor — Admin Guide

## Table of Contents
1. [Project Structure](#project-structure)
2. [Admin Accounts](#admin-accounts)
3. [Permission Levels](#permission-levels)
4. [Managing Areas](#managing-areas)
5. [Bulk Upload (Problems)](#bulk-upload-problems)
6. [Importing Problems from Photos](#importing-from-photos)
7. [Adding Boulders (Polygon Map Data)](#adding-boulders)
8. [GeoJSON Import Workflow](#geojson-import-workflow)
9. [Individual Problem Editing](#individual-problem-editing)
10. [Problem Description](#problem-description)
11. [Topos and Line Drawing](#topos-and-line-drawing)
11. [Circuits](#circuits)
12. [POIs and Routes](#pois-and-routes)
13. [Contributions](#contributions)

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
- **Route line** — drawn directly on the uploaded photo using an in-browser canvas tool; stored as normalised JSON coordinates
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

Accepting a contribution automatically closes any open contribution request for that problem.
