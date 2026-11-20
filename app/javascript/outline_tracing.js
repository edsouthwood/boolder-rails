import { contours } from 'd3-contour'
import { crossingEdges } from 'polygon_geometry'

// Finds boulder outlines drawn on the editor's tracing image: closed loops of dark ink on
// light paper (a hand-drawn crag sketch, a scanned guidebook map). Runs in the browser on
// the image already in memory, so the image is never uploaded.
//
// 1. Ink is anything darker than a threshold (Otsu's, found from the image itself, unless
//    one is given).
// 2. The ink is thickened by `gap` pixels so small breaks in a pen line still close.
// 3. Paper reachable from the edge of the image is outside every loop. Any paper left over
//    is the inside of a closed loop: one region per loop.
// 4. Regions too small (holes in letters and numbers) or spanning the whole image (a frame)
//    are dropped. Each is grown back out to the middle of its pen line, traced, simplified
//    to a few corners and pinned to the map the way the image is drawn.

const MAX_SIDE = 1600       // px; the image is analysed at most this big, for speed
const MIN_AREA_SHARE = 0.0004 // of the image: smaller regions are the holes in letters
const MIN_AREA_PX = 60
const FRAME_SPAN = 0.9      // a region this wide and this tall is the inside of a frame
const MAX_CORNERS = 24

// canvas: the tracing image. corners: where it's pinned, [tl, tr, br, bl] as [lng, lat].
// boulders: [{ id, ring: [[lng, lat], ...] }], to flag shapes over boulders already mapped.
// options: { gap: px of ink thickening (default 2), threshold: 0–255 (default automatic) }
// Returns { shapes: [{ coordinates, area, overlaps, source: 'image' }], threshold }
export function findOutlines(canvas, corners, boulders = [], { gap = 2, threshold } = {}) {
  const scale = Math.min(1, MAX_SIDE / Math.max(canvas.width, canvas.height))
  const w = Math.max(1, Math.round(canvas.width * scale))
  const h = Math.max(1, Math.round(canvas.height * scale))
  const work = document.createElement('canvas')
  work.width = w
  work.height = h
  const context = work.getContext('2d', { willReadFrequently: true })
  context.fillStyle = '#fff' // transparent parts of a PNG count as paper
  context.fillRect(0, 0, w, h)
  context.drawImage(canvas, 0, 0, w, h)
  const { data } = context.getImageData(0, 0, w, h)

  const lum = new Uint8Array(w * h)
  for (let i = 0; i < lum.length; i++) {
    lum[i] = (data[i * 4] * 299 + data[i * 4 + 1] * 587 + data[i * 4 + 2] * 114) / 1000
  }
  const used = threshold ?? otsu(lum)
  const pixelShapes = outlinesInGrid(lum, w, h, { gap, threshold: used })
  const toLngLat = imageToLngLat(corners)
  const flatBoulders = boulders.map(({ id, ring }) => ({ id, ring: ring.map(flat) }))

  const shapes = pixelShapes.map(ring => {
    const coordinates = ring.map(([x, y]) => toLngLat(x / w, y / h))
    const flatRing = coordinates.map(flat)
    return {
      coordinates,
      area: Math.round(Math.abs(ringArea(flatRing)) * METRES_PER_DEGREE ** 2),
      overlaps: overlapping(flatRing, flatBoulders),
      source: 'image',
    }
  })
  return { shapes, threshold: used }
}

