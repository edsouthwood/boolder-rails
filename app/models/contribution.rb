class Contribution < ApplicationRecord
  include Geolocatable
  geolocatable :location

  has_many_attached :photos
  has_many_attached :line_drawings
  has_many_attached :location_drawings
  belongs_to :problem, optional: true
  belongs_to :existing_topo, class_name: "Topo", optional: true

  audited

  STATES = %w[pending accepted closed]
  scope :pending, -> { where(state: "pending") }
  scope :accepted, -> { where(state: "accepted") }
  scope :closed, -> { where(state: "closed") }

  validates :state, inclusion: { in: STATES }
  validates :contributor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :must_have_some_content
  validate :existing_topo_in_problem_area

  def accepted?
    state == "accepted"
  end

  def closed?
    state == "closed"
  end

  def pending?
    state == "pending"
  end

  def self.top_contributors(limit: 15)
    accepted
      .where.not(contributor_name: [ nil, "" ])
      .group("LOWER(TRIM(contributor_name))")
      .select("MIN(contributor_name) AS display_name, COUNT(*) AS contributions_count")
      .order(Arel.sql("contributions_count DESC, display_name ASC"))
      .limit(limit)
  end

  private

  # Reject empty/spam submissions: a contribution must carry at least one piece of
  # useful information. `location` is set from lat/lon by Geolocatable's before_validation.
  def must_have_some_content
    has_content =
      photos.attached? ||
      location.present? ||
      comment.present? ||
      line_coordinates.present? ||
      problem_name.present?

    errors.add(:base, "A contribution must include a photo, location, line, comment or problem name") unless has_content
  end

  def existing_topo_in_problem_area
    return if existing_topo.blank? || problem.blank?

    # reorder(nil) drops the ORDER BY inherited from Line's default scope,
    # which Postgres rejects in a SELECT DISTINCT on a different column
    topo_area_ids = existing_topo.problems.reorder(nil).distinct.pluck(:area_id)
    return if topo_area_ids.empty? || topo_area_ids.include?(problem.area_id)

    errors.add(:existing_topo_id, "must belong to the same area as the problem")
  end
end
