require "test_helper"

class Admin::ProblemsControllerTest < ActionDispatch::IntegrationTest
  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      def current_admin_user = AdminUser.new(username: "tester", role: "super_admin")
    end

    @area = Area.create!(name: "Sort Tor", slug: "sort-tor", published: true)
    @easy = @area.problems.create!(name: "Bravo", grade: "4", steepness: "slab", ascents: 1)
    @hard = @area.problems.create!(name: "alpha", grade: "6a", steepness: "wall", ascents: 5)
    @mid = @area.problems.create!(name: "Charlie", grade: "4c", steepness: "overhang", ascents: 3)
    @ungraded = @area.problems.create!(name: "Delta", steepness: "wall")
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def listed_names
    css_select("tbody tr td:nth-child(2) a").map { |a| a.text.strip }
  end

  test "lists problems by popularity by default" do
    get admin_area_problems_url(area_slug: @area.slug, locale: :en)
    assert_equal %w[alpha Charlie Bravo Delta], listed_names
  end

  test "sorts by name, case-insensitively" do
    get admin_area_problems_url(area_slug: @area.slug, locale: :en, sort: "name")
    assert_equal %w[alpha Bravo Charlie Delta], listed_names

    get admin_area_problems_url(area_slug: @area.slug, locale: :en, sort: "name", dir: "desc")
    assert_equal %w[Delta Charlie Bravo alpha], listed_names
  end

  test "sorts by grade with ungraded problems last either way" do
    get admin_area_problems_url(area_slug: @area.slug, locale: :en, sort: "grade")
    assert_equal %w[Bravo Charlie alpha Delta], listed_names

    get admin_area_problems_url(area_slug: @area.slug, locale: :en, sort: "grade", dir: "desc")
    assert_equal %w[alpha Charlie Bravo Delta], listed_names
  end

  test "sort headers toggle direction and keep the missing filter" do
    get admin_area_problems_url(area_slug: @area.slug, locale: :en, sort: "grade", missing: "location")
    assert_select "th a[href*='sort=grade'][href*='dir=desc'][href*='missing=location']", text: "Grade ▲"
    assert_select "th a[href*='sort=name'][href*='dir=asc']", text: "Name"
  end

  test "problem page hints that the line photo opens the line editor" do
    topo = Topo.new(published: true)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    line = Line.create!(problem: @easy, topo: topo,
      coordinates: [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ])

    get admin_problem_url(@easy, locale: :en)

    assert_select "a[href=?][title='Edit this line']", edit_admin_line_path(line)
    assert_match "Click the photo to edit the line", response.body
  end
end
