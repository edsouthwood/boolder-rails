class Mapping::ContributionsController < ApplicationController
  include RemembersContributor

  invisible_captcha only: [ :create ], on_spam: :handle_spam

  def show
    @contribution = Contribution.find(params[:id])
  end

  def new
    @contribution = Contribution.new(**remembered_contributor, problem_id: params[:problem_id],
                                     area: published_area(params[:area_id]))
    @area_topos = area_topos_for_problem(params[:problem_id])
    @recent_photos = recent_photos_for(@contribution)
  end

  def create
    @contribution = Contribution.new(contribution_params)
    # Only a published area can be named by id; an unknown crag goes in area_name.
    @contribution.area = published_area(@contribution.area_id)
    reuse_recent_photo

    remember_contributor(@contribution)

    if @contribution.save
      remember_photo(@contribution)
      flash[:notice] = t("views.mapping.contributions.new.flash_success")

      ContributeMailer.with(contribution: @contribution).new_contribution_email.deliver_later
      ContributeMailer.with(contribution: @contribution).acknowledgement_email.deliver_later

      # Unlisted-problem submissions have no problem to return to; show the contribution instead.
      redirect_to(@contribution.problem ? [ :mapping, @contribution.problem ] : [ :mapping, @contribution ])
    else
      @area_topos = area_topos_for_problem(@contribution.problem_id)
      @recent_photos = recent_photos_for(@contribution)
      render "new", status: :unprocessable_entity
    end
  end

  private

  # A visitor's own photos from the last day, so the next problem on the same face can be
  # drawn on the same photo instead of a new one each time. Accepting them then puts every
  # line on one topo, as drawn (ContributionImporter matches the photo by its checksum).
  RECENT_PHOTOS = 12
  RECENT_PHOTO_WINDOW = 1.day

  def remember_photo(contribution)
    return unless contribution.photos.attached?

    session[:contribution_photo_ids] = ([ contribution.id ] + recent_photo_ids).first(RECENT_PHOTOS)
  end

  def recent_photo_ids
    Array(session[:contribution_photo_ids]).map(&:to_i)
  end

  # Only this visitor's, only recent, and only at the same crag when that's known. One per
  # photo: drawing two problems on one photo makes two contributions sharing a file.
  def recent_photos_for(contribution)
    ids = recent_photo_ids
    return [] if ids.empty?

    area_id = contribution.problem&.area_id || contribution.area_id
    candidates = Contribution.where(id: ids, created_at: RECENT_PHOTO_WINDOW.ago..).
      includes(:problem, photos_attachments: :blob).order(id: :desc).to_a
    candidates.select! { |c| (c.problem&.area_id || c.area_id) == area_id } if area_id
    candidates.select { |c| c.photos.attached? }.uniq { |c| c.photos.first.blob_id }
  end

  # The form's "your recent photos" pick: attach that stored file again (no new upload).
  # Ignored when a new photo was uploaded too, or it isn't one of this visitor's.
  def reuse_recent_photo
    id = params.dig(:contribution, :source_contribution_id).to_i
    return if id.zero? || @contribution.photos.attached? || !recent_photo_ids.include?(id)

    source = Contribution.find_by(id: id)
    return unless source&.photos&.attached?

    @contribution.photos.attach(source.photos.first.blob)
    @contribution.existing_topo_id = nil
    # Where that photo was taken, as read from it the first time
    @contribution.location = source.location if @contribution.location.blank?
  end

  # invisible_captcha honeypot tripped — silently drop and send the bot home.
  def handle_spam
    redirect_to mapping_path
  end

  def published_area(id)
    Area.published.find_by(id: id) if id.present?
  end

  def area_topos_for_problem(problem_id)
    problem = Problem.find_by(id: problem_id)
    return [] unless problem
    return [] unless problem.area.published

    topo_ids = Line.joins(:problem)
                   .where(problems: { area_id: problem.area_id })
                   .pluck(:topo_id)
                   .uniq
    Topo.published.where(id: topo_ids).order(id: :desc)
  end

  def contribution_params
    params.require(:contribution).permit(
      :location_lat, :location_lon, :comment, :problem_id, :contributor_name, :contributor_email,
      :problem_name, :problem_url, :ukc_url, :line_coordinates, :start_holds, :excluded_areas, :existing_topo_id,
      :area_id, :area_name, photos: [], line_drawings: []
    )
  end
end
