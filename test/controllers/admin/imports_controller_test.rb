require "test_helper"

class Admin::ImportsControllerTest < ActionDispatch::IntegrationTest
  SUPER_ADMIN = AdminUser.new(username: "local", role: "super_admin", areas: [])

  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      define_method(:current_admin_user) { SUPER_ADMIN }
    end

    @area = Area.create!(name: "Imported", slug: "imported", published: true)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  test "an applied import still shows after a record it changed is deleted" do
    import = Import.create!(applied_at: Time.current)
    kept = boulder_from(import, offset: 0)
    deleted = boulder_from(import, offset: 1)
    deleted_id = deleted.id
    Boulder.find(deleted_id).destroy! # deleted later, outside the import

    get admin_import_path(import)

    assert_response :success
    assert_select "td", text: "Boulder ##{kept.id}"
    assert_select "td", text: /Boulder ##{deleted_id}\s+\(since deleted\)/
  end

  test "a deletion recorded against an import is shown, not diffed" do
    import = Import.create!(applied_at: Time.current)
    boulder = boulder_from(import, offset: 0)
    boulder.destroy! # still carries the import, so this audit is associated with it

    get admin_import_path(import)

    assert_response :success
    assert_select "span", text: "deleted"
  end

  private

  # A boulder created as part of the import, so its audit is associated with it.
  def boulder_from(import, offset:)
    ring = [ [ 0, 0 ], [ 0, 1 ], [ 1, 1 ], [ 1, 0 ], [ 0, 0 ] ].map { |x, y| FACTORY.point(-3.8 + offset + x * 0.0001, 50.6 + y * 0.0001) }
    boulder = @area.boulders.new(polygon: FACTORY.polygon(FACTORY.linear_ring(ring)))
    boulder.import = import
    boulder.save!
    boulder
  end
end
