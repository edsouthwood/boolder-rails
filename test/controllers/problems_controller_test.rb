require "test_helper"

class ProblemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
    @problem = @area.problems.create!(name: "Flagpole", grade: "5", steepness: "wall")
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    @line = Line.create!(problem: @problem, topo: topo,
                         coordinates: [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ])
  end

  test "shows start hold markers when the line has them" do
    @line.update!(start_holds: [ { "x" => 0.18, "y" => 0.86 }, { "x" => 0.25, "y" => 0.84 } ])

    get area_problem_url(@area.slug, @problem, locale: :en)

    assert_response :success
    assert_select "[title='Start hold']", 2
    assert_select "div[style*='left:18.0%; top:86.0%']"
    assert_match "Start holds", response.body
  end

  test "shows no start hold markers when the line has none" do
    get area_problem_url(@area.slug, @problem, locale: :en)

    assert_response :success
    assert_select "[title='Start hold']", 0
    assert_no_match "Start holds", response.body
  end
end
