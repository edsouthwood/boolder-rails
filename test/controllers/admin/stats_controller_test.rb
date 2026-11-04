require "test_helper"

class Admin::StatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    @area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    @problem = @area.problems.create!(name: "Wall", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8)
    @area.problems.create!(name: "Guess", grade: "5", steepness: "wall", lat: 50.6, lon: -3.8).update_columns(location_estimated: true)
    @area.problems.create!(name: "Nowhere", grade: "5", steepness: "wall")
    PageView.create!(day: Date.current, kind: "problem", area_id: @area.id, problem_id: @problem.id, views: 7)
    PageView.create!(day: Date.current - 1, kind: "area", area_id: @area.id, views: 3)
    PageView.create!(day: Date.current - 40, kind: "home", views: 100) # outside 30 days
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def as(role, areas: [])
    user = AdminUser.new(username: "someone", role: role, areas: areas)
    Admin::BaseController.define_method(:current_admin_user) { user }
  end

  test "super admins see visits, top areas and problems, activity and progress" do
    as "super_admin"
    get admin_stats_path(locale: :en)

    assert_response :success
    assert_select "a[href=?]", admin_stats_path(locale: :en), text: "Stats"
    assert_select "p.text-3xl", text: "10"
    assert_select "td a", text: "Bell Tor"
    assert_select "td a[href=?]", admin_problem_path(@problem, locale: :en), text: "Wall"
    assert_select "canvas[data-controller=chart]", count: 7
    assert_select "tr", text: /Bell Tor\s+3\s+1\s+33%\s+1\s+1/ # problems, placed, estimated, no location

    get admin_stats_path(days: 90, locale: :en)
    assert_select "p.text-3xl", text: "110"
  end

  test "area admins can't open it and don't see the link" do
    as "area_admin", areas: [ "belltor" ]
    get admin_stats_path(locale: :en)
    assert_redirected_to admin_root_path(locale: :en)

    get admin_area_boulders_path(area_slug: "belltor", locale: :en)
    assert_select "a", text: "Stats", count: 0
  end
end
