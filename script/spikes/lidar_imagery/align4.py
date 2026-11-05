import numpy as np
from scipy import ndimage as ndi
from common import *
from align import rockiness
if __name__ == '__main__':
    for slug in ['bonehill', 'saddletor', 'Smallacomberocks']:
        a = Area(slug); z = np.load(f'{slug}.npz')
        truth = ndi.gaussian_filter((a.truth_labels() > 0).astype(np.float32), 2)
        for key in ('img', 'img_esri'):
            r = rockiness(z[key]); s = 2; rng = int(10 / (a.m_img * s))
            dx, dy = best_shift(truth[::s, ::s], r[::s, ::s], rng, 1)
            # how peaked is it? compare to the mean score over shifts
            print(f'{slug:17} {"clarity" if key == "img" else "esri   "} photo -> outlines: {dx * s * a.m_img:+.2f} m E, {dy * s * a.m_img:+.2f} m S')
