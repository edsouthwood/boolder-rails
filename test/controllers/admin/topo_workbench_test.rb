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

    get workbench_admin_topo_path(@topo)
    assert_response :success

    lines = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-lines-value"])
    assert_equal [ "Drawn" ], lines.map { |l| l["name"] }
    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "Zebra", "Aardvark" ], candidates.map { |c| c["name"] }
    assert_select "a[href=?]", workbench_admin_topo_path(next_topo), text: /Next photo/
  end

  test "problems a list put on the photo's boulder come first, even without a location" do
    @boulder.update!(name: "Photo Arête")
    @mine.problems.create!(name: "Aardvark", steepness: "wall")
    @mine.problems.create!(name: "Zebra", steepness: "wall", lat: 50.6, lon: -3.90014) # ~3 m off the outline
    @mine.problems.create!(name: "Listed", steepness: "wall", boulder: @boulder)

    get workbench_admin_topo_path(@topo)

    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "Listed", "Zebra", "Aardvark" ], candidates.map { |c| c["name"] }
    assert_equal [ true, true, false ], candidates.map { |c| c["near"] }
    assert_select "a", text: "Photo Arête"
  end

  test "an unnamed boulder offers a link to name it" do
    get workbench_admin_topo_path(@topo)
    assert_select "a[href=?]", admin_area_boulder_editor_path(area_slug: "mine", boulder: @boulder.id), text: "name it"
  end

  test "drawing a listed problem with no location places it on the photo's boulder" do
    listed = @mine.problems.create!(name: "Listed", steepness: "wall", boulder: @boulder)
    elsewhere = @mine.boulders.create!(name: "Elsewhere")
    other = @mine.problems.create!(name: "Other", steepness: "wall", boulder: elsewhere)

    post admin_lines_path, params: { line: { problem_id: listed.id, topo_id: @topo.id } }, as: :json
    post admin_lines_path, params: { line: { problem_id: other.id, topo_id: @topo.id } }, as: :json

    assert_in_delta 50.5999, listed.reload.lat, 1e-6
    assert_nil other.reload.location, "a problem listed on another boulder isn't moved onto this one"
  end

  test "with no boulder outline, a problem drawn on the photo takes the photo's GPS" do
    unmapped = topo(@mine, "latitude" => 50.61, "longitude" => -3.91)
    unplaced = @mine.boulders.create!(name: "Not On Map Yet")
    listed = @mine.problems.create!(name: "Listed", steepness: "wall", boulder: unplaced)
    plain = @mine.problems.create!(name: "Plain", steepness: "wall")

    post admin_lines_path, params: { line: { problem_id: listed.id, topo_id: unmapped.id } }, as: :json
    post admin_lines_path, params: { line: { problem_id: plain.id, topo_id: unmapped.id } }, as: :json

    assert_in_delta 50.61, listed.reload.lat, 1e-6
    assert_in_delta(-3.91, listed.lon, 1e-6)
    assert listed.location_estimated?
    # The second one is spread a little way off, not stacked on the first
    assert_operator unmapped.metres_between(listed.location, plain.reload.location), :>, 1
    assert_operator unmapped.metres_between(listed.location, plain.location), :<, 3
    assert plain.location_estimated?
  end

  test "problems added to a photo of a mapped boulder are spread along its outline" do
    problems = %w[One Two Three].map { |name| @mine.problems.create!(name: name, steepness: "wall") }
    problems.each do |problem|
      post admin_lines_path, params: { line: { problem_id: problem.id, topo_id: @topo.id } }, as: :json
    end

    locations = problems.map { |p| p.reload.location }
    assert_equal 3, locations.map(&:as_text).uniq.size
    locations.combination(2).each { |a, b| assert_operator @topo.metres_between(a, b), :>=, 1.5 }
    problems.each do |problem|
      assert Boulder.containing(problem.location).exists?(@boulder.id), "#{problem.name} stays on the boulder"
      assert_equal @boulder, problem.boulder
      assert problem.location_estimated?
    end
  end

  test "photos taken from the same spot don't stack their problems on one point" do
    first, second = 2.times.map { topo(@mine, "latitude" => 50.61, "longitude" => -3.91) }
    a = @mine.problems.create!(name: "A", steepness: "wall")
    b = @mine.problems.create!(name: "B", steepness: "wall")

    post admin_lines_path, params: { line: { problem_id: a.id, topo_id: first.id } }, as: :json
    post admin_lines_path, params: { line: { problem_id: b.id, topo_id: second.id } }, as: :json

    assert_operator first.metres_between(a.reload.location, b.reload.location), :>=, 1
    assert_operator first.metres_between(b.location, second.gps_location), :<, 3
  end

  test "on a photo with no GPS, a problem takes a spot next to one already placed on it" do
    no_gps = topo(@mine)
    @topo.choose_boulder!(nil)
    cracked = @mine.boulders.create!(name: "Cracked") # listed, not on the map
    no_gps.choose_boulder!(cracked)
    placed = @mine.problems.create!(name: "Placed", steepness: "wall", boulder: cracked, lat: 50.58, lon: -3.79)
    Line.create!(problem: placed, topo: no_gps, coordinates: POINTS)
    snatch = @mine.problems.create!(name: "Snatch", steepness: "wall", boulder: cracked)
    elsewhere = @mine.problems.create!(name: "Elsewhere", steepness: "wall", boulder: @mine.boulders.create!(name: "Other"))

    [ snatch, elsewhere ].each do |problem|
      post admin_lines_path, params: { line: { problem_id: problem.id, topo_id: no_gps.id } }, as: :json
    end

    distance = no_gps.metres_between(placed.location, snatch.reload.location)
    assert_operator distance, :>, 1
    assert_operator distance, :<, 3
    assert snatch.location_estimated?
    assert_nil elsewhere.reload.location, "a problem listed on another boulder doesn't take its neighbour's spot"
    assert_not placed.reload.location_estimated?
  end

  test "placing an estimated problem by hand clears the estimate" do
    problem = @mine.problems.create!(name: "Guess", steepness: "wall")
    post admin_lines_path, params: { line: { problem_id: problem.id, topo_id: @topo.id } }, as: :json
    assert problem.reload.location_estimated?

    problem.update!(name: "Renamed")
    assert problem.reload.location_estimated?, "other edits leave it estimated"

    patch admin_problem_path(problem), params: { problem: { lat: 50.6, lon: -3.9 } }, as: :json
    assert_response :success
    assert_not problem.reload.location_estimated?
  end

  test "the location editor's map marks estimated locations" do
    estimated = @mine.problems.create!(name: "Guess", steepness: "wall")
    post admin_lines_path, params: { line: { problem_id: estimated.id, topo_id: @topo.id } }, as: :json
    @mine.problems.create!(name: "Placed", steepness: "wall", lat: 50.6, lon: -3.9)

    get admin_map_path(area_id: @mine.id, format: :geojson)
    flags = JSON.parse(response.body)["features"].select { |f| f["properties"]["problemId"] }.to_h { |f| [ f["properties"]["name"], f["properties"]["estimated"] ] }
    assert_equal true, flags.find { |name, _| name.include?("Guess") }.last
    assert_equal false, flags.find { |name, _| name.include?("Placed") }.last
  end

  test "drawing on an existing line locates an unlocated problem, but never moves a located one" do
    unmapped = topo(@mine, "latitude" => 50.61, "longitude" => -3.91)
    unlocated = @mine.problems.create!(name: "Unlocated", steepness: "wall")
    located = @mine.problems.create!(name: "Located", steepness: "wall", lat: 50.62, lon: -3.92)
    lines = [ unlocated, located ].map { |p| Line.create!(problem: p, topo: unmapped) }

    lines.each do |line|
      patch admin_line_path(line), params: { line: { coordinates: POINTS.to_json } }, as: :json
      assert_response :success
    end

    # From the photo's GPS (spread a little), not from the located problem a kilometre away
    assert_operator unmapped.metres_between(unlocated.reload.location, unmapped.gps_location), :<, 3
    assert_in_delta 50.62, located.reload.lat, 1e-6
  end

  test "quick problem on a photo with GPS but no boulder outline uses the photo's GPS" do
    post quick_problem_admin_topo_path(topo(@mine, "latitude" => 50.61, "longitude" => -3.91)),
         params: { name: "Off the map" }, as: :json

    assert_response :created
    assert_in_delta 50.61, @mine.problems.find_by!(name: "Off the map").lat, 1e-6
  end

  test "the workbench and topo page show the photo's left / right arrows, or why there are none" do
    problem = @mine.problems.create!(name: "On It", steepness: "wall", lat: 50.5999, lon: -3.9)
    Line.create!(problem: problem, topo: @topo, coordinates: POINTS)
    # Facing north at the south edge: a photo of the east edge is to the right
    east = topo(@mine)
    Line.create!(problem: @mine.problems.create!(name: "East Side", steepness: "wall", lat: 50.6, lon: -3.8999), topo: east, coordinates: POINTS)

    [ workbench_admin_topo_path(@topo), edit_admin_topo_path(@topo) ].each do |path|
      get path
      assert_select "#topo-neighbours a[href=?]", workbench_admin_topo_path(east), text: /East Side →/
      assert_select "#topo-neighbours", text: /← none/
      assert_select "#topo-neighbours", text: /No other photo to the left/
    end

    get workbench_admin_topo_path(topo(@mine))
    assert_select "#topo-neighbours", text: /No position/
  end

  test "the workbench links back to the area's topos" do
    get workbench_admin_topo_path(@topo)

    assert_select "a[href=?]", admin_area_topos_path(area_slug: "mine"), text: "← Topos at Mine"
    assert_select "a[href=?]", admin_area_topos_path(area_slug: "mine", undrawn: 1), text: "Photos to draw"
  end

  test "area admins can't open another area's photo" do
    get workbench_admin_topo_path(topo(@theirs))
    assert_redirected_to admin_root_path
  end

  test "quick problem creates a problem on the boulder and a line for it on the photo" do
    assert_difference -> { @mine.problems.count } do
      post quick_problem_admin_topo_path(@topo), params: { name: "New one", grade: "6a" }, as: :json
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
    post quick_problem_admin_topo_path(topo(@mine)), params: { name: "Somewhere" }, as: :json
    assert_response :created
    assert_nil @mine.problems.find_by!(name: "Somewhere").location
  end

  test "quick problem validation errors come back as JSON" do
    post quick_problem_admin_topo_path(@topo), params: { name: "Bad", grade: "11z" }, as: :json
    assert_response :unprocessable_entity
    assert_match "Grade", response.parsed_body["error"]
  end

  test "lines can be added, drawn and removed over JSON" do
    problem = @mine.problems.create!(name: "Arete", steepness: "wall")

    post admin_lines_path, params: { line: { problem_id: problem.id, topo_id: @topo.id } }, as: :json
    assert_response :created
    line = Line.find(response.parsed_body["id"])

    patch admin_line_path(line), params: { line: { coordinates: POINTS.to_json, start_holds: "", excluded_areas: "" } }, as: :json
    assert_response :success
    assert_equal POINTS, line.reload.coordinates
    assert_equal POINTS, response.parsed_body["coordinates"]
    assert problem.reload.has_line

    patch admin_line_path(line), params: { line: { coordinates: POINTS.first(2).to_json } }, as: :json
    assert_response :unprocessable_entity
    assert_match "at least 3 points", response.parsed_body["error"]

    patch admin_line_path(line), params: { line: { coordinates: "{oops" } }, as: :json
    assert_response :unprocessable_entity

    delete admin_line_path(line), as: :json
    assert_response :no_content
    assert_not Line.exists?(line.id)
  end

  test "a line can't put your problem on another area's photo" do
    problem = @mine.problems.create!(name: "Arete", steepness: "wall")
    assert_no_difference -> { Line.count } do
      post admin_lines_path, params: { line: { problem_id: problem.id, topo_id: topo(@theirs).id } }, as: :json
    end
    assert_redirected_to admin_root_path
  end

  test "a photo with no area sends you to its edit page" do
    orphan = topo(nil)
    Admin::BaseController.define_method(:current_admin_user) { AdminUser.new(username: "boss", role: "super_admin") }
    get workbench_admin_topo_path(orphan)
    assert_redirected_to edit_admin_topo_path(orphan)
  end

  test "a photo can be tied to one of its area's boulders, which then comes first and takes new problems" do
    listed_rock = @mine.boulders.create!(name: "Listed Rock") # from a problem list: no outline yet
    @mine.problems.create!(name: "Aardvark", steepness: "wall")
    @mine.problems.create!(name: "On The List", steepness: "wall", boulder: listed_rock)

    patch boulder_admin_topo_path(@topo), params: { boulder_id: listed_rock.id }
    assert_redirected_to workbench_admin_topo_path(@topo)
    assert_equal listed_rock.id, @topo.reload.chosen_boulder_id
    assert_equal listed_rock.id, @topo.matched_boulder_id, "the tie wins over the GPS match"
    assert_equal @boulder.id, @topo.suggested_boulder_id, "the GPS match is kept"

    get workbench_admin_topo_path(@topo)
    candidates = JSON.parse(css_select("[data-controller='topo-workbench']").first["data-topo-workbench-candidates-value"])
    assert_equal [ "On The List", "Aardvark" ], candidates.map { |c| c["name"] }
    assert_equal [ true, false ], candidates.map { |c| c["on_boulder"] }
    assert_select "[data-topo-workbench-target='suggestions'][data-boulder-name='Listed Rock']"
    assert_select "select#workbench_boulder_id option[selected][value=?]", listed_rock.id.to_s
    assert_select "p", text: "Tied by hand."

    post quick_problem_admin_topo_path(@topo), params: { name: "Fresh" }, as: :json
    assert_equal listed_rock, @mine.problems.find_by!(name: "Fresh").boulder
  end

  test "untying a photo falls back to its GPS match" do
    @topo.choose_boulder!(@mine.boulders.create!(name: "Other"))

    patch boulder_admin_topo_path(@topo), params: { boulder_id: "" }

    assert_nil @topo.reload.chosen_boulder_id
    assert_equal @boulder.id, @topo.matched_boulder_id
  end

  test "a photo can't be tied to another area's boulder" do
    theirs = @theirs.boulders.create!(name: "Not Yours")

    patch boulder_admin_topo_path(@topo), params: { boulder_id: theirs.id }

    assert_nil @topo.reload.chosen_boulder_id
    assert_equal "That boulder isn't in this photo's area.", flash[:error]
  end

  test "area admins can't tie another area's photo" do
    theirs = topo(@theirs)
    patch boulder_admin_topo_path(theirs), params: { boulder_id: @boulder.id }
    assert_redirected_to admin_root_path
    assert_nil theirs.reload.chosen_boulder_id
  end

  test "a photo with no boulder hides the suggestions and says how to tie one" do
    get workbench_admin_topo_path(topo(@mine))
    assert_select "[data-topo-workbench-target='suggestions']", count: 0
    assert_select "p", text: /Tie it to a boulder/
  end

  test "the topos page names each photo's boulder: tied, or near by GPS" do
    named = @mine.boulders.create!(name: "Cracked")
    @topo.choose_boulder!(named)
    gps_only = topo(@mine, "suggested_boulder_id" => @boulder.id)

    get admin_area_topos_path(area_slug: "mine")

    assert_select "p[title=?]", "Tied to Cracked" do
      assert_select "a[href=?]", admin_area_boulder_editor_path(area_slug: "mine", boulder: named.id), text: "Cracked"
      assert_select "span", text: "· tied"
    end
    assert_select "p[title=?]", "Taken near Boulder ##{@boulder.id}", text: /near\s+Boulder ##{@boulder.id}/
    assert gps_only
  end
end
