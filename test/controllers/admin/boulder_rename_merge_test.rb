require "test_helper"

# Naming an outline after a listed (not yet drawn) boulder takes over its problems. Renaming
# it again to a second listed name must not quietly merge both lists' problems.
class Admin::BoulderRenameMergeTest < ActionDispatch::IntegrationTest
  ADMIN = AdminUser.new(username: "boss", role: "super_admin")

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
    end
    Admin::BaseController.define_method(:current_admin_user) { ADMIN }

    @area = Area.create!(name: "Rippon Tor", slug: "rippontor", published: true)
    d = 0.0001
    ring = [ [ -d, -d ], [ d, -d ], [ d, d ], [ -d, d ], [ -d, -d ] ].map { |x, y| FACTORY.point(-3.78 + x, 50.56 + y) }
    @outline = @area.boulders.create!(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    @summit = @area.boulders.create!(name: "Rippon Summit")
    @lookout = @area.boulders.create!(name: "Lookout Wall")
    @angela = @area.problems.create!(name: "Angela", steepness: "wall", boulder: @summit)
    @nice = @area.problems.create!(name: "Nice", steepness: "wall", boulder: @lookout)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def name!(name, merge = nil)
    patch admin_boulder_path(@outline), params: { name: name, merge: merge }.compact, as: :json
  end

  test "renaming to a second listed name asks first and changes nothing" do
    name! "Rippon Summit"
    assert_response :success
    name! "Lookout Wall"

    assert_response :conflict
    assert_equal({ "needs_choice" => true, "current" => "Rippon Summit", "current_problems" => 1, "target" => "Lookout Wall", "target_problems" => 1 }, response.parsed_body)
    assert_equal "Rippon Summit", @outline.reload.name
    assert_equal @outline, @angela.reload.boulder
    assert_equal @lookout, @nice.reload.boulder
    assert Boulder.exists?(@lookout.id)
  end

  test "swap: the outline takes the new name and its problems; the old name goes back on the list" do
    name! "Rippon Summit"
    name! "Lookout Wall", "swap"

    assert_response :success
    relisted = response.parsed_body["relisted"]
    assert_equal "Rippon Summit", relisted["name"]
    assert_equal 1, relisted["problems"]
    assert_equal "Lookout Wall", @outline.reload.name
    assert_equal [ @nice ], @outline.problems.to_a
    listed = Boulder.find(relisted["id"])
    assert_not listed.placed?
    assert_equal [ @angela ], listed.problems.to_a

    # and the relisted name can be given to another outline
    other = @area.boulders.create!(polygon: @outline.polygon)
    patch admin_boulder_path(other), params: { name: "Rippon Summit" }, as: :json
    assert_response :success
    assert_equal [ @angela ], other.reload.problems.to_a
  end

  test "merge keeps both lots of problems on the outline, as before" do
    name! "Rippon Summit"
    name! "Lookout Wall", "merge"

    assert_response :success
    assert_equal "Lookout Wall", @outline.reload.name
    assert_equal [ @angela, @nice ].sort_by(&:id), @outline.problems.order(:id).to_a
  end

  test "naming a fresh outline, or renaming to a name that isn't listed, doesn't ask" do
    name! "Rippon Summit"
    assert_response :success
    name! "Something New"
    assert_response :success
    assert_equal "Something New", @outline.reload.name
  end

  test "photo ties follow a merged name, and are cleared when an outline is deleted" do
    topo = Topo.new(area: @area, metadata: { "chosen_boulder_id" => @summit.id, "suggested_boulder_id" => @summit.id })
    topo.photo.attach(io: StringIO.new("x"), filename: "t.jpg", content_type: "image/jpeg")
    topo.save!

    name! "Rippon Summit"
    assert_equal @outline.id, topo.reload.chosen_boulder_id
    assert_equal @outline.id, topo.suggested_boulder_id

    delete admin_boulder_path(@outline), as: :json
    assert_nil topo.reload.chosen_boulder_id
    assert_nil topo.suggested_boulder_id
  end
end