// The pure part, on a grid of brightness values (0 dark – 255 light): rings of corners in
// pixel coordinates (0–w, 0–h), without the closing corner, biggest first
export function outlinesInGrid(lum, w, h, { gap = 2, threshold = 128 } = {}) {
  const n = w * h
  const ink = new Uint8Array(n)
  for (let i = 0; i < n; i++) ink[i] = lum[i] < threshold ? 1 : 0
  const stroke = strokeWidth(ink, w, h)
  const closed = gap > 0 ? dilate(ink, w, h, gap) : ink

  // 0 paper not yet reached, 1 ink, 2 outside every loop
  const state = new Uint8Array(closed)
  const stack = []
  const visit = i => { if (state[i] === 0) { state[i] = 2; stack.push(i) } }
  for (let x = 0; x < w; x++) { visit(x); visit((h - 1) * w + x) }
  for (let y = 0; y < h; y++) { visit(y * w); visit(y * w + w - 1) }
  floodFrom(stack, state, w, h, 0, 2)

  const minArea = Math.max(MIN_AREA_PX, MIN_AREA_SHARE * n)
  const grow = gap + Math.max(1, Math.round(stroke / 2))
  const rings = []
  for (let start = 0; start < n; start++) {
    if (state[start] !== 0) continue
    const region = regionFrom(start, state, w, h)
    if (region.pixels.length < minArea) continue
    if (region.maxX - region.minX + 1 >= FRAME_SPAN * w && region.maxY - region.minY + 1 >= FRAME_SPAN * h) continue
    const ring = traceRegion(region, w, h, grow)
    if (ring) rings.push({ ring, size: region.pixels.length })
  }
  return rings.sort((a, b) => b.size - a.size).map(r => r.ring)
}

// ─── Image to map ────────────────────────────────────────────────────────────────
// MapLibre draws an image source as two triangles in Web Mercator, split along the
// top-right to bottom-left diagonal, stretching it linearly within each. Doing the same
// here puts the shapes exactly on the lines you can see, even when the corners have been
// pulled out of a rectangle.

const R = 20037508.342789244
const toMerc = ([lng, lat]) => [lng * R / 180, Math.log(Math.tan((90 + lat) * Math.PI / 360)) * R / Math.PI]
const fromMerc = ([x, y]) => [x / R * 180, (2 * Math.atan(Math.exp(y / R * Math.PI)) - Math.PI / 2) * 180 / Math.PI]

// (u, v) from 0 to 1 across and down the image → [lng, lat]
export function imageToLngLat(corners) {
  const [tl, tr, br, bl] = corners.map(toMerc)
  return (u, v) => {
    const point = u + v <= 1
      ? [0, 1].map(k => tl[k] + u * (tr[k] - tl[k]) + v * (bl[k] - tl[k]))
      : [0, 1].map(k => br[k] + (1 - u) * (bl[k] - br[k]) + (1 - v) * (tr[k] - br[k]))
    return fromMerc(point)
  }
}

// ─── Grid steps ───────────────────────────────────────────────────────────────────

// Otsu's threshold: the brightness that best splits the image into two groups
export function otsu(lum) {
  const histogram = new Array(256).fill(0)
  for (const v of lum) histogram[v]++
  const total = lum.length
  let sum = 0
  for (let t = 0; t < 256; t++) sum += t * histogram[t]
  let sumBelow = 0, below = 0, best = 0, bestVariance = -1
  for (let t = 0; t < 256; t++) {
    below += histogram[t]
    if (!below) continue
    const above = total - below
    if (!above) break
    sumBelow += t * histogram[t]
    const meanBelow = sumBelow / below, meanAbove = (sum - sumBelow) / above
    const variance = below * above * (meanBelow - meanAbove) ** 2
    if (variance > bestVariance) { bestVariance = variance; best = t }
  }
  return best + 1 // ink is darker than this
}

// Typical pen line width: the median length of horizontal runs of ink
function strokeWidth(ink, w, h) {
  const runs = []
  for (let y = 0; y < h; y++) {
    let run = 0
    for (let x = 0; x <= w; x++) {
      if (x < w && ink[y * w + x]) run++
      else if (run) { runs.push(run); run = 0 }
    }
  }
  if (!runs.length) return 1
  runs.sort((a, b) => a - b)
  return runs[Math.floor(runs.length / 2)]
}

