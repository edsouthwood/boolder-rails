class Admin::MappingController < Admin::BaseController
  def dashboard
    @missing = params[:missing].presence_in(%w[ location line ]) || session[:last_missing] || "location"
    session[:last_missing] = @missing

    filtered = ->(arel, missing) { missing == "line" ? arel.without_line_only : arel.without_location }

    @areas_with_stats = Area.published.
      map { |a|
        total        = a.problems.count.to_f
        total_ascents = a.problems.sum(:ascents)
        missing_arel = filtered.call(a.problems, @missing)

        if total_ascents > 0
          completion          = 1 - missing_arel.sum(:ascents).to_f / total_ascents.to_f
          upcoming_completion = 1 - missing_arel.without_contribution_request.sum(:ascents).to_f / total_ascents.to_f
        else
          completion          = total > 0 ? 1 - missing_arel.count.to_f / total : 0.0
          upcoming_completion = total > 0 ? 1 - missing_arel.without_contribution_request.count.to_f / total : 0.0
        end

        OpenStruct.new(
          area: a,
          ascents: total_ascents,
          completion: completion,
          upcoming_completion: upcoming_completion
        )
      }.
      sort_by(&:ascents).reverse
  end
end
