class Admin::BouldersController < Admin::BaseController
  before_action :set_area_from_slug, only: [:editor, :create]
  before_action :set_boulder,        only: [:update, :destroy]

  def editor
    @boulder_count = @area.boulders.count
  end

  def create
    boulder = @area.boulders.build(polygon: build_polygon(params[:coordinates]))
    boulder.save!
    render json: { id: boulder.id }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    @boulder.update!(polygon: build_polygon(params[:coordinates]))
    render json: { ok: true }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @boulder.destroy!
    render json: { ok: true }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_area_from_slug
    @area = Area.find_by!(slug: params[:area_slug])
  end

  def set_boulder
    @boulder = Boulder.find(params[:id])
  end

  def build_polygon(coordinates)
    pts = Array(coordinates).map { |c| FACTORY.point(c[0].to_f, c[1].to_f) }
    raise ArgumentError, "At least 3 points required" if pts.size < 3
    pts << pts.first unless pts.last.x == pts.first.x && pts.last.y == pts.first.y
    FACTORY.polygon(FACTORY.linear_ring(pts))
  end
end
