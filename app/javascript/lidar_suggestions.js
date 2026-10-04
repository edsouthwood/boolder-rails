import { contours } from 'd3-contour'

// Suggests boulder outlines from Environment Agency 1 m LiDAR (England only).
//
// Rock is anything standing MIN_HEIGHT above the ground model (DTM) whose first and
// last laser returns agree: on rock both hit the same hard surface, in gorse or trees
// the first return comes off the leaves and the last from deeper in. Tuned at Bonehill
// (see docs/admin_guide.md). The EA's WCS reprojects to Web Mercator for us, using the
// OSTN15 grid, so no British National Grid maths happens here.

const WCS = 'https://environment.data.gov.uk/spatialdata/'
const COVERAGES = {
  firstReturn: ['lidar-composite-digital-surface-model-first-return-dsm-1m', 'df4e3ec3-315e-48aa-aaaf-b5ae74d7b2bb__Lidar_Composite_Elevation_FZ_DSM_1m'],
  lastReturn: ['lidar-composite-digital-surface-model-last-return-dsm-1m', '9ba4d5ac-d596-445a-9056-dae3ddec0178__Lidar_Composite_Elevation_LZ_DSM_1m'],
  ground: ['lidar-composite-digital-terrain-model-dtm-1m', '13787b9a-26a4-4775-8523-806d13af58fc__Lidar_Composite_Elevation_DTM_1m'],
}

const MIN_HEIGHT = 1.0      // m above ground
const MAX_RETURN_GAP = 0.25 // m; first minus last return above this = vegetation
const MIN_AREA = 3.0        // m²
const PIXEL = 0.5           // m of ground per pixel requested
const SMOOTHING = 0.4       // px, Gaussian sigma before tracing
const SIMPLIFY = 0.25       // m, Douglas–Peucker tolerance
const MIN_OVERLAP = 0.2     // share of a suggestion or boulder that counts as overlapping
export const MAX_SIZE = 1500 // px per side, so at most ~750 m across

const R = 20037508.342789244
const toMerc = ([lng, lat]) => [lng * R / 180, Math.log(Math.tan((90 + lat) * Math.PI / 360)) * R / Math.PI]
const toLngLat = ([x, y]) => [x / R * 180, (2 * Math.atan(Math.exp(y / R * Math.PI)) - Math.PI / 2) * 180 / Math.PI]

// bounds: { west, south, east, north } in degrees.
// boulders: [{ id, ring: [[lng, lat], ...] }] — used to flag suggestions that overlap them.
// Returns [{ coordinates: [[lng, lat], ...], area, height, overlaps: [boulderId, ...] }]
export async function suggestBoulders(bounds, boulders) {
  const [x0, y0] = toMerc([bounds.west, bounds.south])
  const [x1, y1] = toMerc([bounds.east, bounds.north])
  const k = 1 / Math.cos((bounds.south + bounds.north) / 2 * Math.PI / 180) // mercator units per ground metre
  const width = Math.round((x1 - x0) / (PIXEL * k))
  const height = Math.round((y1 - y0) / (PIXEL * k))
  if (width > MAX_SIZE || height > MAX_SIZE) throw new Error('Zoom in further: the view must be under about 750 m across')

  const [first, last, ground] = await Promise.all(
    Object.values(COVERAGES).map(([dataset, coverage]) => fetchGrid(dataset, coverage, x0, y0, x1, y1, width, height))
  )
  const { width: w, height: h, transform: [a, c, e, f] } = first
  const n = w * h
  const pixelArea = (a / k) * (-e / k)

  // Height above ground, with vegetation zeroed out
  const gap = new Float32Array(n)
  const above = new Float32Array(n)
  for (let i = 0; i < n; i++) {
    gap[i] = nanToZero(first.data[i] - last.data[i])
    above[i] = nanToZero(first.data[i] - ground.data[i])
  }
  const vegetation = median3x3(gap, w, h)
  for (let i = 0; i < n; i++) if (vegetation[i] > MAX_RETURN_GAP) above[i] = 0
  const smooth = gaussian(above, w, h, SMOOTHING)

  const boulderIds = rasteriseBoulders(boulders, w, h, ([lng, lat]) => {
    const [x, y] = toMerc([lng, lat])
    return [(x - c) / a, (y - f) / e]
  })
  const boulderSizes = new Map()
  for (const id of boulderIds) if (id) boulderSizes.set(id, (boulderSizes.get(id) || 0) + 1)
  // An overlap counts when it's a real share of either shape, not just touching edges
  const significant = (id, count, size) =>
    count >= 3 && (count >= MIN_OVERLAP * size || count >= MIN_OVERLAP * boulderSizes.get(id))

  const toWorld = (col, row) => toLngLat([c + col * a, f + row * e])
  const suggestions = []
  for (const comp of components(smooth, w, h, MIN_HEIGHT)) {
    if (comp.pixels.length * pixelArea < MIN_AREA) continue
    const ring = traceComponent(comp, smooth, w)
    if (!ring) continue
    const simplified = simplify(ring, SIMPLIFY * k / a)
    if (simplified.length < 4) continue
    const overlapCounts = new Map()
    let top = 0
    for (const i of comp.pixels) {
      top = Math.max(top, smooth[i])
      const id = boulderIds[i]
      if (id) overlapCounts.set(id, (overlapCounts.get(id) || 0) + 1)
    }
    suggestions.push({
      coordinates: simplified.slice(0, -1).map(([col, row]) => toWorld(col, row)),
      area: Math.round(comp.pixels.length * pixelArea),
      height: Math.round(top * 10) / 10,
      overlaps: [...overlapCounts.entries()].filter(([id, count]) => significant(id, count, comp.pixels.length))
        .sort((p, q) => q[1] - p[1]).map(([id]) => id),
    })
  }
  return suggestions
}

