require "test_helper"

class DiffHelperTest < ActionView::TestCase
  test "escapes both sides of the diff" do
    html = word_diff_html("<b>new</b>", "<img src=x onerror=alert(1)>")

    assert_no_match "<img", html
    assert_no_match "<b>", html
    assert_match "&lt;", html
    assert_match "<ins class=\"differ\">", html
  end
end
