# How far along each boulder in an area is: on the map, photographed, lines drawn.
# Feeds the admin "Boulders" list.
class BoulderProgress
  STATUSES = {
    not_on_map: "Not on map",
    needs_photos: "Needs photos",
    needs_lines: "Needs lines",
    done: "Done",
    no_problems: "No problems"
  }.freeze

  # problems: the shown ones (status and counts); hidden: set aside, listed but not counted
  Row = Struct.new(:boulder, :problems, :hidden, :photos, :next_topo, keyword_init: true) do
    def with_line = problems.count(&:has_line)

    def status
      if problems.empty? then :no_problems
      elsif !boulder.placed? then :not_on_map
      elsif photos.empty? then :needs_photos
      elsif with_line < problems.size then :needs_lines
      else :done
      end
    end

    def needs_topos? = %i[not_on_map needs_photos needs_lines].include?(status)
  end

  attr_reader :area

  def initialize(area)
    @area = area
  end

  # Most urgent first; named boulders before unnamed ones within a status
  def rows
    @rows ||= begin
      all_problems = area.problems.order(:name).to_a
      problems = all_problems.reject(&:hidden).group_by(&:boulder_id)
      hidden = all_problems.select(&:hidden).group_by(&:boulder_id)
      topos_by_boulder, undrawn = photos_by_boulder
      area.boulders.to_a.map do |boulder|
        photos = topos_by_boulder[boulder.id] || []
        # Where to draw next: a photo still waiting for lines, else the latest photo (the
        # workbench adds lines for the boulder's other problems to it)
        Row.new(boulder: boulder, problems: problems[boulder.id] || [], hidden: hidden[boulder.id] || [], photos: photos,
          next_topo: photos.find { |topo| undrawn.include?(topo.id) } || photos.max_by(&:id))
      end.sort_by do |row|
        [ STATUSES.keys.index(row.status), row.boulder.name ? 0 : 1, row.boulder.name.to_s.downcase, row.boulder.id ]
      end
    end
  end

  def unassigned_problems
    @unassigned_problems ||= area.problems.where(boulder_id: nil).order(:name).to_a
  end

  def hidden_count
    @hidden_count ||= area.problems.where(hidden: true).count
  end

  private

  # A photo counts for a boulder when it has a line for one of the boulder's problems, the
  # topo recompute linked it, an admin tied it there, or the photo inbox matched it by GPS.
  def photos_by_boulder
    topos = Topo.in_area(area).includes(lines: :problem).to_a
    undrawn = Topo.in_area(area).undrawn.pluck(:id).to_set
    by_boulder = Hash.new { |hash, key| hash[key] = [] }
    topos.each do |topo|
      ids = topo.lines.filter_map { |line| line.problem&.boulder_id }
      ids << topo.boulder_id << topo.chosen_boulder_id << topo.suggested_boulder_id
      ids.compact.uniq.each { |id| by_boulder[id] << topo }
    end
    [ by_boulder, undrawn ]
  end
end
