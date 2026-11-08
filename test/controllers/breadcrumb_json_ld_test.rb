require "test_helper"

class BreadcrumbJsonLdTest < ActionDispatch::IntegrationTest
  setup do
    @area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)
  end

  test "area page: Dartmoor, area" do
    get area_path(@area)

    assert_equal [ [ "Dartmoor", areas_url ], [ "Bonehill", area_url(@area) ] ], crumbs
  end

  test "area problem list: Dartmoor, area, problems" do
    get area_problems_path(@area)

    assert_equal [ [ "Dartmoor", areas_url ], [ "Bonehill", area_url(@area) ],
                   [ "Problems", area_problems_url(@area) ] ], crumbs
  end

  test "circuit page: Dartmoor, area, circuit" do
    circuit = Circuit.create!(color: "blue")
    @area.problems.create!(name: "Flagpole", grade: "5", steepness: "wall", circuit: circuit, circuit_number: "1",
                           location: FACTORY.point(-3.77, 50.57))

    get circuit_path(circuit)

    assert_response :success
    assert_equal [ "Dartmoor", "Bonehill" ], crumbs.first(2).map(&:first)
    assert_equal circuit_url(circuit), crumbs.last.last
  end

  private

  def crumbs
    list = css_select('script[type="application/ld+json"]').map { |s| JSON.parse(s.text) }
                                                           .find { |d| d["@type"] == "BreadcrumbList" }
    assert list, "no BreadcrumbList on the page"
    items = list["itemListElement"]
    assert_equal (1..items.size).to_a, items.map { |i| i["position"] }
    items.map { |i| [ i["name"], i["item"] ] }
  end
end
