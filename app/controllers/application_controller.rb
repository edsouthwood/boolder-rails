class ApplicationController < ActionController::Base
  around_action :switch_locale

  rescue_from ActiveRecord::RecordNotFound, with: :render_404

  def default_url_options
    { locale: I18n.locale }
  end

  def switch_locale(&action)
    # Unscoped routes (e.g. /search) take ?locale= unconstrained; ignore unknown values.
    locale = params[:locale].presence_in(I18n.available_locales.map(&:to_s)) || I18n.default_locale
    I18n.with_locale(locale, &action)
  end

  # Admin logins (HTTP basic, remembered in the session) last this long, then ask again
  ADMIN_SESSION_LIFETIME = 14.days

  helper_method :admin_session?

  private

  # Signed in to admin within the last ADMIN_SESSION_LIFETIME. Public pages use this to
  # show admin-only extras (edit links, unpublished search results).
  def admin_session?
    return @admin_session if defined?(@admin_session)

    @admin_session = session[:admin_user_name].present? &&
      session[:admin_signed_in_at].to_i > ADMIN_SESSION_LIFETIME.ago.to_i &&
      (session[:admin_account_id].nil? ||
        AdminAccount.enabled.exists?(id: session[:admin_account_id], session_version: session[:admin_session_version].to_i))
  end

  # Pages of an unpublished area (and its problems) are for signed-in admins only;
  # everyone else gets a plain 404, as if it didn't exist. Returns true when it rendered.
  def hide_unpublished_area(area)
    return false if area.nil? || area.published || admin_session?

    render_404
    true
  end

  def end_admin_session
    @admin_session = false
    %i[admin_user_name admin_signed_in_at admin_account_id admin_session_version].each { |key| session.delete(key) }
  end

  def render_404
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end
end
