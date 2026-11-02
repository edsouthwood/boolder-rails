require "test_helper"

# Hidden problems are kept for later but left off the public site (a 404 for their page)
# and the admin to-do lists, until an admin shows them again.
class HiddenProblemsTest < ActionDispatch::IntegrationTest
  POINTS = [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ].freeze

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "admin" => "correct-password" }
    end
    Rails.cache.clear

    @area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    @boulder = @area.boulders.create!(name: "Photo Arête")
    @kept = @area.problems.create!(name: "Photo Wall", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8, boulder: @boulder)
    @junk = @area.problems.create!(name: "Dirty Crack", grade: "5", steepness: "wall", lat: 50.6, lon: -3.8, boulder: @boulder, hidden: true)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def sign_in_admin
    get admin_docs_url(locale: :en),
        headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "correct-password") }
    assert_response :success
  end

  def problem_page(problem) = area_problem_path(@area.slug, problem, locale: :en)

  test "a hidden problem's page is a 404 to the public but open to admins, with a notice" do
    get problem_page(@junk)
    assert_response :not_found

    sign_in_admin
    get problem_page(@junk)
    assert_response :success
    assert_select "p", text: /This problem is hidden/
  end

  test "hidden problems are left off the map data, area pages, grade list and search" do
    get map_data_url(locale: :en, format: :geojson)
    names = JSON.parse(response.body)["features"].filter_map { |f| f.dig("properties", "name") }
    assert_includes names, "Photo Wall"
    assert_not_includes names, "Dirty Crack"

    get area_problems_path(@area.slug, locale: :en)
    assert_match "Photo Wall", response.body
    assert_no_match "Dirty Crack", response.body

    get problems_path(locale: :en, grade: "5")
    assert_no_match "Dirty Crack", response.body

    get search_path(locale: :en, query: "Dirty Crack", format: :json)
    assert_no_match "Dirty Crack", response.body
  end

  test "a hidden problem's line isn't drawn on other problems' photos" do
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    kept_line = Line.create!(problem: @kept, topo: topo, coordinates: POINTS)
    Line.create!(problem: @junk, topo: topo, coordinates: POINTS)

    assert_equal [], kept_line.secondary_lines
  end

  test "the Boulders list counts only shown problems, lists hidden ones, and can hide and show them" do
    sign_in_admin
    get admin_area_boulders_path(area_slug: "belltor", locale: :en, show: "all")

    row = BoulderProgress.new(@area).rows.first
    assert_equal [ @kept ], row.problems
    assert_equal [ @junk ], row.hidden
    assert_select "summary", text: /\(1 hidden\)/
    assert_select "a.line-through", text: "Dirty Crack"

    patch visibility_admin_problem_path(@kept, locale: :en),
      params: { hidden: "1", return_to: admin_area_boulders_path(area_slug: "belltor", open: @boulder.id, locale: :en) }
    assert_redirected_to admin_area_boulders_path(area_slug: "belltor", open: @boulder.id, locale: :en)
    assert @kept.reload.hidden

    patch visibility_admin_problem_path(@junk, locale: :en), params: { hidden: "0", return_to: "https://evil.example/" }
    assert_redirected_to admin_problem_path(@junk, locale: :en)
    assert_not @junk.reload.hidden
  end

  test "the workbench doesn't offer hidden problems" do
    sign_in_admin
    topo = Topo.new(area: @area)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!

    get workbench_admin_topo_path(topo, locale: :en)
    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "Photo Wall" ], candidates.map { |c| c["name"] }
  end
end
