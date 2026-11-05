class Boulder < ApplicationRecord
  belongs_to :area
  # Problems on this boulder: set by a problem-list import, by hand, or filled in when a
  # located problem sits on the outline. Independent of location, so unlocated problems count.
  has_many :problems, dependent: :nullify

  normalizes :name, with: ->(s) { s.squish.presence }
  validates :name, uniqueness: { scope: :area_id, case_sensitive: false }, allow_nil: true

  # A boulder can exist before it's drawn (a name from a problem list); only placed ones
  # have an outline to draw, match or measure.
  scope :placed, -> { where.not(polygon: nil) }
  scope :unplaced, -> { where(polygon: nil) }

  audited associated_with: :import
  attr_accessor :import # used by audited associated_with: :import
  include CheckConflicts

  # Same tolerance the original geo:compute task used: problems sitting on (or a hair
  # outside) the outline count as being on the boulder.
  TOLERANCE = BigDecimal("1e-06")

  # How far from an outline a photo can be taken and still be matched to that boulder
  MATCH_METRES = 15

  # The placed boulder nearest a photo's GPS position, within MATCH_METRES; nil without GPS.
  def self.nearest_to(lat, lon, within: MATCH_METRES)
    return if lat.nil? || lon.nil?

    point = sanitize_sql_array([ "ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography", lon.to_f, lat.to_f ])
    placed.
      where("ST_DWithin(boulders.polygon, #{point}, ?)", within).
      order(Arel.sql("ST_Distance(boulders.polygon, #{point})")).
      first
  end

  scope :containing, ->(point) {
    where("ST_DWithin(boulders.polygon::geometry, ST_GeomFromText(?, 4326), ?)", point.as_text, TOLERANCE)
  }

  after_save -> { Boulder.recompute_topos_later(boulder_ids: [ id ]) }, if: :saved_change_to_polygon?
  after_save :claim_problems_on_outline, if: :saved_change_to_polygon?

  def display_name
    name.presence || "Boulder ##{id}"
  end

  def placed?
    polygon.present?
  end

  # Takes over another boulder (usually an unplaced name from a problem list): its problems,
  # name and photo ties (workbench ties, visitor photos) move onto this one, then it's
  # deleted. Linked topos follow on the next recompute.
  def absorb!(other)
    raise ArgumentError, "can't absorb itself" if other.id == id
    raise ArgumentError, "boulders are in different areas" if other.area_id != area_id

    transaction do
      other.problems.update_all(boulder_id: id)
      Boulder.repoint_photo_ties(from: other.id, to: id, area_id: area_id)
      new_name = other.name
      other.destroy!
      update!(name: new_name) if new_name.present?
    end
    Boulder.recompute_topos_later(boulder_ids: [ id ])
    self
  end
  after_destroy -> {
    Topo.where(boulder_id: id).update_all(boulder_id: nil, position: nil)
    Boulder.repoint_photo_ties(from: id, to: nil, area_id: area_id)
  }

  # Workbench ties and inbox/visitor GPS matches are ids in topo metadata, and visitor photos
  # name a boulder too: move them to another boulder, or clear them (to: nil)
  def self.repoint_photo_ties(from:, to:, area_id:)
    Topo.where(area_id: area_id).where("metadata::jsonb ->> 'chosen_boulder_id' = :id OR metadata::jsonb ->> 'suggested_boulder_id' = :id", id: from.to_s).find_each do |topo|
      data = topo.metadata.dup
      %w[chosen_boulder_id suggested_boulder_id].each do |key|
        next unless data[key].to_s == from.to_s
        to ? data[key] = to : data.delete(key)
      end
      topo.update_columns(metadata: data)
    end
    PhotoContribution.where(boulder_id: from).update_all(boulder_id: to)
    PhotoContribution.where(gps_boulder_id: from).update_all(gps_boulder_id: to)
  end

  # Puts this boulder's problems back on the list as an unplaced boulder with its name, and
  # clears the name here. Used when an outline was given the wrong listed name.
  def relist!
    raise ArgumentError, "only a named boulder can go back on the list" if name.blank?

    transaction do
      listed_name = name
      update!(name: nil)
      listed = Boulder.create!(area_id: area_id, name: listed_name)
      problems.update_all(boulder_id: listed.id)
      listed
    end
  end

  # Enqueue a topo recompute for the given boulders and for every boulder containing
  # any of the given points, once the current transaction has committed (the job
  # queue lives in a separate database, so it could otherwise run too early).
  def self.recompute_topos_later(boulder_ids: [], points: [])
    ids = boulder_ids.compact
    points.compact.each { |point| ids += containing(point).pluck(:id) }
    ids.uniq!
    return if ids.empty?

    ActiveRecord.after_all_transactions_commit { RecomputeBoulderToposJob.perform_later(ids) }
  end

  # Located problems on this outline that have no boulder yet now belong to it. Problems
  # already assigned elsewhere (by a list or by hand) are left alone.
  def claim_problems_on_outline
    return if polygon.nil?

    Problem.where(area_id: area_id, boulder_id: nil).
      where("ST_DWithin(ST_GeomFromText(?, 4326), location::geometry, ?)", polygon.as_text, TOLERANCE).
      update_all(boulder_id: id)
  end

  # Links this boulder's topos to it (topos.boulder_id) and orders them (topos.position)
  # by walking its problems anti-clockwise, starting after the biggest angular gap
  # (the gap is the "back" of the boulder, so we start from the leftmost problem).
  def recompute_topos!
    with_lock do
      Topo.where(boulder_id: id).update_all(boulder_id: nil, position: nil)
      next if polygon.nil?

      centroid = Boulder.where(id: id).pick(Arel.sql("ST_AsText(ST_Centroid(polygon::geometry))"))

      problems = Problem.
        select("problems.*, degrees(ST_Azimuth(ST_GeomFromText(#{Boulder.connection.quote(centroid)}, 4326), location::geometry)) AS degrees").
        where("ST_DWithin(ST_GeomFromText(?, 4326), location::geometry, ?)", polygon.as_text, TOLERANCE).
        order("degrees ASC").to_a

      if problems.length >= 2
        gaps = problems.each_cons(2).map { |a, b| b.degrees.to_f - a.degrees.to_f }
        gaps << (problems.first.degrees.to_f + 360 - problems.last.degrees.to_f)

        idx = gaps.each_with_index.max_by { |gap, _| gap }.last
        problems = Array.new(problems.length) { |i| problems[(idx - i) % problems.length] }
      end

      positions = {}
      problems.each_with_index do |problem, index|
        topo_id = problem.lines.published.first&.topo_id
        positions[topo_id] ||= index if topo_id
      end

      positions.each do |topo_id, position|
        Topo.where(id: topo_id).update_all(boulder_id: id, position: position)
      end
    end
  end
end
