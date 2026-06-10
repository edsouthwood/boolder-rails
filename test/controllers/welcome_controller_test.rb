require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  test "root redirects to a localized home page" do
    get root_url
    assert_response :redirect
  end

  test "should get the localized home page" do
    get root_localized_url(locale: :en)
    assert_response :success
  end
end
