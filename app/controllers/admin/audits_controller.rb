class Admin::AuditsController < Admin::BaseController
  # The log spans every area (and includes contributor details), so it's super admin only.
  before_action :require_super_admin

  def index
    @audits = Audited::Audit.all.order(id: :desc).limit(200)
  end
end
