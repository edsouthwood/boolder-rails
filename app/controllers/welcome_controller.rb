class WelcomeController < ApplicationController
  include CountsPageViews
  count_page_views :home, only: :index

  layout false, only: [ :soon ]

  def index
    # see https://guides.rubyonrails.org/caching_with_rails.html#avoid-caching-instances-of-active-record-objects
    @popular_areas_ids = Area.published.any_tags(:popular).pluck(:id)
    @problem_count = Problem.shown.with_location.joins(:area).where(areas: { published: true }).count
    @area_count = Area.published.count
    # For the home page's "Saved for offline" list to flag areas that changed since saving.
    published = Area.published.to_a
    versions = Area.offline_versions(published)
    @offline_versions = published.to_h { |area| [ area.slug, versions[area.id] ] }
  end


  def problem_permalink
    problem = Problem.find(params[:id])
    return if hide_unpublished_area(problem.area)

    redirect_to helpers.problem_friendly_path(problem)
  end
end
