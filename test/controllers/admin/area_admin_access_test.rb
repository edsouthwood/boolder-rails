require "test_helper"

# An area_admin may only touch data in their own areas; super admins may touch everything.
class Admin::AreaAdminAccessTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  SUPER_ADMIN = AdminUser.new(username: "boss", role: "super_admin")

  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    sign_in_as AREA_ADMIN

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    @their_problem = @theirs.problems.create!(steepness: "slab")
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def sign_in_as(user)
    Admin::BaseController.define_method(:current_admin_user) { user }
  end

  def square(offset = 0)
    [ [ -3.9 + offset, 50.5 ], [ -3.8 + offset, 50.5 ], [ -3.8 + offset, 50.6 ] ]
  end

  # --- boulders ---

  test "area admin cannot create, update or destroy boulders in another area" do
    boulder = @theirs.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(square.map { |x, y| FACTORY.point(x, y) })))

    assert_no_difference "Boulder.count" do
      post admin_area_boulders_url(area_slug: @theirs.slug, locale: :en), params: { coordinates: square }, as: :json
    end
    assert_redirected_to admin_root_path

    patch admin_boulder_url(boulder, locale: :en), params: { coordinates: square(1) }, as: :json
    assert_redirected_to admin_root_path
    assert_equal boulder.polygon, boulder.reload.polygon

    assert_no_difference "Boulder.count" do
      delete admin_boulder_url(boulder, locale: :en), as: :json
    end
    assert_redirected_to admin_root_path
  end

  test "area admin can create boulders in their own area" do
    assert_difference "Boulder.count", 1 do
      post admin_area_boulders_url(area_slug: @mine.slug, locale: :en), params: { coordinates: square }, as: :json
    end
    assert_response :success
  end

  # --- contributions ---

  test "area admin cannot review a contribution for another area's problem" do
    contribution = Contribution.create!(state: "pending", problem: @their_problem, comment: "x")

    get edit_admin_contribution_url(contribution, locale: :en)
    assert_redirected_to admin_root_path

    patch admin_contribution_url(contribution, locale: :en), params: { contribution: { state: "closed" } }
    assert_redirected_to admin_root_path
    assert contribution.reload.pending?
  end

  test "area admin cannot review an unlisted contribution" do
    contribution = Contribution.create!(state: "pending", problem_name: "New slab")

    get edit_admin_contribution_url(contribution, locale: :en)
    assert_redirected_to admin_root_path

    assert_no_difference "Problem.count" do
      post create_problem_admin_contribution_url(contribution, locale: :en),
        params: { problem: { area_id: @mine.id, name: "New slab", steepness: "slab" } }
    end
    assert_redirected_to admin_root_path
  end

  test "area admin cannot bulk close contributions" do
    contribution = Contribution.create!(state: "pending", problem: @their_problem, comment: "x")

    post bulk_close_admin_contributions_url(locale: :en), params: { contribution_ids: [ contribution.id ] }
    assert_redirected_to admin_root_path
    assert contribution.reload.pending?
  end

  test "area admin can review a contribution in their own area" do
    contribution = Contribution.create!(state: "pending", problem: @mine.problems.create!(steepness: "slab"), comment: "x")

    get edit_admin_contribution_url(contribution, locale: :en)
    assert_response :success
  end

  # --- contribution requests ---

  test "area admin cannot request contributions for another area's problem" do
    get new_admin_contribution_request_url(problem_id: @their_problem.id, locale: :en)
    assert_redirected_to admin_root_path

    assert_no_difference "ContributionRequest.count" do
      post admin_contribution_requests_url(locale: :en), params: { contribution_request: { problem_id: @their_problem.id } }
    end
    assert_redirected_to admin_root_path
  end

  # --- poi routes ---

  test "area admin cannot add a poi route to another area" do
    get new_admin_poi_route_url(area_id: @theirs.id, locale: :en)
    assert_redirected_to admin_root_path

    get admin_poi_routes_url(locale: :en)
    assert_redirected_to admin_root_path
  end

  # --- topos ---

  test "area admin cannot edit a topo that has no lines" do
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!

    get edit_admin_topo_url(topo, locale: :en)
    assert_redirected_to admin_root_path
  end

  test "destroying a topo redirects to its area's problems" do
    sign_in_as SUPER_ADMIN
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: @their_problem, topo: topo)

    delete admin_topo_url(topo, locale: :en)
    assert_redirected_to admin_area_problems_path(area_slug: @theirs.slug, circuit_id: "first")
  end
end
