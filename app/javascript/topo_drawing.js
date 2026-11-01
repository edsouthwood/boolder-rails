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
