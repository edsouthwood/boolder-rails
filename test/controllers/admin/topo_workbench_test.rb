require "test_helper"

class Admin::TopoWorkbenchTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  POINTS = [ { "x" => 0.5, "y" => 0.9 }, { "x" => 0.5, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ]

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    Admin::BaseController.define_method(:current_admin_user) { AREA_ADMIN }

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @boulder = @mine.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    # Taken ~20 m south of the boulder, facing it
    @topo = topo(@mine, "latitude" => 50.5998, "longitude" => -3.9, "suggested_boulder_id" => @boulder.id)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def topo(area, metadata = {})
    t = Topo.new(area: area, metadata: metadata)
    t.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    t.save!
    t
  end

  test "workbench lists the photo's lines and the area's other problems, those on the boulder first" do
    drawn = @mine.problems.create!(name: "Drawn", steepness: "wall")
    Line.create!(problem: drawn, topo: @topo, coordinates: POINTS)
    @mine.problems.create!(name: "Aardvark", steepness: "wall")
    @mine.problems.create!(name: "Zebra", steepness: "wall", lat: 50.6, lon: -3.9001)
    next_topo = topo(@mine)

    get workbench_admin_topo_path(@topo, locale: :en)
    assert_response :success

    lines = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-lines-value"])
    assert_equal [ "Drawn" ], lines.map { |l| l["name"] }
    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "Zebra", "Aardvark" ], candidates.map { |c| c["name"] }
    assert_select "a[href=?]", workbench_admin_topo_path(next_topo, locale: :en), text: /Next photo/
  end

  test "problems a list put on the photo's boulder come first, even without a location" do
    @boulder.update!(name: "Photo Arête")
    @mine.problems.create!(name: "Aardvark", steepness: "wall")
    @mine.problems.create!(name: "Zebra", steepness: "wall", lat: 50.6, lon: -3.90014) # ~3 m off the outline
    @mine.problems.create!(name: "Listed", steepness: "wall", boulder: @boulder)

    get workbench_admin_topo_path(@topo, locale: :en)

    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "Listed", "Zebra", "Aardvark" ], candidates.map { |c| c["name"] }
    assert_equal [ true, true, false ], candidates.map { |c| c["near"] }
    assert_select "a", text: "Photo Arête"
  end

  test "an unnamed boulder offers a link to name it" do
    get workbench_admin_topo_path(@topo, locale: :en)
    assert_select "a[href=?]", admin_area_boulder_editor_path(area_slug: "mine", boulder: @boulder.id, locale: :en), text: "name it"
  end

  test "drawing a listed problem with no location places it on the photo's boulder" do
    listed = @mine.problems.create!(name: "Listed", steepness: "wall", boulder: @boulder)
    elsewhere = @mine.boulders.create!(name: "Elsewhere")
    other = @mine.problems.create!(name: "Other", steepness: "wall", boulder: elsewhere)

    post admin_lines_path(locale: :en), params: { line: { problem_id: listed.id, topo_id: @topo.id } }, as: :json
    post admin_lines_path(locale: :en), params: { line: { problem_id: other.id, topo_id: @topo.id } }, as: :json

    assert_in_delta 50.5999, listed.reload.lat, 1e-6
    assert_nil other.reload.location, "a problem listed on another boulder isn't moved onto this one"
  end

  test "the workbench links back to the area's topos" do
    get workbench_admin_topo_path(@topo, locale: :en)

    assert_select "a[href=?]", admin_area_topos_path(area_slug: "mine", locale: :en), text: "← Topos at Mine"
    assert_select "a[href=?]", admin_area_topos_path(area_slug: "mine", undrawn: 1, locale: :en), text: "Photos to draw"
  end

  test "area admins can't open another area's photo" do
    get workbench_admin_topo_path(topo(@theirs), locale: :en)
    assert_redirected_to admin_root_path(locale: :en)
  end

  test "quick problem creates a problem on the boulder and a line for it on the photo" do
    assert_difference -> { @mine.problems.count } do
      post quick_problem_admin_topo_path(@topo, locale: :en), params: { name: "New one", grade: "6a" }, as: :json
    end
    assert_response :created

    problem = @mine.problems.find_by!(name: "New one")
    assert_equal "6a", problem.grade
    assert_equal [ @topo.id ], problem.lines.map(&:topo_id)
    assert_equal problem.lines.first.id, response.parsed_body["id"]
    # Snapped to the south edge of the boulder, so it counts as on it
    assert_in_delta 50.5999, problem.lat, 1e-6
    assert_in_delta(-3.9, problem.lon, 1e-6)
    assert Boulder.containing(problem.location).exists?(@boulder.id)
    assert_equal @boulder, problem.boulder
  end

  test "quick problem without GPS leaves the location for the location editor" do
    post quick_problem_admin_topo_path(topo(@mine), locale: :en), params: { name: "Somewhere" }, as: :json
    assert_response :created
    assert_nil @mine.problems.find_by!(name: "Somewhere").location
  end

  test "quick problem validation errors come back as JSON" do
    post quick_problem_admin_topo_path(@topo, locale: :en), params: { name: "Bad", grade: "11z" }, as: :json
    assert_response :unprocessable_entity
    assert_match "Grade", response.parsed_body["error"]
  end

  test "lines can be added, drawn and removed over JSON" do
    problem = @mine.problems.create!(name: "Arete", steepness: "wall")

    post admin_lines_path(locale: :en), params: { line: { problem_id: problem.id, topo_id: @topo.id } }, as: :json
    assert_response :created
    line = Line.find(response.parsed_body["id"])

    patch admin_line_path(line, locale: :en), params: { line: { coordinates: POINTS.to_json, start_holds: "", excluded_areas: "" } }, as: :json
    assert_response :success
    assert_equal POINTS, line.reload.coordinates
    assert_equal POINTS, response.parsed_body["coordinates"]
    assert problem.reload.has_line

    patch admin_line_path(line, locale: :en), params: { line: { coordinates: POINTS.first(2).to_json } }, as: :json
    assert_response :unprocessable_entity
    assert_match "at least 3 points", response.parsed_body["error"]

    patch admin_line_path(line, locale: :en), params: { line: { coordinates: "{oops" } }, as: :json
    assert_response :unprocessable_entity

    delete admin_line_path(line, locale: :en), as: :json
    assert_response :no_content
    assert_not Line.exists?(line.id)
  end

  test "a line can't put your problem on another area's photo" do
    problem = @mine.problems.create!(name: "Arete", steepness: "wall")
    assert_no_difference -> { Line.count } do
      post admin_lines_path(locale: :en), params: { line: { problem_id: problem.id, topo_id: topo(@theirs).id } }, as: :json
    end
    assert_redirected_to admin_root_path(locale: :en)
  end

  test "a photo with no area sends you to its edit page" do
    orphan = topo(nil)
    Admin::BaseController.define_method(:current_admin_user) { AdminUser.new(username: "boss", role: "super_admin") }
    get workbench_admin_topo_path(orphan, locale: :en)
    assert_redirected_to edit_admin_topo_path(orphan, locale: :en)
  end
end
