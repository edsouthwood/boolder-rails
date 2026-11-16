require "test_helper"

class Admin::MapPointsControllerTest < ActionDispatch::IntegrationTest
  SUPER_ADMIN = AdminUser.new(username: "boss", role: "super_admin")
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "known-crag" ])
  SAMPLE = File.read(Rails.root.join("test/fixtures/files/map_points/sample.kml"))

  setup do
    @user = SUPER_ADMIN
    test_case = self
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { test_case.instance_variable_get(:@user) }
    end

    @area = Area.create!(name: "Known Crag", slug: "known-crag", published: true)
    @owl = @area.boulders.create!(name: "Owl Boulder")
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def upload(text = SAMPLE)
    Rack::Test::UploadedFile.new(StringIO.new(text.dup), "application/vnd.google-earth.kml+xml", original_filename: "map.kml")
  end

  test "the upload form loads" do
    get admin_new_map_points_path

    assert_response :success
    assert_select "input[type=file][name=file]"
  end

  test "preview shows the folders and matches and saves nothing" do
    assert_no_difference -> { Area.count + Boulder.count + Poi.count } do
      post admin_map_points_preview_path, params: { file: upload }
    end

    assert_response :success
    assert_select "h2", text: "Known Crag"
    assert_select "select[name='targets[f0]'] option[selected][value='area:#{@area.id}']"
    assert_select "select[name='targets[f1]'] option[selected][value=new]"
    assert_select "option[selected][value='boulder:#{@owl.id}']"
    assert_select "span", text: "unsure"
    assert_select "li", text: /A Track/
  end

  test "a KMZ or broken file is turned away with a message" do
    post admin_map_points_preview_path, params: { file: upload("PK\x03\x04zip") }
    assert_redirected_to admin_new_map_points_path
    assert_match(/KMZ/, flash[:error])

    post admin_map_points_preview_path, params: { file: upload("<kml><Document>") }
    assert_redirected_to admin_new_map_points_path
    assert_match(/isn't valid KML/, flash[:error])
  end

  test "importing applies the preview's choices" do
    post admin_map_points_path, params: { text: SAMPLE, parking_sent: "1", parking: [],
      targets: { "f1" => "new" }, area_names: { "f1" => "Renamed Crag" } }

    assert_redirected_to admin_areas_path
    assert_match(/1 area created/, flash[:notice])
    assert @owl.reload.location
    assert Area.exists?(name: "Renamed Crag", published: false)
    assert_equal 0, Poi.count, "unticked parking spots aren't added"
  end

  test "Update preview re-plans with the new destinations and saves nothing" do
    assert_no_difference -> { Area.count + Boulder.count + Poi.count } do
      post admin_map_points_path, params: { text: SAMPLE, update_preview: "1", targets: { "f1" => "skip" } }
    end

    assert_response :success
    assert_select "select[name='targets[f1]'] option[selected][value=skip]"
  end

  test "area admins can't use it" do
    @user = AREA_ADMIN

    get admin_new_map_points_path
    assert_redirected_to admin_root_path

    assert_no_difference -> { Boulder.where.not(location: nil).count } do
      post admin_map_points_path, params: { text: SAMPLE }
    end
    assert_redirected_to admin_root_path
  end
end
