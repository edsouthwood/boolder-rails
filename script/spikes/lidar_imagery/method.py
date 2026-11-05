"""LiDAR + imagery boulder segmentation, evaluated area-by-area (train on the other two)."""
import sys, json, numpy as np
from scipy import ndimage as ndi
from skimage import color, filters, segmentation, morphology, feature
from sklearn.ensemble import HistGradientBoostingClassifier
from common import *
from viz import overlay

AREAS = ['bonehill', 'saddletor', 'Smallacomberocks']
SHIFT = {}  # LiDAR -> Esri/outline frame, metres (east, south); measured in step 1 (inverse of truth->LiDAR)

def truth_to_lidar(a):
    base = baseline_labels(a); raw = a.truth_labels()
    sm = lambda m: m[::4, ::4].astype(np.float32)
    dx, dy = best_shift(sm(base > 0), sm(raw > 0), int(4 / (a.m_img * 4)), 1)
    return dx * 4, dy * 4   # image px to move truth onto LiDAR

def build(slug):
    a = Area(slug); z = np.load(f'{slug}.npz')
    a.img = z['img_esri']  # standard Esri: what the editor shows and outlines are traced on
    dx, dy = truth_to_lidar(a)
    shift = lambda g: ndi.shift(g, (-dy, -dx), order=1, mode='nearest')   # LiDAR -> outline frame
    first, last, ground = (np.nan_to_num(x, nan=np.nanmedian(x)) for x in (a.first, a.last, a.ground))
    m = a.m_lid
    above = first - ground
    above_smooth = first - ndi.median_filter(ground, size=int(9 / m))
    gap = ndi.median_filter(np.clip(first - last, 0, 5), size=3)
    gy, gx = np.gradient(ground, m); slope = np.degrees(np.arctan(np.hypot(gx, gy)))
    relief = ndi.maximum_filter(first, size=5) - ndi.minimum_filter(first, size=5)
    fy, fx = np.gradient(first, m); fslope = np.degrees(np.arctan(np.hypot(fx, fy)))
    lid = {n: shift(a.up(v)) for n, v in dict(above=above, above_smooth=above_smooth, gap=gap, slope=slope, relief=relief, fslope=fslope).items()}
    lid['baseline'] = shift(a.up(baseline_grid(a)))
    img = a.img.astype(np.float32) / 255
    lab = color.rgb2lab(a.img)
    L = lab[..., 0]
    f = dict(L=L, A=lab[..., 1], B=lab[..., 2], chroma=np.hypot(lab[..., 1], lab[..., 2]),
             exg=(2 * img[..., 1] - img[..., 0] - img[..., 2]),
             Lstd3=ndi.generic_filter(L, np.std, 3) if False else np.sqrt(np.maximum(ndi.uniform_filter(L**2, 3) - ndi.uniform_filter(L, 3)**2, 0)),
             Lstd9=np.sqrt(np.maximum(ndi.uniform_filter(L**2, 9) - ndi.uniform_filter(L, 9)**2, 0)),
             Lloc=L - ndi.gaussian_filter(L, 10), edge=filters.sobel(ndi.gaussian_filter(L, 1)),
             L9=ndi.gaussian_filter(L, 4), chroma9=ndi.gaussian_filter(np.hypot(lab[..., 1], lab[..., 2]), 4))
    f.update(lid)
    names = list(f)
    X = np.stack([f[n] for n in names], -1).reshape(-1, len(names)).astype(np.float32)
    truth = a.truth_labels()
    return a, X, names, truth, lid

def labels_for_training(truth, a):
    rock = ndi.binary_erosion(truth > 0, iterations=1)
    near = ndi.binary_dilation(truth > 0, iterations=int(1.5 / a.m_img))
    y = np.full(truth.shape, -1, np.int8); y[rock] = 1; y[~near] = 0
    return y.ravel()

def segment(prob, lid, a, p_thresh=0.5, min_area=3.0, split=True, h=0.5, min_dist=1.5):
    mask = prob > p_thresh
    mask = morphology.binary_opening(mask, morphology.disk(2))
    mask = ndi.binary_fill_holes(morphology.binary_closing(mask, morphology.disk(2)))
    lab = components(mask, min_area / a.m_img ** 2)
    if not split: return lab
    # markers: LiDAR height peaks (at least h m prominent, min_dist apart) inside the mask
    height = ndi.gaussian_filter(np.maximum(lid['above'], lid['above_smooth']), 3)
    peaks = morphology.h_maxima(height, h) & (lab > 0)
    peaks = ndi.binary_dilation(peaks, iterations=1)
    markers, n = ndi.label(peaks)
    # merge peaks closer than min_dist
    if n > 1:
        cents = np.array(ndi.center_of_mass(peaks, markers, range(1, n + 1)))
        keep = np.arange(1, n + 1)
        from scipy.cluster.hierarchy import fcluster, linkage
        cl = fcluster(linkage(cents, 'single'), min_dist / a.m_img, 'distance')
        lut = np.zeros(n + 1, int); lut[1:] = cl; markers = lut[markers]
    # components with no peak keep one marker of their own
    nopeak = (lab > 0) & ~np.isin(lab, np.unique(lab[markers > 0]))
    extra, _ = ndi.label(nopeak); markers = np.where(extra > 0, extra + markers.max(), markers)
    # landscape: low between boulders = low height and dark gaps (shadowed cracks)
    dist = ndi.distance_transform_edt(lab > 0)
    landscape = -(height / (height.max() + 1e-6)) - 0.5 * dist / (dist.max() + 1e-6)
    ws = segmentation.watershed(landscape, markers, mask=lab > 0)
    return components(ws > 0, 0) if False else relabel_small(ws, min_area / a.m_img ** 2)

def relabel_small(ws, min_px):
    sizes = np.bincount(ws.ravel()); out = np.zeros_like(ws); k = 0
    for i in range(1, len(sizes)):
        if sizes[i] >= min_px: k += 1; out[ws == i] = k
    return out

if __name__ == '__main__':
    data = {s: build(s) for s in AREAS}
    results = {}
    for test in AREAS:
        Xs, ys = [], []
        for tr in AREAS:
            if tr == test: continue
            a, X, names, truth, lid = data[tr]; y = labels_for_training(truth, a)
            sel = np.nonzero(y >= 0)[0]; rng = np.random.default_rng(0)
            pos = sel[y[sel] == 1]; neg = sel[y[sel] == 0]; neg = rng.choice(neg, min(len(neg), 6 * len(pos)), replace=False)
            idx = np.concatenate([pos, neg]); Xs.append(X[idx]); ys.append(y[idx])
        clf = HistGradientBoostingClassifier(max_iter=200, learning_rate=0.1, class_weight='balanced').fit(np.concatenate(Xs), np.concatenate(ys))
        a, X, names, truth, lid = data[test]
        prob = clf.predict_proba(X)[:, 1].reshape(truth.shape)
        np.save(f'prob-{test}.npy', prob)
        base = components(lid['baseline'] > MIN_HEIGHT, MIN_AREA / a.m_img ** 2)
        r = {'baseline (LiDAR only)': evaluate(base, truth, a.m_img)}
        for pt in (0.5, 0.65):
            r[f'combined p>{pt}'] = evaluate(segment(prob, lid, a, pt, split=False), truth, a.m_img)
            r[f'combined p>{pt} + split'] = evaluate(segment(prob, lid, a, pt, split=True), truth, a.m_img)
        results[test] = r
        print(test)
        for k, v in r.items(): print(f'  {k:28} {v}')
    json.dump(results, open('results.json', 'w'), indent=1)
