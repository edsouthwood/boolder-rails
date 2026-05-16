class Admin::LinesController < Admin::BaseController
  before_action :require_line_area_access,     only: [:show, :edit, :update, :destroy]
  before_action :require_new_line_area_access, only: [:new, :create]

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

    if @line.update(coordinates: coordinates)
      auto_close_contribution_request(@line)

      flash[:notice] = "Line updated"
      redirect_to edit_admin_line_path(@line)
    else
      flash[:error] = @line.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  def create
    @line = Line.new(line_params)

    if @line.save
      auto_close_contribution_request(@line)

      if params[:use_gps_location] == "1" && params[:gps_lat].present? && params[:gps_lon].present?
        @line.problem.update(lat: params[:gps_lat], lon: params[:gps_lon])
      end

      flash[:notice] = "Line created"
      redirect_to edit_admin_line_path(@line)
    else
      @line.build_topo
      @area_topos = area_topos_for(@line.problem)
      flash[:error] = @line.errors.full_messages.join("; ")
      render "new", status: :unprocessable_entity
    end
  end

  def destroy
    line = Line.find(params[:id])
    line.destroy!

    flash[:notice] = "Line destroyed"
    redirect_to admin_problem_path(line.problem)
  end

  private

  def require_line_area_access
    require_area_access(Line.find(params[:id]).problem.area.slug)
  end

  def require_new_line_area_access
    problem_id = params[:problem_id] || params.dig(:line, :problem_id)
    require_area_access(Problem.find(problem_id).area.slug) if problem_id.present?
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
    topo_ids = Line.joins(:problem)
                   .where(problems: { area_id: problem.area_id })
                   .pluck(:topo_id)
                   .uniq
    Topo.where(id: topo_ids).order(id: :desc)
  end
end
