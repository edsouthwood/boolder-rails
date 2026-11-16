require "test_helper"

class AreaLevelsChartTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Chart Tor", slug: "chart-tor", published: true)
    @caching, ActionController::Base.perform_caching = ActionController::Base.perform_caching, true
    @store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    ActionController::Base.perform_caching = @caching
    Rails.cache = @store
  end

  def chart_counts
    get area_path(@area.slug)
    JSON.parse(css_select("canvas[data-controller=chart]").first["data-chart-data-value"])["datasets"][0]["data"]
  end

  test "the levels chart counts problems added and placed after the area was last edited" do
    assert_equal [ 0 ] * 8, chart_counts

    travel 1.minute do
      @area.problems.create!(name: "Groove", grade: "5", steepness: "wall", location: FACTORY.point(-3.9, 50.6))
      assert_equal [ 0, 0, 0, 0, 1, 0, 0, 0 ], chart_counts
    end
  end
end
