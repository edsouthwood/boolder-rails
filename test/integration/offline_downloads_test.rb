require "test_helper"

class OfflineDownloadsTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill-downloads-test", published: true)
    @area.problems.create!(steepness: "slab", location: RGeo::Geographic.spherical_factory(srid: 4326).point(-3.79, 50.58))
    @hidden = Area.create!(name: "Hidden", slug: "hidden-downloads-test", published: false)
  end

  test "downloads page lists published areas with their offline version" do
    get downloads_path(locale: :en)
    assert_response :success

    areas = JSON.parse(css_select("[data-controller=offline-downloads]").first["data-offline-downloads-areas-value"])
    area = areas.find { |a| a["slug"] == @area.slug }
    assert_equal @area.offline_version, area["version"]
    assert_equal 1, area["problemCount"]
    assert_equal area_offline_data_path(@area, locale: :en), area["dataUrl"]
    assert_equal area_path(@area, locale: :en), area["areaUrl"]
    assert_nil areas.find { |a| a["slug"] == @hidden.slug }, "unpublished areas aren't offered"
  end

  test "offline data includes the version and area page used to detect updates" do
    get area_offline_data_path(@area, locale: :en)
    data = response.parsed_body

    assert_equal @area.offline_version, data["version"]
    assert_equal area_path(@area, locale: :en), data["area_url"]
  end

  test "area page and home page carry current versions" do
    get area_path(@area, locale: :en)
    assert_select "[data-offline-download-version-value=?]", @area.offline_version

    get root_localized_path(locale: :en)
    versions = JSON.parse(css_select("[data-controller=saved-areas]").first["data-saved-areas-versions-value"])
    assert_equal @area.offline_version, versions[@area.slug]
  end
end
