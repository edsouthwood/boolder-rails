class Admin::AuditsController < Admin::BaseController
  # The log spans every area (and includes contributor details), so it's super admin only.
  before_action :require_super_admin

  PER_PAGE = 100
  # The "Who" filter value for changes with no admin name: visitors' contributions,
  # background jobs and scripts.
  NO_NAME = "none".freeze

  def index
    @usernames = Audited::Audit.where.not(username: [ nil, "" ]).distinct.order(:username).pluck(:username)
    @types = Audited::Audit.distinct.order(:auditable_type).pluck(:auditable_type)
    @user = params[:user].presence
    @type = params[:type].presence

    audits = Audited::Audit.order(id: :desc)
    audits = audits.where(username: @user == NO_NAME ? [ nil, "" ] : @user) if @user
    audits = audits.where(auditable_type: @type) if @type
    @audits = audits.page(params[:page]).per(PER_PAGE)
  end
end
