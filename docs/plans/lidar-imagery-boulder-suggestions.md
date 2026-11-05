# Plan: LiDAR + photo boulder suggestions in the boulder editor

**Status:** planned, not started (written 5 November 2026). Spike done 4 November 2026.
**Spike report (pictures and numbers):** https://claude.ai/artifact/8pU8AzRFeRd2aRFNLG7UWj
**Spike code:** `script/spikes/lidar_imagery/` (see its README to rerun it).

## Why

The editor's **Suggest boulders in this view** uses Environment Agency 1 m LiDAR only
(`app/javascript/lidar_suggestions.js`). Touching boulders and outcrop faces join up, so it
suggests large areas of rock. Saddle Tor's main block comes back as one ~880 m² shape
covering 7 boulders, and bracken and gorse produce ragged false shapes.

The spike added the satellite photo the editor already shows (Esri World Imagery) and found
that the two together separate boulders far better.

| Against 123 hand-drawn outlines (Bonehill, Saddle Tor, Smallacombe Rocks) | LiDAR only (live) | LiDAR + photo |
| --- | --- | --- |
| Boulders with a shape of their own | 13 | 35 |
| Boulders merged with a neighbour | 44 | 28 |
| Boulders found at all (≥30% covered) | 67 | 72 |
| Shapes suggested | 259 | 139 |
| Area suggested where nothing is mapped | 3,835 m² | 1,521 m² |

Each crag was scored by a model trained only on the other two.

## What the admin will see

1. In the boulder editor, beside **Suggest boulders in this view**, a second button: **Suggest
   with photo** (LiDAR + photo).
2. The first time in an area, a one-off **Line up the photo** step: the LiDAR hillshade is shown
   over the photo, half transparent, with arrow buttons to nudge it into place (0.25 m steps).
   The offset is saved for the area, so it's done once per crag.
3. Suggestions appear exactly as today (green = overlaps an existing outline, amber = new), with
   the same popup and **Add all** button. Only how the shapes are made changes.

## How it works

Same three stages as the spike, moved into the browser.

1. **Fetch** for the current view (capped at about 250 m across):
   - LiDAR first return, last return and DTM at 0.5 m, via the existing `fetchGrid` (WCS,
     reprojected to Web Mercator by the EA).
   - Esri World Imagery tiles at **zoom 19** (about 19 cm a pixel on Dartmoor; zoom 20 is
     blank there), drawn to a canvas. Esri sends `Access-Control-Allow-Origin: *`, and
     `server.arcgisonline.com` is already in the CSP `connect-src`, so pixels can be read.
   - Shift the LiDAR grids by the area's saved photo offset, then upsample them to the photo grid.
2. **Rock score per pixel.** A gradient-boosted tree model (200 trees, ≤31 leaves each,
   about 6,200 leaves) scores each pixel 0–1 from 20 features:
   - photo: Lab lightness, a, b, chroma, green excess (2G − R − B), local lightness std (3 and
     9 px windows), lightness minus its local mean, Sobel edge strength, smoothed lightness and
     smoothed chroma;
   - LiDAR: height above DTM, height above a 9 m median-smoothed DTM, first-minus-last return
     gap (3×3 median), DTM slope, first-return relief in a 2.5 m window, first-return slope,
     and the live rule's own rock-height grid (`baseline`).
   Exact definitions: `build()` in `script/spikes/lidar_imagery/method.py`. The browser
   versions must match them exactly (stage 2 below checks this).
3. **One shape per boulder.**
   - Rock mask: score > 0.65, opened and closed with a 2-pixel disc, holes filled, pieces
     under 3 m² dropped.
   - Seeds: LiDAR height peaks (smoothed height, h-maxima with h = 0.5 m), peaks closer than
     1.5 m merged. A rock piece with no peak gets one seed of its own.
   - Watershed on (−height − 0.5 × distance to the mask edge), seeded at the peaks, inside the
     mask. Each basin is one suggestion.
   - Drop shapes whose highest point is under 0.8 m above the smoothed ground (this is what
     should remove roads and flat slabs).
   - Trace each shape with `d3-contour` and simplify, as now, then return suggestions in the
     same `{ coordinates, area, height, overlaps }` shape as `suggestBoulders`.

## Stages

### 0. Before building (Ed)

- [ ] **Check Esri's terms** for deriving vector outlines automatically from World Imagery.
      The editor already displays it, but automated extraction may be treated differently.
      If it isn't allowed, stop here or look for a licensed alternative (for example APGB/Getmapping
      aerial imagery through a public-sector licence).
