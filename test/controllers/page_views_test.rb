require "test_helper"

# Anonymous daily visit totals: only real visits count, and nothing about the visitor is kept
class PageViewsTest < ActionDispatch::IntegrationTest
  BROWSER = { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1" }.freeze
  NAVIGATE = BROWSER.merge("Sec-Fetch-Mode" => "navigate").freeze

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "admin" => "correct-password" }
    end
    Rails.cache.clear
    @area = Area.create!(name: "Bell Tor", slug: "belltor", published: true)
    @problem = @area.problems.create!(name: "Wall", grade: "4", steepness: "wall", lat: 50.6, lon: -3.8)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def views = PageView.order(:kind).pluck(:kind, :area_id, :problem_id, :views)

  test "browser visits to the home, area, problem and map pages are counted per day and page" do
    get root_localized_path(locale: :en), headers: NAVIGATE
    get area_path(slug: "belltor", locale: :en), headers: NAVIGATE
    2.times { get area_problem_path(slug: "belltor", id: @problem.id, locale: :en), headers: NAVIGATE }
    get map_path(slug: "belltor", locale: :en), headers: NAVIGATE

    assert_equal [ [ "area", @area.id, 0, 1 ], [ "home", 0, 0, 1 ], [ "map", @area.id, 0, 1 ], [ "problem", @area.id, @problem.id, 2 ] ], views
    assert_equal [ Date.current ], PageView.distinct.pluck(:day)
    assert_equal %w[area_id day id kind problem_id views], PageView.column_names.sort, "nothing about the visitor is stored"
  end

  test "Turbo link clicks count, but Turbo's hover prefetches don't" do
    get area_path(slug: "belltor", locale: :en), headers: BROWSER.merge("X-Turbo-Request-Id" => "abc")
    get area_path(slug: "belltor", locale: :en), headers: BROWSER.merge("X-Turbo-Request-Id" => "def", "X-Sec-Purpose" => "prefetch")

    assert_equal [ [ "area", @area.id, 0, 1 ] ], views
  end

  test "offline downloads, bots, missing pages and admins aren't counted" do
    get area_problem_path(slug: "belltor", id: @problem.id, locale: :en), headers: BROWSER.merge("Sec-Fetch-Mode" => "cors") # offline download
    get area_path(slug: "belltor", locale: :en), headers: { "User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1)", "Sec-Fetch-Mode" => "navigate" }
    get area_path(slug: "belltor", locale: :en), headers: { "Sec-Fetch-Mode" => "navigate" } # no user agent
    get area_path(slug: "nowhere", locale: :en), headers: NAVIGATE
    @problem.update!(hidden: true)
    get area_problem_path(slug: "belltor", id: @problem.id, locale: :en), headers: NAVIGATE # 404

    get admin_docs_url(locale: :en), headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("admin", "correct-password") }
    get area_path(slug: "belltor", locale: :en), headers: NAVIGATE

    assert_empty views
  end

  test "a counting failure never breaks the page" do
    PageView.singleton_class.alias_method :_real_record, :record
    PageView.define_singleton_method(:record) { |*, **| raise ActiveRecord::StatementInvalid, "boom" }
    get area_path(slug: "belltor", locale: :en), headers: NAVIGATE
    assert_response :success
  ensure
    PageView.singleton_class.alias_method :record, :_real_record
    PageView.singleton_class.remove_method :_real_record
  end
end
