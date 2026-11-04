# Admin logins, managed from Admin → Accounts. Passwords are bcrypt hashes. Replaces the
# admin_accounts credentials list, which stays as an emergency fallback (see
# Admin::BaseController#database_accounts?).
class CreateAdminAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_accounts do |t|
      t.string :username, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "area_admin"
      t.string :area_slugs, array: true, null: false, default: []
      t.integer :session_version, null: false, default: 0 # bumped to sign the account out everywhere
      t.datetime :disabled_at
      t.datetime :last_signed_in_at
      t.timestamps
    end
    add_index :admin_accounts, :username, unique: true
  end
end
