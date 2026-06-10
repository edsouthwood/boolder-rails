require "test_helper"

class Mapping::ContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Form Area", slug: "form-area")
    @problem = @area.problems.create!(steepness: "slab")
  end

  test "renders the contribution form (with the location picker) for a problem" do
    get new_mapping_contribution_url(locale: :en, problem_id: @problem.id)

    assert_response :success
    assert_select "div[data-controller*=location-picker]"
    assert_select "div[data-location-picker-target=map]"
    # The picker is wired to the area's boulder geojson so outlines are drawn.
    assert_select "div[data-location-picker-map-data-url-value*=?]", "area_id=#{@area.id}"
  end

  test "renders the contribution detail page" do
    contribution = Contribution.create!(state: "pending", problem: @problem, comment: "Looks great")
    get mapping_contribution_url(locale: :en, id: contribution.id)

    assert_response :success
    assert_select "body", text: /Looks great/
  end
end