// Square dilation by r pixels, as a horizontal then a vertical pass
function dilate(mask, w, h, r) {
  const across = new Uint8Array(mask.length)
  for (let y = 0; y < h; y++) {
    let last = -Infinity
    for (let x = 0; x < w; x++) {
      if (mask[y * w + x]) last = x
      if (x - last <= r) across[y * w + x] = 1
    }
    last = Infinity
    for (let x = w - 1; x >= 0; x--) {
      if (mask[y * w + x]) last = x
      if (last - x <= r) across[y * w + x] = 1
    }
  }
  const out = new Uint8Array(mask.length)
  for (let x = 0; x < w; x++) {
    let last = -Infinity
    for (let y = 0; y < h; y++) {
      if (across[y * w + x]) last = y
      if (y - last <= r) out[y * w + x] = 1
    }
    last = Infinity
    for (let y = h - 1; y >= 0; y--) {
      if (across[y * w + x]) last = y
      if (last - y <= r) out[y * w + x] = 1
    }
  }
  return out
}

// 4-connected flood: every `from` cell reachable from the stack becomes `to`
function floodFrom(stack, state, w, h, from, to) {
  while (stack.length) {
    const i = stack.pop()
    const x = i % w
    if (x > 0 && state[i - 1] === from) { state[i - 1] = to; stack.push(i - 1) }
    if (x < w - 1 && state[i + 1] === from) { state[i + 1] = to; stack.push(i + 1) }
    if (i >= w && state[i - w] === from) { state[i - w] = to; stack.push(i - w) }
    if (i < (h - 1) * w && state[i + w] === from) { state[i + w] = to; stack.push(i + w) }
  }
}

// One region of unreached paper, marked done (3) as it goes
function regionFrom(start, state, w, h) {
  const pixels = []
  const stack = [start]
  state[start] = 3
  let minX = w, minY = h, maxX = 0, maxY = 0
  while (stack.length) {
    const i = stack.pop()
    pixels.push(i)
    const x = i % w, y = (i - x) / w
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
    if (x > 0 && state[i - 1] === 0) { state[i - 1] = 3; stack.push(i - 1) }
    if (x < w - 1 && state[i + 1] === 0) { state[i + 1] = 3; stack.push(i + 1) }
    if (y > 0 && state[i - w] === 0) { state[i - w] = 3; stack.push(i - w) }
    if (y < h - 1 && state[i + w] === 0) { state[i + w] = 3; stack.push(i + w) }
  }
  return { pixels, minX, minY, maxX, maxY }
}

// The region grown out by `grow` px (to the middle of the pen line around it), traced and
// simplified: corners in image pixels, or null if no clean shape comes out
function traceRegion(region, w, h, grow) {
  const pad = grow + 1
  const ox = region.minX - pad, oy = region.minY - pad
  const sw = region.maxX - region.minX + 1 + 2 * pad, sh = region.maxY - region.minY + 1 + 2 * pad
  const mask = new Uint8Array(sw * sh)
  for (const i of region.pixels) {
    const x = i % w, y = (i - x) / w
    mask[(y - oy) * sw + (x - ox)] = 1
  }
  const grown = dilate(mask, sw, sh, grow)
  const [shape] = contours().size([sw, sh]).thresholds([0.5])(Float64Array.from(grown))
  let best = null, bestArea = 0
  for (const polygon of shape.coordinates) {
    const area = Math.abs(ringArea(polygon[0]))
    if (area > bestArea) { best = polygon[0]; bestArea = area }
  }
  if (!best) return null
  // Keep it on the image
  const ring = best.map(([x, y]) => [Math.min(w, Math.max(0, x + ox)), Math.min(h, Math.max(0, y + oy))])

  // A few corners: coarser until there are few enough, finer if that made edges cross
  let tolerance = Math.max(1.5, Math.sqrt(bestArea) * 0.03)
  let corners = simplify(ring, tolerance).slice(0, -1)
  while (corners.length > MAX_CORNERS) {
    tolerance *= 1.4
    corners = simplify(ring, tolerance).slice(0, -1)
  }
  for (let tries = 0; corners.length >= 4 && crossingEdges(corners).length && tries < 4; tries++) {
    tolerance /= 1.5
    corners = simplify(ring, tolerance).slice(0, -1)
  }
  if (corners.length < 3 || crossingEdges(corners).length) return null
  return corners
}

