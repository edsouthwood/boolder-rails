require "test_helper"

class Admin::AccountsTest < ActionDispatch::IntegrationTest
  PASSWORD = "correct horse battery".freeze

  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_accounts, :accounts
      def accounts = { "oldadmin" => "credentials-password" }
    end
    Rails.cache.clear
    @mine = Area.create!(name: "Mine", slug: "mine", published: true)
    @theirs = Area.create!(name: "Theirs", slug: "theirs", published: false)
    @boss = AdminAccount.create!(username: "Boss", password: PASSWORD, role: "super_admin")
    @helper = AdminAccount.create!(username: "helper", password: PASSWORD, role: "area_admin", area_slugs: [ "mine" ])
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :accounts, :_real_accounts
      remove_method :_real_accounts
    end
    Rails.cache.clear
  end

  def basic(user, password = PASSWORD) = { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }

  def sign_in(user, password = PASSWORD)
    get admin_docs_url(locale: :en), headers: basic(user, password)
    assert_response :success
  end

  def signed_in? = (get(admin_docs_url(locale: :en)) && response.successful?)

  # ─── Signing in ────────────────────────────────────────────────────────────

  test "with a super admin in the database, logins use accounts (username in any case), not the credentials file" do
    sign_in "BOSS"
    assert @boss.reload.last_signed_in_at.present?
    delete admin_session_url(locale: :en)

    get admin_docs_url(locale: :en)
    get admin_docs_url(locale: :en), headers: basic("oldadmin", "credentials-password")
    assert_response :unauthorized
    get admin_docs_url(locale: :en), headers: basic("boss", "wrong password!!")
    assert_response :unauthorized
  end

  test "with no enabled super admin in the database, the credentials file still works" do
    AdminAccount.delete_all
    sign_in "oldadmin", "credentials-password"
    get admin_profile_url(locale: :en)
    assert_select "div", text: /comes from the server's credentials file/
  end

  test "a credentials session ends once database accounts take over" do
    AdminAccount.delete_all
    sign_in "oldadmin", "credentials-password"
    AdminAccount.create!(username: "boss", password: PASSWORD, role: "super_admin")
    assert_not signed_in?
  end

  test "area admins from the database only reach their areas, and can't manage accounts" do
    sign_in "helper"
    get admin_area_boulders_url(area_slug: "mine", locale: :en)
    assert_response :success
    get admin_area_boulders_url(area_slug: "theirs", locale: :en)
    assert_redirected_to admin_root_path(locale: :en)
    get admin_accounts_url(locale: :en)
    assert_redirected_to admin_root_path(locale: :en)
  end

  test "disabling an account signs it out straight away, on admin and public pages" do
    sign_in "helper"
    get area_url(slug: "theirs", locale: :en)
    assert_response :success, "admins see unpublished areas"

    @helper.update!(disabled: true)
    get area_url(slug: "theirs", locale: :en)
    assert_response :not_found
    assert_not signed_in?
    get admin_docs_url(locale: :en), headers: basic("helper")
    assert_response :unauthorized
  end

  # ─── Accounts page ─────────────────────────────────────────────────────────

  test "super admins add an admin with a generated password, shown once; it works straight away" do
    sign_in "boss"
    get admin_accounts_url(locale: :en)
    assert_select "td", text: /boss\s+\(you\)/

    post admin_accounts_url(locale: :en), params: { current_password: PASSWORD,
      admin_account: { username: "newbie", role: "area_admin", area_slugs: [ "", "mine" ], password: "" } }
    assert_redirected_to admin_accounts_path(locale: :en)
    follow_redirect!
    generated = css_select("code.select-all").first.text
    assert_equal 16, generated.length
    get admin_accounts_url(locale: :en)
    assert_select "code.select-all", count: 0

    newbie = AdminAccount.find_by!(username: "newbie")
    assert_equal [ "mine" ], newbie.area_slugs
    assert newbie.authenticate(generated)
    assert_equal "account created", newbie.audits.last.comment
  end

  test "changing accounts needs your own password" do
    sign_in "boss"
    post admin_accounts_url(locale: :en), params: { current_password: "nope",
      admin_account: { username: "sneaky", role: "super_admin", password: "long enough password" } }
    assert_response :unprocessable_entity
    assert_not AdminAccount.exists?(username: "sneaky")

    patch admin_account_url(@helper, locale: :en), params: { current_password: "nope", admin_account: { role: "super_admin" } }
    assert_response :unprocessable_entity
    assert_equal "area_admin", @helper.reload.role
  end

  test "resetting someone's password signs them out everywhere" do
    open_session do |helper_browser|
      helper_browser.get admin_docs_url(locale: :en), headers: basic("helper")
      helper_browser.assert_response :success

      sign_in "boss"
      patch admin_account_url(@helper, locale: :en), params: { current_password: PASSWORD, generate_password: "1", admin_account: { password: "" } }
      follow_redirect!
      new_password = css_select("code.select-all").first.text

      helper_browser.get admin_docs_url(locale: :en)
      helper_browser.assert_response :unauthorized
      assert @helper.reload.authenticate(new_password)
      assert_equal "password reset", @helper.audits.last.comment
    end
  end

  test "an area admin needs an area, and the areas must exist" do
    sign_in "boss"
    post admin_accounts_url(locale: :en), params: { current_password: PASSWORD,
      admin_account: { username: "nowhere", role: "area_admin", area_slugs: [ "" ], password: "long enough password" } }
    assert_response :unprocessable_entity
    assert_select "div.bg-red-50", text: /at least one area/
  end

  test "the last super admin can't be demoted or disabled, and you can't disable yourself" do
    sign_in "boss"
    patch admin_account_url(@boss, locale: :en), params: { current_password: PASSWORD, admin_account: { disabled: "1" } }
    assert_response :unprocessable_entity
    assert_select "div", text: /can't change your own role or disable yourself/

    other = AdminAccount.create!(username: "other", password: PASSWORD, role: "super_admin")
    other.update!(disabled: true)
    assert_not @boss.update(role: "area_admin", area_slugs: [ "mine" ])
    assert_match "only super admin left", @boss.errors.full_messages.to_sentence
  end

  test "only disabled accounts can be deleted" do
    sign_in "boss"
    delete admin_account_url(@helper, locale: :en), params: { current_password: PASSWORD }
    assert AdminAccount.exists?(@helper.id)

    @helper.update!(disabled: true)
    delete admin_account_url(@helper, locale: :en), params: { current_password: PASSWORD }
    assert_not AdminAccount.exists?(@helper.id)
  end

  # ─── My account ────────────────────────────────────────────────────────────

  test "changing your own password keeps you signed in here but signs out other browsers" do
    open_session do |phone|
      phone.get admin_docs_url(locale: :en), headers: basic("helper")
      phone.assert_response :success

      sign_in "helper"
      patch admin_profile_url(locale: :en), params: { current_password: PASSWORD, password: "a brand new password", password_confirmation: "a brand new password" }
      assert_redirected_to admin_profile_path(locale: :en)
      assert signed_in?

      phone.get admin_docs_url(locale: :en)
      phone.assert_response :unauthorized
      assert @helper.reload.authenticate("a brand new password")
    end
  end

  test "own password change checks the current password, the length and the confirmation" do
    sign_in "helper"
    patch admin_profile_url(locale: :en), params: { current_password: "wrong", password: "a brand new password", password_confirmation: "a brand new password" }
    assert_response :unprocessable_entity
    patch admin_profile_url(locale: :en), params: { current_password: PASSWORD, password: "short", password_confirmation: "short" }
    assert_select "div.bg-red-50", text: /too short/
    patch admin_profile_url(locale: :en), params: { current_password: PASSWORD, password: "a brand new password", password_confirmation: "different words here" }
    assert_select "div.bg-red-50", text: /doesn't match/
    assert @helper.reload.authenticate(PASSWORD)
  end
end
