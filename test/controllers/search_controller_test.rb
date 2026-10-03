require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  setup do
    hidden_area = Area.create!(name: "Hidden Tor", slug: "hidden-tor", published: false)
    hidden_area.problems.create!(name: "Zebrastripe", steepness: "slab")
  end

  test "ignores show_unpublished for visitors" do
    get search_url(query: "Zebrastripe", show_unpublished: "1")
    assert_response :success
    assert_empty response.parsed_body.select { |result| result["type"] == "Problem" }
  end

  test "ignores an unknown locale instead of erroring" do
    get search_url(query: "Zebrastripe", locale: "zz")
    assert_response :success
  end
end
