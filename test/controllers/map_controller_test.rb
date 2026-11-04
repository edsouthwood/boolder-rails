require "test_helper"

class MapControllerTest < ActionDispatch::IntegrationTest
  test "an area with nothing mapped yet opens the map at the default view" do
    Area.create!(name: "Empty Tor", slug: "empty-tor", published: true)

    get "/map/empty-tor"

    assert_response :success
    assert_match "southWestLat", response.body
  end

  test "the grade filter knows which stored grades each display grade covers" do
    get "/map"

    assert_response :success
    groups = JSON.parse(css_select("[data-controller=mapbox]").first["data-mapbox-grade-groups-value"])
    assert_equal [ "4", %w[4 4a 4a+ 4b] ], groups.assoc("4")
    assert_select "select#gradeMin option[selected]", "4"
  end
end
