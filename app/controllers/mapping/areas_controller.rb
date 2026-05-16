class Mapping::AreasController < ApplicationController
  def index
    @areas = Area.published.
      map { |a| OpenStruct.new(
          area: a,
          count: a.problems.incomplete.count,
        )
      }.
      sort_by { |area_with_count| I18n.transliterate(area_with_count.area.name) }
  end
end
