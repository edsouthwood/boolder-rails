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

  private

  def render_404
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end
end
