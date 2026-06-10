require "test_helper"

class MapDataControllerTest < ActionDispatch::IntegrationTest
  def square(lon, lat)
    f = RGeo::Geographic.spherical_factory(srid: 4326)
    f.polygon(f.linear_ring([
      f.point(lon, lat), f.point(lon, lat + 0.001),
      f.point(lon + 0.001, lat + 0.001), f.point(lon + 0.001, lat), f.point(lon, lat)
    ]))
  end

  setup do
    @area_a = Area.create!(name: "A", slug: "map-data-a", published: true)
    @area_b = Area.create!(name: "B", slug: "map-data-b", published: true)
    @boulder_a = @area_a.boulders.create!(polygon: square(-4.0, 50.5))
    @boulder_b = @area_b.boulders.create!(polygon: square(-3.8, 50.6))
  end

  test "scopes boulders to the requested area" do
    get map_data_url(locale: :en, format: :geojson, area_id: @area_a.id)
    assert_response :success

    boulder_ids = JSON.parse(response.body)["features"]
      .select { |f| f.dig("geometry", "type") == "Polygon" }
      .map { |f| f.dig("properties", "boulderId") }

    assert_includes boulder_ids, @boulder_a.id
    assert_not_includes boulder_ids, @boulder_b.id
  end

  test "returns all published areas when no area_id is given" do
    get map_data_url(locale: :en, format: :geojson)
    assert_response :success

    boulder_ids = JSON.parse(response.body)["features"]
      .select { |f| f.dig("geometry", "type") == "Polygon" }
      .map { |f| f.dig("properties", "boulderId") }

    assert_includes boulder_ids, @boulder_a.id
    assert_includes boulder_ids, @boulder_b.id
  end
end
