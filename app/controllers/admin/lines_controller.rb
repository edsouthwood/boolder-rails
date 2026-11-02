class Admin::LinesController < Admin::BaseController
  before_action :require_line_area_access,     only: [ :show, :edit, :update, :destroy ]
  before_action :require_new_line_area_access, only: [ :new, :create ]

  def edit
    set_line

    session[:last_topo_visited] = @line.topo.id
  end

  def show
    set_line
    redirect_to edit_admin_line_path(@line)
  end

  def new
    problem = Problem.find(params[:problem_id])

    @line = Line.new(problem_id: problem.id)
    @line.build_topo # for topo nested attributes (photo)
    @area_topos = area_topos_for(problem)
  end

  def update
    set_line

    coordinates = JSON.parse(params[:line][:coordinates])
    start_holds = params[:line][:start_holds].presence && JSON.parse(params[:line][:start_holds])
    excluded_areas = params[:line][:excluded_areas].presence && JSON.parse(params[:line][:excluded_areas])

    if @line.update(coordinates: coordinates, start_holds: start_holds, excluded_areas: excluded_areas)
      auto_close_contribution_request(@line)

      respond_to do |format|
        format.html do
          flash[:notice] = "Line updated"
          redirect_to edit_admin_line_path(@line)
        end
        format.json { render json: @line.workbench_json }
      end
    else
      respond_to do |format|
        format.html do
          flash[:error] = @line.errors.full_messages.join("; ")
          render "edit", status: :unprocessable_entity
        end
        format.json { render json: { error: @line.errors.full_messages.join("; ") }, status: :unprocessable_entity }
      end
    end
  rescue JSON::ParserError
    message = "Coordinates, start holds and not-in areas must be valid JSON"
    respond_to do |format|
      format.html do
        flash.now[:error] = message
        render "edit", status: :unprocessable_entity
      end
      format.json { render json: { error: message }, status: :unprocessable_entity }
    end
  end

  def create
    @line = Line.new(line_params)

    if @line.save
      auto_close_contribution_request(@line)

      if params[:use_gps_location] == "1" && params[:gps_lat].present? && params[:gps_lon].present?
        @line.problem.update(lat: params[:gps_lat], lon: params[:gps_lon])
      else
        locate_on_photos_boulder(@line)
      end

      respond_to do |format|
        format.html do
          flash[:notice] = "Line created"
          redirect_to edit_admin_line_path(@line)
        end
        format.json { render json: @line.workbench_json, status: :created }
      end
    else
      respond_to do |format|
        format.html do
          @line.build_topo
          @area_topos = area_topos_for(@line.problem)
          flash[:error] = @line.errors.full_messages.join("; ")
          render "new", status: :unprocessable_entity
        end
        format.json { render json: { error: @line.errors.full_messages.join("; ") }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    line = Line.find(params[:id])
    line.destroy!

    respond_to do |format|
      format.html do
        flash[:notice] = "Line destroyed"
        redirect_to admin_problem_path(line.problem)
      end
      format.json { head :no_content }
    end
  end

  private

  # A problem drawn on a photo for the first time with no location of its own gets one on
  # the photo's boulder, unless a problem list put it on a different boulder
  def locate_on_photos_boulder(line)
    problem, topo = line.problem, line.topo
    return if problem.location.present? || topo.nil?
    return if problem.boulder_id && problem.boulder_id != topo.matched_boulder_id

    point = topo.location_on_boulder
    problem.update(location: point) if point
  end

  def require_line_area_access
    require_area_access(Line.find(params[:id]).problem.area.slug)
  end

  def require_new_line_area_access
    problem_id = params[:problem_id] || params.dig(:line, :problem_id)
    require_area_access(Problem.find(problem_id).area.slug) if problem_id.present?
    return if performed?

    # An existing photo must be in an area this admin can access too
    topo_area_id = params.dig(:line, :topo_id).presence && Topo.find(params[:line][:topo_id]).area_id
    require_area_access(Area.find(topo_area_id).slug) if topo_area_id
  end

  def line_params
    params.require(:line).permit(:problem_id, :topo_id, topo_attributes: [ :photo ])
  end

  def set_line
    @line = Line.find(params[:id])
  end

  def auto_close_contribution_request(line)
    line.problem.contribution_requests.open.first&.update(state: "closed")
  end

  def area_topos_for(problem)
    return [] unless problem
    Topo.in_area(problem.area).order(id: :desc)
  end
end
