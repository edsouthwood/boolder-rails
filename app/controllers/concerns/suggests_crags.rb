# The crags this visitor suggested in this session. Only those can have photos and problems
# sent for them, so nobody can file things against someone else's suggestion.
module SuggestsCrags
  extend ActiveSupport::Concern

  MAX_REMEMBERED = 5

  private

  def remember_crag_suggestion(crag_suggestion)
    session[:crag_suggestion_ids] = ([ crag_suggestion.id ] + suggested_crag_ids).first(MAX_REMEMBERED)
  end

  def suggested_crag_ids
    Array(session[:crag_suggestion_ids]).map(&:to_i)
  end

  # This visitor's pending suggestion with that id, or nil
  def own_crag_suggestion(id)
    id = id.to_i
    CragSuggestion.pending.find_by(id: id) if id.positive? && suggested_crag_ids.include?(id)
  end
end
