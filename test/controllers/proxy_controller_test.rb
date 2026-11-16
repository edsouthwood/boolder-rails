require "test_helper"
require "vips"

class ProxyControllerTest < ActionDispatch::IntegrationTest
  def jpeg(width, height)
    Vips::Image.black(width, height, bands: 3).add(120).cast(:uchar).jpegsave_buffer
  end

  def topo(width, height, uncropped:)
    area = Area.create!(name: "Proxy Area", slug: "proxy-area-#{SecureRandom.hex(3)}", published: true)
    problem = area.problems.create!(name: "Groove", steepness: "wall")
    topo = Topo.new(area: area, uncropped: uncropped)
    topo.photo.attach(io: StringIO.new(jpeg(width, height)), filename: "topo.jpg", content_type: "image/jpeg")
    topo.save!
    Line.create!(problem: problem, topo: topo, coordinates: [ { "x" => 0.1, "y" => 0.1 }, { "x" => 0.2, "y" => 0.2 }, { "x" => 0.3, "y" => 0.3 } ])
    topo
  end

  def served_size
    image = Vips::Image.new_from_buffer(response.body, "")
    [ image.width, image.height ]
  end

  test "an uncropped portrait photo is served whole, made on the spot if the background job hasn't run" do
    get topo_proxy_url(topo(1500, 2000, uncropped: true))

    assert_response :success
    assert_operator response.body.bytesize, :>, 0
    assert_equal [ 900, 1200 ], served_size
  end

  test "an older, cropped photo is still served as its 4:3 crop" do
    get topo_proxy_url(topo(1500, 2000, uncropped: false))

    assert_response :success
    assert_equal [ 1200, 900 ], served_size
  end
end
