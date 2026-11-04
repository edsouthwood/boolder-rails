class Admin::BaseController < ApplicationController
  default_form_builder DefaultFormBuilder
  layout "admin"
  before_action :authenticate
  helper_method :current_admin_user

  # Wrong passwords allowed per IP before logins are refused for the rest of the window.
  MAX_LOGIN_FAILURES = 10
  LOGIN_FAILURE_WINDOW = 15.minutes

  private

  def authenticate
    return true if admin_session? && signed_in_account_valid?

    end_admin_session # expired, or the account was removed
    return head(:too_many_requests) if login_failures >= MAX_LOGIN_FAILURES

    # Just signed out: browsers re-send saved basic-auth details by themselves, so
    # ignore them once and ask afresh (a 401 also makes the browser forget them)
    return request_http_basic_authentication("admin") if session.delete(:admin_signed_out)

    authenticate_or_request_with_http_basic("admin") do |id, password|
      username, account = verify_login(id, password)
      if username
        reset_session # a fresh session id on login
        session[:admin_user_name] = username
        session[:admin_signed_in_at] = Time.current.to_i
        if account
          session[:admin_account_id] = account.id
          session[:admin_session_version] = account.session_version
          account.update_column(:last_signed_in_at, Time.current)
        end
        true
      else
        record_login_failure
        false
      end
    end
  end

  # Logins come from Admin → Accounts (AdminAccount) once there's an enabled super admin
  # there. Until then, and as a way back in if the database accounts are ever unusable,
  # the admin_accounts credentials list (or ADMIN_USERNAME / ADMIN_PASSWORD) is used.
  def database_accounts?
    return @database_accounts if defined?(@database_accounts)

    @database_accounts = AdminAccount.any_super_admin?
  end

  # [username, account (nil for a credentials login)] when the password is right
  def verify_login(id, password)
    if database_accounts?
      account = AdminAccount.enabled.authenticate_by(username: id.to_s, password: password.to_s)
      [ account.username, account ] if account
    else
      raw = accounts[id.to_s]
      expected = raw.is_a?(String) ? raw : raw&.with_indifferent_access&.dig(:password)
      [ id.to_s, nil ] if expected.present? && ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected)
    end
  end

  # The signed-in account still exists, is enabled and hasn't been signed out everywhere
  # (password changed or reset); a credentials login only while credentials are in use
  def signed_in_account_valid?
    if session[:admin_account_id]
      current_account.present?
    else
      !database_accounts? && accounts[session[:admin_user_name]].present?
    end
  end

  def login_failure_key
    "admin_login_failures/#{request.remote_ip}"
  end

  def login_failures
    Rails.cache.read(login_failure_key, raw: true).to_i
  end

  def record_login_failure
    Rails.cache.increment(login_failure_key, 1, expires_in: LOGIN_FAILURE_WINDOW)
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
    return @current_admin_user ||= current_account.to_admin_user if current_account

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

  helper_method :current_account

  # The signed-in AdminAccount (nil for a credentials login)
  def current_account
    return @current_account if defined?(@current_account)

    @current_account = session[:admin_account_id] &&
      AdminAccount.enabled.find_by(id: session[:admin_account_id], session_version: session[:admin_session_version].to_i)
  end

  # Re-entering your own password before changing accounts
  def own_password_correct?(password)
    if current_account
      current_account.authenticate(password.to_s).present?
    else
      verify_login(session[:admin_user_name], password).present?
    end
  end

  # used by audited gem (see config/initializers/audited.rb)
  def authenticated_user
    session[:admin_user_name]
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
