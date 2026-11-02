# Photo inbox: upload many topo photos into an area at once, ready for lines to be drawn.
# The browser reads each photo's GPS (exifr) and posts the files one by one.
class Admin::PhotosController < Admin::BaseController
  before_action :set_area_and_check_access

  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_SIZE = 25.megabytes
  # How far from a boulder outline a photo can be taken and still be matched to it
  BOULDER_MATCH_METRES = 15

  def new
    @undrawn_count = Topo.in_area(@area).undrawn.count
  end

  def create
    photo = params[:photo]
    unless photo.respond_to?(:content_type) && CONTENT_TYPES.include?(photo.content_type) && photo.size <= MAX_SIZE
      return render json: { error: "Must be a JPEG, PNG or WebP photo under #{MAX_SIZE / 1.megabyte} MB" }, status: :unprocessable_entity
    end

    lat, lon, heading = gps_params
    boulder = nearest_boulder(lat, lon)
    topo = Topo.new(area: @area, photo: photo, metadata: {
      "source" => "inbox", "latitude" => lat, "longitude" => lon, "heading" => heading,
      "suggested_boulder_id" => boulder&.id
    }.compact)

    if topo.save
      render json: { id: topo.id, suggested_boulder_id: boulder&.id, edit_url: workbench_admin_topo_path(topo) }, status: :created
    else
      render json: { error: topo.errors.full_messages.join("; ") }, status: :unprocessable_entity
    end
  end

  private

  def set_area_and_check_access
    @area = Area.find_by!(slug: params[:area_slug])
    require_area_access(@area.slug)
  end

  def gps_params
    lat = Float(params[:lat], exception: false)
    lon = Float(params[:lon], exception: false)
    heading = Float(params[:heading], exception: false)
    return [ nil, nil, nil ] unless lat&.between?(-90, 90) && lon&.between?(-180, 180)

    [ lat, lon, heading&.between?(0, 360) ? heading : nil ]
  end

  def nearest_boulder(lat, lon)
    return if lat.nil?

    point = Boulder.sanitize_sql_array([ "ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography", lon, lat ])
    @area.boulders.placed.
      where("ST_DWithin(boulders.polygon, #{point}, ?)", BOULDER_MATCH_METRES).
      order(Arel.sql("ST_Distance(boulders.polygon, #{point})")).
      first
  end
end
