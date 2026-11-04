require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  test "the home page is at /" do
    get "/"
    assert_response :success
    assert_select "a[href='/map']"
  end

  test "old /en addresses redirect permanently to the same page without the prefix" do
    area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    {
      "/en" => "/",
      "/en/" => "/",
      "/en/dartmoor/belltor" => "/dartmoor/belltor",
      "/en/map/belltor?pid=12" => "/map/belltor?pid=12",
      "/en/admin/areas" => "/admin/areas",
      "/en/map-data.geojson" => "/map-data.geojson",
      "/fr/dartmoor" => "/dartmoor",
      "/fr" => "/"
    }.each do |old, new|
      get old
      assert_response :moved_permanently, old
      assert_equal "http://www.example.com#{new}", response.location, old
    end
    get "/dartmoor/belltor"
    assert_response :success
    assert area
  end

  test "links and canonical addresses have no language prefix" do
    get "/dartmoor"
    assert_select "a[href^='/en/']", count: 0
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/dartmoor"
  end

  # script/uptime_check.sh treats the site as down without this text; change both together.
  test "home page has the text the uptime check looks for" do
    get root_url
    assert_includes response.body, "Bouldering on Dartmoor"
  end

  test "footer credits Boolder and links to the About page thanks" do
    get root_url
    assert_select "footer a[href='https://www.boolder.com']", text: "Boolder"
    assert_select "footer a[href$='#thanks']", text: /original Boolder team/
  end

  test "about page has the thanks anchor the footer links to" do
    get about_url
    assert_select "section#thanks", text: /Thank you, Boolder/
  end
end
