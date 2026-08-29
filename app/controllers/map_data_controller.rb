class MapDataController < ApplicationController
  def index
    factory = RGeo::GeoJSON::EntityFactory.instance

    problems = Problem.with_location.joins(:area).includes(:area).where(areas: { published: true })
    boulders = Boulder.joins(:area).where(areas: { published: true })

    # Optionally scope to a single area (used by the contribution location picker) to keep
    # the payload small.
    if params[:area_id].present?
      problems = problems.where(area_id: params[:area_id])
      boulders = boulders.where(area_id: params[:area_id])
    end

    problem_features = problems.map do |problem|
      # Circuit fields are dropped when the problem has no circuit rather than sent
      # as null. MapLibre's ["has", ...] is true for a key that *exists* with a null
      # value, so emitting nulls put every problem down the circuit branches of the
      # `problems` layer: max-zoom dot radius 16 instead of 10, circuit sort order,
      # and an empty text label drawn per problem from zoom 19. Dartmoor runs without
      # circuits, but these still populate if circuits are ever added back.
      circuit = {
        circuitColor: problem.circuit&.color,
        circuitNumber: problem.circuit_number_simplified,
        circuitId: problem.circuit_id_simplified
      }.compact

      hash = {
        id: problem.id,
        name: problem.name_with_fallback,
        grade: problem.grade,
        steepness: problem.steepness,
        **circuit,
        # Canonical problem page URL — lets the map link directly (no redirect hop) so the
        # page works offline from the pre-downloaded cache.
        path: helpers.problem_friendly_path(problem)
      }.with_indifferent_access.deep_transform_keys { |key| key.camelize(:lower) }

      factory.feature(problem.location, problem.id, hash)
    end

    boulder_features = boulders.map do |boulder|
      factory.feature(boulder.polygon, boulder.id, { boulderId: boulder.id })
    end

    feature_collection = factory.feature_collection(problem_features + boulder_features)

    respond_to do |format|
      format.geojson do
        render json: RGeo::GeoJSON.encode(feature_collection).to_json
      end
    end
  end
end
