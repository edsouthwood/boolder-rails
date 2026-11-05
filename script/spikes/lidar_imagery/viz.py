import numpy as np
from PIL import Image
from skimage import segmentation
def overlay(img, layers, path, crop=None, scale=1.0):
    """layers: [(label_raster, (r,g,b))] drawn as outlines on the imagery."""
    out = img.copy()
    for lab, rgb in layers:
        b = segmentation.find_boundaries(lab, mode='inner')
        b = np.maximum.reduce([b, np.roll(b, 1, 0), np.roll(b, 1, 1)])
        out[b] = rgb
    if crop: r0, r1, c0, c1 = crop; out = out[r0:r1, c0:c1]
    im = Image.fromarray(out)
    if scale != 1.0: im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    im.save(path)
