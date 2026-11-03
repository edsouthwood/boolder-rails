class Topo < ApplicationRecord
  has_one_attached :photo do |attachable|
    attachable.variant :thumb,  resize_to_fill: [ 300, 200 ],   saver: { quality: 60, strip: true }, preprocessed: true
    attachable.variant :medium, resize_to_fill: [ 1200, 900 ],  saver: { quality: 50, strip: true, interlace: true }, preprocessed: true
  end

  belongs_to :area, optional: true
  has_many :lines, dependent: :destroy
  has_many :problems, through: :lines

  audited

  # Unpublished topos don't count when linking topos to boulders
  after_save -> { Boulder.recompute_topos_later(points: problems.map(&:location)) }, if: :saved_change_to_published?

  scope :published, -> { where(published: true) }
  scope :near_location, ->(point, distance_m = 10) {
    where(id:
      joins(lines: :problem)
        .where(
          "ST_DWithin(problems.location::geography, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, :dist)",
          lon: point.lon, lat: point.lat, dist: distance_m
        )
        .select("topos.id")
    )
  }

  validates :photo, presence: true

  # Photos uploaded to the area, plus older ones linked to it only through their problems
  scope :in_area, ->(area) {
    where(area_id: area.id).or(where(id: Line.unscoped.joins(:problem).where(problems: { area_id: area.id }).select(:topo_id)))
  }

  # Photos with no line yet, or with a line still to be drawn
  scope :undrawn, -> {
    where.not(id: Line.unscoped.select(:topo_id).where.not(topo_id: nil)).
      or(where(id: Line.unscoped.select(:topo_id).where(coordinates: nil)))
  }

  # Set when the photo is uploaded; older topos fall back to their problems' area
  def area_id
    self[:area_id] || problems.first&.area_id
  end

  # Published, and in a published area (by its own area, or any of its problems')
  def publicly_visible?
    return false unless published

    area_ids = ([ self[:area_id] ] + problems.reorder(nil).distinct.pluck(:area_id)).compact.uniq
    area_ids.any? && Area.where(id: area_ids, published: true).exists?
  end

  # Boulder nearest the photo's GPS position when it was uploaded to the inbox
  def suggested_boulder_id
    metadata&.dig("suggested_boulder_id")
  end

  # Boulder an admin tied the photo to in the workbench. Kept in metadata because
  # topos.boulder_id is rewritten whenever the boulder's topos are recomputed.
  def chosen_boulder_id
    metadata&.dig("chosen_boulder_id")
  end

  # Ties the photo to a boulder (nil unties it); saved straight away
  def choose_boulder!(boulder)
    data = (metadata || {}).dup
    if boulder
      data["chosen_boulder_id"] = boulder.id
    else
      data.delete("chosen_boulder_id")
    end
    update!(metadata: data)
  end

  # The boulder this photo shows: tied by hand, linked by its lines, or matched by GPS when uploaded
  def matched_boulder_id
    chosen_boulder_id || boulder_id || suggested_boulder_id
  end

  # How matched_boulder_id was found, for the workbench
  def boulder_match_source
    if chosen_boulder_id then :chosen
    elsif boulder_id then :lines
    elsif suggested_boulder_id then :gps
    end
  end

  # Where the photographer stood, snapped onto the matched boulder's outline, so a problem
  # placed there lands on the boulder (and the photo gets linked to it). Nil without both.
  def location_on_boulder
    lat, lon = metadata_latitude, metadata_longitude
    return unless lat && lon && matched_boulder_id

    sql = Boulder.sanitize_sql_array([ "ST_AsText(ST_ClosestPoint(polygon::geometry, ST_SetSRID(ST_MakePoint(?, ?), 4326)))", lon.to_f, lat.to_f ])
    wkt = Boulder.placed.where(id: matched_boulder_id).pick(Arel.sql(sql))
    wkt && FACTORY.parse_wkt(wkt)
  end

  # Gap between problems estimated from the same photo, so they don't sit on one spot
  SPREAD_METRES = 2
  # A problem on the photo further than this from where it was taken isn't used as a guide
  NEIGHBOUR_MAX_METRES = 30

  # Gives a problem with no location an estimated one from this photo (see
  # estimated_location_for) and flags it, so the location editor shows it needs placing
  # by hand. Returns whether it was located.
  def estimate_location!(problem)
    return false if problem.location.present?

    point = estimated_location_for(problem)
    point.present? && problem.update(location: point, location_estimated: true)
  end

  # Where a problem drawn on this photo goes when it has no location yet, so it can be
  # found on the map and nudged into place. The spot comes from, in order:
  # 1. where the photo was taken, snapped onto its boulder's outline
  # 2. another located problem on the photo (hand-placed ones first, same boulder first)
  # 3. where the photo was taken
  # Problems estimated from the same photo are spread out round that spot: along the
  # boulder's outline when there is one (so they stay on the boulder), else in a small
  # spiral. Nil when there's nothing to go on. Photo GPS isn't used when a problem list
  # put the problem on a different boulder from the one this photo shows.
  def estimated_location_for(problem)
    same_boulder = problem.boulder_id.nil? || matched_boulder_id.nil? || problem.boulder_id == matched_boulder_id
    others = estimate_neighbours(problem)
    neighbour = others.find { |p| p.boulder_id.nil? || problem.boulder_id.nil? || p.boulder_id == problem.boulder_id }
    gps = gps_location if same_boulder
    # A neighbour far from where the photo was taken is on another part of the crag, or misplaced
    neighbour = nil if neighbour && gps && metres_between(neighbour.location, gps) > NEIGHBOUR_MAX_METRES
    boulder = Boulder.placed.find_by(id: problem.boulder_id || matched_boulder_id)

    anchor = (gps if boulder) || neighbour&.location || gps
    return unless anchor

    (boulder && spread_along_outline(boulder, anchor, others.size)) || spread_round(anchor, others.size)
  end

  # Located problems on this photo other than this one, hand-placed first, then those on
  # the same boulder (the best ones to take a position from)
  def estimate_neighbours(problem)
    Problem.where(id: lines.select(:problem_id)).where.not(id: problem.id).with_location.to_a.
      sort_by { |p| [ p.location_estimated? ? 1 : 0, p.boulder_id == problem.boulder_id ? 0 : 1, p.id ] }
  end

  # The nth spot along the boulder's outline from the point nearest the anchor: 0, +2 m,
  # -2 m, +4 m… Nil when the anchor is too far from the outline to be about this boulder.
  def spread_along_outline(boulder, anchor, nth)
    step = (nth + 1) / 2 * SPREAD_METRES * (nth.odd? ? 1 : -1)
    sql = Boulder.sanitize_sql_array([ <<~SQL, anchor.as_text, step, Boulder::MATCH_METRES ])
      WITH ring AS (
        SELECT ST_ExteriorRing(polygon::geometry) AS line, polygon,
               ST_GeomFromText(?, 4326) AS anchor, ?::float AS step
        FROM boulders WHERE id = #{boulder.id.to_i}
      ), at AS (
        SELECT line, ST_LineLocatePoint(line, ST_ClosestPoint(line, anchor)) + step / NULLIF(ST_Length(line::geography), 0) AS f
        FROM ring WHERE ST_DWithin(polygon, anchor::geography, ?)
      )
      SELECT ST_AsText(ST_LineInterpolatePoint(line, f - floor(f))) FROM at
    SQL
    wkt = Boulder.connection.select_value(sql)
    wkt && FACTORY.parse_wkt(wkt)
  end

  # The nth spot of a sunflower spiral round the anchor (the 0th is the anchor itself)
  def spread_round(anchor, nth)
    return anchor if nth.zero?

    radius = SPREAD_METRES * 0.75 * Math.sqrt(nth)
    angle = nth * 137.508 * Math::PI / 180
    metres_per_degree = 111_320.0
    FACTORY.point(anchor.lon + radius * Math.sin(angle) / (metres_per_degree * Math.cos(anchor.lat * Math::PI / 180)),
                  anchor.lat + radius * Math.cos(angle) / metres_per_degree)
  end

  def metres_between(a, b)
    rad = Math::PI / 180
    dlat = (b.lat - a.lat) * rad
    dlon = (b.lon - a.lon) * rad
    h = Math.sin(dlat / 2)**2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dlon / 2)**2
    2 * 6_371_000 * Math.asin(Math.sqrt(h))
  end

  def gps_location
    lat, lon = metadata_latitude, metadata_longitude
    FACTORY.point(lon.to_f, lat.to_f) if lat && lon
  end

  def metadata_latitude
    metadata&.dig("latitude")
  end

  def metadata_longitude
    metadata&.dig("longitude")
  end

  def metadata_horizontal_accuracy
    metadata&.dig("horizontalAccuracy")
  end

  def metadata_heading
    metadata&.dig("heading")
  end
end
