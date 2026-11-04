# An admin login (Admin → Accounts). Super admins can do everything; area admins only
# work on their listed areas. Changing the password or disabling the account signs it
# out everywhere (session_version).
class AdminAccount < ApplicationRecord
  ROLES = %w[super_admin area_admin].freeze
  MIN_PASSWORD_LENGTH = 12

  has_secure_password
  audited except: [ :password_digest, :last_signed_in_at ]

  normalizes :username, with: ->(name) { name.to_s.strip.downcase }
  normalizes :area_slugs, with: ->(slugs) { Array(slugs).compact_blank.map(&:to_s).uniq.sort }

  validates :username, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9._-]{2,40}\z/, message: "can only use letters, numbers, dots, dashes and underscores (2–40)" }
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: MIN_PASSWORD_LENGTH }, allow_nil: true
  validate :area_admin_has_areas
  validate :keeps_a_super_admin, on: :update

  # A new password or disabling ends every existing login (one callback: Rails keeps only
  # the last of several registrations of the same method)
  before_save :sign_out_everywhere, if: -> {
    (persisted? && will_save_change_to_password_digest?) || (will_save_change_to_disabled_at? && disabled_at.present?)
  }
  before_destroy :only_disabled

  scope :enabled, -> { where(disabled_at: nil) }
  scope :super_admins, -> { where(role: "super_admin") }

  def self.any_super_admin? = enabled.super_admins.exists?

  def super_admin? = role == "super_admin"
  def enabled? = disabled_at.nil?

  def disabled=(value)
    self.disabled_at = ActiveModel::Type::Boolean.new.cast(value) ? (disabled_at || Time.current) : nil
  end

  def disabled = disabled_at.present?

  # What the rest of the admin works with (permissions)
  def to_admin_user = AdminUser.new(username: username, role: role, areas: area_slugs)

  def last_super_admin?
    AdminAccount.enabled.super_admins.where.not(id: id).none?
  end

  def self.generate_password = SecureRandom.alphanumeric(16)

  private

  def sign_out_everywhere
    self.session_version += 1
  end

  def area_admin_has_areas
    return if super_admin?

    errors.add(:area_slugs, "must include at least one area for an area admin") if area_slugs.empty?
    unknown = area_slugs - Area.where(slug: area_slugs).pluck(:slug)
    errors.add(:area_slugs, "include unknown areas: #{unknown.join(", ")}") if unknown.any?
  end

  # There must always be an enabled super admin
  def keeps_a_super_admin
    was_active_super = role_was == "super_admin" && disabled_at_was.nil?
    return unless was_active_super && (!super_admin? || !enabled?)

    errors.add(:base, "#{username} is the only super admin left: make someone else a super admin first") if last_super_admin?
  end

  def only_disabled
    return if disabled_at_was.present?

    errors.add(:base, "Disable an account before deleting it")
    throw :abort
  end
end
