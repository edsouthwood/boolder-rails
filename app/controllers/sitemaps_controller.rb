# /sitemap.xml for search engines, built from the database so it always lists the current
# public pages: published areas, their shown and located problems, and circuits.
class SitemapsController < ApplicationController
  def show
    areas = Area.published.order(:id)
    problems = Problem.shown.with_location.joins(:area).merge(Area.published).includes(:area).order(:id)
    circuits = Circuit.joins(problems: :area).merge(Area.published).distinct.order(:id)

    # Crawlers fetch it rarely; an hour's cache spares the database on repeat fetches
    expires_in 1.hour, public: true
    key = [ "sitemap", request.base_url, areas.maximum(:updated_at), problems.maximum(:updated_at), problems.count, circuits.count ]
    xml = Rails.cache.fetch(key, expires_in: 1.day) do
      render_to_string(:show, formats: :xml, locals: { areas: areas, problems: problems, circuits: circuits })
    end
    render xml: xml
  end
end
