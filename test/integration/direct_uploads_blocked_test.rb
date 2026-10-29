require "test_helper"

class DirectUploadsBlockedTest < ActionDispatch::IntegrationTest
  test "direct upload endpoint is blocked" do
    assert_no_difference "ActiveStorage::Blob.count" do
      post "/rails/active_storage/direct_uploads", params: {
        blob: { filename: "x.png", byte_size: 4, checksum: "abc", content_type: "image/png" }
      }, as: :json
    end

    assert_response :forbidden
  end

  test "disk upload endpoint is blocked" do
    put "/rails/active_storage/disk/sometoken", params: "data"

    assert_response :forbidden
  end

  test "untrusted libvips loaders are blocked" do
    error = assert_raises(Vips::Error) { Vips::Image.matload("nonexistent.mat") }
    assert_match(/blocked/i, error.message)
  end
end
