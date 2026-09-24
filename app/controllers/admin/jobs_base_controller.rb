# Base controller for the Mission Control jobs dashboard mounted at /jobs
# (see config/initializers/mission_control.rb): reuses the admin login and
# restricts the dashboard to super admins.
class Admin::JobsBaseController < Admin::BaseController
  before_action :require_super_admin

  private

  # The admin redirect helpers aren't available inside the engine.
  def require_super_admin
    head :forbidden unless current_admin_user.super_admin?
  end
end
