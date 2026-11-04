require "test_helper"
require "rake"

class AdminAccountsImportTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("admin:import_accounts")
    Area.create!(name: "Bonehill", slug: "bonehill")
    credentials = Rails.application.credentials
    credentials.define_singleton_method(:admin_accounts) do
      { ed: "old-short", Bob: { password: "bobs password here", role: "area_admin", areas: [ "bonehill" ] } }
    end
  end

  teardown do
    Rails.application.credentials.singleton_class.remove_method(:admin_accounts)
    Rake::Task["admin:import_accounts"].reenable
  end

  test "copies credentials accounts with their roles, areas and passwords, once" do
    out, = capture_io { Rake::Task["admin:import_accounts"].invoke }

    ed = AdminAccount.find_by!(username: "ed")
    bob = AdminAccount.find_by!(username: "bob")
    assert ed.super_admin?
    assert ed.authenticate("old-short"), "existing passwords keep working, even short ones"
    assert_equal [ "bonehill" ], bob.area_slugs
    assert bob.authenticate("bobs password here")
    assert_match "password is short", out
    assert_match "Logins now use Admin → Accounts", out

    Rake::Task["admin:import_accounts"].reenable
    out, = capture_io { Rake::Task["admin:import_accounts"].invoke }
    assert_match "skip ed", out
    assert_equal 2, AdminAccount.count
  end
end
