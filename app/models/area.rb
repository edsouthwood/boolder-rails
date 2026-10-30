class Area < ApplicationRecord
  include PgSearchable

  init_pg_searchable trigram_threshold: 0.5, trigram_low_threshold: 0.45

  has_many :boulders, dependent: :destroy
  has_many :problems, dependent: :destroy
  has_many :circuits, -> { distinct }, through: :problems
  has_many :poi_routes, dependent: :destroy
  belongs_to :cluster, optional: true
  belongs_to :bleau_area, optional: true

  has_one_attached :cover do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 400, 400 ], saver: { quality: 80, strip: true, interlace: true }, preprocessed: true
    attachable.variant :medium, resize_to_limit: [ 800, 800 ], saver: { quality: 80, strip: true, interlace: true }, preprocessed: true
  end

  audited

  scope :published, -> { where(published: true) }
  include HasTagsConcern

  normalizes :name, :short_name, :description_fr, :description_en, :warning_fr, :warning_en, with: ->(s) { s.strip.presence }

  validates :tags, array: { inclusion: { in: %w[popular beginner_friendly family_friendly dry_fast sheltered sensitive_access remote] } }
  validates :slug, presence: true


  def levels
    @levels ||= 1.upto(8).map { |level| [ level, problems.with_location.level(level).count ] }.to_h
  end

  def self.beginner_friendly
    published.any_tags(:beginner_friendly).
    map { |area| [ area, area.problems.with_location.count ] }.sort { |a, b| b.second <=> a.second }.map(&:first).
    sort_by { |a| -a.circuits.select(&:beginner_friendly?).length }
  end

  def self.with_ids_keep_order(ids)
    where(id: ids).sort_by { |a| ids.index(a.id) }
  end

  def to_param
    slug
  end

  def name_debug
    [ id, name ].join(" - ")
  end

  # Fallback viewport (roughly Dartmoor) used when an area has no located
  # boulders or problems to derive real bounds from.
  DEFAULT_BOUNDS = {
    south_west: { lat: 50.50, lon: -4.10 },
    north_east: { lat: 50.65, lon: -3.75 }
  }.freeze

  def bounds
    @bounds ||=
      bounds_from(boulders.where(ignore_for_area_hull: false), :polygon) ||
      bounds_from(problems.with_location, :location) ||
      { south_west: nil, north_east: nil }
  end

  def serialized_bounds
    sw = bounds[:south_west]
    ne = bounds[:north_east]
    {
      south_west: { lat: sw&.lat || DEFAULT_BOUNDS[:south_west][:lat], lng: sw&.lon || DEFAULT_BOUNDS[:south_west][:lon] },
      north_east: { lat: ne&.lat || DEFAULT_BOUNDS[:north_east][:lat], lng: ne&.lon || DEFAULT_BOUNDS[:north_east][:lon] }
    }
  end

  # TODO: rewrite in SQL
  def main_circuits
    circuits.select { |c| c.problems.where(area_id: id).count >= 10 }.sort_by(&:average_grade)
  end

  def sorted_circuits
    circuits.sort_by(&:average_grade)
  end

  def nearby_areas(limit: 3)
    sw = bounds[:south_west]
    ne = bounds[:north_east]
    return [] unless sw && ne

    center_lon = (sw.lon + ne.lon) / 2.0
    center_lat = (sw.lat + ne.lat) / 2.0

    Area.published
      .where.not(id: id)
      .joins(:boulders)
      .group("areas.id")
      .order(Arel.sql("ST_Distance(ST_Centroid(ST_Collect(boulders.polygon::geometry)), ST_SetSRID(ST_MakePoint(#{center_lon}, #{center_lat}), 4326))"))
      .limit(limit)
  end

  # A short fingerprint of everything "Save for offline" stores for an area (problems,
  # boulders, topo lines and photos, cover): it changes whenever any of them do, so a
  # device can tell its saved copy is out of date. Batched so a page listing every area
  # costs a handful of queries. Returns { area_id => "1a2b3c4d5e6f" }.
  def self.offline_versions(areas)
    ids = areas.map(&:id)
    by_area = "problems.area_id"
    latest = OFFLINE_VERSION_LATEST
    parts = [
      Problem.where(area_id: ids).group(by_area).pluck(by_area, latest[:problems]),
      Boulder.where(area_id: ids).group(:area_id).pluck(:area_id, latest[:boulders]),
      Line.reorder(nil).joins(:problem).where(problems: { area_id: ids }).group(by_area).pluck(by_area, latest[:lines]),
      Topo.published.joins(lines: :problem).where(problems: { area_id: ids }).group(by_area)
        .pluck(by_area, latest[:topos], Arel.sql("array_agg(DISTINCT topos.id ORDER BY topos.id)")),
      ActiveStorage::Attachment.where(name: "photo", record_type: "Topo")
        .joins("JOIN lines ON lines.topo_id = active_storage_attachments.record_id")
        .joins("JOIN problems ON problems.id = lines.problem_id")
        .where(problems: { area_id: ids }).group(by_area)
        .pluck(by_area, Arel.sql("array_agg(DISTINCT active_storage_attachments.blob_id ORDER BY active_storage_attachments.blob_id)")),
      ActiveStorage::Attachment.where(name: "cover", record_type: "Area", record_id: ids).pluck(:record_id, :blob_id)
    ].map { |rows| rows.to_h { |area_id, *values| [ area_id, values ] } }

    areas.to_h do |area|
      fingerprint = [ area.updated_at.to_f, *parts.map { |part| part[area.id] } ].to_json
      [ area.id, Digest::SHA256.hexdigest(fingerprint)[0, 12] ]
    end
  end

  # Literal (non-interpolated) "latest change + row count" expressions per table.
  OFFLINE_VERSION_LATEST = {
    problems: Arel.sql("max(problems.updated_at), count(*)"),
    boulders: Arel.sql("max(boulders.updated_at), count(*)"),
    lines: Arel.sql("max(lines.updated_at), count(*)"),
    topos: Arel.sql("max(topos.updated_at), count(*)")
  }.freeze

  def offline_version
    Area.offline_versions([ self ])[id]
  end

  def download_size
    topos_count.to_f * 0.15
  end

  def topos_count
    Topo.published.joins(lines: :problem).where(problems: { area_id: id }).uniq.count
  end

  private

  # Pre-built, fully-literal extent expressions keyed by column. Kept as literals
  # (no interpolation) so the column name can never carry untrusted input into SQL.
  BOUNDS_EXTENT_EXPRESSIONS = {
    polygon: [
      Arel.sql("ST_XMin(ST_Extent(polygon::geometry))"),
      Arel.sql("ST_YMin(ST_Extent(polygon::geometry))"),
      Arel.sql("ST_XMax(ST_Extent(polygon::geometry))"),
      Arel.sql("ST_YMax(ST_Extent(polygon::geometry))")
    ],
    location: [
      Arel.sql("ST_XMin(ST_Extent(location::geometry))"),
      Arel.sql("ST_YMin(ST_Extent(location::geometry))"),
      Arel.sql("ST_XMax(ST_Extent(location::geometry))"),
      Arel.sql("ST_YMax(ST_Extent(location::geometry))")
    ]
  }.freeze

  # Derives a bounding box from `relation` using the geometry/geography column
  # `column` (:polygon or :location) in a single query. Returns nil when the
  # relation is empty so callers can fall through to the next source.
  def bounds_from(relation, column)
    min_lon, min_lat, max_lon, max_lat = relation.pick(*BOUNDS_EXTENT_EXPRESSIONS.fetch(column))
    return nil if min_lon.nil?

    {
      south_west: FACTORY.point(min_lon, min_lat),
      north_east: FACTORY.point(max_lon, max_lat)
    }
  end
end
