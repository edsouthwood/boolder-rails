class Contribution < ApplicationRecord
  include Geolocatable
  geolocatable :location

  has_many_attached :photos
  has_many_attached :line_drawings
  has_many_attached :location_drawings
  belongs_to :problem, optional: true

  audited

  STATES = %w[pending accepted closed]
  scope :pending, -> { where(state: "pending") }
  scope :accepted, -> { where(state: "accepted") }
  scope :closed, -> { where(state: "closed") }

  validates :state, inclusion: { in: STATES }

  def self.top_contributors(limit: 15)
    accepted
      .where.not(contributor_name: [ nil, "" ])
      .group("LOWER(TRIM(contributor_name))")
      .select("MIN(contributor_name) AS display_name, COUNT(*) AS contributions_count")
      .order(Arel.sql("contributions_count DESC, display_name ASC"))
      .limit(limit)
  end
end
