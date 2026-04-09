class MapDataController < ApplicationController
  def index
    factory = RGeo::GeoJSON::EntityFactory.instance

    problem_features = Problem.with_location.joins(:area).where(areas: { published: true }).map do |problem|
      hash = {
        id: problem.id,
        name: problem.name_with_fallback,
        grade: problem.grade,
        steepness: problem.steepness,
        circuitColor: problem.circuit&.color,
        circuitNumber: problem.circuit_number_simplified,
        circuitId: problem.circuit_id_simplified,
      }.with_indifferent_access.deep_transform_keys { |key| key.camelize(:lower) }

      factory.feature(problem.location, problem.id, hash)
    end

    boulder_features = Boulder.joins(:area).where(areas: { published: true }).map do |boulder|
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
