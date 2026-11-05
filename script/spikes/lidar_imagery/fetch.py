"""Fetch EA LiDAR (first/last return DSM, DTM) and Esri World Imagery for each area's
mapped boulders (+ margin), all on Web Mercator grids. Saves .npz per area."""
import json, math, sys, io, urllib.request, concurrent.futures as cf
import numpy as np, tifffile
from PIL import Image

R = 20037508.342789244
def merc(lng, lat): return lng * R / 180, math.log(math.tan((90 + lat) * math.pi / 360)) * R / math.pi
WCS = 'https://environment.data.gov.uk/spatialdata/'
COV = {
  'first': ('lidar-composite-digital-surface-model-first-return-dsm-1m', 'df4e3ec3-315e-48aa-aaaf-b5ae74d7b2bb__Lidar_Composite_Elevation_FZ_DSM_1m'),
  'last': ('lidar-composite-digital-surface-model-last-return-dsm-1m', '9ba4d5ac-d596-445a-9056-dae3ddec0178__Lidar_Composite_Elevation_LZ_DSM_1m'),
  'ground': ('lidar-composite-digital-terrain-model-dtm-1m', '13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m'),
}
UA = {'User-Agent': 'bowda-lidar-spike/1.0'}

def get(url, tries=4):
    for t in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r: return r.read()
        except Exception as e:
            if t == tries - 1: raise
def wcs(key, x0, y0, x1, y1, w, h):
    ds, cov = COV[key]; crs = 'http://www.opengis.net/def/crs/EPSG/0/3857'
    url = (f"{WCS}{ds}/wcs?service=WCS&version=2.0.1&request=GetCoverage&CoverageId={cov}&format=image/tiff"
           f"&subsettingCrs={crs}&outputCrs={crs}&subset=X({x0},{x1})&subset=Y({y0},{y1})&scaleSize=i({w}),j({h})")
    a = tifffile.imread(io.BytesIO(get(url))).astype(np.float32)
    a[a < -1e30] = np.nan
    return a

def tile_xy(x, y, z):
    n = 2 ** z; return (x + R) / (2 * R) * n, (R - y) / (2 * R) * n
def imagery(x0, y0, x1, y1, z=20):
    tx0, ty0 = tile_xy(x0, y1, z); tx1, ty1 = tile_xy(x1, y0, z)
    xs, ys = range(int(tx0), int(tx1) + 1), range(int(ty0), int(ty1) + 1)
    mosaic = np.zeros((len(ys) * 256, len(xs) * 256, 3), np.uint8)
    def one(ij):
        i, j = ij
        url = f"https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{ys[j]}/{xs[i]}"
        return i, j, np.array(Image.open(io.BytesIO(get(url))).convert('RGB'))
    with cf.ThreadPoolExecutor(8) as ex:
        for i, j, img in ex.map(one, [(i, j) for i in range(len(xs)) for j in range(len(ys))]):
            mosaic[j*256:(j+1)*256, i*256:(i+1)*256] = img
    # crop to bbox: pixel = mercator / (2R / 2^z / 256)
    res = 2 * R / 2 ** z / 256
    c0 = int(round((x0 + R) / res - xs[0] * 256)); r0 = int(round((R - y1) / res - ys[0] * 256))
    w = int(round((x1 - x0) / res)); h = int(round((y1 - y0) / res))
    return mosaic[r0:r0+h, c0:c0+w], res

truth = json.load(open(sys.argv[1]))
for slug, bs in truth.items():
    pts = [merc(*p) for b in bs for p in b['ring']]
    lat = sum(p[1] for b in bs for p in b['ring']) / sum(len(b['ring']) for b in bs)
    k = 1 / math.cos(math.radians(lat))           # mercator units per ground metre
    m = 25 * k                                     # 25 m margin
    x0, y0 = min(p[0] for p in pts) - m, min(p[1] for p in pts) - m
    x1, y1 = max(p[0] for p in pts) + m, max(p[1] for p in pts) + m
    px = 0.5 * k
    w, h = int(round((x1 - x0) / px)), int(round((y1 - y0) / px))
    x1, y1 = x0 + w * px, y0 + h * px
    grids = {key: wcs(key, x0, y0, x1, y1, w, h) for key in COV}
    img, res = imagery(x0, y0, x1, y1)
    np.savez_compressed(f"{sys.argv[2]}/{slug}.npz", **grids, img=img, bbox=np.array([x0, y0, x1, y1]), k=k, px=px, imgres=res)
    print(slug, 'lidar', grids['first'].shape, 'nan%', round(float(np.isnan(grids['first']).mean()) * 100, 1), 'img', img.shape, f'{(x1-x0)/k:.0f}x{(y1-y0)/k:.0f} m')
