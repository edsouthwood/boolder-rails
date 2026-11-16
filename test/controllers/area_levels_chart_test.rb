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

  test "the levels page counts each crag's problems by level, following problems added later" do
    row = -> {
      get areas_levels_path
      css_select("li[data-crag-levels-target=row]").find { |li| li.at_css("a[href='#{area_path(@area.slug)}']") }
    }
    assert_equal [ 0 ] * 8, JSON.parse(row.call["data-counts"])

    travel 1.minute do
      @area.problems.create!(name: "Groove", grade: "5", steepness: "wall", location: FACTORY.point(-3.9, 50.6))
      @area.problems.create!(name: "Slab", grade: "5+", steepness: "slab", location: FACTORY.point(-3.9, 50.6))
      li = row.call
      assert_equal [ 0, 0, 0, 0, 2, 0, 0, 0 ], JSON.parse(li["data-counts"])
      assert_equal "2", li["data-total"]
      assert_match "2 problems", li.text
      assert_equal "2", li.at_css("[data-level='5']").text.strip
    end
  end

  test "the levels page has the level picker" do
    get areas_levels_path

    assert_select "[data-controller=crag-levels] button[data-level]", 8
    assert_select "[data-crag-levels-match-value='{n} at your level · ']"
  end
end
