module Areas
  class OfflineDataController < ApplicationController
    def show
      area = Area.find_by!(slug: params[:slug])

      topo_ids = Topo.published
        .joins(lines: :problem)
        .where(problems: { area_id: area.id })
        .distinct
        .pluck(:id)

      topos = Topo.where(id: topo_ids)

      render json: {
        slug: area.slug,
        name: area.name,
        topo_count: topos.count,
        topo_urls: topos.map { |topo| topo_proxy_url(topo, locale: nil) }
      }
    end
  end
end
