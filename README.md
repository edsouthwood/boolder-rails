# Boolder Dartmoor

A Rails web platform for discovering and mapping bouldering problems on Dartmoor. This is a fork of [boolder-org/boolder-rails](https://github.com/boolder-org/boolder-rails), adapted from its original Fontainebleau focus for the Dartmoor climbing community.

The app manages areas, boulder formations, climbing problems, circuits (colour-coded collections), topos (guidebook images with drawn lines), community contributions, and map data.

---

## Stack

- Ruby on Rails 8, PostgreSQL + PostGIS
- Tailwind CSS, Stimulus, Turbo
- Importmap (no Node bundler)
- Solid Queue / Cache / Cable
- Kamal deployment

---

## Running locally (Linux)

### Prerequisites

```bash
# Ruby (via rbenv)
rbenv install 3.3.5

# PostgreSQL with PostGIS
sudo apt install postgresql postgis
```

### Setup

```bash
git clone git@github.com:edsouthwood/boolder-rails.git
cd boolder-rails
bin/setup
```

Create a `.env` file in the project root:

```
MAPBOX_DEV_ACCESS_KEY=<your Mapbox public token>
ADMIN_USERNAME=<username>
ADMIN_PASSWORD=<password>
```

Get a free Mapbox token at https://account.mapbox.com/access-tokens/

### Start the development server

```bash
bin/dev
```

The app runs at http://localhost:3000. If running as a systemd service (see below) it starts automatically at boot.

---

## Development server as a systemd service

The server runs as two systemd user services that start at boot automatically:

| Service | Purpose |
|---|---|
| `boolder-rails` | Puma web server on port 3000 |
| `boolder-css` | Tailwind CSS watcher |

```bash
systemctl --user status boolder-rails boolder-css
systemctl --user restart boolder-rails
journalctl --user -u boolder-rails -f
```

---

## Backups

Daily automated backups run at midnight via a systemd timer, rsyncing to hosted webspace. What is backed up:

- PostgreSQL database (compressed pg_dump, 7-day rolling retention)
- `storage/` directory (all uploaded topo photos and images)
- `config/master.key` and `.env`

```bash
bin/backup          # run immediately
tail -f log/backup.log
systemctl --user status boolder-backup.timer
```

Remote destination is configured in `.env.backup` (not committed to git).

---

## Admin

The admin interface is at `/en/admin`, protected by HTTP basic auth (set via `ADMIN_USERNAME` / `ADMIN_PASSWORD` or Rails credentials).

Full documentation is available in-app at `/en/admin/docs` and in `docs/admin_guide.md`.

### Admin roles

| Role | Access |
|---|---|
| `super_admin` | Full access — areas, circuits, imports, bulk uploads, POIs, audits |
| `area_admin` | Edit assigned areas and their problems, topos, lines, contributions |

Credentials are stored in Rails encrypted credentials (`config/credentials.yml.enc`):

```bash
rails credentials:edit
```

---

## Changes from upstream

This fork diverges from [boolder-org/boolder-rails](https://github.com/boolder-org/boolder-rails) in the following ways:

### Content and branding
- Rebranded for Dartmoor — updated imagery, copy, and area data
- Map provider updated for UK coverage

### Admin role-based access control
- Two-tier admin system: `super_admin` and `area_admin`
- Area admins are scoped to a list of assigned area slugs
- Stored in Rails credentials with a backward-compatible plain-string format

### In-browser mapping tools
- **Boulder editor** — draw, edit, and delete boulder polygons directly over satellite imagery (no GeoJSON export needed)
- **Location editor** — drag-and-drop problem positioning on a map; bulk-clear bad coordinates via runner
- **Problem position editor** — standalone map view for setting problem locations area by area

### Topo and line improvements
- **Topo picker** — thumbnail grid for selecting an existing topo when adding a new line
- **Topo delete** — fixed nested-form bug; delete button moved outside the update form
- Thumb image variant added for topo picker thumbnails

### Contribution improvements
- Contributors can draw a line on an **existing area topo** instead of uploading a new photo (`existing_topo_id` stored on contributions)
- **Partial acceptance** — separate checkboxes to apply photo/line and GPS independently when approving a contribution
- **Request photos** — bulk-create `ContributionRequest` records for unphotographed problems from the area edit page

### Operations
- Systemd user services for the dev server (`boolder-rails`, `boolder-css`) with auto-start at boot
- Daily automated backup script (`bin/backup`) with systemd timer — database, storage files, master key, and `.env`
- In-app admin documentation at `/en/admin/docs`

---

## Contributing

This is a private fork for the Dartmoor bouldering community. For the original Fontainebleau project, see [boolder-org/boolder-rails](https://github.com/boolder-org/boolder-rails).