// ─── Shapes ───────────────────────────────────────────────────────────────────────

const METRES_PER_DEGREE = 111320

// lng/lat with lng scaled by cos(latitude): degrees of latitude both ways
function flat([lng, lat]) {
  return [lng * Math.cos(lat * Math.PI / 180), lat]
}

function ringArea(ring) {
  let s = 0
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) s += (ring[j][0] - ring[i][0]) * (ring[j][1] + ring[i][1])
  return s / 2
}

// Douglas–Peucker on a closed ring (first point repeated at the end)
function simplify(ring, tolerance) {
  const keep = new Uint8Array(ring.length)
  keep[0] = keep[ring.length - 1] = 1
  let far = 0, farDist = 0
  for (let i = 1; i < ring.length - 1; i++) {
    const d = Math.hypot(ring[i][0] - ring[0][0], ring[i][1] - ring[0][1])
    if (d > farDist) { farDist = d; far = i }
  }
  keep[far] = 1
  const stack = [[0, far], [far, ring.length - 1]]
  while (stack.length) {
    const [s, e] = stack.pop()
    let index = -1, max = tolerance
    for (let i = s + 1; i < e; i++) {
      const d = segmentDistance(ring[i], ring[s], ring[e])
      if (d > max) { max = d; index = i }
    }
    if (index >= 0) { keep[index] = 1; stack.push([s, index], [index, e]) }
  }
  return ring.filter((_, i) => keep[i])
}

function segmentDistance([px, py], [ax, ay], [bx, by]) {
  const dx = bx - ax, dy = by - ay
  const len = dx * dx + dy * dy
  const t = len ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len)) : 0
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
}

function pointInRing(x, y, pts) {
  let inside = false
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j]
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside
  }
  return inside
}

// Boulders this shape overlaps by a real share of either (as the LiDAR suggestions count
// it: a fifth), biggest overlap first. Measured on a 24 × 24 grid of sample points.
function overlapping(ring, boulders) {
  const xs = ring.map(p => p[0]), ys = ring.map(p => p[1])
  const box = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]
  const found = []
  for (const { id, ring: other } of boulders) {
    const oxs = other.map(p => p[0]), oys = other.map(p => p[1])
    const x0 = Math.max(box[0], Math.min(...oxs)), x1 = Math.min(box[2], Math.max(...oxs))
    const y0 = Math.max(box[1], Math.min(...oys)), y1 = Math.min(box[3], Math.max(...oys))
    if (x0 >= x1 || y0 >= y1) continue
    const both = samples(Math.min(box[0], Math.min(...oxs)), Math.min(box[1], Math.min(...oys)),
      Math.max(box[2], Math.max(...oxs)), Math.max(box[3], Math.max(...oys)),
      (x, y) => [pointInRing(x, y, ring), pointInRing(x, y, other)])
    const inShape = both.filter(([a]) => a).length
    const inBoulder = both.filter(([, b]) => b).length
    const shared = both.filter(([a, b]) => a && b).length
    if (shared >= 3 && (shared >= 0.2 * inShape || shared >= 0.2 * inBoulder)) found.push([id, shared])
  }
  return found.sort((p, q) => q[1] - p[1]).map(([id]) => id)
}

function samples(x0, y0, x1, y1, test) {
  const out = []
  const steps = 24
  for (let i = 0; i < steps; i++) {
    for (let j = 0; j < steps; j++) {
      out.push(test(x0 + (i + 0.5) * (x1 - x0) / steps, y0 + (j + 0.5) * (y1 - y0) / steps))
    }
  }
  return out
}