// ─── Fetching ──────────────────────────────────────────────────────────────────

async function fetchGrid(dataset, coverage, x0, y0, x1, y1, width, height) {
  const crs = 'http://www.opengis.net/def/crs/EPSG/0/3857'
  const url = `${WCS}${dataset}/wcs?service=WCS&version=2.0.1&request=GetCoverage&CoverageId=${coverage}` +
    `&format=image/tiff&subsettingCrs=${crs}&outputCrs=${crs}&subset=X(${x0},${x1})&subset=Y(${y0},${y1})` +
    `&scaleSize=i(${width}),j(${height})&geotiff:compression=Deflate`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`LiDAR service returned ${response.status} — try again later`)
  return readGeoTiff(await response.arrayBuffer())
}

// Minimal reader for the single-band float32 GeoTIFFs the EA's GeoServer returns:
// tiled or stripped, uncompressed or zlib-deflated, georeferenced by
// ModelTransformation or tiepoint + pixel scale. Nodata (-3.4e38) becomes NaN.
export async function readGeoTiff(buffer) {
  const view = new DataView(buffer)
  const little = view.getUint16(0) === 0x4949
  const u16 = (o) => view.getUint16(o, little)
  const u32 = (o) => view.getUint32(o, little)
  const f64 = (o) => view.getFloat64(o, little)
  const sizes = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 11: 4, 12: 8, 16: 8 }

  const tags = {}
  const ifd = u32(4)
  for (let i = 0; i < u16(ifd); i++) {
    const entry = ifd + 2 + i * 12
    const tag = u16(entry), type = u16(entry + 2), count = u32(entry + 4)
    const size = sizes[type] || 1
    const at = size * count > 4 ? u32(entry + 8) : entry + 8
    const read = (j) => type === 3 ? u16(at + j * 2) : type === 4 ? u32(at + j * 4) : type === 12 ? f64(at + j * 8) : view.getUint8(at + j)
    tags[tag] = Array.from({ length: count }, (_, j) => read(j))
  }

  const width = tags[256][0], height = tags[257][0]
  const compression = tags[259]?.[0] ?? 1
  if (tags[258][0] !== 32 || tags[339]?.[0] !== 3) throw new Error('Unexpected LiDAR data format (not float32)')
  if ((tags[317]?.[0] ?? 1) !== 1) throw new Error('Unexpected LiDAR data format (predictor)')
  if (![1, 8, 32946].includes(compression)) throw new Error(`Unexpected LiDAR compression (${compression})`)

  const tiled = tags[322] !== undefined
  const blockWidth = tiled ? tags[322][0] : width
  const blockHeight = tiled ? tags[323][0] : (tags[278]?.[0] ?? height)
  const offsets = tiled ? tags[324] : tags[273]
  const counts = tiled ? tags[325] : tags[279]
  const across = Math.ceil(width / blockWidth)

  const data = new Float32Array(width * height)
  await Promise.all(offsets.map(async (offset, b) => {
    let bytes = new Uint8Array(buffer, offset, counts[b])
    if (compression !== 1) {
      const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'))
      bytes = new Uint8Array(await new Response(stream).arrayBuffer())
    }
    const block = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    const left = (b % across) * blockWidth, topRow = Math.floor(b / across) * blockHeight
    const rows = Math.min(blockHeight, height - topRow), cols = Math.min(blockWidth, width - left)
    for (let r = 0; r < rows; r++) {
      for (let col = 0; col < cols; col++) {
        const v = block.getFloat32((r * blockWidth + col) * 4, little)
        data[(topRow + r) * width + left + col] = v < -1e30 ? NaN : v
      }
    }
  }))

  let transform
  if (tags[34264]) {
    const m = tags[34264]
    transform = [m[0], m[3], m[5], m[7]] // x = c + a*col, y = f + e*row
  } else {
    const [sx, sy] = tags[33550], t = tags[33922]
    transform = [sx, t[3] - t[0] * sx, -sy, t[4] + t[1] * sy]
  }
  return { width, height, data, transform }
}

