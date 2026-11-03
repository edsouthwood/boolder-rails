require "test_helper"

class PhotoContributionTest < ActiveSupport::TestCase
  setup do
    @area = Area.create!(name: "Photo Tor", slug: "photo-tor", published: true)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.9 + x, 50.6 + y) }
    @boulder = @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)), name: "The Block")
  end

  def build(**attrs)
    pc = PhotoContribution.new(area: @area, **attrs)
    pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
    pc
  end

  test "needs a photo, and only a JPEG, PNG or WebP one" do
    assert_not PhotoContribution.new(area: @area).valid?

    pc = PhotoContribution.new(area: @area)
    pc.photo.attach(io: StringIO.new("<svg/>"), filename: "x.svg", content_type: "image/svg+xml")
    assert_not pc.valid?
    assert build.valid?
  end

  test "rejects a malformed batch id or email" do
    assert_not build(batch: "not-a-uuid").valid?
    assert_not build(contributor_email: "nope").valid?
    assert build(batch: SecureRandom.uuid, contributor_email: "a@b.com").valid?
  end

  test "only the first photo of a batch is the one emailed about" do
    batch = SecureRandom.uuid
    first = build(batch: batch).tap(&:save!)
    second = build(batch: batch).tap(&:save!)

    assert first.first_in_batch?
    assert_not second.first_in_batch?
    assert build.tap(&:save!).first_in_batch?, "no batch: always emailed about"
  end

  test "accepting moves the photo onto a new undrawn topo with the inbox metadata" do
    pc = build(location: FACTORY.point(-3.9, 50.6002), heading: 90.0, boulder: @boulder, location_source: "photo")
    pc.save!
    blob = pc.photo.blob

    topo = pc.accept!(reviewed_by: "ed")

    assert topo.persisted?
    assert_equal blob, topo.photo.blob, "the file moves rather than being copied"
    assert_equal @area.id, topo[:area_id]
    assert_equal({ "source" => "contribution", "photo_contribution_id" => pc.id, "latitude" => 50.6002,
                   "longitude" => -3.9, "heading" => 90.0, "suggested_boulder_id" => @boulder.id }, topo.metadata)
    assert_includes Topo.in_area(@area).undrawn, topo

    pc.reload
    assert pc.accepted?
    assert_equal topo, pc.topo
    assert_equal "ed", pc.reviewed_by
    assert_not pc.photo.attached?
    assert_equal topo.photo.blob, pc.display_photo.blob
    assert ActiveStorage::Blob.exists?(blob.id)
  end

  test "accepting twice does nothing the second time" do
    pc = build.tap(&:save!)
    assert pc.accept!(reviewed_by: "ed")
    assert_no_difference -> { Topo.count } do
      assert_nil pc.accept!(reviewed_by: "ed")
    end
  end

  test "declining keeps the photo and records the note" do
    pc = build.tap(&:save!)
    pc.close!(reviewed_by: "ed", note: "Blurry")

    assert pc.reload.closed?
    assert_equal "Blurry", pc.moderator_note
    assert pc.photo.attached?
  end

  test "area admins can only review photos in their areas" do
    other = Area.create!(name: "Elsewhere", slug: "elsewhere", published: true)
    mine = build.tap(&:save!)
    theirs = PhotoContribution.new(area: other).tap { |pc| pc.photo.attach(io: StringIO.new("x"), filename: "a.jpg", content_type: "image/jpeg") }
    theirs.save!

    area_admin = AdminUser.new(username: "a", role: "area_admin", areas: [ "photo-tor" ])
    assert_equal [ mine ], PhotoContribution.reviewable_by(area_admin).to_a
    assert_equal 2, PhotoContribution.reviewable_by(AdminUser.new(username: "s", role: "super_admin")).count
  end

  test "accepted photos count towards the top contributors" do
    build(contributor_name: "Ann").tap(&:save!).accept!(reviewed_by: "ed")
    build(contributor_name: "ann ").tap(&:save!).accept!(reviewed_by: "ed")
    build(contributor_name: "Bob").tap(&:save!) # pending: doesn't count
    problem = @area.problems.create!(steepness: "slab")
    Contribution.create!(state: "accepted", problem: problem, comment: "x", contributor_name: "Bob")

    counts = Contribution.top_contributors.map { |c| [ c.display_name.strip.downcase, c.contributions_count ] }
    assert_equal [ [ "ann", 2 ], [ "bob", 1 ] ], counts
  end
end
