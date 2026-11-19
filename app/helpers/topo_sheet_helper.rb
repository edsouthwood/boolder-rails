module TopoSheetHelper
  # SVG path for a topo line on a 400-wide viewBox (300 high for a 4:3 photo), smoothed exactly like
  # topo_line_controller.js#bezierCurve, so printed lines match the website's.
  def topo_line_path(coordinates, height = 300)
    points = coordinates.map { |p| [ p["x"].to_f * 400, p["y"].to_f * height ] }
    return "" if points.size < 2
    return "M #{points[0].join(' ')} L #{points[1].join(' ')}" if points.size == 2

    d = +"M #{js_number(points[0][0])} #{js_number(points[0][1])} Q "
    i = 1
    while i < points.size - 2
      xc = (points[i][0] + points[i + 1][0]) / 2
      yc = (points[i][1] + points[i + 1][1]) / 2
      d << " #{points[i][0].round} #{points[i][1].round} #{xc.round} #{yc.round}"
      i += 1
    end
    d << " #{points[i][0].round} #{points[i][1].round} #{points[i + 1][0].round} #{points[i + 1][1].round}"
  end

  # Numbers as JavaScript prints them (40, not 40.0), so paths match the website's exactly
  def js_number(value)
    value == value.round ? value.round.to_s : value.round(10).to_s
  end

  # Start-point position on the 400x300 viewBox
  def topo_line_start(coordinates, height = 300)
    [ (coordinates.first["x"].to_f * 400).round(1), (coordinates.first["y"].to_f * height).round(1) ]
  end

  # Drawings over a topo are 400 wide; this is their height, so they have the photo's shape
  # (300 for the 4:3 crop older topos have)
  # A start area as an SVG path: a smooth closed curve through its corners (a closed
  # Catmull-Rom spline drawn as cubic Béziers), so four corners round a hold make an oval.
  # Points are fractions of the photo; width and height are the SVG's units.
  # The workbench draws the same curve (smoothClosedPath in topo_drawing.js).
  def start_area_path(area, width, height)
    points = area.map { |point| [ point["x"] * width, point["y"] * height ] }
    count = points.size
    format = ->(x, y) { "#{x.round(1)},#{y.round(1)}" }
    curves = count.times.map do |i|
      before, from, to, after = points[(i - 1) % count], points[i], points[(i + 1) % count], points[(i + 2) % count]
      control1 = format.(from[0] + (to[0] - before[0]) / 6, from[1] + (to[1] - before[1]) / 6)
      control2 = format.(to[0] - (after[0] - from[0]) / 6, to[1] - (after[1] - from[1]) / 6)
      "C #{control1} #{control2} #{format.(*to)}"
    end
    "M #{format.(*points.first)} #{curves.join(" ")} Z"
  end

  def topo_svg_height(topo)
    height = (400 / topo.aspect_ratio).round(1)
    height == height.round ? height.round : height
  end
end
