require "test_helper"

class Admin::AreaToolbarTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    Admin::BaseController.define_method(:current_admin_user) { AREA_ADMIN }

    @area = Area.create!(name: "Mine", slug: "mine", published: true)
    rock = @area.boulders.create!(name: "Listed Rock") # not on the map: needs work
    @area.problems.create!(name: "Unplaced", steepness: "wall", boulder: rock)
    @area.problems.create!(name: "Placed", steepness: "wall", lat: 50.6, lon: -3.9)
    @area.problems.create!(name: "Guessed", steepness: "wall", lat: 50.6, lon: -3.9).update_columns(location_estimated: true)
    @area.problems.create!(name: "Hidden", steepness: "wall", hidden: true)
    topo = Topo.new(area: @area)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  test "every area page has the tool bar, with the current tab marked" do
    {
      admin_area_problems_path(area_slug: "mine") => "Problems",
      admin_area_boulders_path(area_slug: "mine") => "Boulders",
      admin_area_topos_path(area_slug: "mine") => "Photos",
      new_admin_area_photo_path(area_slug: "mine") => "Photos",
      admin_area_map_editor_path(area_slug: "mine") => "Map",
      admin_area_boulder_editor_path(area_slug: "mine") => "Outlines",
      admin_area_problem_list_path(area_slug: "mine") => nil,
      edit_admin_area_path(@area) => nil
    }.each do |path, current|
      get path
      assert_response :success, path
      assert_select "#area-toolbar nav a", count: 5
      if current
        assert_select "#area-toolbar a[aria-current=page]", text: /\A\s*#{current}/
      else
        assert_select "#area-toolbar a[aria-current=page]", count: 0
      end
      assert_select "#area-toolbar summary", text: "+ Add"
      assert_select "#area-toolbar a[href=?]", new_admin_area_photo_path(area_slug: "mine"), text: "Upload photos"
      assert_select "#area-toolbar a[href=?]", edit_admin_area_path(@area), text: "Edit area"
    end
  end

  test "tabs show what's waiting: photos to draw, problems to place, boulders needing work" do
    get admin_area_problems_path(area_slug: "mine")

    assert_select "#area-toolbar a[title=?]", "1 to draw", text: /Photos/
    assert_select "#area-toolbar a[title=?]", "2 to place", text: /Map/ # unlocated + estimated, not hidden
    assert_select "#area-toolbar a[title=?]", "1 need photos or lines", text: /Boulders/
  end

  test "the areas list links straight to each area's tools with counts" do
    get admin_areas_path

    assert_select "a[href=?]", admin_area_topos_path(area_slug: "mine", undrawn: 1), text: /Photos\s*1/
    assert_select "a[href=?]", admin_area_map_editor_path(area_slug: "mine"), text: /Map\s*2/
    assert_select "a[href=?]", admin_area_boulders_path(area_slug: "mine"), text: "Boulders"
  end
end
