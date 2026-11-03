# "Add boulder photos": visitors upload photos of boulders, one request per photo (sent by
# photo_contribution_controller.js, which reads each photo's GPS in the browser first).
# Each photo waits in the admin queue until it's accepted as a topo.
class Mapping::PhotoContributionsController < ApplicationController
  include RemembersContributor

  # invisible_captcha's timestamp is single-use, so it checks the first photo of an upload
  # session; the rest of that batch are let through by the session it started.
  invisible_captcha only: [ :create ], unless: :continuing_batch?,
                    on_spam: :handle_spam, on_timestamp_spam: :handle_timestamp_spam
  # Generous for a day at the crag with a phone full of photos, but caps an abusive client
  rate_limit to: 120, within: 1.hour, only: :create,
             with: -> { render json: { error: t("views.mapping.photo_contributions.errors.too_many") }, status: :too_many_requests }

  def new
    @photo_contribution = PhotoContribution.new(**remembered_contributor)
    @areas = Area.published.order(:name)
    @area = @areas.find_by(id: params[:area_id])
    load_wanted if @area
    @chosen_boulder_id = params[:boulder_id].to_i if params[:boulder_id].present?
  end

  def create
    @photo_contribution = PhotoContribution.new(photo_contribution_params)
    @photo_contribution.photo.attach(params[:photo]) if params[:photo].respond_to?(:content_type)
    assign_position

    remember_contributor(@photo_contribution)

    # Past the captcha (or already in its batch): the rest of the batch may follow, even if
    # this photo is refused
    session[:photo_contribution_batch] = @photo_contribution.batch if @photo_contribution.batch.to_s.match?(PhotoContribution::BATCH_FORMAT)

    if @photo_contribution.save
      notify if @photo_contribution.first_in_batch?
      render json: { id: @photo_contribution.id, boulder: @photo_contribution.boulder&.display_name,
                     located: @photo_contribution.located? }, status: :created
    else
      render json: { error: @photo_contribution.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private

  def continuing_batch?
    batch = params.dig(:photo_contribution, :batch)
    batch.present? && batch == session[:photo_contribution_batch]
  end

  # Where the photo was taken, and the boulder it shows: the one the visitor chose from
  # the list, else the one its GPS matches. The boulder decides the area, so a photo is
  # filed correctly even when the wrong area was chosen.
  def assign_position
    @photo_contribution.area = Area.published.find_by(id: @photo_contribution.area_id)
    if (chosen = published_boulders.find_by(id: params.dig(:photo_contribution, :boulder_id).presence))
      @photo_contribution.boulder = chosen
      @photo_contribution.boulder_chosen = true
      @photo_contribution.area = chosen.area
    end

    lat = Float(params[:lat], exception: false)
    lon = Float(params[:lon], exception: false)
    return unless lat&.between?(-90, 90) && lon&.between?(-180, 180)

    @photo_contribution.location = FACTORY.point(lon, lat)
    @photo_contribution.location_source = params[:location_source].presence_in(PhotoContribution::LOCATION_SOURCES) || "photo"
    heading = Float(params[:heading], exception: false)
    @photo_contribution.heading = heading if heading&.between?(0, 360)

    @photo_contribution.gps_boulder = published_boulders.nearest_to(lat, lon)
    return if @photo_contribution.boulder_chosen || @photo_contribution.gps_boulder.nil?

    @photo_contribution.boulder = @photo_contribution.gps_boulder
    @photo_contribution.area = @photo_contribution.gps_boulder.area
  end

  def published_boulders
    Boulder.joins(:area).merge(Area.published)
  end

  def notify
    PhotoContributionMailer.with(photo_contribution: @photo_contribution).new_photos_email.deliver_later
    PhotoContributionMailer.with(photo_contribution: @photo_contribution).acknowledgement_email.deliver_later
  end

  # Boulders with no photo at all (by the same rule as the admin Boulders list), most
  # problems first. Only named ones or ones with problems: an unnamed outline means nothing
  # to a visitor, and its photos can still come in with "another boulder" and GPS.
  def load_wanted
    @wanted = BoulderProgress.new(@area).rows.
      select { |row| row.photos.empty? && (row.boulder.name.present? || row.problems.any?) }.
      sort_by { |row| [ -row.problems.size, row.boulder.name.to_s.downcase ] }
    @awaiting_review = PhotoContribution.pending.where(boulder_id: @wanted.map { |row| row.boulder.id }).distinct.pluck(:boulder_id).to_set
  end

  def photo_contribution_params
    params.require(:photo_contribution).permit(:area_id, :contributor_name, :contributor_email, :comment, :batch)
  end

  # invisible_captcha honeypot tripped: drop it without saying why
  def handle_spam
    render json: { error: "rejected" }, status: :unprocessable_entity
  end

  # Sent too soon after the page loaded; the uploader waits and tries again
  def handle_timestamp_spam
    render json: { error: "too_fast" }, status: :unprocessable_entity
  end
end
