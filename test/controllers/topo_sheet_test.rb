require "test_helper"

class TopoSheetTest < ActionDispatch::IntegrationTest
  include TopoSheetHelper

  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill", published: true, warning_en: "Keep off the walls.")
  end

  def topo_with(*problems_and_x, published: true)
    topo = Topo.new(published: published)
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    problems_and_x.each do |problem, x|
      Line.create!(problem: problem, topo: topo,
                   coordinates: [ { "x" => x, "y" => 0.9 }, { "x" => x, "y" => 0.5 }, { "x" => x + 0.05, "y" => 0.1 } ])
    end
    topo
  end

  test "topo_line_path matches the website's bezier smoothing" do
    coords = [ { "x" => 0.1, "y" => 0.9 }, { "x" => 0.2, "y" => 0.5 }, { "x" => 0.3, "y" => 0.3 }, { "x" => 0.25, "y" => 0.1 } ]
    # Same output as topo_line_controller.js#bezierCurve for these points
    assert_equal "M 40 270 Q  80 150 100 120 120 90 100 30", topo_line_path(coords)
  end

  test "the sheet numbers problems on each photo left to right and lists the rest" do
    right = @area.problems.create!(name: "Right Arete", grade: "6a", steepness: "wall", lat: 50.6, lon: -3.9)
    left = @area.problems.create!(name: "Left Wall", grade: "4+", steepness: "wall", sit_start: true, lat: 50.6, lon: -3.9)
    topo_with([ right, 0.7 ], [ left, 0.2 ])
    hidden = @area.problems.create!(name: "Unpublished Photo Problem", grade: "5", steepness: "slab", lat: 50.6, lon: -3.9)
    topo_with([ hidden, 0.5 ], published: false)
    @area.problems.create!(name: "Unlocated", grade: "3", steepness: "slab")

    get area_print_url(@area.slug)

    assert_response :success
    assert_select "h1", "Bonehill"
    assert_select "p", /Keep off the walls/
    assert_select "section.topo-block img[src^=?]", "/proxy/topos/", count: 1
    assert_select "section.topo-block svg text", 2
    assert_select "section.topo-block ol li", 2 do |items|
      assert_match(/1\s*Left Wall\s*4\+\s*sit start/, items[0].text.squish)
      assert_match(/2\s*Right Arete\s*6a/, items[1].text.squish)
    end
    # Problems not on a published photo, with a location, go in the table
    assert_select "table td", "Unpublished Photo Problem"
    assert_no_match "Unlocated", response.body
    assert_no_match "data-controller=\"mapbox\"", response.body
  end

  test "the area page links to the sheet; unpublished areas' sheets are hidden" do
    get area_url(@area.slug)
    assert_select "a[href=?]", area_print_path(@area.slug), text: /Print topo sheet/

    hidden = Area.create!(name: "Combestone", slug: "combestone", published: false)
    get area_print_url(hidden.slug)
    assert_response :not_found
  end

  test "the sheet leaves out problems on a hidden boulder" do
    hidden_boulder = @area.boulders.create!(name: "Out Of Scope Block", hidden: true)
    shown = @area.problems.create!(name: "Shown Wall", grade: "4", steepness: "wall", lat: 50.6, lon: -3.9)
    on_hidden = @area.problems.create!(name: "Hidden Block Arete", grade: "5", steepness: "wall", lat: 50.6, lon: -3.9, boulder: hidden_boulder)
    topo_with([ shown, 0.2 ], [ on_hidden, 0.6 ])
    topo_with([ on_hidden, 0.4 ])

    get area_print_url(@area.slug)

    assert_response :success
    assert_match "Shown Wall", response.body
    assert_no_match "Hidden Block Arete", response.body
    assert_select "section.topo-block img", count: 1
    assert_select "section.topo-block svg text", 1
  end
end
