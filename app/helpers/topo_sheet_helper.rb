module TopoSheetHelper
  # SVG path for a topo line on a 400x300 viewBox, smoothed exactly like
  # topo_line_controller.js#bezierCurve, so printed lines match the website's.
  def topo_line_path(coordinates)
    points = coordinates.map { |p| [ p["x"].to_f * 400, p["y"].to_f * 300 ] }
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
  def topo_line_start(coordinates)
    [ (coordinates.first["x"].to_f * 400).round(1), (coordinates.first["y"].to_f * 300).round(1) ]
  end
end
