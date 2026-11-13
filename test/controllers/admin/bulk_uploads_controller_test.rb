require "test_helper"

class Admin::BulkUploadsControllerTest < ActionDispatch::IntegrationTest
  # Bypass HTTP-basic admin auth without depending on credentials (so it works in CI too).
  setup do
    Admin::BaseController.class_eval do
      alias_method :_real_authenticate, :authenticate
      alias_method :_real_current_admin_user, :current_admin_user
      def authenticate = true
      def current_admin_user = AdminUser.new(username: "tester", role: "super_admin")
    end

    @area = Area.create!(name: "Upload Area", slug: "upload-area", published: true)
  end

  teardown do
    Admin::BaseController.class_eval do
      alias_method :authenticate, :_real_authenticate
      alias_method :current_admin_user, :_real_current_admin_user
      remove_method :_real_authenticate
      remove_method :_real_current_admin_user
    end
  end

  test "links each uploaded topo to its problem" do
    csv = Rack::Test::UploadedFile.new(StringIO.new("name,grade,image_filename\nArete,6a,arete.jpg\n"), "text/csv", original_filename: "problems.csv")
    image = Rack::Test::UploadedFile.new(StringIO.new("fake image"), "image/jpeg", original_filename: "arete.jpg")

    post admin_bulk_uploads_url, params: { area_id: @area.id, csv_file: csv, images: [ image ] }
    assert_redirected_to new_admin_bulk_upload_path

    problem = @area.problems.find_by!(name: "Arete")
    assert_equal 1, problem.lines.count
    assert problem.lines.first.topo.photo.attached?
  end

  test "a row with a mistyped or half-given location is reported and nothing is saved" do
    { "abc,-3.93" => /Row 2 \(Arete\): Latitude must be a number/,
      "50.57," => /Row 2 \(Arete\): Latitude and longitude go together/ }.each do |location, message|
      csv = Rack::Test::UploadedFile.new(StringIO.new("name,grade,lat,lon\nArete,6a,#{location}\n"), "text/csv", original_filename: "problems.csv")
      assert_no_difference "Problem.count" do
        post admin_bulk_uploads_url, params: { area_id: @area.id, csv_file: csv }
      end
      assert_match message, flash[:error]
    end
  end

  test "a row with a location places the problem" do
    csv = Rack::Test::UploadedFile.new(StringIO.new("name,grade,lat,lon\nArete,6a, 50.57 ,-3.93\n"), "text/csv", original_filename: "problems.csv")
    post admin_bulk_uploads_url, params: { area_id: @area.id, csv_file: csv }

    problem = @area.problems.find_by!(name: "Arete")
    assert_equal [ 50.57, -3.93 ], [ problem.lat, problem.lon ]
  end
end
