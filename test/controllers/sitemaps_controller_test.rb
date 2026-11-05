require "test_helper"

class SitemapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    @hidden_area = Area.create!(name: "Secret Tor", slug: "secret", published: false)
    @shown = @area.problems.create!(name: "Wall", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8)
    @hidden = @area.problems.create!(name: "Junk", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8, hidden: true)
    @unlocated = @area.problems.create!(name: "Somewhere", grade: "4", steepness: "wall")
    @secret = @hidden_area.problems.create!(name: "Secret", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8)
  end

  def locs = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").map(&:text)

  test "lists the public pages, built live from the database" do
    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes locs, "http://www.example.com/"
    assert_includes locs, "http://www.example.com/map"
    assert_includes locs, "http://www.example.com/dartmoor/belltor"
    assert_includes locs, "http://www.example.com/dartmoor/belltor/problems"
    assert_includes locs, "http://www.example.com#{area_problem_path(@area, @shown)}"
    assert_equal locs.uniq, locs, "no address twice"
    assert_match "<lastmod>#{@shown.updated_at.to_date.iso8601}</lastmod>", response.body
    assert_match "max-age=3600", response.headers["Cache-Control"]
  end

  test "leaves out hidden and unlocated problems and unpublished areas" do
    get "/sitemap.xml"

    assert locs.none? { |l| l.include?("secret") }
    assert_not_includes locs, "http://www.example.com#{area_problem_path(@area, @hidden)}"
    assert_not_includes locs, "http://www.example.com#{area_problem_path(@area, @unlocated)}"
  end

  test "a new problem shows up straight away" do
    get "/sitemap.xml"
    added = @area.problems.create!(name: "Fresh", grade: "5", steepness: "wall", lat: 50.6, lon: -3.8)
    get "/sitemap.xml"
    assert_includes locs, "http://www.example.com#{area_problem_path(@area, added)}"
  end

  test "area pages name their preferred address" do
    get "/dartmoor/belltor"
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/dartmoor/belltor"
    get "/dartmoor/belltor/problems"
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/dartmoor/belltor/problems"
  end
end