- [ ] **Check zoom 19 coverage** on every area (sample a tile per area; grey "Map data not yet
      available" tiles mean no coverage).

### 1. Training pipeline in the repo (offline, Python)

Move the spike into a maintained script, e.g. `script/lidar_model/`:

- `train.py`: exports outlines from the database (the README's runner command), fetches LiDAR and
  photo, trains on every area with enough hand-drawn outlines, and writes the model.
- `export.py`: writes the trees as compact JSON: per tree, arrays of feature index, threshold,
  left, right and leaf value, plus feature order and the threshold, h and other settings.
  Target: under 300 KB. Ship it as an importmap-pinned module loaded only by the editor (e.g.
  `app/javascript/lidar_model_data.js`), so public pages never download it.
- `fixture.py`: saves a small parity fixture (one 40 m × 40 m patch: inputs, features,
  scores and final shapes) for stage 2.

Done when it reproduces the spike table within ±2 on each row, leave-one-crag-out.

### 2. Browser module (`app/javascript/lidar_photo_suggestions.js`)

- Photo fetch to canvas, RGB → Lab (D65, as `skimage.color.rgb2lab`), feature maps, tree
  evaluation, mask clean-up, h-maxima seeds, priority-flood watershed, tracing and simplification.
- Reuse from `lidar_suggestions.js`: `fetchGrid`, `readGeoTiff`, `outcropFaces` (for the
  `baseline` feature), the overlap flagging and `simplify`. Export what's needed instead of
  copying.
- Speed: about 1M pixels for a 190 m view; 200 trees is roughly 1–2 × 10⁹ comparisons, so a
  few seconds. Run it in a Web Worker if the page freezes. If the CSP blocks a `blob:` worker,
  add a `worker-src`, or try scoring at 0.38 m (a quarter of the pixels) and check what it
  costs in quality.
- **Parity check:** `script/lidar_model/parity_check.mjs` runs the module in Node on the
  stage 1 fixture. Feature values must match to 1e-3, scores to 0.01, and final shapes to
  IoU > 0.95 against Python. There's no JS test runner in the project; run it from CI as a
  plain `node` step.

### 3. Lining up photo and LiDAR

The photo and LiDAR don't line up, and the gap differs by crag. The spike measured how far
the hand outlines (traced on the photo) are from LiDAR rock: Bonehill 0.4 m E / 1.1 m S,
Saddle Tor 0 / 2.3 m S, Smallacombe 2.7 m W / 0.8 m S. Automatic matching (hillshade
correlation, grey-rock pixels, photo-to-photo phase correlation) gave inconsistent answers.

- **Migration:** `areas.lidar_photo_offset_m` (jsonb `{ "east": 0, "south": 0 }`, nullable).
- **Line up the photo** panel in the editor: EA hillshade overlay (the existing WMS layer) at
  50% opacity over the Esri photo, arrows for 0.25 m steps, **Save offset**. Area admins can
  set their own areas'.
- Default before anyone has set it: 1.5 m south, the typical spike value. Show a hint
  ("Line up the photo first for better shapes") until it's set.
- Later, optional: retry automatic alignment by matching LiDAR-only rock that's certain
  (freestanding > 1.5 m, no vegetation gap) against the classifier's photo-only score.

### 4. Editor integration

- **Suggest with photo** button and status line ("Fetching photo… Scoring… Tracing…"), reusing
  `renderSuggestions`, the popup and **Add all**. Keep the LiDAR-only button.
- Mark suggestions with their source so admins can compare the two methods on a crag.
- Phone width: the editor is used from a phone (see the memory note on PR #6), so test at 390 px.

### 5. Check on a new crag, then document

- Outline 10–20 boulders by hand at a crag the model hasn't seen (Bell Tor or Hound Tor), then
  score the browser output against them with the spike's `separated()` measure. Aim for at
  least twice the LiDAR-only "own shape" count, without more stray area.
- Retrain including that crag if it does noticeably worse than the spike's numbers.
- Update `docs/admin_guide.md` (Boulder Editor section) and the in-app docs page.

### 6. Ship

- PR, CI, deploy (needs `db:migrate` for the offset column). Rollback: `db:rollback` and the
  previous commit; the LiDAR-only button keeps working throughout.

## Known weaknesses to tackle while building

| Seen in the spike | Idea |
| --- | --- |
| A road at Bonehill came through as rock | The stage 2 height check (≥ 0.8 m above smoothed ground); add a minimum share of LiDAR-supported pixels if that isn't enough |
| Shapes fill the rock up to their neighbours, bigger than the climbable tops Ed draws | Option to shrink each shape to its high-score core (score > 0.8) or erode by 0.5 m |
| Small boulders under bracken or gorse are missed | Probably a limit of the photo. Accept, or fall back to LiDAR-only shapes where the photo is mostly vegetation |
| Only 3 crags of training outlines | Retrain as more crags are drawn (stage 1 makes this one command) |
| The model's 0.65 threshold was tuned for the big model; smaller models need retuning | Keep the 200-tree model unless speed forces a smaller one, then re-sweep the threshold |

## Open questions

- Esri terms (stage 0) decide whether this goes ahead at all.
- Should the offset be per area or per view? Per area is simpler. Large areas might need more
  than one, which the spike couldn't tell.
- Is a few seconds per **Suggest with photo** acceptable on a phone, or does it need the Web
  Worker from the start?

## Rough effort

About 3–5 days: stage 1 one day, stage 2 one to two days (watershed and parity are the fiddly
parts), stage 3 half a day, stage 4 half a day, stage 5 depends on outlining a new crag.
