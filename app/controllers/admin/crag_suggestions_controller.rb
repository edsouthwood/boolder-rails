# Crags suggested by visitors, with the photos and problems sent for them. Accepting one
# makes a new unpublished area holding its photos (as undrawn topos) and problems (still
# pending, one by one). Super admins only, as for any new area.
class Admin::CragSuggestionsController < Admin::BaseController
  before_action :require_super_admin
  before_action :set_crag_suggestion, only: [ :show, :accept, :close ]

  def index
    @state = params[:state].presence_in(CragSuggestion::STATES) || (params.key?(:state) ? nil : "pending")
    @crag_suggestions = CragSuggestion.includes(:area).order(id: :desc)
    @crag_suggestions = @crag_suggestions.where(state: @state) if @state
    @crag_suggestions = @crag_suggestions.page(params[:page]).per(50)
    @photo_counts = PhotoContribution.where(crag_suggestion_id: @crag_suggestions.map(&:id)).group(:crag_suggestion_id).count
    @problem_counts = Contribution.where(crag_suggestion_id: @crag_suggestions.map(&:id)).group(:crag_suggestion_id).count
  end

  def show
    @photos = @crag_suggestion.photo_contributions.includes(:topo, photo_attachment: :blob, topo: { photo_attachment: :blob }).order(:id)
    @problems = @crag_suggestion.contributions.order(:id)
    # Is it a crag we already have? Only worth asking before it's accepted (after, it's itself)
    @nearest_area, @nearest_metres = Area.nearest_to(@crag_suggestion.location, within: 2000) if @crag_suggestion.pending?
  end

  def accept
    area = @crag_suggestion.accept!(reviewed_by: current_admin_user&.username, name: params[:area_name])
    return redirect_to(admin_crag_suggestion_path(@crag_suggestion), flash: { error: "Already reviewed." }) unless area

    CragSuggestionMailer.with(crag_suggestion: @crag_suggestion).reviewed_email.deliver_later
    link = helpers.link_to("Photos to draw at #{area.name}", admin_area_topos_path(area_slug: area.slug, undrawn: 1), class: "underline")
    flash[:notice] = "New area \"#{ERB::Util.html_escape(area.name)}\" created, unpublished. #{link}; its problems are listed below to review.".html_safe
    redirect_to admin_crag_suggestion_path(@crag_suggestion)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_crag_suggestion_path(@crag_suggestion), flash: { error: "Couldn't accept: #{e.record.errors.full_messages.to_sentence}" }
  end

  def close
    if @crag_suggestion.close!(reviewed_by: current_admin_user&.username, note: params[:moderator_note])
      CragSuggestionMailer.with(crag_suggestion: @crag_suggestion).reviewed_email.deliver_later
      flash[:notice] = "Declined \"#{@crag_suggestion.name}\"."
    else
      flash[:error] = "Already reviewed."
    end
    redirect_to admin_crag_suggestions_path
  end

  private

  def set_crag_suggestion
    @crag_suggestion = CragSuggestion.find(params[:id])
  end
end
