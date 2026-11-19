// Canvas drawing shared by the line editor (topo_editor_controller) and the topo
// workbench (topo_workbench_controller). Points are { x, y } fractions of the photo.

export const LINE_RED = '#ff2626'
export const HOLD_GREEN = '#10b981'
export const NOT_IN_RED = '#dc2626'

// The clicked spot as a point, rounded to 4 decimal places
export function pointFromClick(event, canvas) {
  const rect = canvas.getBoundingClientRect()
  const round = value => parseFloat(value.toFixed(4))
  return { x: round((event.clientX - rect.left) / rect.width), y: round((event.clientY - rect.top) / rect.height) }
}

// A filled dot: one point of a line
export function drawDot(ctx, point, color, radius = 6) {
  ctx.fillStyle = color
  ctx.beginPath()
  ctx.arc(point.x * ctx.canvas.width, point.y * ctx.canvas.height, radius, 0, Math.PI * 2)
  ctx.fill()
}

// A green ring: a start hold
export function drawHold(ctx, point) {
  ctx.strokeStyle = HOLD_GREEN
  ctx.lineWidth = 3
  ctx.beginPath()
  ctx.arc(point.x * ctx.canvas.width, point.y * ctx.canvas.height, 12, 0, Math.PI * 2)
  ctx.stroke()
}

// A shaded red polygon: a not-in area
export function drawExcludedArea(ctx, area) {
  if (!area.length) return
  ctx.strokeStyle = NOT_IN_RED
  ctx.fillStyle = 'rgba(220, 38, 38, 0.3)'
  ctx.lineWidth = 2
  tracePath(ctx, area)
  ctx.closePath()
  ctx.fill()
  ctx.stroke()
}

// A polyline through the points
export function drawPath(ctx, points, color, width) {
  if (points.length < 2) return
  ctx.strokeStyle = color
  ctx.lineWidth = width
  ctx.lineJoin = 'round'
  ctx.lineCap = 'round'
  tracePath(ctx, points)
  ctx.stroke()
}

function tracePath(ctx, points) {
  ctx.beginPath()
  points.forEach((p, i) => {
    const x = p.x * ctx.canvas.width
    const y = p.y * ctx.canvas.height
    i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)
  })
}

// ─── Start areas ────────────────────────────────────────────────────────────────
// A patch of rock to start on, drawn as a smooth closed curve through its corners (a closed
// Catmull-Rom spline as cubic Béziers), so four corners round a hold make an oval. The
// public topo draws the same curve (start_area_path in topo_sheet_helper.rb).

// The Bézier control points for the curve from corner i to the next, in canvas pixels
function startAreaSegment(points, i, width, height) {
  const n = points.length
  const at = k => { const p = points[((k % n) + n) % n]; return [p.x * width, p.y * height] }
  const [before, from, to, after] = [at(i - 1), at(i), at(i + 1), at(i + 2)]
  return {
    from, to,
    control1: [from[0] + (to[0] - before[0]) / 6, from[1] + (to[1] - before[1]) / 6],
    control2: [to[0] - (after[0] - from[0]) / 6, to[1] - (after[1] - from[1]) / 6],
  }
}

export function drawStartArea(ctx, area, color = HOLD_GREEN) {
  if (area.length < 2) return
  const { width, height } = ctx.canvas
  ctx.beginPath()
  ctx.moveTo(area[0].x * width, area[0].y * height)
  if (area.length < 3) {
    ctx.lineTo(area[1].x * width, area[1].y * height) // still being drawn: a plain line
  } else {
    area.forEach((_, i) => {
      const { control1, control2, to } = startAreaSegment(area, i, width, height)
      ctx.bezierCurveTo(...control1, ...control2, ...to)
    })
    ctx.closePath()
    ctx.fillStyle = 'rgba(16, 185, 129, 0.2)'
    ctx.fill()
  }
  ctx.lineJoin = 'round'
  ctx.lineWidth = 4
  ctx.strokeStyle = '#ffffff'
  ctx.stroke()
  ctx.lineWidth = 2
  ctx.strokeStyle = color
  ctx.stroke()
}

// The point halfway along the curve from corner i to the next, as a fraction of the photo
// (where a mid dot sits, so adding a corner there keeps the shape)
export function startAreaMidpoint(area, i) {
  const { from, to, control1, control2 } = startAreaSegment(area, i, 1, 1)
  const round = value => parseFloat(value.toFixed(4))
  return {
    x: round((from[0] + 3 * control1[0] + 3 * control2[0] + to[0]) / 8),
    y: round((from[1] + 3 * control1[1] + 3 * control2[1] + to[1]) / 8),
  }
}
