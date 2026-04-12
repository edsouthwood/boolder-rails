class Admin::ImportsController < Admin::BaseController
  before_action :require_import_area_access, only: [:apply]

  def index
    @imports = Import.all.order(id: :desc)
  end

  def new
    @import = Import.new
  end

  def create
    @import = Import.new(import_params)

    if @import.save
      redirect_to [ :admin, @import ]
    else
      flash[:error] = @import.errors.full_messages.join("; ")
      render :new
    end
  end

  def show
    @import = Import.find(params[:id])

    @updates = if @import.applied?
      @import.associated_audits.map { |audit| [ audit.auditable, audit.audited_changes, audit ] }
    else
      @import.objects_to_update.map { |object| [ object, object.changes ] }
    end
  end

  def apply
    @import = Import.find(params[:id])

    if @import.objects_to_update.any? { |object| object.conflicting_updated_at }
      flash[:error] = "Cannot apply import when there is a conflict"
      redirect_to admin_import_path(@import)
      return
    end

    ActiveRecord::Base.transaction do
      @import.objects_to_update.each do |object|
        object.import = @import
        object.save!
      end

      @import.update!(applied_at: Time.now)
    end

    flash[:success] = "Import successful"
    redirect_to admin_import_path(@import)
  end

  private

  def require_import_area_access
    import = Import.find(params[:id])
    area_id = import.objects_to_update.map(&:area_id).compact.first
    area = Area.find(area_id)
    require_area_access(area.slug)
  end

  def import_params
    params.require(:import).permit(:applied_at, :file)
  end
end
