class Admin::AreasController < Admin::BaseController
  before_action :require_super_admin, only: [:new, :create, :destroy]
  before_action :set_area,            only: [:show, :edit, :update, :destroy]
  before_action -> { require_area_access(@area.slug) }, only: [:edit, :update]

  def index
    sort = params[:sort] == "id" ? :id : :name
    @areas = if (slugs = current_admin_user.accessible_area_slugs)
      Area.where(slug: slugs).order(sort)
    else
      Area.order(sort)
    end
  end

  def new
    @area = Area.new(published: false, priority: 3)
  end

  def create
    @area = Area.new
    @area.assign_attributes(area_params)
    @area.tags = params[:area][:joined_tags].to_s.split(",")

    if @area.save
      flash[:notice] = "Area created"
      redirect_to edit_admin_area_path(@area)
    else
      flash.now[:error] = @area.errors.full_messages.join("; ")
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    set_area
  end

  def show
    set_area
    redirect_to admin_area_problems_path(@area, circuit_id: "first")
  end

  def update
    set_area

    @area.assign_attributes(area_params)
    @area.tags = params[:area][:joined_tags].split(",")

    if cover = params[:area][:cover]
      @area.cover = params[:area][:cover]
    end

    if @area.save
      flash[:notice] = "Area updated"
      redirect_to edit_admin_area_path(@area)
    else
      flash[:error] = @area.errors.full_messages.join("; ")
      render "edit", status: :unprocessable_entity
    end
  end

  def destroy
    set_area
    @area.destroy!
    flash[:notice] = "Area deleted"
    redirect_to admin_areas_path
  end

  private

  def area_params
    params.require(:area).
      permit(:name, :slug, :published, :priority, :short_name, :description_fr, :description_en, :warning_fr, :warning_en)
  end

  def set_area
    @area = Area.find_by(slug: params[:slug])
  end
end
