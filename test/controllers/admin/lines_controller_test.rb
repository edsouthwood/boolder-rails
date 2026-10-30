require "test_helper"

class Admin::LinesControllerTest < ActionDispatch::IntegrationTest
  AREA_ADMIN = AdminUser.new(username: "local", role: "area_admin", areas: [ "mine" ])
  COORDINATES = [ { "x" => 0.2, "y" => 0.9 }, { "x" => 0.3, "y" => 0.5 }, { "x" => 0.4, "y" => 0.1 } ].freeze
  HOLDS = [ { "x" => 0.18, "y" => 0.86 }, { "x" => 0.25, "y" => 0.84 } ].freeze

  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { AREA_ADMIN }
    end

    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: true)
    @line = line_in(@mine)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  def line_in(area)
    topo = Topo.new
    topo.photo.attach(io: StringIO.new("fake image"), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: area.problems.create!(steepness: "wall"), topo: topo, coordinates: COORDINATES)
  end

  def update_line(line, start_holds)
    patch admin_line_url(line, locale: :en), params: { line: { coordinates: COORDINATES.to_json, start_holds: start_holds } }
  end

  test "saves start holds" do
    update_line(@line, HOLDS.to_json)

    assert_redirected_to edit_admin_line_path(@line)
    assert_equal HOLDS, @line.reload.start_holds
  end

  test "blank start holds clears them" do
    @line.update!(start_holds: HOLDS)
    update_line(@line, "")

    assert_nil @line.reload.start_holds
  end

  test "malformed JSON re-renders the editor instead of erroring" do
    update_line(@line, "[{x:")

    assert_response :unprocessable_entity
    assert_nil @line.reload.start_holds
  end

  test "area admin cannot set start holds in another area" do
    their_line = line_in(@theirs)
    update_line(their_line, HOLDS.to_json)

    assert_redirected_to admin_root_path
    assert_nil their_line.reload.start_holds
  end
end
