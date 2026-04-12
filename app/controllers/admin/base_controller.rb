class Admin::BaseController < ApplicationController
  default_form_builder DefaultFormBuilder
  layout "admin"
  before_action :authenticate
  before_action :set_cookie
  helper_method :current_admin_user

  private

  def authenticate
    authenticate_or_request_with_http_basic("admin") do |id, password|
      account = accounts[id.to_s]
      if account
        session[:admin_user_name] = id
        expected = account.is_a?(String) ? account : account.with_indifferent_access[:password]
        password == expected
      end
    end
  end

  def accounts
    cred_accounts = Rails.application.credentials.admin_accounts
    if cred_accounts.present?
      # Use transform_keys (not stringify_keys) so hash values are preserved as-is
      cred_accounts.transform_keys(&:to_s)
    else
      { ENV["ADMIN_USERNAME"] => ENV["ADMIN_PASSWORD"] }.compact
    end
  end

  def current_admin_user
    @current_admin_user ||= begin
      username = session[:admin_user_name]
      raw = accounts[username.to_s]
      if raw
        AdminUser.from_credentials(username, raw)
      else
        # ENV-var fallback: already authenticated, treat as super_admin
        AdminUser.new(username: username.to_s, role: "super_admin")
      end
    end
  end

  # used by audited gem (see config/initializers/audited.rb)
  def authenticated_user
    session[:admin_user_name]
  end

  def set_cookie
    session[:admin] = true
  end

  def require_super_admin
    unless current_admin_user.super_admin?
      flash[:error] = "You do not have permission to perform this action."
      redirect_to admin_root_path
    end
  end

  def require_area_access(area_slug)
    unless current_admin_user.can_access_area?(area_slug)
      flash[:error] = "You do not have permission to access this area."
      redirect_to admin_root_path
    end
  end
end
