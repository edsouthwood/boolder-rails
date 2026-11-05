import io, sys, urllib.request, concurrent.futures as cf, numpy as np
from PIL import Image
R = 20037508.342789244
BASES = {'clarity': 'https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile',
         'esri': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile'}
def get(url):
    for t in range(4):
        try: return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'bowda-spike'}), timeout=60).read()
        except Exception:
            if t == 3: raise
def mosaic(base, z, x0, y0, x1, y1):
    n = 2 ** z; res = 2 * R / n / 256
    tx0, ty0 = int((x0 + R) / (2 * R) * n), int((R - y1) / (2 * R) * n)
    tx1, ty1 = int((x1 + R) / (2 * R) * n), int((R - y0) / (2 * R) * n)
    xs, ys = range(tx0, tx1 + 1), range(ty0, ty1 + 1)
    m = np.zeros((len(ys) * 256, len(xs) * 256, 3), np.uint8)
    def one(ij):
        i, j = ij; return i, j, np.array(Image.open(io.BytesIO(get(f'{base}/{z}/{ys[j]}/{xs[i]}'))).convert('RGB').resize((256, 256)))
    with cf.ThreadPoolExecutor(8) as ex:
        for i, j, img in ex.map(one, [(i, j) for i in range(len(xs)) for j in range(len(ys))]): m[j*256:(j+1)*256, i*256:(i+1)*256] = img
    return m, res, xs[0] * 256 * res - R, R - ys[0] * 256 * res   # mosaic, res, left x, top y
for slug in sys.argv[1:]:
    z = dict(np.load(f'{slug}.npz'))
    x0, y0, x1, y1 = z['bbox']
    res19 = 2 * R / 2 ** 19 / 256
    W, H = int(round((x1 - x0) / res19)), int(round((y1 - y0) / res19))
    out = {}
    for name, zoom in (('esri', 19), ('clarity', 18)):
        m, res, left, top = mosaic(BASES[name], zoom, x0, y0, x1, y1)
        # crop at native res then resample to the z19 grid
        c0, r0 = (x0 - left) / res, (top - y1) / res
        im = Image.fromarray(m).crop((c0, r0, c0 + (x1 - x0) / res, r0 + (y1 - y0) / res)).resize((W, H), Image.BICUBIC)
        out[name] = np.array(im)
    z['img'] = out['clarity']; z['img_esri'] = out['esri']; z['imgres'] = res19
    np.savez_compressed(f'{slug}.npz', **z)
    print(slug, out['clarity'].shape, 'std clarity', out['clarity'].std().round(1), 'esri', out['esri'].std().round(1))
