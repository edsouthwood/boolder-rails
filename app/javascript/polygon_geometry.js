// Closed-shape helpers shared by the boulder editor (outlines) and the topo workbench
// (not-in and start areas). Points are [x, y] in a space where distances are fair: screen
// pixels, or lng/lat with lng scaled by cos(latitude).

// Where a new corner clicked near a shape should go, so clicking corners in any order still
// gives a shape whose edges don't cross: the index to splice it in at. Usually the end, as
// before (so a shape clicked round in order, hollows and all, comes out as clicked). Only
// when that would make edges cross does it go into the edge it adds least length to
// (cheapest insertion) among those where it makes no crossing.
export function insertionIndex(ring, point) {
  const n = ring.length
  const crossesAt = index => crossingEdges([...ring.slice(0, index), point, ...ring.slice(index)]).length > 0
  if (n < 3 || !crossesAt(n)) return n
  const candidates = ring.map((a, i) => {
    const b = ring[(i + 1) % n]
    return { index: i + 1, cost: distance(a, point) + distance(point, b) - distance(a, b) }
  }).sort((p, q) => p.cost - q.cost)
  return (candidates.find(({ index }) => !crossesAt(index)) || candidates[0]).index
}

// The edges (by the index of their first corner: edge i runs from corner i to i+1) that cross
// another edge of the same closed shape
export function crossingEdges(ring) {
  const n = ring.length
  if (n < 4) return []
  const crossing = new Set()
  for (let i = 0; i < n; i++) {
    for (let j = i + 2; j < n; j++) {
      if (i === 0 && j === n - 1) continue // neighbours through the closing corner
      if (segmentsCross(ring[i], ring[(i + 1) % n], ring[j], ring[(j + 1) % n])) {
        crossing.add(i)
        crossing.add(j)
      }
    }
  }
  return [...crossing].sort((a, b) => a - b)
}

function distance(a, b) {
  return Math.hypot(a[0] - b[0], a[1] - b[1])
}

// Whether two segments properly cross (touching ends don't count)
function segmentsCross(a, b, c, d) {
  const d1 = side(c, d, a), d2 = side(c, d, b), d3 = side(a, b, c), d4 = side(a, b, d)
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

function side(a, b, p) {
  return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
}
