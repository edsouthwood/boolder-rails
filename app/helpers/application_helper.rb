module ApplicationHelper
  LOGO_POINTS = "40.35,112.36 21.90,30.93 36.34,18.36 71.58,34.59 72.17,64.70 94.60,82.02 98.95,112.36".freeze

  # Top-nav link classes, highlighting the section the visitor is currently in.
  def nav_link_classes(active:)
    base = "flex items-center min-h-[44px] px-3.5 rounded-lg text-[15px] "
    if active
      base + "font-semibold text-granite bg-ground"
    else
      base + "font-medium text-muted hover:text-granite hover:bg-ground"
    end
  end

  # The bowda "B" drawn inline, so it can take any colour (e.g. light on the granite footer).
  def bowda_logo_svg(color: "#6F767A", **options)
    options[:"aria-hidden"] = "true" unless options.key?(:"aria-label")
    tag.svg(xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 117 133", **options) do
      tag.polygon(points: LOGO_POINTS, fill: "none", stroke: color, "stroke-width": 11, "stroke-linejoin": "round")
    end
  end
end
