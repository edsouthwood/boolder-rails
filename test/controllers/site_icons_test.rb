require "test_helper"

# Icon files are cached for a year at fixed URLs, so pages link them with a version
# (ApplicationHelper::ICON_VERSION) to make browsers pick up new icons.
class SiteIconsTest < ActionDispatch::IntegrationTest
  test "pages and the app manifest link versioned icons" do
    v = "?v=#{ApplicationHelper::ICON_VERSION}"
    area = Area.create!(name: "Bonehill", slug: "bonehill", published: true)

    [ root_localized_url(locale: :en), area_url(area.slug, locale: :en), map_url(locale: :en), area_print_url(area.slug, locale: :en) ].each do |url|
      get url
      assert_select "link[rel=icon][href=?]", "/icon.svg#{v}", 1, url
      assert_select "link[rel=icon][href=?]", "/favicon.ico#{v}", 1, url
      assert_select "link[rel=apple-touch-icon][href=?]", "/apple-touch-icon.png#{v}", 1, url
    end

    get "/manifest"
    icons = JSON.parse(response.body)["icons"].map { |icon| icon["src"] }
    assert icons.all? { |src| src.end_with?(v) }, icons.inspect
  end
end
