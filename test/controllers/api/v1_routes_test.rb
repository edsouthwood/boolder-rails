require "test_helper"

class Api::V1RoutesTest < ActionDispatch::IntegrationTest
  test "only the topos endpoints exist under /api/v1/areas" do
    assert_recognizes({ controller: "api/v1/topos", action: "index", area_id: "1" }, "/api/v1/areas/1/topos")

    [ "/api/v1/areas", "/api/v1/areas/1", "/api/v1/areas/new", "/api/v1/areas/1/edit" ].each do |path|
      get path
      assert_response :not_found, path
    end
  end
end
