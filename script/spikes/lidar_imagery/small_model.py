import warnings, time, numpy as np; warnings.filterwarnings('ignore')
from sklearn.ensemble import HistGradientBoostingClassifier
from method import *
from sweep import separated, lidar_support, data
from collections import defaultdict
tot = defaultdict(lambda: defaultdict(int))
for iters, leaves in ((200, 31), (60, 15), (25, 8)):
    t0 = time.time()
    for test in AREAS:
        Xs, ys = [], []
        for tr in AREAS:
            if tr == test: continue
            a, X, names, truth, lid = data[tr]; y = labels_for_training(truth, a)
            sel = np.nonzero(y >= 0)[0]; rng = np.random.default_rng(0)
            pos = sel[y[sel] == 1]; neg = rng.choice(sel[y[sel] == 0], 6 * len(pos), replace=False)
            idx = np.concatenate([pos, neg]); Xs.append(X[idx]); ys.append(y[idx])
        clf = HistGradientBoostingClassifier(max_iter=iters, max_leaf_nodes=leaves, class_weight='balanced').fit(np.concatenate(Xs), np.concatenate(ys))
        a, X, names, truth, lid = data[test]
        prob = clf.predict_proba(X)[:, 1].reshape(truth.shape)
        np.save(f'prob{iters}-{test}.npy', prob)
        seg = lidar_support(segment(prob, lid, a, 0.65, split=True, h=0.5), lid)
        np.save(f'seg{iters}-{test}.npy', seg)
        r = separated(seg, truth); r['stray_m2'] = round(r['stray_m2'] * a.m_img ** 2)
        for k, v in r.items(): tot[(iters, leaves)][k] += v
    print(f'{iters} trees x {leaves} leaves ({iters * leaves} leaves total):', dict(tot[(iters, leaves)]))
