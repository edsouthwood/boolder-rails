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

  test "the form carries the start holds mode and field" do
    get new_mapping_contribution_url(locale: :en, problem_id: @problem.id)

    assert_select "button[data-mode=holds]"
    assert_select "input[type=hidden][name='contribution[start_holds]']"
  end

  test "saves start holds submitted with a contribution" do
    # Submit the fields a freshly loaded form carries (invisible_captcha's spinner etc.), not too fast.
    get new_mapping_contribution_url(locale: :en, problem_id: @problem.id)
    fields = css_select("form input[type=hidden][name]").to_h { |input| [ input["name"], input["value"].to_s ] }

    travel 10.seconds do
      assert_difference "Contribution.count", 1 do
        post mapping_contributions_url(locale: :en), params: fields.merge(
          "contribution[comment]" => "Start matched on the jug", "contribution[start_holds]" => '[{"x":0.2,"y":0.8}]'
        )
      end
    end

    assert_equal [ { "x" => 0.2, "y" => 0.8 } ], Contribution.last.start_holds
  end
end
