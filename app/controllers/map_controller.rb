class MapController < ApplicationController
  layout "map"

  def index
    if params[:slug] && (area = Area.find_by(slug: params[:slug]))
      @area = area # FIXME: don't forget to refactor _map_nav when changing this
      # serialized_bounds falls back to the default Dartmoor view for an area with
      # nothing mapped yet, which otherwise has no bounds at all
      bounds = area.serialized_bounds
      @bounds = {
        southWestLat: bounds[:south_west][:lat],
        southWestLon: bounds[:south_west][:lng],
        northEastLat: bounds[:north_east][:lat],
        northEastLon: bounds[:north_east][:lng]
      }.with_indifferent_access
    end

    if params[:pid] && (problem = Problem.find(params[:pid]))
      location = if params[:contribute]
        problem.contribution_requests.first&.location_estimated
      else
        problem.location
      end

      return unless location.present?

      @problem = {
        id: problem.id, # FIXME: don't forget to refactor _map_nav when changing this
        lat: location.lat,
        lon: location.lon,
        name: problem.name_with_fallback,
        grade: problem.grade,
        path: helpers.problem_friendly_path(problem)
      }.
      with_indifferent_access.deep_transform_keys { |key| key.camelize(:lower) }
    end
  end
end
