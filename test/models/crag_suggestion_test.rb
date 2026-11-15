require "test_helper"

class CragSuggestionTest < ActiveSupport::TestCase
  def suggestion(**attrs)
    CragSuggestion.create!(name: "Hidden Tor", location: FACTORY.point(-3.85, 50.55), access_notes: "Park at the bridge", **attrs)
  end

  def photo_for(crag_suggestion, **attrs)
    PhotoContribution.new(crag_suggestion: crag_suggestion, **attrs).tap do |pc|
      pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
      pc.save!
    end
  end

  test "needs a name and a pin in the south-west" do
    assert_not CragSuggestion.new(location: FACTORY.point(-3.85, 50.55)).valid?
    assert_not CragSuggestion.new(name: "Nowhere").valid?
    assert_not CragSuggestion.new(name: "Null Island", location: FACTORY.point(0, 0)).valid?
    assert CragSuggestion.new(name: "Hidden Tor", location_lat: "50.55", location_lon: "-3.85").valid?
  end

  test "a photo needs an area or a crag suggestion" do
    pc = PhotoContribution.new
    pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
    assert_not pc.valid?
    assert_includes pc.errors.attribute_names, :area

    pc.crag_suggestion = suggestion
    assert pc.valid?
  end

  test "a suggested crag's photo can't be accepted on its own, nor reviewed from the photo queue" do
    pc = photo_for(suggestion)

    assert_nil pc.accept!(reviewed_by: "admin")
    assert pc.reload.pending?
    assert_not_includes PhotoContribution.reviewable_by(AdminUser.new(username: "x", role: "super_admin")), pc
  end

  test "accepting makes an unpublished area with the photos as undrawn topos and the problems filed in it" do
    crag = suggestion
    located = photo_for(crag, location: FACTORY.point(-3.8501, 50.5501), heading: 90)
    unlocated = photo_for(crag)
    problem = Contribution.create!(crag_suggestion: crag, problem_name: "Hidden Arete", area_name: crag.name)

    area = crag.accept!(reviewed_by: "admin", name: "Hidden Tor East")

    assert_equal "Hidden Tor East", area.name
    assert_equal "hidden-tor-east", area.slug
    assert_not area.published
    assert_equal "Park at the bridge", area.description_en
    assert crag.reload.accepted?
    assert_equal area, crag.area
    assert_equal "admin", crag.reviewed_by

    [ located, unlocated ].each(&:reload)
    assert [ located, unlocated ].all?(&:accepted?)
    assert_equal [ area ], [ located.topo.area, unlocated.topo.area ].uniq
    assert_in_delta 50.5501, located.topo.metadata["latitude"], 1e-6

    problem.reload
    assert problem.pending?, "problems are still checked one by one"
    assert_equal area, problem.area

    assert_nil crag.accept!(reviewed_by: "admin"), "accepting twice does nothing"
    assert_equal 1, Area.where(name: "Hidden Tor East").count
  end

  test "accepting keeps a clashing slug apart" do
    Area.create!(name: "Hidden Tor", slug: "hidden-tor")
    assert_equal "hidden-tor-2", suggestion.accept!(reviewed_by: "admin").slug
  end

  test "declining keeps everything and closes its photos" do
    crag = suggestion
    pc = photo_for(crag)
    problem = Contribution.create!(crag_suggestion: crag, problem_name: "Hidden Arete")

    assert_no_difference -> { Area.count } do
      assert crag.close!(reviewed_by: "admin", note: "Already listed as Bell Tor")
    end
    assert_equal "closed", crag.reload.state
    assert_equal "Already listed as Bell Tor", crag.moderator_note
    assert_equal "closed", pc.reload.state
    assert problem.reload.pending?
  end

  test "an accepted crag's area is found from its pin before anything in it is mapped" do
    area = suggestion.accept!(reviewed_by: "admin")

    found, metres = Area.nearest_to(FACTORY.point(-3.851, 50.55), within: 1000)
    assert_equal area, found
    assert_operator metres, :<, 100
  end
end
