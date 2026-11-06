require "test_helper"

# "Hide boulder" sets a whole boulder aside (e.g. out of scope): its outline and every problem
# on it leave the public site, without touching each problem's own hidden flag.
class HiddenBouldersTest < ActionDispatch::IntegrationTest
  FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

  def square(lon, lat)
    FACTORY.polygon(FACTORY.linear_ring([
      FACTORY.point(lon, lat), FACTORY.point(lon, lat + 0.0001),
      FACTORY.point(lon + 0.0001, lat + 0.0001), FACTORY.point(lon + 0.0001, lat), FACTORY.point(lon, lat)
    ]))
  end

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "admin" => "correct-password" }
    end
    Rails.cache.clear

    @area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    @out = @area.boulders.create!(name: "Far Block", polygon: square(-3.80, 50.60))
    @in = @area.boulders.create!(name: "Main Wall", polygon: square(-3.81, 50.60))
    @far_problem = @area.problems.create!(name: "Out Of Scope Arete", grade: "5", steepness: "wall", lat: 50.60005, lon: -3.79995, boulder: @out)
    @far_junk = @area.problems.create!(name: "Already Hidden Crack", grade: "4", steepness: "wall", lat: 50.60005, lon: -3.79995, boulder: @out, hidden: true)
    @kept = @area.problems.create!(name: "Main Wall Classic", grade: "6a", steepness: "wall", lat: 50.60005, lon: -3.80995, boulder: @in)
    @loose = @area.problems.create!(name: "Boulderless Traverse", grade: "3", steepness: "wall", lat: 50.61, lon: -3.82)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def sign_in_admin
    get admin_docs_url,
        headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "correct-password") }
    assert_response :success
  end

  def public_map_data
    get map_data_url(format: :geojson)
    JSON.parse(response.body)["features"].map { |f| f["properties"] }
  end

  test "Problem.shown leaves out problems on hidden boulders but keeps ones on no boulder" do
    @out.update!(hidden: true)
    assert_equal [ @kept, @loose ].sort_by(&:id), @area.problems.shown.order(:id).to_a
    assert @far_problem.reload.hidden_from_public?
    assert_not @far_problem.hidden, "the problem's own flag is untouched"
  end

  test "a hidden boulder's outline and problems leave the public map, pages and search, and come back" do
    @out.update!(hidden: true)

    props = public_map_data
    assert_not_includes props.filter_map { |p| p["boulderId"] }, @out.id
    assert_includes props.filter_map { |p| p["boulderId"] }, @in.id
    assert_not_includes props.filter_map { |p| p["name"] }, "Out Of Scope Arete"

    get area_problems_path(@area.slug)
    assert_no_match "Out Of Scope Arete", response.body
    assert_match "Main Wall Classic", response.body

    get search_path(query: "Out Of Scope", format: :json)
    assert_no_match "Out Of Scope Arete", response.body

    get area_problem_path(@area.slug, @far_problem)
    assert_response :not_found

    @out.update!(hidden: false)
    assert_includes public_map_data.filter_map { |p| p["name"] }, "Out Of Scope Arete"
    assert_not_includes public_map_data.filter_map { |p| p["name"] }, "Already Hidden Crack",
      "a problem hidden on its own stays hidden when its boulder comes back"
  end

  test "admins can still open a hidden boulder's problem page, with a notice" do
    @out.update!(hidden: true)
    sign_in_admin
    get area_problem_path(@area.slug, @far_problem)
    assert_response :success
    assert_select "p", text: /boulder is hidden/

    get admin_problem_path(@far_problem)
    assert_match "Boulder hidden:", response.body
  end

  test "the Boulders list can hide a boulder, lists it apart, and shows it again" do
    sign_in_admin
    patch visibility_admin_boulder_path(@out), params: { hidden: "1", return_to: admin_area_boulders_path(area_slug: "belltor") }
    assert_redirected_to admin_area_boulders_path(area_slug: "belltor")
    assert @out.reload.hidden

    progress = BoulderProgress.new(@area)
    assert_equal [ @in ], progress.rows.map(&:boulder)
    assert_equal [ @out ], progress.hidden_boulders
    assert_equal 0, progress.hidden_count, "problems on a hidden boulder aren't counted as hidden problems"

    get admin_area_boulders_path(area_slug: "belltor", show: "all")
    assert_select "#hidden-boulders summary", text: /1 hidden boulder/
    assert_select "#hidden-boulders li", text: /Far Block.*2 problems/m

    patch visibility_admin_boulder_path(@out), params: { hidden: "0", return_to: "https://evil.example/" }
    assert_redirected_to admin_area_boulders_path(area_slug: "belltor")
    assert_not @out.reload.hidden
  end

  test "the boulder editor toggles visibility over JSON and gets the flag in its map data" do
    sign_in_admin
    patch visibility_admin_boulder_path(@out), params: { hidden: true }, as: :json
    assert_equal({ "ok" => true, "hidden" => true }, JSON.parse(response.body))

    get admin_map_url(area_id: @area.id, format: :geojson)
    flags = JSON.parse(response.body)["features"].filter_map { |f| [ f.dig("properties", "boulderId"), f.dig("properties", "hidden") ] if f.dig("properties", "boulderId") }.to_h
    assert_equal({ @out.id => true, @in.id => false }, flags)
  end

  test "mapping progress leaves out a hidden boulder's problems" do
    @kept.update_column(:has_line, true)
    completion = -> do
      get "/admin/mapping", params: { missing: "line" }
      controller.instance_variable_get(:@areas_with_stats).find { |row| row.area == @area }.completion
    end
    sign_in_admin

    assert_in_delta 1 / 3.0, completion.call # 1 of 3 shown problems has its line
    @out.update!(hidden: true)
    assert_in_delta 1 / 2.0, completion.call # the far block's problem no longer counts
  end

  test "hiding needs an admin" do
    patch visibility_admin_boulder_path(@out), params: { hidden: "1" }
    assert_response :unauthorized
    assert_not @out.reload.hidden
  end
end
