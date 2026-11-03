# A photo of a boulder sent in by a visitor, waiting to become a topo. Accepting one moves
# its photo onto a new, undrawn topo in the area (the same as a photo inbox upload), ready
# for lines to be drawn in the workbench.
class PhotoContribution < ApplicationRecord
  # Variants strip EXIF (GPS, camera details): only these are ever shown, even to admins.
  has_one_attached :photo do |attachable|
    attachable.variant :thumb, resize_to_fill: [ 300, 225 ], saver: { quality: 60, strip: true }
    attachable.variant :large, resize_to_limit: [ 1600, 1600 ], saver: { quality: 70, strip: true }
  end

  belongs_to :area
  belongs_to :boulder, optional: true
  # Set once accepted: the topo the photo became
  belongs_to :topo, optional: true

  audited

  STATES = %w[pending accepted closed].freeze
  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_SIZE = 15.megabytes
  # "photo": from the photo's own EXIF GPS; "device": the phone's position when it uploaded
  # a photo taken moments before (the photo itself had no GPS).
  LOCATION_SOURCES = %w[photo device].freeze
  BATCH_FORMAT = /\A[0-9a-f-]{36}\z/

  scope :pending, -> { where(state: "pending") }
  scope :accepted, -> { where(state: "accepted") }
  scope :closed, -> { where(state: "closed") }
  # The ones an admin may review: all for super admins, else those in their areas
  scope :reviewable_by, ->(admin) {
    slugs = admin.accessible_area_slugs
    slugs.nil? ? all : joins(:area).where(areas: { slug: slugs })
  }

  validates :state, inclusion: { in: STATES }
  validates :photo, presence: true, on: :create
  validates :location_source, inclusion: { in: LOCATION_SOURCES }, allow_nil: true
  validates :heading, numericality: { in: 0..360 }, allow_nil: true
  validates :contributor_name, length: { maximum: 100 }
  validates :contributor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :comment, length: { maximum: 1000 }
  # One upload session's photos share a client-made UUID, so they're emailed about once
  validates :batch, format: { with: BATCH_FORMAT }, allow_nil: true
  validate :photo_is_a_reasonable_image, on: :create

  normalizes :contributor_name, :contributor_email, :comment, with: ->(s) { s.strip.presence }

  def pending? = state == "pending"
  def accepted? = state == "accepted"
  def closed? = state == "closed"

  # The first photo of an upload session: the one the emails go out for
  def first_in_batch?
    batch.nil? || !PhotoContribution.where(batch: batch).where(id: ...id).exists?
  end

  def located? = location.present?

  # Makes the photo a topo in the area (undrawn, so it shows in "Photos to draw") and marks
  # this accepted. The photo's file moves to the topo rather than being copied. Returns the
  # topo, or nil when there's nothing to accept (already reviewed, or no photo).
  def accept!(reviewed_by:)
    return unless pending? && photo.attached?

    transaction do
      self.topo = Topo.create!(area: area, photo: photo.blob, metadata: topo_metadata)
      photo.detach
      update!(state: "accepted", reviewed_by: reviewed_by, reviewed_at: Time.current)
    end
    topo
  end

  def close!(reviewed_by:, note: nil)
    update!(state: "closed", reviewed_by: reviewed_by, reviewed_at: Time.current,
            moderator_note: note.presence || moderator_note)
  end

  # What to show for this photo: its own until accepted, then the topo's
  def display_photo
    topo&.photo&.attached? ? topo.photo : (photo if photo.attached?)
  end

  private

  # Same shape as a photo inbox upload's, so the workbench and boulder matching treat both alike
  def topo_metadata
    {
      "source" => "contribution",
      "photo_contribution_id" => id,
      "latitude" => location&.lat,
      "longitude" => location&.lon,
      "heading" => heading,
      "suggested_boulder_id" => boulder_id
    }.compact
  end

  # Uploads come from anonymous visitors, so only accept bounded, real image types.
  def photo_is_a_reasonable_image
    return unless photo.attached?

    errors.add(:photo, "must be a JPEG, PNG or WebP image") unless CONTENT_TYPES.include?(photo.content_type)
    errors.add(:photo, "must be under #{MAX_SIZE / 1.megabyte} MB") if photo.byte_size > MAX_SIZE
  end
end
