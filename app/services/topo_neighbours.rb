# Finds the photos to the left and right of a topo photo, as if you turned and walked along
# the rocks from where it was taken, so a visitor can step from photo to photo.
#
# Each public photo in the area gets:
# - a position: the middle of its located problems, else where the photo was taken;
# - a facing direction: the compass heading saved with the photo, else inferred from its
#   boulder (you stand outside the outline looking in, so it's from the nearest point on the
#   outline towards the boulder's middle).
# A photo with no facing direction gets no neighbours. Otherwise "right" is the nearest photo
# clearly to its right (20°–160° off the facing direction) within MAX_DISTANCE, and left
# likewise; photos taken from the same spot are skipped, having no side.
class TopoNeighbours
  MAX_DISTANCE = 150 # metres
  SAME_SPOT = 2 # metres
  SIDEWAYS = (20.0..160.0) # degrees off the facing direction
  EARTH_RADIUS = 6_371_000.0
  BOULDER_MATCH = 5 # metres from a photo's position to the boulder it shows

  Neighbour = Struct.new(:topo_id, :problem, :distance, keyword_init: true)

  def initialize(topo)
    @topo = topo
  end

  def left = neighbours[:left]
  def right = neighbours[:right]

  def neighbours
    @neighbours ||= find_neighbours
  end

  # Position and facing for every public photo in the area: { topo_id => [lat, lon, heading] }
  def placements
    @placements ||= compute_placements
  end

  private

  attr_reader :topo

  def area
    @area ||= Area.find_by(id: topo.area_id)
  end

  def find_neighbours
    return { left: nil, right: nil } unless area&.published && placements.key?(topo.id) && placements[topo.id][2]

    own = nearest_sides(topo.id)
    { left: :right, right: :left }.to_h do |side, opposite|
      # Stepping right then left should come back: a photo whose nearest on the `opposite`
      # side is this one wins, as long as it really is on this side of this photo
      returning = placements.keys.
        select { |id| id != topo.id && landing_problems[id] && nearest_sides(id)[opposite]&.first == topo.id && side_of(topo.id, id) == side }.
        min_by { |id| distance_between(topo.id, id) }
      found = returning ? [ returning, distance_between(topo.id, returning) ] : own[side]
      [ side, found && neighbour(*found) ]
    end
  end

  # The nearest photo clearly to each side of a photo, by its own facing direction:
  # { left: [topo_id, metres] | nil, right: … }
  def nearest_sides(id)
    @nearest_sides ||= {}
    @nearest_sides[id] ||= begin
      best = { left: nil, right: nil }
      if placements.dig(id, 2)
        placements.each_key do |other_id|
          next if other_id == id || !landing_problems[other_id]

          distance = distance_between(id, other_id)
          next if distance < SAME_SPOT || distance > MAX_DISTANCE

          side = side_of(id, other_id, SIDEWAYS)
          next unless side
          next if best[side] && best[side][1] <= distance

          best[side] = [ other_id, distance ]
        end
      end
      best
    end
  end

  # Which side of photo `from` (by its facing direction) photo `to` is on, if within `range`
  # degrees off that direction (default: anywhere either side)
  def side_of(from, to, range = (0.0..180.0))
    lat, lon, heading = placements[from]
    return unless heading

    _, bearing = offset(lat, lon, *placements[to][0, 2])
    relative = ((bearing - heading + 540) % 360) - 180 # -180..180, positive = to the right
    if range.cover?(relative) && relative.positive? then :right
    elsif range.cover?(-relative) && relative.negative? then :left
    end
  end

  def distance_between(a, b)
    offset(*placements[a][0, 2], *placements[b][0, 2]).first
  end

  # The neighbour's link: its most climbed problem that shows this photo on its own page
  def neighbour(topo_id, distance)
    problem = landing_problems[topo_id]
    problem && Neighbour.new(topo_id: topo_id, problem: problem, distance: distance)
  end

  def landing_problems
    @landing_problems ||= begin
      lines = Line.where(topo_id: placements.keys).includes(problem: :area).to_a
      problem_ids = lines.map(&:problem_id).uniq
      # A problem page shows the problem's first published line (Line's default order)
      page_topo = Line.unscoped.joins(:topo).where(topos: { published: true }, problem_id: problem_ids).
        select("DISTINCT ON (lines.problem_id) lines.problem_id, lines.topo_id").
        order("lines.problem_id, lines.created_at").to_h { |l| [ l.problem_id, l.topo_id ] }

      lines.group_by(&:topo_id).to_h do |topo_id, topo_lines|
        landing = topo_lines.map(&:problem).uniq.
          select { |p| !p.hidden && page_topo[p.id] == topo_id }.
          max_by { |p| [ p.ascents.to_i, -p.id ] }
        [ topo_id, landing ]
      end
    end
  end

  def compute_placements
    return {} unless area

    topos = Topo.published.in_area(area).to_a
    return {} if topos.empty?

    rows = Topo.connection.select_all(Topo.sanitize_sql_array([ <<~SQL, topos.map(&:id), area.id, BOULDER_MATCH ]))
      WITH positions AS (
        SELECT l.topo_id, ST_Centroid(ST_Collect(p.location::geometry)) AS pos
        FROM lines l JOIN problems p ON p.id = l.problem_id
        WHERE l.topo_id IN (?) AND p.location IS NOT NULL AND p.hidden = false
        GROUP BY l.topo_id
      )
      SELECT positions.topo_id, ST_Y(pos) AS lat, ST_X(pos) AS lon,
             degrees(ST_Azimuth(
               ST_ClosestPoint(ST_ExteriorRing(b.polygon::geometry), pos)::geography,
               ST_Centroid(b.polygon::geometry)::geography)) AS boulder_heading
      FROM positions
      LEFT JOIN LATERAL (
        SELECT polygon FROM boulders
        WHERE area_id = ? AND polygon IS NOT NULL AND ST_DWithin(polygon, pos::geography, ?)
        ORDER BY ST_Distance(polygon, pos::geography) LIMIT 1
      ) b ON true
    SQL
    from_problems = rows.to_h { |r| [ r["topo_id"], r ] }

    topos.each_with_object({}) do |t, out|
      row = from_problems[t.id]
      lat = row&.dig("lat") || t.metadata_latitude
      lon = row&.dig("lon") || t.metadata_longitude
      next unless lat && lon

      heading = t.metadata_heading || row&.dig("boulder_heading")
      out[t.id] = [ lat.to_f, lon.to_f, heading&.to_f ]
    end
  end

  # Distance (m) and compass bearing (degrees) from one point to another; flat-earth is
  # plenty at the scale of one crag
  def offset(lat1, lon1, lat2, lon2)
    north = (lat2 - lat1) * Math::PI / 180 * EARTH_RADIUS
    east = (lon2 - lon1) * Math::PI / 180 * EARTH_RADIUS * Math.cos(lat1 * Math::PI / 180)
    [ Math.hypot(north, east), Math.atan2(east, north) * 180 / Math::PI % 360 ]
  end
end
