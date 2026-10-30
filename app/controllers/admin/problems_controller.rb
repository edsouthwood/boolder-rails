class Admin::ProblemsController < Admin::BaseController
  before_action :require_index_area_access,   only: [ :index, :map_editor ]
  before_action :require_problem_area_access, only: [ :new, :create, :show, :edit, :update, :destroy ]

  def index
    @area = Area.find_by(slug: params[:area_slug])

    if params[:circuit_id] == "first" && (id = @area.sorted_circuits.first&.id)
      redirect_to admin_area_problems_path(area_slug: @area.slug, circuit_id: id)
    end

    arel = Problem.where(area_id: @area.id)

    arel = if params[:circuit_id].to_i > 0
      arel.where(circuit_id: params[:circuit_id]).sort_by(&:enumerable_circuit_number) if params[:circuit_id].present?
    else
      arel.order("ascents DESC NULLS LAST")
    end

    arel = if params[:missing] == "line"
      arel.without_line_only
    elsif params[:missing] == "location"
      arel.without_location
    else
      arel
    end

    @problems = sort_problems(arel)

    circuits = @area.sorted_circuits
    @circuit_tabs = circuits.map { |c| [ c.id, c.name ] }.push([ nil, "All" ])

    @missing_grade = @area.problems.where("grade IS NULL OR grade = ''")
  end

  def new
    area = Area.find(params[:area_id])

    @problem = Problem.new(steepness: :other)

    @problem.area = area
    @circuits = area.sorted_circuits
  end

  def create
    @problem = Problem.new
    @problem.assign_attributes(problem_params)

    if @problem.save
      flash[:notice] = "Problem created"
      redirect_to [ :admin, @problem ]
    else
      @circuits = @problem.area&.sorted_circuits || []
      flash.now[:error] = @problem.errors.full_messages.join(", ")
      render :new, status: :unprocessable_entity
    end
  end

  def show
    set_problem
  end

  def edit
    set_problem
  end

  def destroy
    set_problem
    area = @problem.area
    @problem.destroy!
    flash[:notice] = "Problem deleted"
    redirect_to admin_area_problems_path(area_slug: area.slug)
  end

  def map_editor
    @area = Area.find_by!(slug: params[:area_slug])
    @unlocated_problems = @area.problems.without_location.order(:name)
  end

  def update
    set_problem

    @problem.assign_attributes(problem_params)

    if @problem.save
      respond_to do |format|
        format.html do
          flash[:notice] = "Problem updated"
          redirect_to admin_problem_path(@problem)
        end
        format.json { render json: { ok: true } }
      end
    else
      respond_to do |format|
        format.html do
          flash[:error] = @problem.errors.full_messages.join("; ")
          render "edit", status: :unprocessable_entity
        end
        format.json { render json: { errors: @problem.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  private

  def require_index_area_access
    area = Area.find_by(slug: params[:area_slug])
    require_area_access(area.slug) if area
  end

  # Checks the problem's current area and, on create/update, the area it's being put in
  # (otherwise an area admin could move one of their problems into any area).
  def require_problem_area_access
    areas = [
      (Problem.find(params[:id]).area if params[:id]),
      (Area.find(params[:problem][:area_id]) if params.dig(:problem, :area_id).present?),
      (Area.find(params[:area_id]) if params[:area_id].present?)
    ].compact

    forbidden = areas.find { |area| !current_admin_user.can_access_area?(area.slug) }
    require_area_access(forbidden.slug) if forbidden
  end

  def problem_params
    params.require(:problem).
      permit(:area_id, :name, :grade, :steepness, :sit_start,
        :ukc_url, :parent_id,
        :lat, :lon, :description,
      )
  end

  def set_problem
    @problem = Problem.find(params[:id])
    @circuits = @problem.area.sorted_circuits
  end

  # Column sorting for the area problems list (?sort=name&dir=desc); without a sort param the
  # list keeps its default order (popularity, or circuit order on a circuit tab).
  SORTABLE_COLUMNS = {
    "id" => ->(p) { p.id },
    "name" => ->(p) { p.name_with_fallback.to_s.downcase.presence },
    "grade" => ->(p) { Problem.grade_rank(p.grade) },
    "steepness" => ->(p) { p.steepness }
  }.freeze

  def sort_problems(problems)
    key = SORTABLE_COLUMNS[params[:sort]]
    return problems unless key

    # Blank values (no name/grade) go last in either direction
    present, blank = problems.to_a.partition { |p| !key.call(p).nil? }
    sorted = present.sort_by { |p| [ key.call(p), p.id ] }
    sorted.reverse! if params[:dir] == "desc"
    sorted + blank
  end
end
