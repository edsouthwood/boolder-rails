class AreaLabelsController < ApplicationController
  def index
    factory = RGeo::GeoJSON::EntityFactory.instance

    features = Area.published.filter_map do |area|
      b = area.bounds
      next if b[:south_west].lon.nil? || b[:north_east].lon.nil?

      center = FACTORY.point(
        (b[:south_west].lon + b[:north_east].lon) / 2.0,
        (b[:south_west].lat + b[:north_east].lat) / 2.0
      )

      factory.feature(center, area.id, {
        name:         area.name,
        southWestLon: b[:south_west].lon,
        southWestLat: b[:south_west].lat,
        northEastLon: b[:north_east].lon,
        northEastLat: b[:north_east].lat,
      })
    end

    feature_collection = factory.feature_collection(features)

    respond_to do |format|
      format.geojson do
        render json: RGeo::GeoJSON.encode(feature_collection).to_json
      end
    end
  end
end
