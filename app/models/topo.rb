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

  # Boulder nearest the photo's GPS position when it was uploaded to the inbox
  def suggested_boulder_id
    metadata&.dig("suggested_boulder_id")
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
