require "test_helper"

class OpenDataControllerTest < ActionDispatch::IntegrationTest
  FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

  setup do
    @area = Area.create!(name: "Open Area", slug: "open-area", published: true)
    @hidden_area = Area.create!(name: "Hidden Area", slug: "hidden-area", published: false)
  end

  test "exports published located problems as CSV" do
    problem = @area.problems.create!(name: "The Nose, mini", grade: "6a", steepness: "wall",
      location: FACTORY.point(-3.9, 50.58))
    @area.problems.create!(name: "No location yet", steepness: "slab")
    @hidden_area.problems.create!(name: "Secret", steepness: "wall", location: FACTORY.point(-3.8, 50.5))

    get open_data_problems_path

    assert_response :success
    assert_match %r{\Atext/csv}, response.content_type

    rows = CSV.parse(response.body, headers: true)
    assert_equal %w[id name grade steepness latitude longitude area url], rows.headers
    assert_equal 1, rows.size

    row = rows.first
    assert_equal problem.id.to_s, row["id"]
    assert_equal "The Nose, mini", row["name"]
    assert_equal "6a", row["grade"]
    assert_equal "wall", row["steepness"]
    assert_in_delta 50.58, row["latitude"].to_f, 0.0001
    assert_in_delta(-3.9, row["longitude"].to_f, 0.0001)
    assert_equal "Open Area", row["area"]
    assert_match %r{/en/p/#{problem.id}\z}, row["url"]
  end

  test "returns just the header row when nothing is published" do
    get open_data_problems_path

    assert_response :success
    assert_equal "id,name,grade,steepness,latitude,longitude,area,url", response.body.strip
  end

  test "serves 304 to clients that already have the current version" do
    @area.problems.create!(steepness: "wall", location: FACTORY.point(-3.9, 50.58))

    get open_data_problems_path
    etag = response.headers["ETag"]
    assert etag.present?

    get open_data_problems_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end
end