// ─── Raster helpers ────────────────────────────────────────────────────────────

const nanToZero = (v) => (Number.isNaN(v) ? 0 : v)

function median3x3(src, w, h) {
  const out = new Float32Array(src.length)
  const win = new Float32Array(9)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let k = 0
      for (let dy = -1; dy <= 1; dy++) {
        const yy = Math.min(h - 1, Math.max(0, y + dy))
        for (let dx = -1; dx <= 1; dx++) {
          const xx = Math.min(w - 1, Math.max(0, x + dx))
          win[k++] = src[yy * w + xx]
        }
      }
      win.sort()
      out[y * w + x] = win[4]
    }
  }
  return out
}

function gaussian(src, w, h, sigma) {
  const radius = Math.ceil(3 * sigma)
  const kernel = []
  for (let i = -radius; i <= radius; i++) kernel.push(Math.exp(-(i * i) / (2 * sigma * sigma)))
  const sum = kernel.reduce((s, v) => s + v, 0)
  const weights = kernel.map((v) => v / sum)
  const pass = (input, horizontal) => {
    const out = new Float32Array(input.length)
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let acc = 0
        for (let i = -radius; i <= radius; i++) {
          const xx = horizontal ? Math.min(w - 1, Math.max(0, x + i)) : x
          const yy = horizontal ? y : Math.min(h - 1, Math.max(0, y + i))
          acc += input[yy * w + xx] * weights[i + radius]
        }
        out[y * w + x] = acc
      }
    }
    return out
  }
  return pass(pass(src, true), false)
}

// 4-connected regions above threshold
function components(grid, w, h, threshold) {
  const seen = new Uint8Array(grid.length)
  const found = []
  for (let start = 0; start < grid.length; start++) {
    if (seen[start] || grid[start] <= threshold) continue
    const pixels = []
    const stack = [start]
    seen[start] = 1
    let minX = w, minY = h, maxX = 0, maxY = 0
    while (stack.length) {
      const i = stack.pop()
      pixels.push(i)
      const x = i % w, y = (i - x) / w
      if (x < minX) minX = x
      if (x > maxX) maxX = x
      if (y < minY) minY = y
      if (y > maxY) maxY = y
      for (const j of [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]) {
        if (j >= 0 && !seen[j] && grid[j] > threshold) { seen[j] = 1; stack.push(j) }
      }
    }
    found.push({ pixels, minX, minY, maxX, maxY })
  }
  return found
}

// Trace one region's outline at MIN_HEIGHT, on a 1px zero-padded sub-grid so the
// contour closes. Returns the largest outer ring in full-grid pixel coordinates.
function traceComponent(comp, grid, w) {
  const sw = comp.maxX - comp.minX + 3, sh = comp.maxY - comp.minY + 3
  const sub = new Float64Array(sw * sh)
  for (const i of comp.pixels) {
    const x = i % w, y = (i - x) / w
    sub[(y - comp.minY + 1) * sw + (x - comp.minX + 1)] = grid[i]
  }
  const [shape] = contours().size([sw, sh]).thresholds([MIN_HEIGHT])(sub)
  let best = null, bestArea = 0
  for (const polygon of shape.coordinates) {
    const ring = polygon[0]
    const area = Math.abs(ringArea(ring))
    if (area > bestArea) { best = ring; bestArea = area }
  }
  return best && best.map(([x, y]) => [x - 1 + comp.minX, y - 1 + comp.minY])
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
  // Split at the point farthest from the start so a closed ring has a proper baseline
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

// Grid of boulder ids (0 = none), by testing pixel centres against each outline
function rasteriseBoulders(boulders, w, h, toPixel) {
  const ids = new Int32Array(w * h)
  for (const { id, ring } of boulders) {
    const pts = ring.map(toPixel)
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1])
    const x0 = Math.max(0, Math.floor(Math.min(...xs))), x1 = Math.min(w - 1, Math.ceil(Math.max(...xs)))
    const y0 = Math.max(0, Math.floor(Math.min(...ys))), y1 = Math.min(h - 1, Math.ceil(Math.max(...ys)))
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        if (pointInRing(x + 0.5, y + 0.5, pts)) ids[y * w + x] = id
      }
    }
  }
  return ids
}

function pointInRing(x, y, pts) {
  let inside = false
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j]
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside
  }
  return inside
}
