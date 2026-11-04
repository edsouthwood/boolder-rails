class Admin::StatsController < Admin::BaseController
  before_action :require_super_admin

  def show
    @stats = AdminStats.new(days: params[:days])
  end
end
