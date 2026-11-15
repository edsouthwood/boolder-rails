# A crag that isn't on the site yet, suggested by a visitor: its name, where it is and how
# to get there, plus any photos and problems they send for it in the same sitting. Nothing
# public changes until a super admin accepts it, which makes one new unpublished area and
# files everything sent with it into that area.
class CragSuggestion < ApplicationRecord
  include Geolocatable
  geolocatable :location

  belongs_to :area, optional: true
  has_many :photo_contributions, dependent: :nullify
  has_many :contributions, dependent: :nullify

  audited

  STATES = %w[pending accepted closed].freeze
  # A loose box round the south-west (Dartmoor and its neighbours): catches a pin left at
  # 0,0 or dropped in the wrong country, not a crag a few miles off the moor.
  LAT_RANGE = (49.9..51.3)
  LON_RANGE = (-5.8..-2.8)

  scope :pending, -> { where(state: "pending") }
  scope :accepted, -> { where(state: "accepted") }

  normalizes :name, :access_notes, :contributor_name, :contributor_email, with: ->(s) { s.strip.presence }

  validates :name, presence: true, length: { maximum: 100 }
  validates :state, inclusion: { in: STATES }
  validates :access_notes, length: { maximum: 2000 }
  validates :contributor_name, length: { maximum: 100 }
  validates :contributor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validate :location_in_the_south_west

  def pending? = state == "pending"
  def accepted? = state == "accepted"

  # Makes the area (unpublished), turns each pending photo into an undrawn topo there, and
  # points each pending problem at it so its review starts with the area chosen. The
  # problems stay pending: their lines and grades are still checked one by one.
  # Returns the area, or nil if this was already reviewed.
  def accept!(reviewed_by:, name: nil)
    return unless pending?

    transaction do
      area_name = name.to_s.strip.presence || self.name
      new_area = Area.create!(name: area_name, slug: Area.unique_slug_for(area_name), published: false,
                              description_en: access_notes)

      photo_contributions.pending.each do |photo_contribution|
        photo_contribution.update!(area: new_area)
        photo_contribution.accept!(reviewed_by: reviewed_by)
      end
      contributions.where(state: "pending", problem_id: nil).find_each { |contribution| contribution.update!(area: new_area) }

      update!(state: "accepted", area: new_area, reviewed_by: reviewed_by, reviewed_at: Time.current)
      new_area
    end
  end

  # Declined: kept, with the photos sent for it closed too. Problems are left pending in the
  # normal queue, as unlisted ones: one may still be worth having elsewhere.
  def close!(reviewed_by:, note: nil)
    return unless pending?

    transaction do
      photo_contributions.pending.each { |pc| pc.close!(reviewed_by: reviewed_by, note: note) }
      update!(state: "closed", reviewed_by: reviewed_by, reviewed_at: Time.current, moderator_note: note.presence)
    end
    true
  end

  private

  def location_in_the_south_west
    if location.blank?
      errors.add(:location, :blank)
    elsif !(LAT_RANGE.cover?(location.lat) && LON_RANGE.cover?(location.lon))
      errors.add(:location, "must be in the south-west of England")
    end
  end
end
