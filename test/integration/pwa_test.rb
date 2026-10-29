require "test_helper"

class PwaTest < ActionDispatch::IntegrationTest
  test "manifest is installable and its icons and screenshots exist" do
    get pwa_manifest_path
    assert_response :success

    manifest = JSON.parse(response.body)
    assert_equal "standalone", manifest["display"]
    assert_equal "/en", manifest["start_url"]

    sizes = manifest["icons"].map { |icon| [ icon["sizes"], icon["purpose"] ] }
    assert_includes sizes, [ "192x192", "any" ]
    assert_includes sizes, [ "512x512", "any" ]
    assert_includes sizes, [ "512x512", "maskable" ]

    (manifest["icons"] + manifest["screenshots"]).each do |image|
      path = Rails.public_path.join(image["src"].delete_prefix("/"))
      assert path.exist?, "#{image["src"]} is missing"
      width, height = image["sizes"].split("x").map(&:to_i)
      assert_equal [ width, height ], Vips::Image.new_from_file(path.to_s).then { |img| [ img.width, img.height ] },
        "#{image["src"]} is not #{image["sizes"]}"
    end
  end

  test "home page links the manifest, registers the service worker and offers install" do
    get root_localized_path(locale: :en)

    assert_select "link[rel=manifest][href='/manifest']"
    assert_select "link[rel=apple-touch-icon][href='/apple-touch-icon.png']"
    assert_includes response.body, "serviceWorker.register('/service-worker.js'"
    assert_select "[data-controller=saved-areas]"
    assert_select "[data-controller=install-prompt]"
  end

  test "map page links the manifest and registers the service worker" do
    get map_path(locale: :en)

    assert_select "link[rel=manifest][href='/manifest']"
    assert_includes response.body, "serviceWorker.register('/service-worker.js'"
  end
end
