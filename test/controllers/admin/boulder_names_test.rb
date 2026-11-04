require "test_helper"

class Admin::BoulderNamesTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  RING = [ [ -3.9, 50.6 ], [ -3.8999, 50.6 ], [ -3.8999, 50.6001 ], [ -3.9, 50.6001 ] ].freeze

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { AREA_ADMIN }
    end

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    @outline = @mine.boulders.create!(polygon: polygon(RING))
    @listed = @mine.boulders.create!(name: "Photo Arête")
    @problem = @mine.problems.create!(name: "Photo Wall", steepness: "wall", boulder: @listed)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def polygon(ring)
    FACTORY.polygon(FACTORY.linear_ring((ring + [ ring.first ]).map { |x, y| FACTORY.point(x, y) }))
  end

  def name!(boulder, name)
    patch admin_boulder_path(boulder), params: { name: name }, as: :json
  end

  test "naming an outline after a listed boulder takes over its problems" do
    name!(@outline, "photo arête")

    assert_response :success
    assert_equal({ "ok" => true, "name" => "Photo Arête", "absorbed_id" => @listed.id }, response.parsed_body)
    assert_equal @outline, @problem.reload.boulder
    assert_not Boulder.exists?(@listed.id)
  end

  test "an outline can be given a new name, or none" do
    name!(@outline, "  Little   Roof ")
    assert_equal "Little Roof", @outline.reload.name
    assert_nil response.parsed_body["absorbed_id"]

    name!(@outline, "")
    assert_nil @outline.reload.name
  end

  test "a name already used by another outline is refused" do
    @mine.boulders.create!(name: "Taken", polygon: polygon(RING.map { |x, y| [ x + 0.01, y ] }))

    name!(@outline, "Taken")
    assert_response :unprocessable_entity
    assert_match "already on the map", response.parsed_body["error"]
    assert_nil @outline.reload.name
  end

  test "drawing a listed boulder gives it its outline" do
    post admin_area_boulders_path(area_slug: "mine"), params: { coordinates: RING, boulder_id: @listed.id }, as: :json

    assert_response :success
    assert_equal({ "id" => @listed.id, "name" => "Photo Arête" }, response.parsed_body)
    assert @listed.reload.placed?
  end

  test "the editor lists the names still to draw and focuses a boulder" do
    get admin_area_boulder_editor_path(area_slug: "mine", boulder: @outline.id)

    editor = css_select("[data-controller='admin-boulder-editor']").first
    assert_equal [ { "id" => @listed.id, "name" => "Photo Arête", "problems" => 1 } ], JSON.parse(editor["data-admin-boulder-editor-unplaced-value"])
    assert_equal @outline.id.to_s, editor["data-admin-boulder-editor-focus-id-value"]
  end

  test "the editor's map data carries boulder names" do
    @outline.update!(name: "Named")
    get admin_map_path(area_id: @mine.id, format: :geojson)

    names = JSON.parse(response.body)["features"].filter_map { |f| f.dig("properties", "name") if f.dig("geometry", "type") == "Polygon" }
    assert_equal [ "Named" ], names
  end

  test "area admins can't rename another area's boulder" do
    theirs = @theirs.boulders.create!(polygon: polygon(RING))
    name!(theirs, "Mine now")

    assert_response :redirect
    assert_nil theirs.reload.name
  end

  test "a problem's boulder can be set on its edit form, but only to one in its area" do
    patch admin_problem_path(@problem), params: { problem: { boulder_id: @outline.id } }
    assert_equal @outline, @problem.reload.boulder

    other = @theirs.boulders.create!(name: "Away")
    patch admin_problem_path(@problem), params: { problem: { boulder_id: other.id } }
    assert_equal @outline, @problem.reload.boulder
  end
end
