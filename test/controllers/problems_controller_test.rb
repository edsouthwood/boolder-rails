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

  test "the breadcrumb names the problem's boulder when it has one" do
    get area_problem_url(@area.slug, @problem, locale: :en)
    assert_select "div", text: "Photo Arête", count: 0

    @problem.update!(boulder: @area.boulders.create!(name: "Photo Arête"))
    get area_problem_url(@area.slug, @problem, locale: :en)
    assert_select "div", text: "Photo Arête"
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

  test "shades not-in areas when the line has them" do
    @line.update!(excluded_areas: [ [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.3, "y" => 0.1 }, { "x" => 0.2, "y" => 0.4 } ] ])

    get area_problem_url(@area.slug, @problem, locale: :en)

    assert_select "svg[aria-label='Not in'] polygon[points='40.0,30.0 120.0,30.0 80.0,120.0']"
    assert_match "Not in", response.body
  end

  test "shows no not-in shading when the line has none" do
    get area_problem_url(@area.slug, @problem, locale: :en)

    assert_select "svg[aria-label='Not in']", 0
  end

  test "browse by grade lists published, located problems of that grade, topos first" do
    @problem.update!(lat: 50.6, lon: -3.9)
    @area.problems.create!(name: "Legacy four", grade: "5a", steepness: "slab", lat: 50.6, lon: -3.9)
    @area.problems.create!(name: "Unplaced", grade: "5", steepness: "slab")
    hidden = Area.create!(name: "Hidden", slug: "hidden", published: false)
    hidden.problems.create!(name: "Secret", grade: "5", steepness: "wall", lat: 50.6, lon: -3.9)
    @area.problems.create!(name: "Harder", grade: "6b", steepness: "wall", lat: 50.6, lon: -3.9)

    get problems_url(locale: :en, grade: "5")

    assert_response :success
    assert_select "h1", "Problems by grade"
    assert_select "option[selected][value='5']", "5 (2)"
    assert_select "option[value='6b']", "6b (1)"
    assert_select "ul[role=list] li", 2
    assert_select "ul[role=list] li:first-child", /Flagpole/
    assert_select "ul[role=list] li", text: /Legacy four/
    assert_no_match "Unplaced", response.body
    assert_no_match "Secret", response.body
  end

  test "browse by grade falls back to a grade that has problems" do
    @problem.update!(lat: 50.6, lon: -3.9)
    get problems_url(locale: :en, grade: "9c")
    assert_response :success
    assert_select "option[selected][value='5']"
  end

  test "the topo has arrows to the photos to its left and right" do
    d = 0.0002
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    @problem.update!(lat: 50.6 - d, lon: -3.9) # south face, looking north
    east = @area.problems.create!(name: "East Face", steepness: "wall", lat: 50.6, lon: -3.9 + d)
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: east, topo: topo, coordinates: @line.coordinates)

    get area_problem_url(@area.slug, @problem, locale: :en)

    assert_select "a[data-topo-nav-target=right][href=?][title=?]",
                  area_problem_path(@area, east, locale: :en), "Photo to the right: East Face"
    assert_select "a[data-topo-nav-target=left]", count: 0
  end

  test "no arrows when the photo's direction can't be worked out" do
    get area_problem_url(@area.slug, @problem, locale: :en)
    assert_response :success
    assert_select "a[data-topo-nav-target]", count: 0
  end
end
