require "test_helper"

# Adding, moving and removing points on an outline in the boulder editor
class Admin::BoulderOutlineTest < ActionDispatch::IntegrationTest
  RING = [ [ -3.9, 50.6 ], [ -3.8999, 50.6 ], [ -3.8999, 50.6001 ], [ -3.9, 50.6001 ] ].freeze

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { AdminUser.new(username: "local", role: "super_admin") }
    end

    @area = Area.create!(name: "Outlines", slug: "outlines", published: true)
    @boulder = @area.boulders.create!(polygon: polygon(RING))
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

  def save!(coordinates)
    patch admin_boulder_path(@boulder), params: { coordinates: coordinates }, as: :json
  end

  def corners
    @boulder.reload.polygon.exterior_ring.points.size - 1
  end

  test "a point added halfway along an edge is saved" do
    save!(RING.dup.insert(1, [ -3.89995, 50.59995 ]))
    assert_response :success
    assert_equal 5, corners
  end

  test "a point can be removed, down to three" do
    save!(RING.first(3))
    assert_response :success
    assert_equal 3, corners
  end

  test "fewer than three points is refused" do
    save!(RING.first(2))
    assert_response :unprocessable_entity
    assert_equal 4, corners
  end

  test "an outline that crosses itself is refused, with where it crosses" do
    bow_tie = [ RING[0], RING[2], RING[1], RING[3] ]
    save!(bow_tie)
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_match(/crosses itself/, body["error"])
    assert_in_delta(-3.89995, body["crossing"][0], 1e-6)
    assert_in_delta 50.60005, body["crossing"][1], 1e-6
    assert_equal RING, @boulder.reload.polygon.exterior_ring.points.first(4).map { |p| [ p.x, p.y ] }
  end

  test "a new outline isn't checked, so LiDAR shapes can be added and tidied after" do
    post admin_area_boulders_path(area_slug: @area.slug), params: { coordinates: [ RING[0], RING[2], RING[1], RING[3] ] }, as: :json
    assert_response :success
  end
end
