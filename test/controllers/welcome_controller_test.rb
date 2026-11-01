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

  test "footer credits Boolder and links to the About page thanks" do
    get root_localized_url(locale: :en)
    assert_select "footer a[href='https://www.boolder.com']", text: "Boolder"
    assert_select "footer a[href$='#thanks']", text: /original Boolder team/
  end

  test "about page has the thanks anchor the footer links to" do
    get about_url(locale: :en)
    assert_select "section#thanks", text: /Thank you, Boolder/
  end
end
