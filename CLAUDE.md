# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This App Does

Boolder is a Rails 8 web platform for discovering and mapping bouldering problems. It serves the Dartmoor fork of the original Fontainebleau-focused boolder.com. The app manages areas, boulder formations, climbing problems, circuits (themed collections), topos (guidebook images with drawn lines), community contributions, and map data.

## Commands

```bash
bin/setup          # First-time setup: bundle, db:prepare
bin/dev            # Development: Rails server + Tailwind CSS watcher (via Foreman)
bin/rails server   # Rails only (no Tailwind watch)

bin/rubocop        # Lint Ruby (rubocop-rails-omakase style)
bin/brakeman       # Security scan
bin/importmap audit  # JS dependency audit

bin/rails test                          # All tests
bin/rails test test/models/area_test.rb # Single test file
bin/rails test test/models/area_test.rb:42 # Single test
```

CI runs rubocop, brakeman, and importmap audit on push. The test job is currently commented out in `.github/workflows/ci.yml`.

## Architecture

**Stack:** Rails 8, PostgreSQL + PostGIS, Tailwind CSS, Stimulus + Turbo, Importmap (no Node bundler), Solid Queue/Cache/Cable, Kamal deployment.

**Multi-database setup** — four databases defined in `config/database.yml`:
- `primary` — all app data
- `cache` — Solid Cache
- `queue` — Solid Queue background jobs
- `cable` — Solid Cable (WebSockets)

**Core domain models:**
- `Area` — geographic bouldering region with PostGIS polygon bounds
- `Boulder` — polygon outline of a rock formation within an area
- `Problem` — individual climbing problem; belongs to boulder, optional circuit and topo line
- `Circuit` — ordered, color-coded collection of problems in an area
- `Topo` — guidebook image with an array of drawn `Line` records overlay
- `Line` — a polyline on a topo image identifying a problem
- `Poi` / `PoisRoute` — points of interest (parking, amenities) with routing
- `Contribution` / `ContributionRequest` — community mapping submissions with audit trail

**Geospatial:** PostGIS extensions via the `rgeo` / `activerecord-postgis-adapter` gems. Boulders and areas store geometries; viewport bounds are derived from boulder hull geometry. The `FACTORY` constant (initializer) creates RGeo point/polygon objects.

**Route structure** (`config/routes.rb`):
- Localized public routes under `/:locale` (areas, problems, circuits, map, search, proxy)
- `/mapping` — community contribution interface
- `/admin` — HTTP-basic-auth protected admin namespace (ActiveAdmin-style but custom controllers)
- `/api/v1` — deprecated JSON API (topos endpoint only)

**Admin section** lives in `app/controllers/admin/` and `app/views/admin/`. Access controlled via `ADMIN_USERNAME` / `ADMIN_PASSWORD` env vars or Rails credentials.

**JavaScript:** Stimulus controllers in `app/javascript/controllers/`. No build step — importmap handles JS dependencies. CDN imports include Chart.js and Exifr (EXIF reading from uploaded photos).

**Auditing:** All model changes tracked via the `audited` gem; audit log accessible at `/admin/audits`.

**Background jobs:** Solid Queue (runs in-process via Puma). Custom Rake tasks in `lib/tasks/` for data imports, Mapbox tile generation, popularity scoring, and OpenStreetMap sync.

## Environment

Development requires a `.env` file:
```
MAPBOX_DEV_ACCESS_KEY=<public token>
ADMIN_USERNAME=<username>
ADMIN_PASSWORD=<password>
```

Development database is `dartmoor-dev` (PostGIS required). Production uses Docker + Kamal (`config/deploy.yml`), S3 for file storage, and PostGIS 16-3.5.
