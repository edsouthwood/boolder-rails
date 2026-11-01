require "test_helper"

class Admin::PhotosControllerTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    Admin::BaseController.define_method(:current_admin_user) { AREA_ADMIN }

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    # ~22 m square boulder centred on (-3.9, 50.6)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @boulder = @mine.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def photo(type = "image/jpeg")
    Rack::Test::UploadedFile.new(StringIO.new("fake image"), type, original_filename: "topo.jpg")
  end

  test "upload page" do
    get new_admin_area_photo_path(area_slug: "mine", locale: :en)
    assert_response :success
  end

  test "creates a topo in the area and matches it to the nearest boulder" do
    assert_difference -> { Topo.count } do
      post admin_area_photos_path(area_slug: "mine", locale: :en),
           params: { photo: photo, lat: "50.6002", lon: "-3.9", heading: "182.5" }
    end
    assert_response :created

    topo = Topo.last
    assert_equal @mine.id, topo[:area_id]
    assert_equal @boulder.id, response.parsed_body["suggested_boulder_id"]
    assert_equal @boulder.id, topo.suggested_boulder_id
    assert_equal({ "source" => "inbox", "latitude" => 50.6002, "longitude" => -3.9, "heading" => 182.5,
                   "suggested_boulder_id" => @boulder.id }, topo.metadata)
  end

  test "no boulder suggestion when the photo is too far away or has no GPS" do
    post admin_area_photos_path(area_slug: "mine", locale: :en), params: { photo: photo, lat: "50.61", lon: "-3.9" }
    assert_response :created
    assert_nil response.parsed_body["suggested_boulder_id"]

    post admin_area_photos_path(area_slug: "mine", locale: :en), params: { photo: photo, lat: "nonsense" }
    assert_response :created
    assert_equal({ "source" => "inbox" }, Topo.last.metadata)
  end

  test "rejects non-images" do
    assert_no_difference -> { Topo.count } do
      post admin_area_photos_path(area_slug: "mine", locale: :en), params: { photo: photo("image/svg+xml") }
    end
    assert_response :unprocessable_entity
  end

  test "area admins can't upload to other areas" do
    assert_no_difference -> { Topo.count } do
      post admin_area_photos_path(area_slug: "theirs", locale: :en), params: { photo: photo }
    end
    assert_redirected_to admin_root_path(locale: :en)
  end

  test "inbox photos show in the area's topos and the undrawn queue until a line is drawn" do
    post admin_area_photos_path(area_slug: "mine", locale: :en), params: { photo: photo }
    topo = Topo.last

    assert_includes Topo.in_area(@mine), topo
    assert_includes Topo.undrawn, topo
    get admin_area_topos_path(area_slug: "mine", locale: :en, undrawn: 1)
    assert_response :success
    assert_select "p", text: /Topo ##{topo.id}/

    problem = @mine.problems.create!(steepness: "wall")
    line = Line.create!(problem: problem, topo: topo)
    assert_includes Topo.undrawn, topo, "an empty line still needs drawing"

    line.update!(coordinates: [ { "x" => 0.1, "y" => 0.9 }, { "x" => 0.2, "y" => 0.5 }, { "x" => 0.3, "y" => 0.1 } ])
    assert_not_includes Topo.undrawn, topo

    # Area admins can now open it (it belongs to their area even before it had lines)
    get edit_admin_topo_path(topo, locale: :en)
    assert_response :success
  end

  test "older topos get their area from their first line" do
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: @mine.problems.create!(steepness: "wall"), topo: topo)

    assert_equal @mine.id, topo.reload[:area_id]
  end
end
