class Admin::ToposController < Admin::BaseController
  before_action :require_super_admin,      only: [ :new, :create ]
  before_action :require_topo_area_access, only: [ :show, :edit, :update, :destroy, :workbench, :quick_problem, :choose_boulder ]
  before_action :set_area_and_check_access, only: [ :index ]

  def index
    @topos = Topo.in_area(@area).includes(lines: :problem).order(id: :desc)
    @undrawn_count = @topos.undrawn.count
    @topos = @topos.undrawn if params[:undrawn] == "1"
  end

  def new
    @topo = Topo.new
  end

  def create
    ActiveRecord::Base.transaction do
      topo = Topo.new(topo_params)

      if params[:topo][:ignore_metadata] == "1"
        topo.photo = params[:topo][:photo]
        topo.save!
      else
        photo = params[:topo][:photo]
        metadata = params[:topo][:metadata]
        metadata_hash = JSON.parse(metadata.read)

        if Pathname(photo.original_filename).sub_ext("").to_s != Pathname(metadata.original_filename).sub_ext("").to_s
          raise "filenames don't match"
        end

        topo.update(photo: photo)
        topo.update(metadata: metadata_hash)

        problems = Problem.find(metadata_hash["problem_ids"])
        problems = problems + problems.flat_map(&:variants)

        problems.uniq.each do |problem|
          Line.create(topo_id: topo.id, problem_id: problem.id)
        end
      end

      flash[:notice] = "Topo created"
      redirect_to edit_admin_topo_path(topo)
    end
  end

  # One page to draw every line on a photo: pick or create problems, draw, save, next
  def workbench
    set_topo
    @area = Area.find_by(id: @topo.area_id)
    unless @area
      flash[:error] = "This photo isn't in an area yet. Draw a line on it from a problem first."
      return redirect_to edit_admin_topo_path(@topo)
    end

    @lines = @topo.lines.includes(problem: :circuit).to_a
    @boulder_id = @topo.matched_boulder_id
    @boulder = Boulder.find_by(id: @boulder_id)
    @candidates = workbench_candidates
    @area_boulders = @area.boulders.order(Arel.sql("name IS NULL, lower(name), id")).pluck(:id, :name)
    undrawn = Topo.in_area(@area).undrawn.where.not(id: @topo.id).reorder(:id)
    @next_topo = undrawn.where("topos.id > ?", @topo.id).first || undrawn.first
    @undrawn_count = undrawn.count
  end

  # Workbench: create a problem in the photo's area and a line for it on this photo
  def quick_problem
    set_topo
    area = Area.find(@topo.area_id)
    problem = area.problems.new(name: params[:name], grade: params[:grade].presence, steepness: "other",
      boulder: Boulder.find_by(id: @topo.matched_boulder_id, area_id: area.id))
    problem.location = @topo.location_for(problem)

    line = Problem.transaction do
      problem.save!
      Line.create!(problem: problem, topo: @topo)
    end
    render json: line.workbench_json, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join("; ") }, status: :unprocessable_entity
  end

  # Workbench: tie the photo to one of its area's boulders (blank unties it), so the
  # workbench suggests that boulder's problems and puts new problems on it
  def choose_boulder
    set_topo
    area_id = @topo.area_id
    boulder = params[:boulder_id].presence && Boulder.find_by(id: params[:boulder_id], area_id: area_id)
    if params[:boulder_id].present? && !boulder
      flash[:error] = "That boulder isn't in this photo's area."
    else
      @topo.choose_boulder!(boulder)
      flash[:notice] = boulder ? "Photo tied to #{boulder.display_name}" : "Photo untied from its boulder"
    end
    redirect_to workbench_admin_topo_path(@topo)
  end

  def show
    set_topo
    redirect_to edit_admin_topo_path(@topo)
  end

  def edit
    set_topo
    session[:last_topo_visited] = @topo.id
  end

  def update
    set_topo

    if @topo.update(topo_params)
      flash[:notice] = "Topo updated"
      redirect_to edit_admin_topo_path(@topo)
    else
      flash[:error] = @topo.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  def destroy
    set_topo
    # Read before destroying: the lines (and so the problems) go with the topo.
    area = @topo.area_id && Area.find_by(id: @topo.area_id)

    if @topo.destroy
      flash[:notice] = "Topo destroyed"
      if area
        redirect_to admin_area_problems_path(area_slug: area.slug, circuit_id: "first")
      else
        redirect_to admin_areas_path
      end
    else
      flash[:error] = @topo.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  private

  def set_area_and_check_access
    @area = Area.find_by!(slug: params[:area_slug])
    require_area_access(@area.slug)
  end

  def require_topo_area_access
    area_id = Topo.find(params[:id]).area_id
    slug = area_id && Area.find(area_id).slug
    # A topo with no lines belongs to no area, so only super admins may touch it.
    slug ? require_area_access(slug) : require_super_admin
  end

  # Area problems not yet on this photo: those assigned to its boulder (by a problem list
  # or by hand) first, then ones located on or near it, then ones still missing a line,
  # then the rest
  def workbench_candidates
    problems = @area.problems.shown.where.not(id: @lines.map(&:problem_id)).includes(:circuit).to_a
    near_ids = []
    if (polygon = Boulder.where(id: @boulder_id).pick(:polygon))
      near_ids = @area.problems.where("ST_DWithin(problems.location, ST_GeogFromText(?), 5)", polygon.as_text).pluck(:id)
    end
    on_boulder = ->(p) { @boulder_id && p.boulder_id == @boulder_id }

    problems.
      sort_by { |p| [ on_boulder.(p) ? 0 : 1, near_ids.include?(p.id) ? 0 : 1, p.has_line ? 1 : 0, p.name_with_fallback.to_s.downcase ] }.
      map { |p| { id: p.id, name: p.name_with_fallback, grade: p.grade, near: on_boulder.(p) || near_ids.include?(p.id),
                  on_boulder: on_boulder.(p), has_line: p.has_line } }
  end

  def topo_params
    params.require(:topo).permit(:published, :photo)
  end

  def set_topo
    @topo = Topo.find(params[:id])
  end
end
