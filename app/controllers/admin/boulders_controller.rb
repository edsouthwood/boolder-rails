class Admin::BouldersController < Admin::BaseController
  before_action :set_area_from_slug, only: [ :index, :editor, :create ]
  before_action :set_boulder,        only: [ :update, :destroy ]
  before_action -> { require_area_access((@area || @boulder.area).slug) }

  # Which boulders still need photos or lines (most urgent first)
  def index
    @progress = BoulderProgress.new(@area)
    @show_all = params[:show] == "all"
  end

  def editor
    @boulder_count = @area.boulders.placed.count
    # Names from a problem list that haven't been drawn yet
    @unplaced = @area.boulders.unplaced.where.not(name: nil).order(:name).
      left_joins(:problems).group(:id).select("boulders.*, count(problems.id) AS problems_count").
      map { |boulder| { id: boulder.id, name: boulder.name, problems: boulder.problems_count } }
    @focus_id = params[:boulder].to_i if params[:boulder].present?
    @place_id = params[:place].to_i if params[:place].present?
    @maptiler_key = Rails.application.credentials.dig(:maptiler, :api_key)
    @azure_maps_key = Rails.application.credentials.dig(:azure_maps, :subscription_key)
    @mapbox_key = ENV["MAPBOX_DEV_ACCESS_KEY"]
  end

  # Draws a new outline, or gives a listed (not yet drawn) boulder its outline
  def create
    boulder = params[:boulder_id].present? ? @area.boulders.unplaced.find(params[:boulder_id]) : @area.boulders.build
    boulder.polygon = build_polygon(params[:coordinates])
    boulder.save!
    render json: { id: boulder.id, name: boulder.name }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Saves the outline and/or the name. Naming an outline after a listed boulder that isn't
  # drawn yet merges the two: the outline takes over that boulder's problems.
  def update
    absorbed = nil
    Boulder.transaction do
      @boulder.update!(polygon: build_polygon(params[:coordinates])) if params.key?(:coordinates)
      absorbed = rename(params[:name]) if params.key?(:name)
    end
    render json: { ok: true, name: @boulder.name, absorbed_id: absorbed&.id }
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

  def rename(raw)
    name = raw.to_s.squish.presence
    namesake = name && @boulder.area.boulders.where.not(id: @boulder.id).where("lower(name) = ?", name.downcase).first
    unless namesake
      @boulder.update!(name: name)
      return
    end
    raise ArgumentError, "#{namesake.display_name} is already on the map with that name" if namesake.placed?

    @boulder.absorb!(namesake)
    namesake
  end

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
