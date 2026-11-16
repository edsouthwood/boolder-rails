require "test_helper"

class Admin::BouldersIndexTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  LON = -3.9
  LAT = 50.6

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { AREA_ADMIN }
    end

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def square(lon)
    d = 0.0001
    FACTORY.polygon(FACTORY.linear_ring([ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(lon + x, LAT + y) }))
  end

  def topo_with_line(problem, coordinates: [ { "x" => 0.5, "y" => 0.9 }, { "x" => 0.5, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ])
    topo = Topo.new(area: @mine)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(topo: topo, problem: problem, coordinates: coordinates)
    topo
  end

  test "each boulder's status, most urgent first, and problems on no boulder" do
    listed = @mine.boulders.create!(name: "Listed Only")
    @mine.problems.create!(name: "Unseen", steepness: "wall", boulder: listed)

    bare = @mine.boulders.create!(name: "Bare Rock", polygon: square(LON))
    @mine.problems.create!(name: "No Photo", steepness: "wall", boulder: bare)

    half = @mine.boulders.create!(name: "Half Done", polygon: square(LON + 0.01))
    drawn = @mine.problems.create!(name: "Drawn", steepness: "wall", boulder: half)
    @mine.problems.create!(name: "Not Yet", steepness: "wall", boulder: half)
    topo_with_line(drawn)

    done = @mine.boulders.create!(name: "Finished", polygon: square(LON + 0.02))
    topo_with_line(@mine.problems.create!(name: "All Good", steepness: "wall", boulder: done))

    @mine.boulders.create!(polygon: square(LON + 0.03)) # unnamed pebble, no problems
    @mine.problems.create!(name: "Loose", steepness: "wall")

    progress = BoulderProgress.new(@mine)
    assert_equal [ [ "Listed Only", :not_on_map ], [ "Bare Rock", :needs_photos ], [ "Half Done", :needs_lines ],
                   [ "Finished", :done ], [ nil, :no_problems ] ], progress.rows.map { [ _1.boulder.name, _1.status ] }
    assert_equal [ "Loose" ], progress.unassigned_problems.map(&:name)

    get admin_area_boulders_path(area_slug: "mine")
    assert_response :success
    assert_select "tbody tr", 3, "the default view hides done boulders and ones without problems"
    assert_select "a", text: "Draw lines →"
    assert_select "summary", text: /1 problem not on any boulder/

    get admin_area_boulders_path(area_slug: "mine", show: "all")
    assert_select "tbody tr", 5
  end

  test "a photo matched to a boulder by GPS counts as a photo of it" do
    rock = @mine.boulders.create!(name: "Rock", polygon: square(LON))
    @mine.problems.create!(name: "Problem", steepness: "wall", boulder: rock)
    topo = Topo.new(area: @mine, metadata: { "suggested_boulder_id" => rock.id })
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!

    row = BoulderProgress.new(@mine).rows.first
    assert_equal :needs_lines, row.status
    assert_equal topo, row.next_topo
  end

  # --- renaming from the list ---

  test "renames a listed boulder that isn't on the map yet, keeping its problems" do
    boulder = @mine.boulders.create!(name: "Big Boulder")
    problem = @mine.problems.create!(name: "Crack", steepness: "wall", boulder: boulder)

    patch rename_admin_boulder_url(boulder), params: { name: "  The  Big One ", return_to: admin_area_boulders_path(area_slug: "mine") }

    assert_redirected_to admin_area_boulders_path(area_slug: "mine")
    assert_equal "The Big One", boulder.reload.name
    assert_equal boulder, problem.reload.boulder
    assert_match "renamed The Big One", flash[:notice]
  end

  test "renames a boulder drawn on the map" do
    boulder = @mine.boulders.create!(name: "Lump", polygon: square(LON))

    patch rename_admin_boulder_url(boulder), params: { name: "Slab Block" }

    assert_equal "Slab Block", boulder.reload.name
    assert boulder.placed?
  end

  test "refuses a name another boulder in the area has, and an empty name" do
    boulder = @mine.boulders.create!(name: "Lump")
    @mine.boulders.create!(name: "Slab Block")

    patch rename_admin_boulder_url(boulder), params: { name: "slab block" }
    assert_equal "Lump", boulder.reload.name
    assert_match "already a boulder", flash[:alert]

    patch rename_admin_boulder_url(boulder), params: { name: " " }
    assert_equal "Lump", boulder.reload.name
  end

  test "an area admin can't rename a boulder in someone else's area" do
    theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    boulder = theirs.boulders.create!(name: "Lump")

    patch rename_admin_boulder_url(boulder), params: { name: "Mine Now" }

    assert_equal "Lump", boulder.reload.name
  end

  test "the list has a rename box for each boulder" do
    boulder = @mine.boulders.create!(name: "Big Boulder")
    @mine.problems.create!(name: "Crack", steepness: "wall", boulder: boulder)

    get admin_area_boulders_url(area_slug: "mine", show: "all")

    assert_select "form[action=?] input[name=name][value=?]", rename_admin_boulder_path(boulder), "Big Boulder"
  end
end
