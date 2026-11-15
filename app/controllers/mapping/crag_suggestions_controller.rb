# "Suggest a new crag": a visitor tells us about a crag that isn't on the site, then sends
# its photos and problems on the usual forms, which file them with the suggestion.
class Mapping::CragSuggestionsController < ApplicationController
  include RemembersContributor
  include SuggestsCrags

  invisible_captcha only: [ :create ], on_spam: :handle_spam
  rate_limit to: 5, within: 1.hour, only: :create,
             with: -> { redirect_to new_mapping_crag_suggestion_path, flash: { error: t("views.mapping.crag_suggestions.new.too_many") } }

  def new
    @crag_suggestion = CragSuggestion.new(**remembered_contributor)
  end

  def create
    @crag_suggestion = CragSuggestion.new(crag_suggestion_params)
    remember_contributor(@crag_suggestion)

    if @crag_suggestion.save
      remember_crag_suggestion(@crag_suggestion)
      CragSuggestionMailer.with(crag_suggestion: @crag_suggestion).new_crag_email.deliver_later
      CragSuggestionMailer.with(crag_suggestion: @crag_suggestion).acknowledgement_email.deliver_later
      redirect_to mapping_crag_suggestion_path(@crag_suggestion)
    else
      render "new", status: :unprocessable_entity
    end
  end

  # What next: photos and problems for it. Only for the visitor who suggested it.
  def show
    @crag_suggestion = CragSuggestion.find_by(id: params[:id].to_i) if suggested_crag_ids.include?(params[:id].to_i)
    return redirect_to(new_mapping_crag_suggestion_path) unless @crag_suggestion

    @photo_count = @crag_suggestion.photo_contributions.count
    @problem_count = @crag_suggestion.contributions.count
  end

  private

  def crag_suggestion_params
    params.require(:crag_suggestion).permit(:name, :location_lat, :location_lon, :access_notes,
                                            :contributor_name, :contributor_email)
  end

  def handle_spam
    redirect_to mapping_path
  end
end
