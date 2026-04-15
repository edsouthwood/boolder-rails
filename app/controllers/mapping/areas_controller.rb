class Mapping::AreasController < ApplicationController
  def index
    @areas = Area.published.
      map { |a| OpenStruct.new(
          area: a,
          count: ContributionRequest.open.joins(:problem).where(problems: { area_id: a.id }).where(what: "photo").count +
                 a.problems.where(location: nil).without_contribution_request.count,
        )
      }.
      sort_by { |area_with_count| I18n.transliterate(area_with_count.area.name) }
  end
end
