import json, warnings, numpy as np; warnings.filterwarnings('ignore')
from method import *
def separated(pred, truth):
    nt, npred = truth.max(), pred.max()
    both = (truth > 0) & (pred > 0)
    pairs = np.bincount(truth[both].astype(np.int64) * (npred + 1) + pred[both], minlength=(nt + 1) * (npred + 1)).reshape(nt + 1, npred + 1)[1:, 1:]
    tsz = np.bincount(truth.ravel(), minlength=nt + 1)[1:]
    cover = pairs / np.maximum(tsz[:, None], 1)            # share of each truth covered by each prediction
    many = (cover >= 0.3).sum(axis=0)                      # truths each prediction covers
    sep = sum(1 for t in range(nt) if cover[t].max() >= 0.5 and many[cover[t].argmax()] == 1)
    found = int((cover.sum(axis=1) >= 0.3).sum())
    merged = int(((cover >= 0.3) & (many >= 2)[None, :]).any(axis=1).sum())
    psz = np.bincount(pred.ravel(), minlength=npred + 1)[1:]
    stray = float(psz[(pairs.sum(axis=0) / np.maximum(psz, 1)) < 0.1].sum())
    return dict(found=found, separated=sep, merged=merged, shapes=int(npred), stray_m2=stray)
def lidar_support(seg, lid, min_h=0.8):
    h = np.maximum(lid['above'], lid['above_smooth'], lid['relief'] * 0.5)
    mx = ndi.maximum(h, seg, range(1, seg.max() + 1)) if seg.max() else []
    keep = np.zeros(seg.max() + 1, bool); keep[1:] = np.array(mx) >= min_h
    return relabel_small(np.where(keep[seg], seg, 0), 1)
data = {s: build(s) for s in AREAS}
probs = {s: np.load(f'prob-{s}.npy') for s in AREAS}
rows = []
for s in AREAS:
    a, X, names, truth, lid = data[s]; m2 = a.m_img ** 2
    base = components(lid['baseline'] > MIN_HEIGHT, MIN_AREA / m2)
    r = separated(base, truth); r['stray_m2'] = round(r['stray_m2'] * m2); rows.append((s, 'LiDAR only (deployed)', r))
    for pt in (0.5, 0.65, 0.8):
        for h in (0.3, 0.5, 0.8):
            seg = lidar_support(segment(probs[s], lid, a, pt, split=True, h=h), lid)
            r = separated(seg, truth); r['stray_m2'] = round(r['stray_m2'] * m2); rows.append((s, f'combined p>{pt} h={h}', r))
json.dump(rows, open('sweep.json', 'w'))
# totals per method across areas
from collections import defaultdict
tot = defaultdict(lambda: defaultdict(int)); nt = sum(data[s][3].max() for s in AREAS)
for s, m, r in rows:
    for k, v in r.items(): tot[m][k] += v
print(f'{"method":26} found separated merged shapes stray_m2   (of {nt} mapped boulders)')
for m, r in tot.items(): print(f'{m:26} {r["found"]:5} {r["separated"]:9} {r["merged"]:6} {r["shapes"]:6} {r["stray_m2"]:8}')
print()
for s, m, r in rows:
    if m in ('LiDAR only (deployed)', 'combined p>0.65 h=0.5'): print(s, m, r)
