require "test_helper"

# The fields offline search (offline_areas.js searchOffline) and direct result links rely on.
class OfflineSearchDataTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Quartzite Tor", slug: "quartzite-tor", published: true)
    @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(
      [ [ -3.8, 50.5 ], [ -3.8, 50.501 ], [ -3.799, 50.501 ], [ -3.8, 50.5 ] ].map { |x, y| FACTORY.point(x, y) }
    )))
    @problem = @area.problems.create!(name: "Xylophone Crack", grade: "6a", steepness: "wall",
      location: RGeo::Geographic.spherical_factory(srid: 4326).point(-3.7995, 50.5005))
  end

  test "search results carry their page path" do
    get search_url(query: "Xylophone", locale: "en")
    problem = response.parsed_body.find { |r| r["type"] == "Problem" }
    assert_equal "/en/dartmoor/quartzite-tor/#{@problem.id}-xylophone-crack", problem["path"]

    get search_url(query: "Quartzite", locale: "en")
    area = response.parsed_body.find { |r| r["type"] == "Area" }
    assert_equal "/en/dartmoor/quartzite-tor", area["path"]
  end

  test "map data problems carry their area name" do
    get map_data_url(locale: :en, format: :geojson)
    feature = JSON.parse(response.body)["features"].find { |f| f.dig("properties", "id") == @problem.id }
    assert_equal "Quartzite Tor", feature.dig("properties", "areaName")
  end

  test "area labels carry the area page path" do
    get area_labels_url(locale: :en, format: :geojson)
    feature = JSON.parse(response.body)["features"].find { |f| f["id"] == @area.id }
    assert_equal "/en/dartmoor/quartzite-tor", feature.dig("properties", "path")
  end
end
