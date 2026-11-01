class Boulder < ApplicationRecord
  belongs_to :area

  audited associated_with: :import
  attr_accessor :import # used by audited associated_with: :import
  include CheckConflicts

  # Same tolerance the original geo:compute task used: problems sitting on (or a hair
  # outside) the outline count as being on the boulder.
  TOLERANCE = BigDecimal("1e-06")

  scope :containing, ->(point) {
    where("ST_DWithin(boulders.polygon::geometry, ST_GeomFromText(?, 4326), ?)", point.as_text, TOLERANCE)
  }

  after_save -> { Boulder.recompute_topos_later(boulder_ids: [ id ]) }, if: :saved_change_to_polygon?
  after_destroy -> { Topo.where(boulder_id: id).update_all(boulder_id: nil, position: nil) }

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
