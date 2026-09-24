class Admin::PoiRoutesController < Admin::BaseController
  before_action :require_super_admin, only: [ :index ]
  before_action :require_poi_route_area_access, except: [ :index ]

  def index
    @poi_routes = PoiRoute.order(:id)
  end

  def new
    @poi_route = PoiRoute.new(area_id: params[:area_id])
  end

  def create
    poi_route = PoiRoute.create!(poi_route_params)

    flash[:notice] = "Poi route created"
    redirect_to edit_admin_poi_route_path(poi_route)
  end

  def edit
    set_poi_route
  end

  def update
    set_poi_route

    if @poi_route.update(poi_route_params)
      flash[:notice] = "Poi route updated"
      redirect_to edit_admin_poi_route_path(@poi_route)
    else
      flash[:error] = @poi_route.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  private

  # Checks the route's current area and, on create/update, the area it's being moved to.
  def require_poi_route_area_access
    area_ids = [
      (PoiRoute.find(params[:id]).area_id if params[:id]),
      params[:area_id],
      params.dig(:poi_route, :area_id)
    ].compact_blank

    forbidden = Area.where(id: area_ids).find { |area| !current_admin_user.can_access_area?(area.slug) }
    require_area_access(forbidden.slug) if forbidden
  end

  def poi_route_params
    params.require(:poi_route).
      permit(:distance, :transport, :area_id, :poi_id)
  end

  def set_poi_route
    @poi_route = PoiRoute.find(params[:id])
  end
end
