require "test_helper"

class NewsDigestTest < ActiveSupport::TestCase
  LINE = [ { "x" => 0.3, "y" => 0.9 }, { "x" => 0.35, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ].freeze

  setup do
    travel_to 1.month.ago do
      @area = Audited.audit_class.as_user("old_admin") { Area.create!(name: "Old Tor", slug: "old-tor", published: true) }
      @old = @area.problems.create!(name: "Old one", steepness: "wall", lat: 50.6, lon: -3.9)
    end
  end

  def problem(name, grade: "6a", area: @area, **attrs)
    area.problems.create!(name: name, grade: grade, steepness: "wall", lat: 50.6, lon: -3.9, **attrs)
  end

  def topo(width: 800, height: 600)
    topo = Topo.new(area: @area, published: true, uncropped: true)
    topo.photo.attach(io: StringIO.new(Vips::Image.black(width, height).add(120).cast(:uchar).bandjoin([ 120, 120 ]).jpegsave_buffer),
                      filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    topo.photo.blob.update!(metadata: { "analyzed" => true, "identified" => true, "width" => width, "height" => height })
    topo
  end

  def digest = NewsDigest.new(since: 7.days.ago).call

  test "lists problems the public can see that were added in the period, hardest first" do
    easy = problem("Easy", grade: "5+")
    hard = problem("Hard", grade: "7b")
    problem("Hidden", hidden: true)
    hidden_boulder = Boulder.create!(area: @area, hidden: true,
                                     polygon: FACTORY.polygon(FACTORY.linear_ring([ [ -3.8, 50.5 ], [ -3.8, 50.51 ], [ -3.79, 50.5 ], [ -3.8, 50.5 ] ].map { |x, y| FACTORY.point(x, y) })))
    problem("On hidden boulder", lat: 50.501, lon: -3.799).update_columns(boulder_id: hidden_boulder.id)
    problem("No location").update_columns(location: nil)
    secret = Area.create!(name: "Secret", slug: "secret", published: false)
    problem("In unpublished area", area: secret)

    names = digest[:problems].map { |p| p[:name] }
    assert_equal [ hard.name, easy.name ], names
    assert_equal 2, digest[:counts][:problems]
    assert_equal "https://bowda.rocks/p/#{hard.id}", digest[:problems].first[:url]
  end

  test "credits the contributor, else the admin who created it, else nobody" do
    by_visitor = Audited.audit_class.as_user("jo") { problem("Visitor's") }
    Contribution.create!(state: "accepted", problem: by_visitor, comment: "x", contributor_name: "  Sam  Climber ")
    Audited.audit_class.as_user("jo") { problem("Admin's") }
    problem("Script's")

    credits = digest[:problems].to_h { |p| [ p[:name], p[:credit] ] }
    assert_equal({ kind: "visitor", name: "Sam Climber", source: "contribution" }, credits["Visitor's"])
    assert_equal({ kind: "admin", name: "jo", source: "admin" }, credits["Admin's"])
    assert_nil credits["Script's"]
  end

  test "an area published in the period counts, with its older problems" do
    area = travel_to(1.month.ago) do
      area = Audited.audit_class.as_user("jo") { Area.create!(name: "New Tor", slug: "new-tor", published: false) }
      problem("Waiting", area: area)
      area
    end
    area.update!(published: true)
    CragSuggestion.create!(name: "New Tor", contributor_name: "Alex", state: "accepted", area: area, location: FACTORY.point(-3.9, 50.6))

    result = digest
    assert_equal [ "New Tor" ], result[:areas].map { |a| a[:name] }
    assert_equal({ kind: "visitor", name: "Alex", source: "crag suggestion" }, result[:areas].first[:credit])
    assert_equal 1, result[:areas].first[:problems]
    assert_includes result[:problems].map { |p| p[:name] }, "Waiting"
    assert_not_includes result[:areas].map { |a| a[:name] }, "Old Tor"
  end

  test "features the public photo with the most new lines, numbered left to right" do
    busy = topo
    right = problem("Right")
    left = problem("Left")
    Line.create!(problem: right, topo: busy, coordinates: LINE.map { |p| p.merge("x" => p["x"] + 0.4) })
    Line.create!(problem: left, topo: busy, coordinates: LINE)
    Line.create!(problem: problem("Elsewhere"), topo: topo, coordinates: LINE)
    PhotoContribution.new(area: @area, state: "accepted", contributor_name: "Pat", topo: busy).save!(validate: false)

    featured = digest[:featured_topo]
    assert_equal busy.id, featured[:id]
    assert_equal({ kind: "visitor", name: "Pat", source: "photo" }, featured[:credit])
    assert_equal [ [ 1, "Left" ], [ 2, "Right" ] ], featured[:lines].map { |l| [ l[:number], l[:problem] ] }
  end

  test "no featured photo when no lines were drawn" do
    assert_nil digest[:featured_topo]
  end

  test "the post image is 1080x1350 with the lines drawn on the photo" do
    photo = topo(width: 600, height: 900)
    Line.create!(problem: problem("Drawn", grade: "6b"), topo: photo, coordinates: LINE)

    image = NewsDigest::Image.new(topo: photo, headline: "1 new problem", credit: "Sam <& co>").image
    assert_equal [ 1080, 1350, 3 ], [ image.width, image.height, image.bands ]
    # The red 6b line runs through the middle of the photo, which is otherwise flat grey
    assert image.crop(0, 0, 1080, 1110).extract_band(0).max > 200
    # The SVG loader is blocked again afterwards, for uploads
    assert_raises(Vips::Error) { Vips::Image.svgload_buffer("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/>") }
  end
end
