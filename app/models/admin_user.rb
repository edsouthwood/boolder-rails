class AdminUser
  attr_reader :username

  def initialize(username:, role:, areas: [])
    @username = username.to_s
    @role     = role.to_s
    @areas    = Array(areas).map(&:to_s)
  end

  def super_admin?
    @role == "super_admin"
  end

  def can_access_area?(slug)
    super_admin? || @areas.include?(slug.to_s)
  end

  # Returns nil for super_admin (no filter), or the list of area slugs for area_admin
  def accessible_area_slugs
    super_admin? ? nil : @areas
  end

  # Build from the raw credentials value for this username.
  # `raw` is either a String (legacy format) or a Hash with string/symbol keys.
  def self.from_credentials(username, raw)
    if raw.is_a?(String)
      new(username: username, role: "super_admin")
    else
      cfg = raw.with_indifferent_access
      new(
        username: username,
        role:     cfg.fetch(:role, "area_admin"),
        areas:    cfg.fetch(:areas, [])
      )
    end
  end
end
