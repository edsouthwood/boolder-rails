import json, math
import numpy as np
from scipy import ndimage as ndi
from skimage import color, draw, transform

R = 20037508.342789244
def merc(lng, lat): return lng * R / 180, math.log(math.tan((90 + lat) * math.pi / 360)) * R / math.pi

class Area:
    def __init__(self, slug, d='.'):
        z = np.load(f'{d}/{slug}.npz')
        self.slug = slug
        self.first, self.last, self.ground = z['first'], z['last'], z['ground']
        self.img = z['img']; self.bbox = z['bbox']; self.k = float(z['k']); self.px = float(z['px']); self.imgres = float(z['imgres'])
        self.H, self.W = self.img.shape[:2]
        self.m_img = self.imgres / self.k      # ground metres per image pixel (~0.095)
        self.m_lid = self.px / self.k          # ground metres per LiDAR pixel (0.5)
        truth = json.load(open(f'{d}/truth.json'))[slug]
        self.truth = truth

    # LiDAR grid -> image grid (bilinear), NaN-safe
    def up(self, a, order=1):
        filled = np.where(np.isnan(a), np.nanmedian(a), a)
        return transform.resize(filled, (self.H, self.W), order=order, preserve_range=True, anti_aliasing=False).astype(np.float32)

    def to_img_px(self, lng, lat):
        x, y = merc(lng, lat); x0, y0, x1, y1 = self.bbox
        return (x - x0) / self.imgres, (y1 - y) / self.imgres

    def truth_labels(self, dx=0.0, dy=0.0):
        """Raster of truth boulder ids (1..n) at image resolution, shifted by (dx, dy) image px."""
        lab = np.zeros((self.H, self.W), np.int32)
        for i, b in enumerate(self.truth, 1):
            cols, rows = zip(*[self.to_img_px(*p) for p in b['ring']])
            rr, cc = draw.polygon(np.array(rows) + dy, np.array(cols) + dx, (self.H, self.W))
            lab[rr, cc] = i
        return lab

# ── The deployed browser rule, ported (lidar_suggestions.js) ──
MIN_HEIGHT, MAX_RETURN_GAP, MIN_AREA, SMOOTHING = 1.0, 0.25, 3.0, 0.4
FACE_SLOPE, FACE_DROP, FACE_STRIP = 45, 1.5, 1.5

def outcrop_faces(surface, ground, metres):
    h, w = surface.shape
    mask = np.zeros_like(surface); drop = np.zeros_like(surface)
    gy, gx = np.gradient(ground, metres)  # note: rows increase southwards
    steep = np.hypot(gx, gy)
    r = max(1, round(1 / metres))
    hi = ndi.maximum_filter(np.nan_to_num(surface, nan=-1e9), size=2 * r + 1)
    lo = ndi.minimum_filter(np.nan_to_num(surface, nan=1e9), size=2 * r + 1)
    face = (steep > math.tan(math.radians(FACE_SLOPE))) & ((hi - lo) > FACE_DROP)
    steps = round(FACE_STRIP / metres)
    ys, xs = np.nonzero(face)
    for y, x in zip(ys, xs):
        mask[y, x] = 1; drop[y, x] = hi[y, x] - lo[y, x]
        ux, uy = gx[y, x] / steep[y, x], gy[y, x] / steep[y, x]
        prev = ground[y, x]
        for s in range(1, steps + 1):
            sx, sy = round(x + ux * s), round(y + uy * s)
            if not (0 <= sx < w and 0 <= sy < h): break
            if not (ground[sy, sx] >= prev - 0.3): break
            mask[sy, sx] = 1; prev = ground[sy, sx]
    return mask, drop

def baseline_grid(a):
    """Smoothed 'rock height' grid at LiDAR resolution; rock where > MIN_HEIGHT."""
    gap = np.nan_to_num(a.first - a.last)
    above = np.nan_to_num(a.first - a.ground)
    veg = ndi.median_filter(gap, size=3, mode='nearest')
    above[veg > MAX_RETURN_GAP] = 0
    free = ndi.gaussian_filter(above, SMOOTHING)
    oc, _ = outcrop_faces(a.first, a.ground, a.m_lid)
    ocg = ndi.gaussian_filter(oc * 2 * MIN_HEIGHT, SMOOTHING)
    return np.maximum(free, ocg)

def components(mask, min_area_px):
    lab, n = ndi.label(mask)
    sizes = ndi.sum(np.ones_like(lab), lab, range(1, n + 1))
    keep = np.zeros(n + 1, bool); keep[1:] = sizes >= min_area_px
    lab[~keep[lab]] = 0
    lab, _ = ndi.label(lab > 0)
    return lab

def baseline_labels(a):
    g = a.up(baseline_grid(a))
    return components(g > MIN_HEIGHT, MIN_AREA / a.m_img ** 2)

# ── Evaluation ──
def evaluate(pred, truth, m_px):
    """pred, truth: label rasters. Returns dict of metrics."""
    nt, npred = truth.max(), pred.max()
    both = (truth > 0) & (pred > 0)
    pairs = np.bincount(truth[both].astype(np.int64) * (npred + 1) + pred[both], minlength=(nt + 1) * (npred + 1)).reshape(nt + 1, npred + 1)
    tsz = np.bincount(truth.ravel(), minlength=nt + 1); psz = np.bincount(pred.ravel(), minlength=npred + 1)
    iou = pairs / np.maximum(tsz[:, None] + psz[None, :] - pairs, 1)
    best = iou[1:, 1:].max(axis=1) if npred else np.zeros(nt)
    bestp = iou[1:, 1:].argmax(axis=1) + 1 if npred else np.zeros(nt, int)
    matched = best >= 0.4
    # one-to-one: the truth's best prediction also has this truth as its best
    one2one = sum(1 for t in range(nt) if matched[t] and iou[1:, bestp[t]].argmax() == t)
    # merges: predictions covering >=30% of two or more truths
    cover_t = pairs[1:, 1:] / np.maximum(tsz[1:, None], 1)
    merges = int(((cover_t >= 0.3).sum(axis=0) >= 2).sum())
    merged_truths = int(((cover_t >= 0.3) & ((cover_t >= 0.3).sum(axis=0) >= 2)[None, :]).any(axis=1).sum())
    missed = int((cover_t.max(axis=1) < 0.3).sum()) if npred else nt
    stray = int(((pairs[1:, 1:].sum(axis=0) / np.maximum(psz[1:], 1)) < 0.1).sum())
    stray_area = float(sum(psz[1:][(pairs[1:, 1:].sum(axis=0) / np.maximum(psz[1:], 1)) < 0.1]) * m_px ** 2)
    return dict(truths=int(nt), preds=int(npred), mean_iou=round(float(best.mean()), 3), matched=int(matched.sum()),
                one2one=int(one2one), merged_truths=merged_truths, merges=merges, missed=missed, stray=stray, stray_m2=round(stray_area))

def best_shift(fixed, moving, max_px, step=2):
    """Integer (dx, dy) to move `moving` so it best overlaps `fixed` (both float maps)."""
    best = (-1e18, 0, 0)
    f = fixed - fixed.mean()
    for dy in range(-max_px, max_px + 1, step):
        for dx in range(-max_px, max_px + 1, step):
            mv = ndi.shift(moving, (dy, dx), order=0, mode='constant')
            s = float((f * (mv - mv.mean())).sum())
            if s > best[0]: best = (s, dx, dy)
    return best[1], best[2]
