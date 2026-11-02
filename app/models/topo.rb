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

  # The boulder this photo shows: linked by its lines, or matched by GPS when uploaded
  def matched_boulder_id
    boulder_id || suggested_boulder_id
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

  # Where a problem drawn on this photo goes when it has no location yet: on the photo's
  # boulder outline when there is one, else where the photo was taken (so it can be found
  # on the map and nudged into place). Nil without photo GPS, or when a problem list put
  # the problem on a different boulder from the one this photo shows.
  def location_for(problem)
    return if problem.boulder_id && matched_boulder_id && problem.boulder_id != matched_boulder_id

    location_on_boulder || gps_location
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
