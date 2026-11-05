# LiDAR + imagery boulder spike (November 2026)

Throwaway research code behind [docs/plans/lidar-imagery-boulder-suggestions.md](../../../docs/plans/lidar-imagery-boulder-suggestions.md).
Not used by the app. Kept so the numbers in the plan can be reproduced and the model retrained.

## Setup

```bash
python3 -m venv /tmp/lidar-venv
/tmp/lidar-venv/bin/pip install numpy scipy scikit-image scikit-learn pyproj pillow shapely tifffile imagecodecs
mkdir -p /tmp/lidar-spike && cd /tmp/lidar-spike
cp /path/to/repo/script/spikes/lidar_imagery/*.py .
```

## Run order

1. **Reference outlines.** Export the hand-drawn outlines (read-only) from the app:

   ```bash
   bin/rails runner -e production '
     out = %w[bonehill saddletor Smallacomberocks].to_h { |slug|
       [slug, Area.find_by(slug: slug).boulders.placed.map { |b| { id: b.id, name: b.name, ring: b.polygon.exterior_ring.points.map { |p| [p.x, p.y] } } }] }
     File.write("/tmp/lidar-spike/truth.json", JSON.generate(out))'
   ```

2. `python fetch.py truth.json .` — EA LiDAR (first return, last return, DTM) at 0.5 m in Web Mercator, 25 m around each crag's outlines, saved as `<slug>.npz`. Its own imagery fetch asks for zoom 20, which Esri doesn't have on Dartmoor (grey "Map data not yet available" tiles), so run step 3 after it.
3. `python fetch_img.py bonehill saddletor Smallacomberocks` — adds Esri World Imagery zoom 19 (`img_esri`, the one used) and Esri Clarity zoom 18 (`img`, tried and rejected) to each `.npz`.
4. `python method.py` — trains the per-pixel model leaving one crag out each time, saves `prob-<slug>.npy`.
5. `python sweep.py` — the headline table: found / separated / merged / shapes / stray m², LiDAR-only versus combined at several thresholds.
6. `python small_model.py` — model size versus quality; saves `seg200-<slug>.npy` for pictures.

`common.py` holds the port of the live browser rule (`lidar_suggestions.js`) used as the baseline, plus the scoring. `align4.py` is the photo-to-outlines offset measurement.

## Known shortcuts

- LiDAR is moved onto the photo using an offset measured from the hand outlines (`truth_to_lidar` in `method.py`). The live version can't do that; see the plan's alignment step.
- `sweep.py` and `small_model.py` run their work at import time; they're scripts, not modules.
