# The tool bar under the breadcrumbs on every area admin page: tabs for the working views
# with counts of what's waiting in each, "+ Add", and a ⋮ menu for rarer actions.
module Admin::AreaToolbarHelper
  # Call from an area page's view; current is the tab to underline (nil for none)
  def area_toolbar(area, current = nil)
    content_for :area_toolbar, render("admin/areas/toolbar", area: area, current: current)
  end

  # What's waiting in each tool: photos with lines to draw, problems with no location or
  # only an estimated one, boulders needing photos or lines. Boulders is the slow one, so
  # the areas list leaves it out.
  def area_tool_counts(area, boulders: true)
    @area_tool_counts ||= {}
    @area_tool_counts[[ area.id, boulders ]] ||= begin
      shown = area.problems.shown
      counts = {
        photos: Topo.in_area(area).undrawn.count,
        map: shown.where(location: nil).or(shown.where(location_estimated: true)).count
      }
      if boulders
        progress = @progress if @progress.is_a?(BoulderProgress) && @progress.area == area # the Boulders page has one
        counts[:boulders] = (progress || BoulderProgress.new(area)).rows.count(&:needs_topos?)
      end
      counts
    end
  end

  def area_tool_tabs(area)
    [
      [ :problems, "Problems", admin_area_problems_path(area_slug: area.slug, circuit_id: "first"), nil ],
      [ :boulders, "Boulders", admin_area_boulders_path(area_slug: area.slug), "need photos or lines" ],
      [ :photos,   "Photos",   admin_area_topos_path(area_slug: area.slug), "to draw" ],
      [ :map,      "Map",      admin_area_map_editor_path(area_slug: area.slug), "to place" ],
      [ :outlines, "Outlines", admin_area_boulder_editor_path(area_slug: area.slug), nil ]
    ]
  end
end
