class PagesController < ApplicationController
  def privacy
  end

  def about
  end

  def ethics
  end

  def contribute
  end

  def offline_status
  end

  def downloads
    areas = Area.published.order(:name).to_a
    versions = Area.offline_versions(areas)
    problem_counts = Problem.with_location.where(area_id: areas.map(&:id)).group(:area_id).count

    @offline_areas = areas.map do |area|
      {
        slug: area.slug,
        name: area.name,
        version: versions[area.id],
        problemCount: problem_counts[area.id].to_i,
        dataUrl: area_offline_data_path(area),
        areaUrl: area_path(area)
      }
    end
  end
end
